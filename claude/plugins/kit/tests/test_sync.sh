. "$(dirname "$0")/helpers.sh"

OFFICIAL='.marketplaces = [{"name":"official","source":"github","repo":"x/official"}]'
with_a() { on "$1" fake_set "${OFFICIAL} | .plugins = [{\"id\":\"a@official\",\"enabled\":true}]"; }
setup_ab_with_a() {
  t_remote; t_clone A; t_clone B
  with_a A
  on A kit sync
  on B kit sync
}
log_of() { cat "$(state_file "$1" sync.log)" 2>/dev/null; }

s_propagate_add() {
  t_remote; t_clone A; t_clone B
  with_a A
  on A kit sync
  assert_json_eq "$(remote_manifest | jq -c '{marketplaces, plugins}')" \
    '{"marketplaces":{"official":{"source":"github","repo":"x/official"}},"plugins":{"a@official":true}}' "A の追加がリモートに届く"
  assert_eq "$(git --git-dir="${T_TMP}/remote.git" log -1 --format=%s master)" "chore(kit): sync from $(hostname -s)" "kit のコミット"
  on B kit sync
  assert_contains "$(calls_of B)" "claude plugin marketplace add x/official --scope user" "B にマーケットプレイスが入る"
  assert_contains "$(calls_of B)" "claude plugin install a@official -s user --json" "B にプラグインが入る"
  assert_json_eq "$(manifest_of B | jq -c .plugins)" '{"a@official":true}' "B の manifest も同じ"
  assert_json_eq "$(jq -c .plugins "$(state_file B base.json)")" '{"a@official":true}' "B の base も合意する"
}
s_propagate_remove() {
  setup_ab_with_a
  on B fake_set '.plugins = []'
  on B kit sync
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{}' "B での削除がリモートに届く"
  on A kit sync
  assert_contains "$(calls_of A)" "claude plugin uninstall a@official -s user" "A からも削除される"
}
s_conflict() {
  setup_ab_with_a
  on A fake_set '.plugins[0].enabled = false'
  on A kit sync
  on B fake_set '.plugins = []'
  on B kit sync
  assert_contains "$(calls_of B)" "claude plugin disable a@official -s user" "衝突は残す側（false）を採って B に入れ直す"
  assert_contains "$(notices_of B)" "衝突" "衝突を通知する"
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":false}' "リモートは false のまま"
}
s_offline() {
  t_remote; t_clone A
  with_a A
  git -C "${T_TMP}/A/dotfiles" remote set-url origin "${T_TMP}/nowhere.git"
  on A kit sync
  assert_json_eq "$(manifest_of A | jq -c .plugins)" '{"a@official":true}' "オフラインでも manifest に書く"
  assert_eq "$(git -C "${T_TMP}/A/dotfiles" rev-list --count HEAD)" "1" "オフラインではコミットしない"
  assert_json_eq "$(jq -c .plugins "$(state_file A base.json)")" '{}' "push できていない変更は base に入れない"
  git -C "${T_TMP}/A/dotfiles" remote set-url origin "${T_TMP}/remote.git"
  on A kit sync
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true}' "オンラインに戻ったら push する"
}
s_push_rejected_once() {
  t_remote; t_clone A
  printf '#!/bin/sh\nif [ -f reject-once ]; then rm -f reject-once; echo rejected >&2; exit 1; fi\nexit 0\n' \
    >"${T_TMP}/remote.git/hooks/pre-receive"
  chmod +x "${T_TMP}/remote.git/hooks/pre-receive"
  touch "${T_TMP}/remote.git/reject-once"
  with_a A
  on A kit sync
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true}' "1 回拒否されても再試行で push できる"
  assert_contains "$(log_of A)" "sync: push rejected, retrying" "再試行したことがログに残る"
}
s_diverged_kit_only() {
  t_remote; t_clone A; t_clone B
  printf '#!/bin/sh\nexit 1\n' >"${T_TMP}/remote.git/hooks/pre-receive"
  chmod +x "${T_TMP}/remote.git/hooks/pre-receive"
  with_a A
  on A kit sync
  rm "${T_TMP}/remote.git/hooks/pre-receive"
  on B fake_set "${OFFICIAL} | .plugins = [{\"id\":\"b@official\",\"enabled\":true}]"
  on B kit sync
  on A kit sync
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true,"b@official":true}' "kit のコミットだけの分岐は付け直して push する"
}
s_non_master() {
  setup_ab_with_a
  git -C "${T_TMP}/B/dotfiles" checkout -q -b feat
  n="$(git -C "${T_TMP}/B/dotfiles" rev-list --count HEAD)"
  on B fake_set '.plugins += [{"id":"c@official","enabled":true}]'
  on B kit sync
  assert_eq "$(manifest_of B | jq -r '.plugins["c@official"]')" "true" "master 以外でも manifest に書く"
  assert_eq "$(git -C "${T_TMP}/B/dotfiles" rev-list --count HEAD)" "$n" "master 以外ではコミットしない"
  assert_contains "$(notices_of B)" "以外のブランチ" "通知する"
}
s_foreign_unpushed() {
  setup_ab_with_a
  echo mine >"${T_TMP}/B/dotfiles/mine.txt"
  git -C "${T_TMP}/B/dotfiles" add mine.txt
  git -C "${T_TMP}/B/dotfiles" commit -q -m "feat: mine"
  on B fake_set '.plugins += [{"id":"d@official","enabled":true}]'
  on B kit sync
  assert_eq "$(git -C "${T_TMP}/B/dotfiles" log -1 --format=%s)" "chore(kit): sync from $(hostname -s)" "コミットまではする"
  assert_eq "$(remote_manifest | jq -r '.plugins["d@official"] // "none"')" "none" "push はしない"
  assert_contains "$(notices_of B)" "push していないコミット" "通知する"
}
s_dirty_conflict() {
  setup_ab_with_a
  echo "from A" >"${T_TMP}/A/dotfiles/other.txt"
  git -C "${T_TMP}/A/dotfiles" commit -q -am "feat: other"
  git -C "${T_TMP}/A/dotfiles" push -q origin master
  echo "B local" >"${T_TMP}/B/dotfiles/other.txt"
  head_before="$(git -C "${T_TMP}/B/dotfiles" rev-parse HEAD)"
  on B kit sync
  assert_eq "$(git -C "${T_TMP}/B/dotfiles" rev-parse HEAD)" "$head_before" "取り込まない"
  assert_eq "$(cat "${T_TMP}/B/dotfiles/other.txt")" "B local" "未コミットの変更は残る"
  assert_contains "$(notices_of B)" "ぶつかる" "通知する"
}
s_failure_cap() {
  setup_ab_with_a
  on A fake_set '.plugins += [{"id":"e@official","enabled":true}]'
  on A kit sync
  on B fake_set '.fail = ["e@official"]'
  on B kit sync; on B kit sync; on B kit sync
  assert_eq "$(count_calls B "install e@official")" "3" "3 回まで試す"
  on B kit sync
  assert_eq "$(count_calls B "install e@official")" "3" "上限に達したら試さない"
  assert_contains "$(notices_of B)" "kit sync --retry plugins/e@official" "再開の方法を通知する"
  on B kit sync --retry plugins/e@official
  assert_eq "$(count_calls B "install e@official")" "4" "--retry で再開する"
}
count_calls() { grep -c -- "$2" <<<"$(calls_of "$1")" || true; }
s_command_source() {
  setup_ab_with_a
  on A fake_set '.plugins += [{"id":"g@official","enabled":true}]'
  on A kit sync
  on B fake_set '.command_source = ["g@official"]'
  on B kit sync
  assert_contains "$(notices_of B)" "承認が必要です" "承認が必要と通知する"
  assert_json_eq "$(jq -c .failures "$(state_file B sync.json)")" '{}' "失敗として数えない"
}
s_throttle_and_lock() {
  t_remote; t_clone A
  with_a A
  export KIT_THROTTLE_SECONDS=600
  on A kit sync
  on A kit sync
  assert_contains "$(log_of A)" "sync: throttled" "変更がなく 10 分以内なら何もしない"
  mkdir -p "$(state_file A lock)"
  on A kit sync --force
  assert_contains "$(log_of A)" "sync: another sync is running" "ロック中は何もしない"
  touch -t 202001010000 "$(state_file A lock)"
  : >"$(state_file A sync.log)"
  on A kit sync --force
  assert_contains "$(log_of A)" "sync: done" "古いロックは無視して動く"
}
s_concurrent() {
  t_remote; t_clone A
  with_a A
  (t_machine A; export FAKE_SLOW=1; kit sync) &
  sleep 0.3
  (t_machine A; export FAKE_SLOW=1; kit sync) &
  wait
  assert_contains "$(log_of A)" "sync: another sync is running" "同時に起動しても 1 つだけ動く（Review Focus 5）"
  jq -e . "$(state_file A base.json)" >/dev/null; assert_eq "$?" "0" "base.json は壊れない"
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true}' "manifest は正しく push される"
}
s_discovery() {
  setup_ab_with_a
  m="${T_TMP}/A/dotfiles/claude/manifest.json"
  jq '.discovery.watch += ["x/y"]' "$m" >"${m}.tmp" && mv "${m}.tmp" "$m"
  on A kit sync
  on B kit sync
  assert_json_eq "$(manifest_of B | jq -c .discovery.watch)" '["x/y"]' "A で足したウォッチが B に届く"
  m="${T_TMP}/B/dotfiles/claude/manifest.json"
  jq '.discovery.dismissed += [{"id":"p@m","at":"2026-10-22","reason":""}]' "$m" >"${m}.tmp" && mv "${m}.tmp" "$m"
  on B kit sync
  on A kit sync
  assert_json_eq "$(manifest_of A | jq -c '[.discovery.watch, [.discovery.dismissed[].id]]')" '[["x/y"],["p@m"]]' "両方の編集が残る"
}
s_dry_run() {
  t_remote; t_clone A; t_clone B
  with_a A
  on A kit sync
  out="$(on B kit sync --dry-run)"
  assert_contains "$out" "add plugins/a@official" "計画を表示する"
  assert_not_contains "$(calls_of B)" "install" "何も入れない"
  assert_eq "$(manifest_of B)" "" "manifest を書かない"
  out="$(on A kit status)"
  assert_contains "$out" "最後に成功した同期" "status は最後の同期を表示する"
  assert_contains "$out" "同期の計画" "status は計画を表示する"
}
s_broken_local_state() {
  setup_ab_with_a
  (t_machine A; export FAKE_BROKEN=1; kit sync)
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true}' "ローカル状態が読めなければ何も消さない（Review Focus 1）"
  assert_contains "$(notices_of A)" "読み取れなかった" "通知する"
}
s_invalid_manifest() {
  setup_ab_with_a
  m="${T_TMP}/A/dotfiles/claude/manifest.json"
  jq '.discovery.watch += ["x/y"]' "$m" >"${m}.tmp" && mv "${m}.tmp" "$m"
  on A kit sync
  printf '<<<<<<< HEAD\n{\n' >"$m"
  on A kit sync
  assert_contains "$(notices_of A)" "正しい JSON ではない" "壊れた manifest は通知する（Review Focus 2）"
  assert_json_eq "$(remote_manifest | jq -c .discovery.watch)" '["x/y"]' "discovery を消さない"
}
s_untracked_then_remote() {
  t_remote; t_clone A; t_clone B
  git -C "${T_TMP}/B/dotfiles" remote set-url origin "${T_TMP}/nowhere.git"
  on B fake_set "${OFFICIAL} | .plugins = [{\"id\":\"b@official\",\"enabled\":true}]"
  on B kit sync
  with_a A
  on A kit sync
  git -C "${T_TMP}/B/dotfiles" remote set-url origin "${T_TMP}/remote.git"
  on B kit sync
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true,"b@official":true}' "未追跡の manifest があっても両方残る（Review Focus 3）"
  assert_contains "$(calls_of B)" "claude plugin install a@official" "B に A の変更が入る"
}

t_scenario "追加が他のマシンに届く" s_propagate_add
t_scenario "削除が他のマシンに届く" s_propagate_remove
t_scenario "衝突は残す側を採る" s_conflict
t_scenario "オフライン" s_offline
t_scenario "push が 1 回拒否される" s_push_rejected_once
t_scenario "kit のコミットだけで分岐" s_diverged_kit_only
t_scenario "master 以外のブランチ" s_non_master
t_scenario "kit 以外の未 push コミット" s_foreign_unpushed
t_scenario "未コミットの変更とぶつかる" s_dirty_conflict
t_scenario "3 回失敗したら止める" s_failure_cap
t_scenario "コマンドを実行するプラグイン" s_command_source
t_scenario "間引きとロック" s_throttle_and_lock
t_scenario "同時に起動しても 1 つだけ動く" s_concurrent
t_scenario "discovery の編集を両方残す" s_discovery
t_scenario "dry-run と status" s_dry_run
t_scenario "ローカル状態が読めないと中止する" s_broken_local_state
t_scenario "manifest が壊れていたら中止する" s_invalid_manifest
t_scenario "未追跡の manifest とリモートの manifest" s_untracked_then_remote
t_done

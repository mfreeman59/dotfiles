. "$(dirname "$0")/helpers.sh"
# 最終レビューで再現された「1 台のマシンの出来事が全マシンでの削除・消失に広がる」経路の回帰テスト

OFFICIAL='.marketplaces = [{"name":"official","source":"github","repo":"x/official"}]'
FOUR="${OFFICIAL} | .plugins = [{\"id\":\"a@official\",\"enabled\":true},{\"id\":\"b@official\",\"enabled\":true},{\"id\":\"c@official\",\"enabled\":true},{\"id\":\"d@official\",\"enabled\":true}]"
with_a() { on "$1" fake_set "${OFFICIAL} | .plugins = [{\"id\":\"a@official\",\"enabled\":true}]"; }
count_calls() { grep -c -- "$2" <<<"$(calls_of "$1")" || true; }

# C1: push できていない変更があるままオフラインで同期しても、後でアンインストールしない
s_offline_after_unpushed() {
  t_remote; t_clone A
  on A fake_set "$OFFICIAL"
  on A kit sync
  echo mine >"${T_TMP}/A/dotfiles/mine.txt"
  git -C "${T_TMP}/A/dotfiles" add mine.txt && git -C "${T_TMP}/A/dotfiles" commit -q -m "feat: mine"
  on A fake_set '.plugins += [{"id":"x@official","enabled":true}]'
  on A kit sync
  git -C "${T_TMP}/A/dotfiles" remote set-url origin "${T_TMP}/nowhere.git"
  on A kit sync
  git -C "${T_TMP}/A/dotfiles" remote set-url origin "${T_TMP}/remote.git"
  git -C "${T_TMP}/A/dotfiles" reset -q --hard origin/master   # ユーザーが自分のコミットを片付ける
  on A kit sync
  assert_not_contains "$(calls_of A)" "uninstall x@official" "このマシンで入れたものをアンインストールしない"
  assert_eq "$(remote_manifest | jq -r '.plugins["x@official"]')" "true" "push できていなかった追加が後で届く"
}

# C1: 古いブランチ（manifest がない）でオフライン同期しても、全部をアンインストールしない
s_offline_old_branch() {
  t_remote; t_clone A
  with_a A
  on A kit sync
  git -C "${T_TMP}/A/dotfiles" checkout -q -b old HEAD~1
  git -C "${T_TMP}/A/dotfiles" remote set-url origin "${T_TMP}/nowhere.git"
  on A kit sync
  assert_not_contains "$(calls_of A)" "uninstall" "アンインストールしない"
  assert_not_contains "$(calls_of A)" "marketplace remove" "マーケットプレイスを削除しない"
}

# C2: リモートの manifest が壊れていたら中止し、空の manifest を push しない
s_invalid_remote_manifest() {
  t_remote; t_clone A; t_clone B
  with_a A
  on A kit sync
  on B kit sync
  printf '<<<<<<< HEAD\n{\n' >"${T_TMP}/B/dotfiles/claude/manifest.json"
  git -C "${T_TMP}/B/dotfiles" commit -q -am "fix: oops"
  git -C "${T_TMP}/B/dotfiles" push -q origin master
  on A kit sync
  assert_eq "$(git --git-dir="${T_TMP}/remote.git" log -1 --format=%s master)" "fix: oops" "何もコミット・push しない"
  assert_contains "$(notices_of A)" "壊れて" "通知する"
  assert_eq "$(jq -c .plugins "$(state_file A base.json)")" '{"a@official":true}' "base.json を壊さない"
  assert_not_contains "$(calls_of A)" "uninstall" "アンインストールしない"
}

# C2: base.json が空のファイルでも、空の manifest を push しない
s_empty_base() {
  t_remote; t_clone A
  with_a A
  on A kit sync
  : >"$(state_file A base.json)"
  on A kit sync
  assert_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true}' "manifest の中身を保つ"
  jq -e 'type == "object"' "$(state_file A base.json)" >/dev/null; assert_eq "$?" "0" "base.json を作り直す"
}

# C3: マーケットプレイスのソースが変わっても、そのプラグインを全マシンでアンインストールしない
s_marketplace_change() {
  t_remote; t_clone A; t_clone B
  with_a A
  on A kit sync
  on B kit sync
  on A fake_set '.marketplaces = [{"name":"official","source":"github","repo":"x/fork"}]'
  on A kit sync
  on B kit sync
  on B kit sync
  on A kit sync
  assert_not_contains "$(calls_of B)" "marketplace remove" "B はマーケットプレイスを削除しない"
  assert_contains "$(notices_of B)" "マーケットプレイス" "B に通知する"
  assert_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true}' "プラグインは manifest に残る"
  assert_not_contains "$(calls_of A)" "uninstall" "A もアンインストールしない"
}

# C4: リモートの manifest が消されたら（git revert / git rm）、全部を消さずに止める
s_remote_manifest_deleted() {
  t_remote; t_clone A; t_clone B
  with_a A
  on A kit sync
  on B kit sync
  git -C "${T_TMP}/B/dotfiles" rm -q claude/manifest.json
  git -C "${T_TMP}/B/dotfiles" commit -q -m "revert: kit"
  git -C "${T_TMP}/B/dotfiles" push -q origin master
  on A kit sync
  assert_not_contains "$(calls_of A)" "uninstall" "アンインストールしない"
  assert_not_contains "$(calls_of A)" "marketplace remove" "マーケットプレイスを削除しない"
  assert_contains "$(notices_of A)" "見つかりません" "通知する"
}

# C4: このマシンで一度に 3 件以上消えたら（CLI の異常など）、--allow-removals まで広げない
s_mass_local_removal() {
  t_remote; t_clone A
  on A fake_set "$FOUR"
  on A kit sync
  on A fake_set '.plugins = []'
  on A kit sync
  assert_eq "$(remote_manifest | jq '.plugins | length')" "4" "manifest からは消さない"
  assert_contains "$(notices_of A)" "kit sync --allow-removals" "確定の方法を通知する"
  on A kit sync --allow-removals
  assert_eq "$(remote_manifest | jq '.plugins | length')" "0" "--allow-removals で確定する"
}

# C4: 他のマシンで一度に 3 件以上消えても、--allow-removals まで反映しない
s_mass_remote_removal() {
  t_remote; t_clone A; t_clone B
  on A fake_set "$FOUR"
  on A kit sync
  on B kit sync
  on B fake_set '.plugins = []'
  on B kit sync --allow-removals
  on A kit sync
  assert_eq "$(count_calls A "uninstall")" "0" "アンインストールしない"
  assert_contains "$(notices_of A)" "kit sync --allow-removals" "確定の方法を通知する"
  on A kit sync --allow-removals
  assert_eq "$(count_calls A "uninstall")" "4" "--allow-removals で反映する"
}

# I1: プロジェクトのディレクトリから同期しても、プロジェクト設定の enabled を manifest に書かない
s_cwd_independent() {
  t_remote; t_clone A
  with_a A
  on A kit sync
  mkdir -p "${T_TMP}/proj/.claude"
  echo '{"enabledPlugins":{"a@official":false}}' >"${T_TMP}/proj/.claude/settings.json"
  (t_machine A; cd "${T_TMP}/proj" && kit sync)
  assert_eq "$(remote_manifest | jq -r '.plugins["a@official"]')" "true" "ユーザースコープの値のまま"
}

# I2: 件名が chore(kit) のユーザーのコミットを捨てない
s_user_chore_kit_commit() {
  t_remote; t_clone A; t_clone B
  on A fake_set "$OFFICIAL"
  on A kit sync
  on B kit sync
  echo v2 >"${T_TMP}/A/dotfiles/other.txt"
  git -C "${T_TMP}/A/dotfiles" commit -q -am "chore(kit): bump plugin version"
  mine="$(git -C "${T_TMP}/A/dotfiles" rev-parse HEAD)"
  echo b >"${T_TMP}/B/dotfiles/README.md"
  git -C "${T_TMP}/B/dotfiles" commit -q -am "docs: b"
  git -C "${T_TMP}/B/dotfiles" push -q origin master
  on A fake_set '.plugins += [{"id":"y@official","enabled":true}]'
  on A kit sync
  git -C "${T_TMP}/A/dotfiles" merge-base --is-ancestor "$mine" HEAD; assert_eq "$?" "0" "ユーザーのコミットは残る"
}

# M1（Important に格上げ）: fetch / push できない状態が 24 時間以上続いたら通知する
s_persistent_offline() {
  t_remote; t_clone A
  with_a A
  git -C "${T_TMP}/A/dotfiles" remote set-url origin "${T_TMP}/nowhere.git"
  on A kit sync
  assert_not_contains "$(notices_of A)" "24 時間" "すぐには通知しない"
  f="$(state_file A sync.json)"
  jq --argjson t "$(($(date +%s) - 90000))" '.offline_since = $t' "$f" >"${f}.tmp" && mv "${f}.tmp" "$f"
  on A kit sync
  assert_contains "$(notices_of A)" "24 時間" "続いたら通知する"
  git -C "${T_TMP}/A/dotfiles" remote set-url origin "${T_TMP}/remote.git"
  on A kit sync
  assert_eq "$(jq -r '.offline_since // "none"' "$f")" "none" "回復したら記録を消す"
}

# M3（Important に格上げ）: 追跡済みの manifest を作業ツリーから消しても、discovery を消さない
s_manifest_deleted_in_worktree() {
  t_remote; t_clone A
  with_a A
  on A kit sync
  m="${T_TMP}/A/dotfiles/claude/manifest.json"
  jq '.discovery.watch += ["x/y"] | .discovery.dismissed += [{"id":"p@m","at":"2026-10-22","reason":""}]' "$m" >"${m}.tmp" && mv "${m}.tmp" "$m"
  on A kit sync
  rm "$m"
  on A kit sync
  assert_json_eq "$(remote_manifest | jq -c '[.discovery.watch, [.discovery.dismissed[].id]]')" '[["x/y"],["p@m"]]' "discovery は残る"
}

t_scenario "C1 push できていない変更があるままオフライン" s_offline_after_unpushed
t_scenario "C1 古いブランチでオフライン" s_offline_old_branch
t_scenario "C2 リモートの manifest が壊れている" s_invalid_remote_manifest
t_scenario "C2 base.json が空" s_empty_base
t_scenario "C3 マーケットプレイスのソース変更" s_marketplace_change
t_scenario "C4 リモートの manifest が消された" s_remote_manifest_deleted
t_scenario "C4 このマシンでの大量削除" s_mass_local_removal
t_scenario "C4 他のマシンでの大量削除" s_mass_remote_removal
t_scenario "I1 プロジェクトのディレクトリから同期" s_cwd_independent
t_scenario "I2 件名が chore(kit) のユーザーのコミット" s_user_chore_kit_commit
t_scenario "M1 fetch できない状態が続く" s_persistent_offline
t_scenario "M3 作業ツリーから manifest を消した" s_manifest_deleted_in_worktree
t_done

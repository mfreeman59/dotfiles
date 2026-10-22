# kit sync（設計書 §7）。

kit_sync_usage() { echo "usage: kit sync [--dry-run] [--force] [--retry <section/key>] [--allow-removals]"; }

kit_sync() {
  local dry=0 force=0 retry="" allow=0 rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --force) force=1 ;;
      --allow-removals) allow=1 ;;
      --retry)
        retry="${2:-}"
        [ -n "$retry" ] || { kit_sync_usage >&2; return 2; }
        shift ;;
      *) kit_sync_usage >&2; return 2 ;;
    esac
    shift
  done
  if ! kit_require jq || ! kit_require git; then
    echo "kit: jq と git が必要です" >&2
    return 1
  fi
  if ! kit_require claude; then
    kit_notice warn "claude コマンドが見つからないため、同期できませんでした"
    return 1
  fi
  if [ -z "$KIT_DOTFILES" ] || [ ! -e "${KIT_DOTFILES}/.git" ]; then
    kit_notice warn "dotfiles リポジトリが見つからないため、同期できませんでした"
    return 1
  fi
  kit_init_state
  if [ "$dry" = 1 ]; then
    kit_sync_run 1 0 "" "$allow"
    return $?
  fi
  if ! kit_lock; then
    kit_log "sync: another sync is running"
    return 0
  fi
  kit_sync_run 0 "$force" "$retry" "$allow"
  rc=$?
  kit_trim_log
  kit_unlock
  return "$rc"
}

# kit_managed <json>: 管理セクション 3 つだけを取り出す
kit_managed() {
  jq -c '{marketplaces: (.marketplaces // {}), plugins: (.plugins // {}), skills: (.skills // {})}' <<<"$1"
}

# kit_working_manifest: 作業ツリーの manifest（W）。ファイルがなければ HEAD の manifest
# （追跡済みの manifest を誤って消しても、discovery を「全部消した」と扱わないため）
kit_working_manifest() {
  if [ -f "$KIT_MANIFEST" ]; then jq -c . "$KIT_MANIFEST"; else kit_git_show_manifest HEAD; fi
}

kit_sync_run() {  # <dry> <force> <retry> <allow-removals>
  local dry="$1" force="$2" retry="$3" allow="$4"
  local L B W H R M up input result results st attempt online git_ok net_fail R2 L2 last up_rc since n
  if [ -f "$KIT_MANIFEST" ] && ! jq -e 'type == "object"' "$KIT_MANIFEST" >/dev/null 2>&1; then
    kit_notice warn "claude/manifest.json が正しい JSON ではないため、同期を中止しました（衝突マーカーなどを直してください）"
    return 1
  fi
  if ! L="$(kit_local_state)"; then
    kit_notice warn "このマシンのプラグイン・スキルの状態を読み取れなかったため、同期を中止しました"
    return 1
  fi
  B="$(kit_managed "$(kit_read_json "${KIT_STATE}/base.json" '{}')")"
  st="$(kit_read_json "${KIT_STATE}/sync.json" '{"last_success":0,"failures":{}}')"
  [ -n "$retry" ] && st="$(jq -c --arg k "$retry" 'del(.failures[$k])' <<<"$st")"

  # 間引き（設計書 §7.2）
  if [ "$dry" = 0 ] && [ "$force" = 0 ] && [ -z "$retry" ] && [ "$allow" = 0 ]; then
    last="$(jq -r '.last_success // 0' <<<"$st")"
    if [ $(($(kit_now) - last)) -lt "$KIT_THROTTLE_SECONDS" ] &&
      kit_json_eq "$L" "$B" &&
      kit_json_eq "$(kit_working_manifest)" "$(kit_git_show_manifest HEAD)"; then
      kit_log "sync: throttled"
      return 0
    fi
  fi

  up="$(kit_git_remote_ref)"
  for attempt in 1 2; do
    W="$(kit_working_manifest)"
    online=1
    kit_git_fetch || online=0
    if ! H="$(kit_git_base_manifest)"; then
      kit_notice warn "dotfiles の履歴にある claude/manifest.json が壊れているため、同期を中止しました"
      return 1
    fi
    # R はリモートの manifest。オフラインでも HEAD は使わず、最後に取得した ${up} を使う
    # （HEAD には push できていないこのマシンの変更が入っていることがあり、それを「合意済み」にすると後で消してしまう）
    if kit_git rev-parse -q --verify "$up" >/dev/null; then
      if ! R="$(kit_git_show_manifest "$up")"; then
        kit_notice warn "${up} の claude/manifest.json が壊れているため、同期を中止しました（リモートの manifest を直してください）"
        return 1
      fi
      if ! kit_git_has_manifest "$up" && ! kit_json_eq "$B" "$(kit_managed '{}')"; then
        kit_notice warn "${up} に claude/manifest.json が見つかりません。消されたものとして扱うと全マシンからプラグインが削除されるため、同期を止めました"
        return 1
      fi
    else
      # リモートを一度も取得していない: リモートからの変更はないものとして扱う
      R="$(jq -c --argjson b "$B" '. + $b' <<<"$H")"
    fi
    input="$(jq -nc --argjson L "$L" --argjson B "$B" --argjson R "$R" --argjson H "$H" --argjson W "$W" \
      --argjson f "$(jq -c '.failures // {}' <<<"$st")" --argjson max "$KIT_MAX_FAILURES" \
      --argjson allow "$([ "$allow" = 1 ] && echo true || echo false)" --argjson guard "$KIT_REMOVAL_GUARD" \
      '{L: $L, B: $B, R: $R, H: $H, W: $W, failures: $f, max_failures: $max, allow_removals: $allow, removal_guard: $guard}')"
    result="$(kit_merge3 "$input")"
    if [ -z "$input" ] || ! jq -e '.M | type == "object"' >/dev/null 2>&1 <<<"$result"; then
      kit_notice warn "manifest の比較に失敗したため、同期を中止しました"
      return 1
    fi
    M="$(jq -c .M <<<"$result")"
    if [ "$dry" = 1 ]; then
      kit_sync_print_plan "$result" "$W" "$online"
      return 0
    fi
    n="$(jq '.blocked_removals | length' <<<"$result")"
    if [ "$n" -gt 0 ]; then
      kit_notice warn "${n} 件の削除をまとめて検出したため、反映を止めました（$(jq -r '[.blocked_removals[] | "\(.section)/\(.key)"] | join(", ")' <<<"$result")）。意図した削除なら kit sync --allow-removals を実行してください"
    fi

    results="$(kit_apply "$(jq -c .ops <<<"$result")" "$M")"
    st="$(kit_sync_record_results "$st" "$result" "$results")"

    R2="$R"
    git_ok=0
    net_fail=0
    if [ "$online" = 0 ]; then
      kit_write_json "$KIT_MANIFEST" "$M"
      kit_log "sync: offline, wrote manifest only"
      net_fail=1
    elif ! kit_git_branch_ok; then
      kit_write_json "$KIT_MANIFEST" "$M"
      kit_notice warn "dotfiles が ${KIT_BRANCH} 以外のブランチにあるか作業の途中のため、manifest の書き出しだけ行いました"
    else
      kit_git_update
      up_rc=$?
      kit_write_json "$KIT_MANIFEST" "$M"
      if [ "$up_rc" = 2 ]; then
        kit_notice warn "dotfiles の ${KIT_BRANCH} が ${KIT_REMOTE}/${KIT_BRANCH} と分岐しているため、同期を保留しました（rebase などで解消してください）"
      elif [ "$up_rc" != 0 ]; then
        kit_notice warn "dotfiles の未コミットの変更が ${KIT_REMOTE}/${KIT_BRANCH} の変更とぶつかるため、同期を保留しました"
      elif ! kit_git_commit_manifest; then
        kit_notice warn "manifest のコミットに失敗しました"
      elif kit_git_foreign_unpushed; then
        kit_notice warn "dotfiles の ${KIT_BRANCH} に kit 以外の push していないコミットがあるため、push しませんでした"
      elif kit_git_push; then
        R2="$M"
        git_ok=1
      elif [ "$attempt" = 1 ]; then
        kit_log "sync: push rejected, retrying"
        L="$(kit_local_state)" || return 1
        continue
      else
        kit_notice warn "dotfiles の push に失敗しました。次の同期で再試行します"
        net_fail=1
      fi
    fi
    break
  done

  # base の更新（設計書 §7.5 手順 9）。反映後の状態が読めなければ base は前のまま残す
  if L2="$(kit_local_state)"; then
    kit_write_json "${KIT_STATE}/base.json" \
      "$(kit_base_update "$(jq -nc --argjson M "$M" --argjson L2 "$L2" --argjson R2 "$R2" --argjson B "$B" \
        '{M: $M, L2: $L2, R2: $R2, B: $B}')")"
  fi
  if [ "$git_ok" = 1 ]; then
    st="$(jq -c --argjson t "$(kit_now)" '.last_success = $t | del(.offline_since)' <<<"$st")"
  elif [ "$net_fail" = 1 ]; then
    # fetch / push できない状態が続いたら知らせる（気づかないまま同期が止まらないように）
    st="$(jq -c --argjson t "$(kit_now)" '.offline_since //= $t' <<<"$st")"
    since="$(jq -r '.offline_since' <<<"$st")"
    if [ $(($(kit_now) - since)) -ge 86400 ]; then
      kit_notice warn "dotfiles を 24 時間以上 fetch / push できていません。ネットワークや git の認証（SSH）を確認してください"
    fi
  fi
  kit_write_json "${KIT_STATE}/sync.json" "$st"
  kit_log "sync: done (online=${online} git_ok=${git_ok} ops=$(jq length <<<"$results"))"
  return 0
}

# kit_sync_record_results <sync-state> <merge-result> <apply-results>: 通知を出し、新しい sync-state を出す
kit_sync_record_results() {
  local st="$1" result="$2" results="$3" line
  jq -r '.conflicts[] | "衝突: \(.section)/\(.key) はこのマシンと他のマシンで別々に変更されていたため、\(.chosen | tojson) にしました"' <<<"$result" |
    while IFS= read -r line; do kit_notice info "$line"; done
  jq -r '.[] | select(.status == "failed") | "反映に失敗しました: \(.section)/\(.key)（\(.message | split("\n")[0])）"' <<<"$results" |
    while IFS= read -r line; do kit_notice warn "$line"; done
  jq -r '.[] | select(.status == "needs_approval") | "承認が必要です: \(.key) はインストール時にコマンドを実行します。内容を確認してから claude plugin install \(.key) を実行してください"' <<<"$results" |
    while IFS= read -r line; do kit_notice warn "$line"; done
  jq -r '.[] | select(.status == "deferred") | "保留しました: \(.section)/\(.key)（\(.message)）"' <<<"$results" |
    while IFS= read -r line; do kit_notice info "$line"; done
  st="$(jq -c --argjson r "$results" '
    reduce $r[] as $x (.;
      ("\($x.section)/\($x.key)") as $k
      | if $x.status == "ok" then del(.failures[$k])
        elif $x.status == "failed" then .failures[$k] = ((.failures[$k] // 0) + 1)
        else . end)' <<<"$st")"
  jq -r --argjson max "$KIT_MAX_FAILURES" --argjson r "$results" '
    (.failures // {}) | to_entries[] | select(.value == $max)
    | select(.key as $k | $r | any("\(.section)/\(.key)" == $k))
    | "\(.key) は \($max) 回続けて反映に失敗したため、再試行を止めました（kit sync --retry \(.key) で再開できます）"' <<<"$st" |
    while IFS= read -r line; do kit_notice warn "$line"; done
  printf '%s' "$st"
}

# kit_sync_print_plan <merge-result> <W> <online>: --dry-run の表示（設計書 §7.8）
kit_sync_print_plan() {
  local result="$1" w="$2" online="$3" d
  if [ "$online" = 1 ]; then
    echo "比較対象: ${KIT_REMOTE}/${KIT_BRANCH} の manifest"
  else
    echo "比較対象: HEAD の manifest（fetch できませんでした）"
  fi
  jq -r '
    "このマシンでの変更（manifest に書く）: \(.local_changes | length) 件",
    (.local_changes[] | "  \(.section)/\(.key)"),
    "このマシンへの操作: \(.ops | length) 件",
    (.ops[] | "  \(.op) \(.section)/\(.key)\(if .op == "remove" then "" else " → \(.to | tojson)" end)"),
    "衝突: \(.conflicts | length) 件",
    (.conflicts[] | "  \(.section)/\(.key): このマシン=\(.local | tojson) 他=\(.remote | tojson) → \(.chosen | tojson)"),
    "再試行を止めている項目: \(.skipped | length) 件",
    (.skipped[] | "  \(.section)/\(.key)"),
    "まとめて検出したため止めている削除: \(.blocked_removals | length) 件（kit sync --allow-removals で確定）",
    (.blocked_removals[] | "  \(.section)/\(.key)（\(if .direction == "local" then "このマシン" else "他のマシン" end)）")' <<<"$result"
  echo "manifest の差分（作業ツリー → 同期後）:"
  d="$(diff -u <(jq -S . <<<"$w") <(jq -S .M <<<"$result") | sed '1,2d')"
  if [ -n "$d" ]; then printf '%s\n' "$d"; else echo "  （差分なし）"; fi
  if kit_git_branch_ok; then
    echo "git: ${KIT_BRANCH} 上なので、コミットと push を行う"
  else
    echo "git: ${KIT_BRANCH} 以外のブランチか作業の途中なので、manifest の書き出しだけ行う"
  fi
}

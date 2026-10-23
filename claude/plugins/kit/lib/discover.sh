# 発見（設計書 §8）。状態は ${KIT_STATE}/discover/。

KIT_DISCOVER_DIR="${KIT_STATE}/discover"
KIT_DISCOVER_INTERVAL_SECONDS="${KIT_DISCOVER_INTERVAL_SECONDS:-604800}"
KIT_DISCOVER_MIN_PROMPTS="${KIT_DISCOVER_MIN_PROMPTS:-20}"
KIT_DISCOVER_RETRY_SECONDS="${KIT_DISCOVER_RETRY_SECONDS:-86400}"
KIT_DISCOVER_LOCK_STALE_SECONDS="${KIT_DISCOVER_LOCK_STALE_SECONDS:-3600}"

kit_discover_usage() {
  cat <<'EOF'
usage: kit discover <command>
  list [--json]                                 未処理のおすすめを表示する
  search <keywords...>                          キーワード（語句は引用符で囲む）で候補を探し、JSON で出す
  inspect <N か id>                              候補の中身を取得して、確認すべきファイルを表示する
  adopt <N か id> [--accept-command <sha256>]   候補を導入する
  dismiss <N か id> [--reason <text>]           候補を却下する（全マシンで二度と提案しない）
  run                                           利用履歴を分析しておすすめを作る
  maybe-run                                     分析の時期なら run を切り離して起動する
EOF
}

kit_discover() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  kit_require jq || { echo "kit: jq が必要です" >&2; return 1; }
  mkdir -p "$KIT_DISCOVER_DIR"
  case "$sub" in
    search) kit_discover_search "$@" ;;
    run) kit_discover_run ;;
    maybe-run) kit_discover_maybe_run ;;
    -h | --help | help) kit_discover_usage ;;
    *) kit_discover_usage >&2; return 2 ;;
  esac
}

# kit_discover_search <keywords...>: キーワードで候補を探して JSON で出す（設計書 §8.5 の 5）。
# 結果は search.json に残し、inspect / adopt / dismiss で id から引けるようにする
kit_discover_search() {
  local needs cands
  [ $# -gt 0 ] || { echo "usage: kit discover search <keywords...>" >&2; return 2; }
  needs="$(jq -nc --arg t "$*" '[{theme: $t, keywords: $ARGS.positional}]' --args "$@")"
  cands="$(kit_collect_candidates "$needs")" || return 1
  kit_write_json "${KIT_DISCOVER_DIR}/search.json" "$cands"
  printf '%s\n' "$cands"
}

# kit_discover_maybe_run: 前回の分析から 7 日以上経ち、その後の自分のプロンプトが 20 件以上あれば、分析を切り離して起動する
# （設計書 §8.2）。前回の分析が失敗してから 1 日以内は起動しない（毎回のセッション開始で失敗とコストを繰り返さない）
kit_discover_maybe_run() {
  local since last failed n
  kit_require claude || return 0
  since="$(cat "${KIT_DISCOVER_DIR}/last-run" 2>/dev/null)"
  last="$(jq -Rr 'fromdateiso8601? // 0' <<<"${since:-x}" 2>/dev/null)"
  [ $(($(kit_now) - ${last:-0})) -ge "$KIT_DISCOVER_INTERVAL_SECONDS" ] || return 0
  failed="$(cat "${KIT_DISCOVER_DIR}/last-failed" 2>/dev/null)"
  case "$failed" in '' | *[!0-9]*) failed=0 ;; esac
  [ $(($(kit_now) - failed)) -ge "$KIT_DISCOVER_RETRY_SECONDS" ] || return 0
  n="$(kit_count_prompts "$since")"
  if [ "${n:-0}" -lt "$KIT_DISCOVER_MIN_PROMPTS" ]; then
    kit_log "discover: skip (${n:-0} prompts since ${since:-never})"
    return 0
  fi
  kit_detach "${KIT_ROOT}/bin/kit" discover run
  return 0
}

# kit_discover_run: 分析ジョブ（設計書 §8.2 の ①〜⑤）。同時に 1 つだけ動く
kit_discover_run() {
  local rc
  kit_require claude || { kit_log "discover: claude not found"; return 1; }
  if ! kit_mkdir_lock "${KIT_DISCOVER_DIR}/lock" "$KIT_DISCOVER_LOCK_STALE_SECONDS"; then
    kit_log "discover: another run is in progress"
    return 0
  fi
  kit_discover_analyze
  rc=$?
  rmdir "${KIT_DISCOVER_DIR}/lock" 2>/dev/null
  if [ "$rc" -ne 0 ]; then
    kit_now >"${KIT_DISCOVER_DIR}/last-failed"
    kit_notice warn "スキル・プラグインの発見の分析に失敗しました（詳細は kit の sync.log）。1 日後に再試行します"
  fi
  return "$rc"
}

# kit_discover_analyze: ① 抽出 → ② ニーズ抽出 → ③ 候補収集 → ④ 順位付け → ⑤ 保存。途中の結果も discover/ に残す
kit_discover_analyze() {
  local since until digest installed needs cands recs
  since="$(cat "${KIT_DISCOVER_DIR}/last-run" 2>/dev/null)"
  until="$(kit_iso_now)"
  digest="$(kit_digest "$since")" && [ -n "$digest" ] || return 1
  kit_write_json "${KIT_DISCOVER_DIR}/digest.json" "$digest" || return 1
  installed="$(kit_installed)"
  needs="$(kit_llm needs "$(jq -nc --argjson d "$digest" --argjson i "$installed" '{digest: $d, installed: $i}')")" || return 1
  needs="$(jq -c '[.needs[]? | select((.theme | type) == "string" and (.keywords | type) == "array" and (.keywords | length) > 0)
    | {theme, evidence: ([(.evidence // [])[]? | strings | .[0:200]] | .[0:3]), keywords: ([.keywords[] | strings] | .[0:4])}]
    | .[0:5]' <<<"$needs")" || return 1
  kit_write_json "${KIT_DISCOVER_DIR}/needs.json" "$needs" || return 1
  cands="$(kit_collect_candidates "$needs")" && [ -n "$cands" ] || return 1
  kit_write_json "${KIT_DISCOVER_DIR}/candidates.json" "$cands" || return 1
  if [ "$(jq length <<<"$cands")" -eq 0 ]; then
    recs='[]'
  else
    recs="$(kit_llm rank "$(jq -nc --argjson n "$needs" --argjson c "$cands" --argjson i "$installed" \
      '{needs: $n, candidates: [$c[] | {id, kind, name, description, need, signals}], installed: $i}')")" || return 1
    recs="$(jq -c -L "$KIT_LIB_DIR" --argjson c "$cands" 'include "candidates"; kit_recommendations($c)' <<<"$recs")" || return 1
  fi
  kit_write_json "${KIT_DISCOVER_DIR}/recommendations.json" "$recs" || return 1
  rm -f "${KIT_DISCOVER_DIR}/last-notified" "${KIT_DISCOVER_DIR}/last-failed"
  printf '%s\n' "$until" >"${KIT_DISCOVER_DIR}/last-run"
  kit_log "discover: done (needs=$(jq length <<<"$needs") candidates=$(jq length <<<"$cands") recommendations=$(jq length <<<"$recs"))"
}

# kit_discover_pending_notice: 未処理のおすすめがあり、今日まだ伝えていなければ通知文を出し、今日の日付を記録する
# （設計書 §8.4。並列セッションでうるさくならないよう 1 日 1 回）
kit_discover_pending_notice() {
  local n today
  n="$(kit_read_json "${KIT_DISCOVER_DIR}/recommendations.json" '[]' | jq 'length')"
  [ "${n:-0}" -gt 0 ] || return 0
  today="$(date +%Y-%m-%d)"
  [ "$(cat "${KIT_DISCOVER_DIR}/last-notified" 2>/dev/null)" = "$today" ] && return 0
  printf '%s\n' "$today" >"${KIT_DISCOVER_DIR}/last-notified"
  printf '🔎 おすすめ %s 件 — /kit:discover で確認' "$n"
}

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
    list) kit_discover_list "$@" ;;
    adopt) kit_discover_adopt "$@" ;;
    dismiss) kit_discover_dismiss "$@" ;;
    inspect) kit_discover_inspect "$@" ;;
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
  local since until digest n installed needs cands recs
  since="$(cat "${KIT_DISCOVER_DIR}/last-run" 2>/dev/null)"
  until="$(kit_iso_now)"
  digest="$(kit_digest "$since")" && [ -n "$digest" ] || return 1
  kit_write_json "${KIT_DISCOVER_DIR}/digest.json" "$digest" || return 1
  # 前回の分析があり、その後の自分のプロンプトが少なければ分析しない。ほぼ空の期間を分析して、おすすめを空で置き換えないため
  # （手動の kit discover run や、前の分析の終わりと同時に起動した分析もここで止まる）
  n="$(jq '.prompts | length' <<<"$digest")"
  if [ -n "$since" ] && [ "${n:-0}" -lt "$KIT_DISCOVER_MIN_PROMPTS" ]; then
    kit_log "discover: skip (${n:-0} prompts since ${since})"
    return 0
  fi
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

# kit_discover_find <N か id>: おすすめ（N は rank）、おすすめの id、直前の検索結果（search.json）の id の順に探し、候補を 1 件出す
kit_discover_find() {
  local recs search
  recs="$(kit_read_json "${KIT_DISCOVER_DIR}/recommendations.json" '[]')"
  search="$(kit_read_json "${KIT_DISCOVER_DIR}/search.json" '[]')"
  jq -ec --arg k "$1" --argjson s "$search" '
    first((if ($k | test("^[0-9]+$")) then (.[] | select(.rank == ($k | tonumber))) else empty end),
          (.[] | select(.id == $k)),
          ($s[] | select(.id == $k)))' <<<"$recs" 2>/dev/null
}

# kit_discover_forget <id>: おすすめと直前の検索結果からその候補を外す（全件なくなれば「未処理のおすすめ」もなくなる）
kit_discover_forget() {
  local f
  for f in recommendations.json search.json; do
    [ -f "${KIT_DISCOVER_DIR}/${f}" ] || continue
    kit_write_json "${KIT_DISCOVER_DIR}/${f}" \
      "$(kit_read_json "${KIT_DISCOVER_DIR}/${f}" '[]' | jq -c --arg id "$1" 'map(select(.id != $id))')"
  done
}

# kit_manifest_edit <arg-json> <jq-filter>: 作業ツリーの manifest（W）を、$x に arg-json を束縛したフィルタで書き換える。
# W が読めない・壊れているなら何も書かずに 1（壊れたファイルを空の manifest で上書きすると、全マシンの discovery が消える）
kit_manifest_edit() {
  local w out
  if [ -z "$KIT_DOTFILES" ] || [ ! -e "${KIT_DOTFILES}/.git" ]; then
    echo "kit: dotfiles リポジトリが見つかりません" >&2
    return 1
  fi
  if ! w="$(kit_working_manifest 2>/dev/null)" || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$w"; then
    echo "kit: claude/manifest.json を読めません（衝突マーカーなどを直してください）" >&2
    return 1
  fi
  if ! out="$(jq -c --argjson x "$1" "$2" <<<"$w")" || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
    echo "kit: manifest を更新できませんでした" >&2
    return 1
  fi
  kit_write_json "$KIT_MANIFEST" "$out"
}

# kit_discover_sync: 導入・却下・ウォッチの編集の後の同期。失敗しても編集は作業ツリーに残り、次の同期で反映される
kit_discover_sync() {
  kit_sync || echo "kit: 同期できませんでした。次のセッションの開始時に同期します（kit status で確認できます）" >&2
  return 0
}

# kit discover list [--json]（設計書 §8.5 の 1）
kit_discover_list() {
  local recs
  recs="$(kit_read_json "${KIT_DISCOVER_DIR}/recommendations.json" '[]')"
  if [ "${1:-}" = --json ]; then
    printf '%s\n' "$recs"
    return 0
  fi
  if [ "$(jq length <<<"$recs")" -eq 0 ]; then
    echo "未処理のおすすめはありません"
    return 0
  fi
  jq -r -L "$KIT_LIB_DIR" 'include "candidates"; .[] |
    "\(.rank). [\(.kind)] \(.name)（\(.id)）",
    "   出どころ: \(kit_source_label)",
    "   理由: \(.reason)",
    (if (.overlap // "") != "" then "   既存との重なり: \(.overlap)" else empty end),
    "   目安: \((.signals // {}) | to_entries | map("\(.key)=\(.value)") | join(" ") | if . == "" then "なし" else . end)"' <<<"$recs"
  echo "前回の分析: $(cat "${KIT_DISCOVER_DIR}/last-run" 2>/dev/null || echo まだありません)"
}

# kit discover dismiss <N か id> [--reason <text>]（設計書 §8.5 の 3）。おすすめにない id もそのまま却下できる
kit_discover_dismiss() {
  local key="${1:-}" reason="" c id usage="usage: kit discover dismiss <N か id> [--reason <text>]"
  [ -n "$key" ] || { echo "$usage" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason="${2:-}"; shift ;;
      *) echo "$usage" >&2; return 2 ;;
    esac
    shift
  done
  if c="$(kit_discover_find "$key")"; then
    id="$(jq -r .id <<<"$c")"
  else
    case "$key" in
      *[!0-9]*) id="$key" ;;
      *) echo "kit: おすすめ ${key} が見つかりません" >&2; return 1 ;;
    esac
  fi
  kit_manifest_edit "$(jq -nc --arg id "$id" --arg at "$(date +%Y-%m-%d)" --arg r "$reason" '{id: $id, at: $at, reason: $r}')" \
    '.discovery.dismissed = ((((.discovery.dismissed // []) | map(select(.id != $x.id))) + [$x]) | sort_by(.id))' || return 1
  kit_discover_forget "$id"
  echo "却下しました: ${id}"
  kit_discover_sync
}

# kit discover adopt <N か id> [--accept-command <sha256>]（設計書 §8.6）。導入したらおすすめから外し、kit sync で manifest に記録する
kit_discover_adopt() {
  local key="${1:-}" accept="" c kind id usage="usage: kit discover adopt <N か id> [--accept-command <sha256>]"
  [ -n "$key" ] || { echo "$usage" >&2; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --accept-command)
        accept="${2:-}"
        [ -n "$accept" ] || { echo "$usage" >&2; return 2; }
        shift ;;
      *) echo "$usage" >&2; return 2 ;;
    esac
    shift
  done
  c="$(kit_discover_find "$key")" || {
    echo "kit: 候補 ${key} が見つかりません（kit discover list か kit discover search で確かめてください）" >&2
    return 1
  }
  kind="$(jq -r .kind <<<"$c")"
  id="$(jq -r .id <<<"$c")"
  case "$kind" in
    plugin) kit_discover_install_plugin "$c" "$accept" || return 1 ;;
    skill)
      kit_require npx || { echo "kit: npx が必要です" >&2; return 1; }
      npx --yes skills add "$(jq -r .source <<<"$c")" -s "$(jq -r .skill <<<"$c")" -g -y -a claude-code </dev/null >/dev/null 2>&1 || {
        echo "kit: スキル ${id} の導入に失敗しました" >&2
        return 1
      } ;;
    watch) kit_watch_edit add "$id" || return 1 ;;
    *) echo "kit: 未知の種別です: ${kind}" >&2; return 1 ;;
  esac
  kit_discover_forget "$id"
  echo "導入しました: ${id}"
  kit_discover_sync
}

# kit_discover_install_plugin <candidate> <accept-sha>: プラグインを入れる。未登録のマーケットプレイス（ウォッチリスト由来）のものは
# --marketplace でマーケットプレイスごと登録する。インストール時にコマンドを実行するもの（shownCommand）は、内容と承認の方法を見せて止める
kit_discover_install_plugin() {
  local c="$1" accept="$2" id name mkt msrc out rc
  id="$(jq -r .id <<<"$c")"
  name="$(jq -r .name <<<"$c")"
  mkt="$(jq -r '.marketplace // ""' <<<"$c")"
  msrc="$(jq -r '.marketplace_source // ""' <<<"$c")"
  if [ -n "$msrc" ] && ! kit_claude plugin marketplace list --json </dev/null 2>/dev/null |
    jq -e --arg m "$mkt" 'any(.[]?; .name == $m)' >/dev/null 2>&1; then
    set -- plugin install "$name" --marketplace "$msrc" -s user --json
  else
    set -- plugin install "$id" -s user --json
  fi
  [ -n "$accept" ] && set -- "$@" --accept-command "$accept"
  out="$(kit_claude "$@" </dev/null 2>/dev/null)"
  rc=$?
  if jq -e '.shownCommand' >/dev/null 2>&1 <<<"$out"; then
    jq -r --arg id "$id" '"\($id) はインストール時に次のコマンドを実行します:", "  \(.shownCommand.command)",
      "内容を確認して問題がなければ、kit discover adopt \($id) --accept-command \(.shownCommand.sha256) を実行してください"' <<<"$out"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "kit: プラグイン ${id} の導入に失敗しました（$(jq -r '.message // "理由不明"' <<<"$out" 2>/dev/null)）" >&2
    return 1
  fi
}

# kit_watch_edit <add|remove> <owner/repo>: 作業ツリーの manifest の discovery.watch を編集する
kit_watch_edit() {
  if [ "$1" = add ]; then
    kit_manifest_edit "$(jq -nc --arg r "$2" '$r')" '.discovery.watch = (((.discovery.watch // []) + [$x]) | unique)'
  else
    kit_manifest_edit "$(jq -nc --arg r "$2" '$r')" '.discovery.watch = ((.discovery.watch // []) | map(select(. != $x)))'
  fi
}

# kit watch add|remove <owner/repo>（設計書 §9）
kit_watch() {
  local op="${1:-}" repo="${2:-}" usage="usage: kit watch add|remove <owner/repo>"
  case "$op" in add | remove) ;; *) echo "$usage" >&2; return 2 ;; esac
  kit_valid_repo "$repo" || { echo "$usage" >&2; return 2; }
  kit_require jq || { echo "kit: jq が必要です" >&2; return 1; }
  kit_watch_edit "$op" "$repo" || return 1
  if [ "$op" = add ]; then echo "ウォッチリストに加えました: ${repo}"; else echo "ウォッチリストから外しました: ${repo}"; fi
  kit_discover_sync
}

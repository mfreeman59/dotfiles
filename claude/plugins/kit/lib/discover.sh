# 発見（設計書 §8）。状態は ${KIT_STATE}/discover/。

KIT_DISCOVER_DIR="${KIT_STATE}/discover"

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

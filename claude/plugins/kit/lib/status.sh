# kit status（設計書 §9）。

kit_status() {
  local st last n
  st="$(kit_read_json "${KIT_STATE}/sync.json" '{"last_success":0,"failures":{}}')"
  last="$(jq -r '.last_success // 0' <<<"$st")"
  echo "dotfiles: ${KIT_DOTFILES:-（見つかりません）}"
  if [ "$last" = 0 ]; then
    echo "最後に成功した同期: まだありません"
  else
    echo "最後に成功した同期: $(date -r "$last" '+%Y-%m-%d %H:%M:%S')"
  fi
  n=0
  [ -f "${KIT_STATE}/notices.jsonl" ] && n="$(wc -l <"${KIT_STATE}/notices.jsonl" | tr -d ' ')"
  echo "まだ表示していない通知: ${n} 件"
  jq -r '(.failures // {}) | to_entries[] | "失敗が続いている項目: \(.key)（\(.value) 回）"' <<<"$st"
  kit_claude plugin marketplace list --json </dev/null 2>/dev/null |
    jq -r '.[]? | select(.name != "dotfiles" and (.source == "directory" or .source == "file"))
      | "管理対象外: マーケットプレイス \(.name)（ローカルパスのため同期しません）"' 2>/dev/null
  echo "--- 同期の計画（kit sync --dry-run）"
  kit_sync --dry-run
}

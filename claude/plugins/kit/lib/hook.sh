# Claude Code のフック（設計書 §7.1）。呼び出し元の bin/kit は常に終了コード 0 で終わる。
# 重い処理（同期）は kit_detach で切り離し、フック自体はすぐ戻る。

kit_hook() {
  [ "${KIT_NESTED:-}" = 1 ] && return 0
  cat >/dev/null 2>&1   # フックの入力 JSON は使わない
  case "${1:-}" in
    session-start) kit_hook_session_start ;;
    session-end) kit_detach "${KIT_ROOT}/bin/kit" sync ;;
  esac
  return 0
}

# SessionStart の systemMessage は画面に表示されない（設計書 §13 で確かめた）ため、Claude の最初の応答で伝えてもらう
kit_hook_session_start() {
  local text
  text="$(kit_take_notices | jq -r 'map("・" + .message) | join("\n")')"
  if [ -n "$text" ]; then
    jq -nc --arg t "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ("kit からの通知です。最初の応答の冒頭で、次の内容をユーザーに一度だけ簡潔に伝えてください:\n" + $t)}}'
  fi
  kit_detach "${KIT_ROOT}/bin/kit" sync
}

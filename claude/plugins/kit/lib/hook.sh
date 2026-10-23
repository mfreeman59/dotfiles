# Claude Code のフック（設計書 §7.1）。呼び出し元の bin/kit は常に終了コード 0 で終わる。
# 重い処理（同期と発見の分析）は kit_detach で切り離し、フック自体はすぐ戻る。

kit_hook() {
  [ "${KIT_NESTED:-}" = 1 ] && return 0
  cat >/dev/null 2>&1   # フックの入力 JSON は使わない
  case "${1:-}" in
    session-start) kit_hook_session_start ;;
    session-end) kit_detach "${KIT_ROOT}/bin/kit" sync ;;
  esac
  return 0
}

# 通知は systemMessage で画面に出す（設計書 §8.4）。Claude には渡さない（応答に混ぜず、コンテキストも使わない）。
# 通知はマシンで 1 つのキューなので、最初に起動・再開したセッションがまとめて受け取る
kit_hook_session_start() {
  local text rec
  text="$(kit_take_notices | jq -r 'map("・" + .message) | join("\n")')"
  rec="$(kit_discover_pending_notice)"
  if [ -n "$rec" ]; then
    if [ -n "$text" ]; then
      text="${text}
・${rec}"
    else
      text="・${rec}"
    fi
  fi
  if [ -n "$text" ]; then
    jq -nc --arg t "$text" '{systemMessage: ("kit:\n" + $t)}'
  fi
  # 同期に続けて、発見の分析の時期かを判定する（設計書 §7.1、§8.2）
  kit_detach /bin/bash -c '"$0" sync; "$0" discover maybe-run' "${KIT_ROOT}/bin/kit"
}

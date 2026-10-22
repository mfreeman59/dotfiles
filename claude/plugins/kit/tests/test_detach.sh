. "$(dirname "$0")/helpers.sh"
t_tmp
export HOME="${T_TMP}/home" KIT_STATE_DIR="${T_TMP}/state" KIT_DOTFILES="${T_TMP}/dot"
. "${KIT_PLUGIN_DIR}/lib/common.sh"
. "${KIT_PLUGIN_DIR}/lib/detach.sh"

# すぐ戻る
start="$(t_ms)"
kit_detach /bin/sh -c "sleep 2; echo done >'${T_TMP}/out1'"
end="$(t_ms)"
assert_lt "$((end - start))" "500" "kit_detach はすぐ戻る"

# 親のプロセスグループごと SIGTERM を送っても、子は動き続ける（Claude Code の終了を模す）
(perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- /bin/bash -c "
  export HOME='${T_TMP}/home' KIT_STATE_DIR='${T_TMP}/state' KIT_DOTFILES='${T_TMP}/dot'
  . '${KIT_PLUGIN_DIR}/lib/common.sh'
  . '${KIT_PLUGIN_DIR}/lib/detach.sh'
  kit_detach /bin/sh -c \"sleep 2; echo survived >'${T_TMP}/out2'\"
  echo \$\$ >'${T_TMP}/parent.pid'
  sleep 30
" &)  # サブシェルで起動し、テストのシェルにジョブとして追跡させない（終了の報告を出さない）
i=0
while [ ! -s "${T_TMP}/parent.pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM -- "-$(cat "${T_TMP}/parent.pid")" 2>/dev/null
sleep 3
assert_eq "$(cat "${T_TMP}/out2" 2>/dev/null)" "survived" "親のプロセスグループが終了しても子は生き残る"
assert_eq "$(cat "${T_TMP}/out1" 2>/dev/null)" "done" "切り離した処理は最後まで動く"

# 子の出力は sync.log に入る
kit_detach /bin/sh -c "echo from-child"
sleep 1
assert_contains "$(cat "${KIT_STATE}/sync.log" 2>/dev/null)" "from-child" "子の出力は sync.log に追記される"

t_done

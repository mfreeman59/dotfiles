. "$(dirname "$0")/helpers.sh"

s_nested() {
  t_remote; t_clone A
  out="$(t_machine A; export KIT_NESTED=1; kit hook session-start </dev/null)"; rc=$?
  assert_eq "$rc" "0" "入れ子でも終了コード 0"
  assert_eq "$out" "" "入れ子では何も出さない"
  assert_eq "$([ -e "$(state_file A sync.log)" ] && echo yes || echo no)" "no" "入れ子では同期しない"
}
s_notices() {
  t_remote; t_clone A
  (t_machine A; . "${KIT_PLUGIN_DIR}/lib/common.sh"; kit_notice info "テスト通知1"; kit_notice warn "テスト通知2")
  out="$(on A kit hook session-start </dev/null)"
  msg="$(jq -r .systemMessage <<<"$out")"
  assert_eq "$(head -n 1 <<<"$msg")" "kit:" "kit からの通知とわかる見出し"
  assert_contains "$msg" "・テスト通知1" "通知をユーザーに見せる"
  assert_contains "$msg" "・テスト通知2" "全部の通知を見せる"
  assert_eq "$(jq -r 'has("hookSpecificOutput")' <<<"$out")" "false" "Claude には渡さない（応答に混ぜず、コンテキストも使わない）"
  wait_log A "sync: done"; assert_eq "$?" "0" "切り離した同期が最後まで動く"
  wait_log A "discover: skip"; assert_eq "$?" "0" "同期に続けて、発見の分析の時期かを判定する"
  assert_eq "$(on A kit hook session-start </dev/null)" "" "通知を出したら空になる"
  wait_log A "sync: done" 2
  wait_log A "discover: skip" 2
}
s_session_end_fast() {
  t_remote; t_clone A
  start="$(t_ms)"
  (t_machine A; export FAKE_SLOW=2; kit hook session-end </dev/null)
  end="$(t_ms)"
  assert_lt "$((end - start))" "1000" "SessionEnd は 1 秒以内に戻る"
  wait_log A "sync: done"; assert_eq "$?" "0" "戻った後も同期は動く"
}
s_always_zero() {
  t_remote; t_clone A
  (t_machine A; export KIT_DOTFILES="${T_TMP}/nowhere"; kit hook session-start </dev/null >/dev/null); rc=$?
  assert_eq "$rc" "0" "同期できない環境でも終了コード 0"
  wait_log A "dotfiles リポジトリが見つからない"; assert_eq "$?" "0" "切り離した同期は通知を残して終わる"
  wait_log A "discover: skip"
  (t_machine A; kit hook unknown </dev/null); rc=$?
  assert_eq "$rc" "0" "不明なフックでも終了コード 0"
}
s_recommend() {
  t_remote; t_clone A
  t_machine A
  mkdir -p "$(state_file A discover)"
  echo '[{"rank":1,"id":"a@m"},{"rank":2,"id":"b@m"}]' >"$(state_file A discover/recommendations.json)"
  out="$(kit hook session-start </dev/null)"
  assert_contains "$(jq -r .systemMessage <<<"$out")" "・🔎 おすすめ 2 件 — /kit:discover で確認" "未処理のおすすめを伝える"
  assert_eq "$(cat "$(state_file A discover/last-notified)")" "$(date +%Y-%m-%d)" "伝えた日を記録する"
  wait_log A "discover: skip"
  assert_eq "$(kit hook session-start </dev/null)" "" "同じ日には 1 回だけ"
  wait_log A "discover: skip" 2
}

t_scenario "入れ子では何もしない" s_nested
t_scenario "通知を出して同期を起動する" s_notices
t_scenario "SessionEnd はすぐ戻る" s_session_end_fast
t_scenario "常に終了コード 0" s_always_zero
t_scenario "未処理のおすすめを 1 日 1 回伝える" s_recommend
t_done

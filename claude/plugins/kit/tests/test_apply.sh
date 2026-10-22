. "$(dirname "$0")/helpers.sh"
t_tmp
t_machine A
. "${KIT_PLUGIN_DIR}/lib/common.sh"
. "${KIT_PLUGIN_DIR}/lib/apply.sh"
st() { jq -r --arg k "$1" '.[] | select(.key == $k) | .status' <<<"$res"; }

fake_set '.marketplaces = [{"name":"old","source":"github","repo":"x/old"}]
  | .plugins = [{"id":"c@official","enabled":true},{"id":"d@official","enabled":true}]
  | .fail = ["f@official"] | .command_source = ["g@official"]'
M='{"plugins":{"a@official":false,"x@old":true},"skills":{}}'
ops='[
  {"section":"marketplaces","key":"old","op":"remove","from":{"source":"github","repo":"x/old"},"to":null},
  {"section":"skills","key":"s1","op":"add","from":null,"to":{"source":"o/r"}},
  {"section":"plugins","key":"a@official","op":"add","from":null,"to":false},
  {"section":"marketplaces","key":"agents","op":"add","from":null,"to":{"source":"github","repo":"w/agents"}},
  {"section":"plugins","key":"c@official","op":"change","from":true,"to":false},
  {"section":"plugins","key":"d@official","op":"remove","from":true,"to":null},
  {"section":"plugins","key":"f@official","op":"add","from":null,"to":true},
  {"section":"plugins","key":"g@official","op":"add","from":null,"to":true}]'
res="$(kit_apply "$ops" "$M")"

assert_eq "$(jq length <<<"$res")" "8" "全部の操作に結果がある"
assert_eq "$(st agents)" "ok" "マーケットプレイスの追加"
assert_eq "$(st a@official)" "ok" "false で追加"
assert_eq "$(st c@official)" "ok" "無効化"
assert_eq "$(st d@official)" "ok" "削除"
assert_eq "$(st f@official)" "failed" "失敗"
assert_eq "$(jq -r '.[] | select(.key == "f@official") | .message' <<<"$res")" "boom" "失敗の理由を持つ"
assert_eq "$(st g@official)" "needs_approval" "コマンドを実行するプラグインは承認待ち"
assert_eq "$(st s1)" "ok" "スキルの追加"
assert_eq "$(st old)" "deferred" "プラグインが manifest に残るマーケットプレイスは削除を保留する"

calls="$(fake_calls)"
assert_eq "$(sed -n 1p <<<"$calls")" "claude plugin marketplace add w/agents --scope user" "マーケットプレイスの追加が最初"
assert_contains "$calls" "claude plugin install a@official -s user --json" "インストール"
assert_contains "$calls" "claude plugin disable a@official -s user" "false ならインストール後に無効化"
assert_contains "$calls" "claude plugin disable c@official -s user" "change false は disable"
assert_contains "$calls" "claude plugin uninstall d@official -s user" "remove は uninstall"
assert_eq "$(tail -n 1 <<<"$calls")" "npx --yes skills add o/r -s s1 -g -y -a claude-code" "スキルはプラグインの後"
assert_not_contains "$calls" "marketplace remove" "保留したマーケットプレイスは削除しない"
assert_eq "$(jq -r '.skills.s1.source' "${HOME}/.agents/.skill-lock.json")" "o/r" "スキルが入る"

: >"${FAKE_DIR}/calls.log"
res="$(kit_apply '[
  {"section":"marketplaces","key":"old","op":"remove","from":{"source":"github","repo":"x/old"},"to":null},
  {"section":"skills","key":"s1","op":"change","from":{"source":"o/r"},"to":{"source":"o/r2"}}]' '{"plugins":{}}')"
assert_eq "$(st old)" "ok" "プラグインが残っていなければ削除する"
assert_eq "$(fake_calls)" "$(printf '%s\n' \
  "npx --yes skills remove s1 -g -y" \
  "npx --yes skills add o/r2 -s s1 -g -y -a claude-code" \
  "claude plugin list --json" \
  "claude plugin marketplace remove old --scope user")" "スキルの change は削除してから追加、マーケットプレイスの削除は最後（使われていないことを確かめてから）"

assert_eq "$(kit_apply '[]' '{}')" "[]" "操作がなければ空の配列"

# マーケットプレイスの変更・削除でプラグインを巻き込まない、データを消さない（レビュー C3 / I4 / I3）
: >"${FAKE_DIR}/calls.log"
fake_set '.marketplaces = [{"name":"m1","source":"github","repo":"x/m1"},{"name":"wf","source":"github","repo":"w/wf"}]
  | .plugins = [{"id":"z@m1","enabled":true},{"id":"pp@wf","enabled":true,"scope":"project"}]'
res="$(kit_apply '[
  {"section":"marketplaces","key":"m1","op":"change","from":{"source":"github","repo":"x/m1"},"to":{"source":"github","repo":"x/fork"}},
  {"section":"marketplaces","key":"wf","op":"remove","from":{"source":"github","repo":"w/wf"},"to":null},
  {"section":"plugins","key":"z@m1","op":"remove","from":true,"to":null}]' '{"plugins":{}}')"
assert_eq "$(st m1)" "deferred" "マーケットプレイスのソース変更は自動で反映しない"
assert_eq "$(st wf)" "deferred" "プロジェクトスコープで使われているマーケットプレイスは削除しない"
assert_not_contains "$(fake_calls)" "marketplace remove" "マーケットプレイスを削除しない"
assert_not_contains "$(fake_calls)" "marketplace add" "マーケットプレイスを追加し直さない"
assert_contains "$(fake_calls)" "claude plugin uninstall z@m1 -s user --keep-data" "アンインストールはプラグインのデータを残す"

t_done

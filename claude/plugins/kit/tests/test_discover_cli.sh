. "$(dirname "$0")/helpers.sh"

RECS='[
 {"rank":1,"kind":"plugin","id":"db@official","name":"db","description":"Supabase migrations","source":"./db","marketplace":"official","need":"DB","reason":"r1","overlap":"","signals":{"installs":50}},
 {"rank":2,"kind":"plugin","id":"wp@wmk","name":"wp","description":"","source":"./wp","marketplace":"wmk","marketplace_source":"o/w","need":"DB","reason":"r2","overlap":"","signals":{"stars":50}},
 {"rank":3,"kind":"skill","id":"o/r@cr","name":"cr","description":"","source":"o/r","skill":"cr","need":"PR","reason":"r3","overlap":"既存と重なる","signals":{"installs":9}},
 {"rank":4,"kind":"watch","id":"g/db","name":"g/db","description":"","source":"g/db","need":"DB","reason":"r4","overlap":"","signals":{"stars":30,"pushed_at":"2026-10-01"}}]'

setup() {
  t_remote; t_clone A
  t_machine A
  mkdir -p "$(state_file A discover)"
  printf '%s\n' "$RECS" >"$(state_file A discover/recommendations.json)"
  fake_set '.marketplaces = [{"name":"official","source":"github","repo":"o/official"}]'
}
rec_ids() { jq -c '[.[].id]' "$(state_file A discover/recommendations.json)"; }
W() { printf '%s/A/dotfiles/claude/manifest.json' "$T_TMP"; }

s_list() {
  setup
  out="$(kit discover list)"
  assert_contains "$out" "1. [plugin] db（db@official）" "番号・種別・名前・id"
  assert_contains "$out" "出どころ: マーケットプレイス official" "出どころ"
  assert_contains "$out" "出どころ: マーケットプレイス wmk（o/w、未登録）" "未登録のマーケットプレイス"
  assert_contains "$out" "出どころ: skills.sh o/r" "skills.sh"
  assert_contains "$out" "出どころ: GitHub g/db" "GitHub"
  assert_contains "$out" "理由: r1" "理由"
  assert_contains "$out" "既存との重なり: 既存と重なる" "既存との重なり"
  assert_contains "$out" "目安: installs=50" "信頼性の目安"
  assert_contains "$out" "前回の分析: まだありません" "前回の分析"
  assert_json_eq "$(kit discover list --json)" "$RECS" "--json はそのまま出す"
  echo '[]' >"$(state_file A discover/recommendations.json)"
  assert_eq "$(kit discover list)" "未処理のおすすめはありません" "なければそう表示する"
}
s_dismiss() {
  setup
  out="$(kit discover dismiss 1 --reason "使わない")"; rc=$?
  assert_eq "$rc" "0" "成功"
  assert_contains "$out" "却下しました: db@official" "結果を伝える"
  assert_json_eq "$(jq -c .discovery.dismissed "$(W)")" "[{\"id\":\"db@official\",\"at\":\"$(date +%Y-%m-%d)\",\"reason\":\"使わない\"}]" "manifest に記録する"
  assert_eq "$(rec_ids)" '["wp@wmk","o/r@cr","g/db"]' "おすすめから外す"
  assert_eq "$(remote_manifest | jq -c '[.discovery.dismissed[].id]')" '["db@official"]' "同期して他のマシンに広げる"
  kit discover dismiss other/repo@x >/dev/null
  assert_eq "$(jq -c '[.discovery.dismissed[].id]' "$(W)")" '["db@official","other/repo@x"]' "おすすめにない id も却下できる"
  kit discover dismiss 99 >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "1" "ない番号は失敗"
  kit discover dismiss >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "引数がなければ使い方の誤り"
}
s_broken_manifest() {
  setup
  printf '{broken' >"$(W)"
  kit discover dismiss 1 >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "1" "manifest が壊れていたら却下しない"
  assert_eq "$(cat "$(W)")" "{broken" "壊れた manifest を上書きしない"
  assert_eq "$(rec_ids | jq length)" "4" "おすすめも残す"
  kit watch add o/x >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "1" "ウォッチリストも編集しない"
  assert_eq "$(cat "$(W)")" "{broken" "壊れた manifest をそのまま残す"
}
s_watch() {
  setup
  out="$(kit watch add o/new)"; rc=$?
  assert_eq "$rc" "0" "加えられる"
  assert_contains "$out" "ウォッチリストに加えました: o/new" "結果を伝える"
  kit watch add o/new >/dev/null
  assert_eq "$(jq -c .discovery.watch "$(W)")" '["o/new"]' "重複させない"
  assert_eq "$(remote_manifest | jq -c .discovery.watch)" '["o/new"]' "同期する"
  kit watch remove o/new >/dev/null
  assert_eq "$(jq -c .discovery.watch "$(W)")" '[]' "外せる"
  kit watch add ../x >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "owner/repo の形でなければ使い方の誤り"
  kit watch list x/y >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "不明な操作は使い方の誤り"
}
s_adopt_plugin() {
  setup
  out="$(kit discover adopt 1)"; rc=$?
  assert_eq "$rc" "0" "成功"
  assert_contains "$(fake_calls)" "claude plugin install db@official -s user --json" "登録済みのマーケットプレイスから入れる"
  assert_contains "$out" "導入しました: db@official" "結果を伝える"
  assert_eq "$(rec_ids)" '["wp@wmk","o/r@cr","g/db"]' "おすすめから外す"
  assert_eq "$(remote_manifest | jq -c .plugins)" '{"db@official":true}' "同期して manifest に記録する"
}
s_adopt_unregistered() {
  setup
  export FAKE_MKT_NAME=wmk
  kit discover adopt wp@wmk >/dev/null; rc=$?
  assert_eq "$rc" "0" "成功"
  assert_contains "$(fake_calls)" "claude plugin install wp --marketplace o/w -s user --json" "未登録のマーケットプレイスは --marketplace で登録しながら入れる"
  assert_eq "$(remote_manifest | jq -c '{m: (.marketplaces | keys), p: .plugins}')" '{"m":["official","wmk"],"p":{"wp@wmk":true}}' "マーケットプレイスとプラグインを記録する"
}
s_adopt_registered_watch() {
  setup
  fake_set '.marketplaces += [{"name":"wmk","source":"github","repo":"o/w"}]'
  kit discover adopt 2 >/dev/null; rc=$?
  assert_eq "$rc" "0" "成功"
  assert_contains "$(fake_calls)" "claude plugin install wp@wmk -s user --json" "すでに登録済みなら名前@マーケットプレイスで入れる"
}
s_adopt_command() {
  setup
  fake_set '.command_source = ["db@official"]'
  out="$(kit discover adopt 1)"; rc=$?
  assert_eq "$rc" "1" "コマンドを実行するプラグインはすぐには入れない"
  assert_contains "$out" "  make" "実行されるコマンドを見せる"
  assert_contains "$out" "kit discover adopt db@official --accept-command abc" "承認の方法を示す"
  assert_eq "$(rec_ids | jq length)" "4" "おすすめに残す"
  kit discover adopt 1 --accept-command abc >/dev/null; rc=$?
  assert_eq "$rc" "0" "承認されたら入れる"
  assert_contains "$(fake_calls)" "claude plugin install db@official -s user --json --accept-command abc" "承認したコマンドだけを許可して入れる"
}
s_adopt_skill() {
  setup
  kit discover adopt 3 >/dev/null; rc=$?
  assert_eq "$rc" "0" "成功"
  assert_contains "$(fake_calls)" "npx --yes skills add o/r -s cr -g -y -a claude-code" "skills.sh から入れる"
  assert_eq "$(remote_manifest | jq -c .skills)" '{"cr":{"source":"o/r"}}' "同期して manifest に記録する"
}
s_adopt_watch() {
  setup
  kit discover adopt 4 >/dev/null; rc=$?
  assert_eq "$rc" "0" "成功"
  assert_eq "$(remote_manifest | jq -c .discovery.watch)" '["g/db"]' "ウォッチリストに加える"
  assert_not_contains "$(fake_calls)" "plugin install" "Claude Code には登録しない"
}
s_adopt_fail() {
  setup
  fake_set '.fail = ["db@official"]'
  kit discover adopt 1 >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "1" "導入に失敗したら 1"
  assert_eq "$(rec_ids | jq length)" "4" "おすすめに残す"
  kit discover adopt nothing@x >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "1" "見つからない候補は 1"
  kit discover adopt 1 --bad >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "不明なオプションは使い方の誤り"
}
s_adopt_search() {
  setup
  echo '[{"kind":"plugin","id":"zz@official","name":"zz","source":"./zz","marketplace":"official"}]' >"$(state_file A discover/search.json)"
  kit discover adopt zz@official >/dev/null; rc=$?
  assert_eq "$rc" "0" "直前の検索結果からも入れられる"
  assert_contains "$(fake_calls)" "claude plugin install zz@official -s user --json" "検索結果の候補を入れる"
}
s_status() {
  setup
  out="$(kit status)"
  assert_contains "$out" "未処理のおすすめ: 4 件（/kit:discover で確認）" "おすすめの件数"
  assert_contains "$out" "前回の発見の分析: まだありません" "前回の分析"
}

t_scenario "一覧" s_list
t_scenario "却下" s_dismiss
t_scenario "manifest が壊れていたら却下しない" s_broken_manifest
t_scenario "ウォッチリスト" s_watch
t_scenario "プラグインを入れる" s_adopt_plugin
t_scenario "未登録のマーケットプレイスのプラグインを入れる" s_adopt_unregistered
t_scenario "登録済みになったマーケットプレイスのプラグインを入れる" s_adopt_registered_watch
t_scenario "コマンドを実行するプラグインは承認を求める" s_adopt_command
t_scenario "スキルを入れる" s_adopt_skill
t_scenario "ウォッチ候補を承認する" s_adopt_watch
t_scenario "導入の失敗" s_adopt_fail
t_scenario "検索結果から入れる" s_adopt_search
t_scenario "kit status" s_status
t_done

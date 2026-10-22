. "$(dirname "$0")/helpers.sh"
t_tmp
export HOME="${T_TMP}/home" KIT_STATE_DIR="${T_TMP}/state" KIT_DOTFILES="${T_TMP}/dot"
. "${KIT_PLUGIN_DIR}/lib/common.sh"
. "${KIT_PLUGIN_DIR}/lib/merge.sh"

# m3 <L> <B> <R> [failures]: H と W は空、上限 3 で 3 者比較する
m3() {
  local f="${4:-}"
  [ -n "$f" ] || f='{}'
  kit_merge3 "$(jq -nc --argjson L "$1" --argjson B "$2" --argjson R "$3" --argjson f "$f" \
    '{L: $L, B: $B, R: $R, H: {}, W: {}, failures: $f, max_failures: 3}')"
}
p() { printf '{"plugins":%s}' "$1"; }
# check <説明> <L> <B> <R> <期待する M.plugins> <期待する ops（"op key to" の配列）> [failures]
check() {
  local r
  r="$(m3 "$(p "$2")" "$(p "$3")" "$(p "$4")" "${7:-}")"
  assert_json_eq "$(jq -c .M.plugins <<<"$r")" "$5" "$1: M"
  assert_json_eq "$(jq -c '[.ops[] | "\(.op) \(.key) \(.to | tojson)"]' <<<"$r")" "$6" "$1: ops"
}

# 設計書 §7.3 の表
check "変更なし"                 '{"a":true}' '{"a":true}' '{"a":true}' '{"a":true}' '[]'
check "このマシンで追加"         '{"a":true,"b":true}' '{"a":true}' '{"a":true}' '{"a":true,"b":true}' '[]'
check "このマシンで削除"         '{}' '{"a":true}' '{"a":true}' '{}' '[]'
check "他のマシンで追加"         '{}' '{}' '{"a":true}' '{"a":true}' '["add a true"]'
check "他のマシンで削除"         '{"a":true}' '{"a":true}' '{}' '{}' '["remove a null"]'
check "他のマシンで無効化"       '{"a":true}' '{"a":true}' '{"a":false}' '{"a":false}' '["change a false"]'
check "両方で同じ変更"           '{"a":false}' '{"a":true}' '{"a":false}' '{"a":false}' '[]'
check "衝突: 削除と無効化"       '{}' '{"a":true}' '{"a":false}' '{"a":false}' '["add a false"]'
check "衝突: true と false"      '{"a":true}' '{}' '{"a":false}' '{"a":true}' '[]'
check "初回同期は和集合"         '{"a":true}' '{}' '{"b":true}' '{"a":true,"b":true}' '["add b true"]'
check "false を「なし」と区別する" '{"a":false}' '{"a":false}' '{"a":false}' '{"a":false}' '[]'
check "失敗が上限の項目は操作しない" '{}' '{}' '{"a":true}' '{"a":true}' '[]' '{"plugins/a":3}'

r="$(m3 "$(p '{}')" "$(p '{}')" "$(p '{"a":true}')" '{"plugins/a":3}')"
assert_json_eq "$(jq -c .skipped <<<"$r")" '[{"section":"plugins","key":"a"}]' "上限の項目は skipped に入る"
r="$(m3 "$(p '{}')" "$(p '{"a":true}')" "$(p '{"a":false}')")"
assert_json_eq "$(jq -c .conflicts <<<"$r")" '[{"section":"plugins","key":"a","local":null,"remote":false,"chosen":false}]' "衝突を記録する"
r="$(m3 "$(p '{"a":true,"b":true}')" "$(p '{"a":true}')" "$(p '{"a":true}')")"
assert_json_eq "$(jq -c .local_changes <<<"$r")" '[{"section":"plugins","key":"b"}]' "このマシンでの変更を記録する"

# マーケットプレイスとスキル
r="$(m3 '{"marketplaces":{"m":{"source":"github","repo":"x/one"}}}' '{}' '{"marketplaces":{"m":{"source":"github","repo":"x/two"}}}')"
assert_json_eq "$(jq -c .M.marketplaces.m <<<"$r")" '{"source":"github","repo":"x/two"}' "マーケットプレイスの衝突は R を採る"
assert_eq "$(jq -r '.ops[0].op' <<<"$r")" "change" "マーケットプレイスのソース変更は change"
r="$(m3 '{"skills":{}}' '{}' '{"skills":{"s1":{"source":"o/r"}}}')"
assert_json_eq "$(jq -c .ops <<<"$r")" '[{"section":"skills","key":"s1","op":"add","from":null,"to":{"source":"o/r"}}]' "スキルの追加"
assert_json_eq "$(jq -c '.M | keys' <<<"$r")" '["discovery","marketplaces","plugins","skills","version"]' "M は manifest の全キーを持つ"

# discovery のマージ（設計書 §7.4）: (R ∪ (W − H)) − (H − W)
dm() {
  kit_merge3 "$(jq -nc --argjson H "$1" --argjson W "$2" --argjson R "$3" \
    '{L: {}, B: {}, R: $R, H: $H, W: $W, failures: {}, max_failures: 3}')" | jq -c .M.discovery
}
assert_json_eq "$(dm '{"discovery":{"watch":["x","y"],"dismissed":[]}}' \
                     '{"discovery":{"watch":["x"],"dismissed":[{"id":"p1"}]}}' \
                     '{"discovery":{"watch":["x","y","z"],"dismissed":[{"id":"p2"}]}}')" \
  '{"watch":["x","z"],"dismissed":[{"id":"p1"},{"id":"p2"}]}' "W で足したものは足し、W で消したものは消し、他は R に従う"
assert_json_eq "$(dm '{"discovery":{"watch":["x"]}}' '{"discovery":{"watch":["x","y"]}}' '{"discovery":{"watch":["x"]}}')" \
  '{"watch":["x","y"],"dismissed":[]}' "オフライン（R = H）なら W のまま"
assert_json_eq "$(dm '{}' '{"discovery":{"dismissed":[{"id":"p1","reason":"新"}]}}' '{"discovery":{"dismissed":[{"id":"p1","reason":"旧"}]}}')" \
  '{"watch":[],"dismissed":[{"id":"p1","reason":"新"}]}' "同じ id は W の内容を採る"

# base の更新規則（設計書 §7.5 手順 9）
bu() {
  kit_base_update "$(jq -nc --argjson M "$1" --argjson L2 "$2" --argjson R2 "$3" --argjson B "$4" \
    '{M: $M, L2: $L2, R2: $R2, B: $B}')" | jq -c .plugins
}
assert_json_eq "$(bu "$(p '{"a":true}')" "$(p '{"a":true}')" "$(p '{"a":true}')" '{}')" '{"a":true}' "push できたら合意する"
assert_json_eq "$(bu "$(p '{"a":true}')" "$(p '{"a":true}')" '{}' '{}')" '{}' "push できなければ合意しない"
assert_json_eq "$(bu "$(p '{"a":true}')" '{}' "$(p '{"a":true}')" '{}')" '{}' "反映に失敗したら合意しない"
assert_json_eq "$(bu '{}' '{}' '{}' "$(p '{"a":true}')")" '{}' "削除も合意する"
assert_json_eq "$(bu "$(p '{"a":false}')" "$(p '{"a":false}')" "$(p '{"a":false}')" '{}')" '{"a":false}' "false も合意する"

# 大量削除の歯止め（レビュー C4）: 1 回の同期で 3 件以上の削除は、--allow-removals がなければ止める
g3() {  # <L> <B> <R> <allow>
  kit_merge3 "$(jq -nc --argjson L "$1" --argjson B "$2" --argjson R "$3" --argjson allow "$4" \
    '{L: $L, B: $B, R: $R, H: {}, W: {}, failures: {}, max_failures: 3, allow_removals: $allow, removal_guard: 3}')"
}
abc="$(p '{"a":true,"b":true,"c":true}')"
r="$(g3 "$(p '{}')" "$abc" "$abc" false)"
assert_json_eq "$(jq -c .M.plugins <<<"$r")" '{"a":true,"b":true,"c":true}' "このマシンでの 3 件以上の削除は manifest に書かない"
assert_eq "$(jq '.blocked_removals | length' <<<"$r")" "3" "止めた削除を報告する（このマシン）"
r="$(g3 "$abc" "$abc" "$(p '{}')" false)"
assert_json_eq "$(jq -c .ops <<<"$r")" '[]' "他のマシンでの 3 件以上の削除は反映しない"
assert_eq "$(jq '.blocked_removals | length' <<<"$r")" "3" "止めた削除を報告する（他のマシン）"
r="$(g3 "$abc" "$abc" "$(p '{}')" true)"
assert_eq "$(jq '[.ops[] | select(.op == "remove")] | length' <<<"$r")" "3" "--allow-removals なら反映する"
r="$(g3 "$(p '{"a":true}')" "$abc" "$abc" false)"
assert_json_eq "$(jq -c .M.plugins <<<"$r")" '{"a":true}' "2 件までの削除は止めない"
assert_eq "$(jq '.blocked_removals | length' <<<"$r")" "0" "2 件までなら何も止めない"

t_done

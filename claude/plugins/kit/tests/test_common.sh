. "$(dirname "$0")/helpers.sh"
t_tmp
export HOME="${T_TMP}/home" KIT_STATE_DIR="${T_TMP}/state" KIT_DOTFILES="${T_TMP}/dot"
. "${KIT_PLUGIN_DIR}/lib/common.sh"

# kit_write_json / kit_read_json
kit_write_json "${T_TMP}/x.json" '{"b":1,"a":{"d":2,"c":3}}'
assert_eq "$(cat "${T_TMP}/x.json")" "$(printf '{\n  "a": {\n    "c": 3,\n    "d": 2\n  },\n  "b": 1\n}')" "キーをソートしインデント 2 で書く"
kit_write_json "${T_TMP}/x.json" '{'; rc=$?
assert_eq "$rc" "1" "不正な JSON は書かずに失敗する"
assert_eq "$(jq -c . "${T_TMP}/x.json")" '{"a":{"c":3,"d":2},"b":1}' "失敗しても元のファイルは残る"
assert_eq "$(kit_read_json "${T_TMP}/none.json" '{"d":1}')" '{"d":1}' "ないファイルは既定値"
kit_json_eq '{"a":1,"b":2}' '{"b":2,"a":1}'; assert_eq "$?" "0" "キーの順序は比較に影響しない"

# 通知
kit_notice info "一つ目"; kit_notice info "二つ目"; kit_notice info "一つ目"
got="$(kit_take_notices)"
assert_eq "$(jq length <<<"$got")" "2" "同じ文面はまとめる"
assert_eq "$(jq -r '.[0].level' <<<"$got")" "info" "level を持つ"
assert_eq "$(kit_take_notices)" "[]" "取り出したら空になる"
KIT_NOTICE_SUPPRESS_SECONDS=21600
kit_notice warn "警告A"; kit_notice warn "警告A"
assert_eq "$(kit_take_notices | jq length)" "1" "同じ警告は抑制期間中は 1 回だけ"
KIT_NOTICE_SUPPRESS_SECONDS=0
kit_notice warn "警告A"
assert_eq "$(kit_take_notices | jq length)" "1" "抑制期間が過ぎれば再び通知する"

# ロック
kit_lock; assert_eq "$?" "0" "ロックを取れる"
kit_lock; assert_eq "$?" "1" "取得済みなら取れない"
touch -t 202001010000 "${KIT_STATE}/lock"
kit_lock; assert_eq "$?" "0" "古いロックは消して取り直す"
kit_unlock
assert_eq "$([ -d "${KIT_STATE}/lock" ] && echo yes || echo no)" "no" "解除する"

# タイムアウト
start="$(t_ms)"; kit_with_timeout 1 sleep 5; rc=$?; end="$(t_ms)"
assert_ne "$rc" "0" "タイムアウトしたら 0 以外"
assert_lt "$((end - start))" "3000" "指定秒数で打ち切る"
err="$( (kit_with_timeout 1 sleep 5) 2>&1)"; rc=$?
assert_eq "$rc" "124" "タイムアウトの終了コードは 124"
assert_eq "$err" "" "シェルのシグナル報告（Alarm clock）をログに混ぜない"
kit_with_timeout 5 sh -c 'exit 3'; assert_eq "$?" "3" "時間内に終われば子の終了コードを返す"

# git の外（キャッシュのコピー）から動いても、記録したパスで dotfiles を見つける（Review Focus 4）
mkdir -p "${T_TMP}/copy" "${T_TMP}/state2"
cp -R "${KIT_PLUGIN_DIR}/lib" "${T_TMP}/copy/lib"
printf '%s' "/path/to/dotfiles" >"${T_TMP}/state2/dotfiles-path"
got="$(env -u KIT_DOTFILES KIT_STATE_DIR="${T_TMP}/state2" /bin/bash -c ". '${T_TMP}/copy/lib/common.sh'; printf '%s' \"\$KIT_DOTFILES\"")"
assert_eq "$got" "/path/to/dotfiles" "git の外からは記録したパスを使う"

# bin/kit
out="$(/bin/bash "$KIT_BIN" help)"; assert_contains "$out" "usage: kit" "help を表示する"
/bin/bash "$KIT_BIN" nosuch >/dev/null 2>&1; assert_eq "$?" "2" "不明なコマンドは 2"

t_done

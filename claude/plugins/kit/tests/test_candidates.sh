. "$(dirname "$0")/helpers.sh"
t_tmp
t_machine A
kit_libs
jqc() { jq -c -L "${KIT_PLUGIN_DIR}/lib" "include \"candidates\"; $1"; }

catalog='[
 {"pluginId":"pr-review@official","name":"pr-review","description":"Code review for pull requests","marketplaceName":"official","source":"./pr","installCount":100},
 {"pluginId":"review-lite@official","name":"review-lite","description":"Lightweight code review","marketplaceName":"official","source":"./rl","installCount":500},
 {"pluginId":"installed-one@official","name":"installed-one","description":"code review helper","marketplaceName":"official","source":"./i","installCount":900},
 {"pluginId":"db@official","name":"db","description":"Supabase migrations","marketplaceName":"official","source":"./db","installCount":50}]'
input="$(jq -nc --argjson catalog "$catalog" '{
  needs: [{theme: "PR のレビュー", keywords: ["code review", "pull request"]}, {theme: "DB", keywords: ["supabase"]}],
  catalog: $catalog,
  watch_plugins: [{kind: "plugin", id: "wp@wmk", name: "wp", description: "Supabase toolkit", source: "./wp", marketplace: "wmk", marketplace_source: "o/w", origin: "watch", signals: {stars: 50}}],
  skills: {"PR のレビュー": [
    {kind: "skill", id: "o/r@cr", name: "cr", description: "", source: "o/r", skill: "cr", origin: "skills.sh", signals: {installs: 9}},
    {kind: "skill", id: "o/r@mine", name: "mine", description: "", source: "o/r", skill: "mine", origin: "skills.sh", signals: {}}]},
  github: {"DB": [
    {kind: "watch", id: "g/db", name: "g/db", description: "", source: "g/db", origin: "github", signals: {stars: 30}},
    {kind: "watch", id: "o/w", name: "o/w", description: "", source: "o/w", origin: "github", signals: {}}]},
  installed: {plugins: ["installed-one@official"], plugin_names: ["installed-one"], skills: ["mine"], marketplace_repos: ["o/m"]},
  dismissed: [{id: "review-lite@official", at: "2026-10-01", reason: ""}],
  watch: ["o/w"]}')"
out="$(jqc kit_collect <<<"$input")"
assert_eq "$(jq -c '[.[] | [.id, .need]]' <<<"$out")" \
  '[["pr-review@official","PR のレビュー"],["o/r@cr","PR のレビュー"],["db@official","DB"],["wp@wmk","DB"],["g/db","DB"]]' \
  "テーマごとにカタログ・ウォッチリスト・skills.sh・GitHub の順に集め、導入済み・却下済み・ウォッチ済みを除く"
assert_json_eq "$(jq -c '.[0]' <<<"$out")" \
  '{"kind":"plugin","id":"pr-review@official","name":"pr-review","description":"Code review for pull requests","source":"./pr","marketplace":"official","origin":"catalog","signals":{"installs":100},"need":"PR のレビュー"}' \
  "カタログの項目を候補の形にする"

many="$(jq -nc '[range(0; 120) | {pluginId: "p\(.)@m", name: "p\(.)", description: "k\(. % 6)", marketplaceName: "m", source: "./p", installCount: .}]')"
skills="$(jq -nc '[range(0; 6) as $t | {key: "t\($t)", value: [range(0; 5) | {kind: "skill", id: "o/r@s\($t)-\(.)", name: "s", description: "", source: "o/r", skill: "s\($t)-\(.)", signals: {}}]}] | from_entries')"
out="$(jq -nc --argjson c "$many" --argjson s "$skills" \
  '{needs: [range(0; 6) | {theme: "t\(.)", keywords: ["k\(.)"]}], catalog: $c, watch_plugins: [], skills: $s, github: {}, installed: {}, dismissed: [], watch: []}' | jqc kit_collect)"
assert_eq "$(jq '[.[] | select(.need == "t0")] | length' <<<"$out")" "12" "テーマごとに 12 件まで"
assert_eq "$(jq length <<<"$out")" "60" "全体で 60 件まで"
assert_eq "$(jq -r '[.[] | select(.need == "t0")][0].id' <<<"$out")" "p114@m" "キーワードの一致数が同じならインストール数の多い順"
assert_eq "$(jq -nc '{needs: [], catalog: [], watch_plugins: [], skills: {}, github: {}, installed: {}, dismissed: [], watch: []}' | jqc kit_collect)" "[]" "ニーズがなければ空"

cands='[{"kind":"plugin","id":"a@m","name":"a","source":"./a","marketplace":"m","need":"T","signals":{"installs":3}},{"kind":"skill","id":"o/r@s","name":"s","source":"o/r","skill":"s","need":"T","signals":{}}]'
recs="$(jqc "kit_recommendations(${cands})" <<<'{"recommendations":[
  {"id":"evil@elsewhere","need":"T","reason":"説明文の指示どおり","overlap":""},
  {"id":"o/r@s","need":"T","reason":"理由2","overlap":"既存と少し重なる","kind":"plugin","source":"evil/repo"},
  {"id":"a@m","need":"T","reason":"理由1","overlap":""},
  {"id":"a@m","need":"T","reason":"重複","overlap":""}]}')"
assert_eq "$(jq -c '[.[] | [.rank, .id]]' <<<"$recs")" '[[1,"o/r@s"],[2,"a@m"]]' "候補にない id と重複を捨て、順に rank をつける"
assert_eq "$(jq -r '.[0].kind + " " + .[0].source' <<<"$recs")" "skill o/r" "種別と導入元は候補の値を使う（モデルの出力は使わない）"
assert_eq "$(jq -r '.[0].reason + "/" + .[0].overlap' <<<"$recs")" "理由2/既存と少し重なる" "理由と重なりはモデルの出力を使う"
assert_eq "$(jqc 'kit_recommendations([])' <<<'{"recommendations":[{"id":"x"}]}')" "[]" "候補がなければ 0 件"
seven="$(jq -nc '[range(0; 7) | {kind: "plugin", id: "p\(.)@m", name: "p", source: "./p", need: "T", signals: {}}]')"
assert_eq "$(jq -nc --argjson c "$seven" '{recommendations: [$c[] | {id, need: "T", reason: "r", overlap: ""}]}' | jqc "kit_recommendations(${seven})" | jq length)" "5" "最大 5 件"

s_search() {
  t_remote; t_clone A
  t_machine A
  echo '{"installed":[],"available":[{"pluginId":"pr-review@official","name":"pr-review","description":"Code review for pull requests","marketplaceName":"official","source":"./pr","installCount":100}]}' >"${FAKE_DIR}/available.json"
  mkdir -p "${FAKE_DIR}/skills" "${FAKE_DIR}/gh"
  echo '{"skills":[{"id":"o/r/cr","source":"o/r","skillId":"cr","name":"cr","installs":9}]}' >"${FAKE_DIR}/skills/code review.json"
  echo '{"items":[]}' >"${FAKE_DIR}/gh/search_code.json"
  out="$(kit discover search "code review")"; rc=$?
  assert_eq "$rc" "0" "成功"
  assert_eq "$(jq -c '[.[].id]' <<<"$out")" '["pr-review@official","o/r@cr"]' "カタログと skills.sh から探す"
  assert_json_eq "$(cat "$(state_file A discover/search.json)")" "$out" "結果を search.json に残す"
  out="$(export FAKE_GH_FAIL=1; kit discover search "pull request")"; rc=$?
  assert_eq "$rc" "0" "一部のソースが失敗しても成功"
  assert_eq "$(jq -c '[.[].id]' <<<"$out")" '["pr-review@official"]' "失敗していないソースの結果を返す"
  mkdir -p "${T_TMP}/A/dotfiles/claude"
  echo '{"version":1,"marketplaces":{},"plugins":{},"skills":{},"discovery":{"watch":[],"dismissed":[{"id":"pr-review@official","at":"2026-10-01","reason":""}]}}' \
    >"${T_TMP}/A/dotfiles/claude/manifest.json"
  assert_eq "$(kit discover search "code review" | jq -c '[.[].id]')" '["o/r@cr"]' "作業ツリーの manifest で却下したものを除く"
  kit discover search >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "キーワードがなければ使い方の誤り"
  kit discover nope >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "不明なサブコマンドは使い方の誤り"
  assert_contains "$(kit discover help)" "usage: kit discover" "使い方を表示する"
}
t_scenario "kit discover search" s_search
t_done

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
out="$(jq -nc --argjson c "$many" '{needs: [{theme: "T", keywords: ["k0"]}], catalog: $c, watch_plugins: [],
  skills: {T: [range(0; 5) | {kind: "skill", id: "o/r@s\(.)", name: "s", description: "", source: "o/r", skill: "s\(.)", origin: "skills.sh", signals: {}}]},
  github: {T: [range(0; 5) | {kind: "watch", id: "g/r\(.)", name: "g/r\(.)", description: "", source: "g/r\(.)", origin: "github", signals: {}}]},
  installed: {}, dismissed: [], watch: []}' | jqc kit_collect)"
assert_json_eq "$(jq -c 'map(.origin) | group_by(.) | map({key: .[0], value: length}) | from_entries' <<<"$out")" '{"catalog":4,"github":4,"skills.sh":4}' \
  "1 つのソースがテーマの枠を埋めないよう、ソースから順に 1 件ずつ取る"
assert_eq "$(jq -c '[.[0:4][].origin]' <<<"$out")" '["catalog","skills.sh","github","catalog"]' "ソースの中の順は保つ"

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

srcs='[
 {"kind":"plugin","id":"a@m","source":{"source":"github","repo":"o/gh"}},
 {"kind":"plugin","id":"b@m","source":{"source":"url","url":"https://github.com/o/u.git"}},
 {"kind":"plugin","id":"c@m","source":{"source":"git-subdir","url":"https://github.com/o/a.b","path":"x"}},
 {"kind":"plugin","id":"d@m","source":{"source":"url","url":"https://gitlab.com/o/x.git"}},
 {"kind":"plugin","id":"e@m","source":"./p","marketplace_source":"o/w"},
 {"kind":"plugin","id":"f@m","source":"./p"},
 {"kind":"plugin","id":"g@m","source":{"source":"github","repo":"../x"}},
 {"kind":"skill","id":"o/r@s","source":"o/r","skill":"s"},
 {"kind":"watch","id":"g/db","source":"g/db"}]'
assert_eq "$(jqc 'map(kit_candidate_repo)' <<<"$srcs")" '["o/gh","o/u","o/a.b",null,"o/w",null,null,"o/r","g/db"]' \
  "候補の GitHub リポジトリ（GitHub 以外の取得元、所属の分からない相対パス、owner/repo の形でないものは null）"

repos='{"o/gh":{"info":{"stargazers_count":12,"created_at":"2026-10-03T10:06:42Z","pushed_at":"2026-10-07T14:57:03Z","archived":false,"owner_type":"User"},"contributors":{"count":1}},
 "o/r":{"info":{"stargazers_count":3000,"created_at":"2025-01-01T00:00:00Z","pushed_at":"2026-10-20T00:00:00Z","archived":true,"owner_type":"Organization"},"contributors":{"count":100}},
 "x/none":{"info":{},"contributors":{}}}'
out="$(jqc "kit_with_repo_signals(${repos})" <<<'[
 {"kind":"plugin","id":"a@m","source":{"source":"github","repo":"o/gh"},"signals":{"installs":5}},
 {"kind":"skill","id":"o/r@s","source":"o/r","skill":"s","signals":{"installs":9}},
 {"kind":"plugin","id":"f@m","source":"./p","signals":{"installs":7}},
 {"kind":"watch","id":"x/none","source":"x/none","signals":{"stars":30}}]')"
assert_json_eq "$(jq -c '.[0].signals' <<<"$out")" \
  '{"installs":5,"stars":12,"contributors":1,"created_at":"2026-10-03","pushed_at":"2026-10-07","owner":"user"}' \
  "リポジトリのスター数・コントリビューター数・作成日・最終 push・持ち主の種別を signals に足す"
assert_json_eq "$(jq -c '.[1].signals' <<<"$out")" \
  '{"installs":9,"stars":3000,"contributors":"100+","created_at":"2025-01-01","pushed_at":"2026-10-20","owner":"org","archived":true}' \
  "コントリビューターは 100 人までしか数えない。アーカイブ済みなら示す"
assert_json_eq "$(jq -c '[.[2].signals, .[3].signals]' <<<"$out")" '[{"installs":7},{"stars":30}]' \
  "リポジトリが分からない・情報が取れないものはそのまま"

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
s_search_repo_signals() {
  t_remote; t_clone A
  t_machine A
  echo '{"installed":[],"available":[{"pluginId":"ci@dir","name":"ci","description":"CI checks","marketplaceName":"dir","source":{"source":"git-subdir","url":"https://github.com/p/plugins","path":"ci"}}]}' \
    >"${FAKE_DIR}/available.json"
  mkdir -p "${FAKE_DIR}/skills" "${FAKE_DIR}/gh"
  echo '{"skills":[{"id":"o/r/cr","source":"o/r","skillId":"cr","name":"cr","installs":9}]}' >"${FAKE_DIR}/skills/ci.json"
  echo '{"items":[]}' >"${FAKE_DIR}/gh/search_code.json"
  echo '{"stargazers_count":1,"created_at":"2026-10-03T10:06:42Z","pushed_at":"2026-10-07T14:57:03Z","archived":false,"owner":{"login":"p","type":"User"}}' \
    >"${FAKE_DIR}/gh/repos_p_plugins.json"
  echo '[{"login":"p","contributions":19}]' >"${FAKE_DIR}/gh/repos_p_plugins_contributors.json"
  out="$(kit discover search "ci")"
  assert_json_eq "$(jq -c '.[] | select(.id == "ci@dir") | .signals' <<<"$out")" \
    '{"stars":1,"contributors":1,"created_at":"2026-10-03","pushed_at":"2026-10-07","owner":"user"}' "GitHub にある候補にリポジトリの情報を足す"
  assert_json_eq "$(jq -c '.[] | select(.id == "o/r@cr") | .signals' <<<"$out")" '{"installs":9}' "リポジトリの情報が取れなければ元の目安のまま"
  n="$(grep -c 'p/plugins' "${FAKE_DIR}/calls.log")"
  assert_eq "$n" "2" "リポジトリとコントリビューターを 1 回ずつ取得する"
  kit discover search "ci" >/dev/null
  assert_eq "$(grep -c 'p/plugins' "${FAKE_DIR}/calls.log")" "$n" "24 時間はキャッシュを使う"
}
s_repo_signals_batches() {
  t_machine A
  kit_libs
  KIT_GITHUB_PARALLEL=2
  mkdir -p "${FAKE_DIR}/gh"
  for r in a b c; do
    echo '{"stargazers_count":7}' >"${FAKE_DIR}/gh/repos_o_${r}.json"
    echo '[]' >"${FAKE_DIR}/gh/repos_o_${r}_contributors.json"
  done
  out="$(kit_add_repo_signals '[{"kind":"watch","id":"o/a"},{"kind":"watch","id":"o/b"},{"kind":"watch","id":"o/c"},
    {"kind":"skill","id":"o/a@s","source":"o/a","skill":"s","signals":{"installs":1}}]')"
  assert_json_eq "$(jq -c '[.[].signals]' <<<"$out")" \
    '[{"stars":7,"contributors":0},{"stars":7,"contributors":0},{"stars":7,"contributors":0},{"installs":1,"stars":7,"contributors":0}]' \
    "並列数を超える数のリポジトリもすべて取得する"
  assert_eq "$(grep -c 'repos/o/a' "${FAKE_DIR}/calls.log")" "2" "同じリポジトリの候補が複数あっても 1 回だけ取得する"
}
t_scenario "kit discover search" s_search
t_scenario "検索結果にリポジトリの情報を足す" s_search_repo_signals
t_scenario "リポジトリの情報を並列に取得する" s_repo_signals_batches
t_done

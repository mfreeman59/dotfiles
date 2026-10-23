. "$(dirname "$0")/helpers.sh"
t_tmp
t_machine A
kit_libs

# 登録済みカタログ（24 時間キャッシュ）
echo '{"installed":[],"available":[{"pluginId":"a@m","name":"a","description":"A","marketplaceName":"m","source":"./a","installCount":5}]}' >"${FAKE_DIR}/available.json"
f="$(kit_catalog_file)"
assert_eq "$(jq -c '[.[].pluginId]' "$f")" '["a@m"]' "カタログを取得する"
kit_catalog_file >/dev/null
assert_eq "$(grep -c 'plugin list --available --json' "${FAKE_DIR}/calls.log")" "1" "24 時間以内はキャッシュを使う"
echo '{"installed":[],"available":[{"pluginId":"b@m","name":"b","marketplaceName":"m","source":"./b"}]}' >"${FAKE_DIR}/available.json"
touch -t 202001010000 "${KIT_STATE_DIR}/catalog.json"
f="$(kit_catalog_file)"
assert_eq "$(jq -c '[.[].pluginId]' "$f")" '["b@m"]' "古くなったら取り直す"
touch -t 202001010000 "${KIT_STATE_DIR}/catalog.json"
f="$(export FAKE_BROKEN=1; kit_catalog_file)"
assert_eq "$(jq -c '[.[].pluginId]' "$f")" '["b@m"]' "取得に失敗したら前回のキャッシュを使う"
rm "${KIT_STATE_DIR}/catalog.json"
f="$(export FAKE_BROKEN=1; kit_catalog_file)"
assert_eq "$(cat "$f")" "[]" "キャッシュもなければ空"
assert_eq "$([ -e "${KIT_STATE_DIR}/catalog.json" ] && echo yes || echo no)" "no" "失敗を 24 時間のキャッシュにしない"

# skills.sh
mkdir -p "${FAKE_DIR}/skills" "${FAKE_DIR}/gh"
echo '{"skills":[{"id":"o/r/s1","source":"o/r","skillId":"s1","name":"s1","installs":10},{"id":"bad","name":"x"}]}' >"${FAKE_DIR}/skills/code review.json"
assert_json_eq "$(kit_skills_search "code review" 5)" \
  '[{"kind":"skill","id":"o/r@s1","name":"s1","description":"","source":"o/r","skill":"s1","origin":"skills.sh","signals":{"installs":10}}]' \
  "skills.sh の検索結果を候補にする（source と skillId のないものは捨てる）"
assert_contains "$(fake_calls)" "curl -fsS -m 15 -G https://skills.sh/api/search --data-urlencode q=code review --data-urlencode limit=5" "skills.sh の検索 API を関連度の順のまま使う"
assert_eq "$(kit_skills_search "nothing" 5)" "[]" "検索に失敗したら空"

# ウォッチリスト（24 時間キャッシュ）
echo '{"name":"wmk","plugins":[{"name":"p1","description":"Postgres helper","source":"./plugins/p1"},{"description":"名前なし"}]}' \
  >"${FAKE_DIR}/gh/repos_o_w_contents_.claude-plugin_marketplace.json.json"
echo '{"stargazers_count":50,"pushed_at":"2026-10-01T00:00:00Z","archived":false,"description":"W"}' >"${FAKE_DIR}/gh/repos_o_w.json"
assert_json_eq "$(kit_watch_candidates '["o/w","bad repo","../x","o/..","*/*"]')" \
  '[{"kind":"plugin","id":"p1@wmk","name":"p1","description":"Postgres helper","source":"./plugins/p1","marketplace":"wmk","marketplace_source":"o/w","origin":"watch","signals":{"stars":50,"pushed_at":"2026-10-01"}}]' \
  "ウォッチリストのマーケットプレイスのプラグインを候補にする（owner/repo の形でないものは無視）"
kit_watch_candidates '["o/w"]' >/dev/null
assert_eq "$(grep -c 'contents/.claude-plugin' "${FAKE_DIR}/calls.log")" "1" "24 時間以内はキャッシュを使う"
assert_eq "$(kit_watch_candidates '["o/none"]')" "[]" "取得できなければ空"
assert_eq "$([ -e "${KIT_STATE_DIR}/discover/watch-cache/o_none.json" ] && echo yes || echo no)" "no" "エラーの応答をキャッシュしない"

# GitHub 全体
recent="$(date -u -v-10d +%Y-%m-%dT%H:%M:%SZ)"
old="$(date -u -v-400d +%Y-%m-%dT%H:%M:%SZ)"
echo '{"items":[{"repository":{"full_name":"g/good"}},{"repository":{"full_name":"g/few"}},{"repository":{"full_name":"g/stale"}},{"repository":{"full_name":"g/arch"}},{"repository":{"full_name":"g/good"}}]}' \
  >"${FAKE_DIR}/gh/search_code.json"
jq -n --arg t "$recent" '{stargazers_count: 30, pushed_at: $t, archived: false, description: "good"}' >"${FAKE_DIR}/gh/repos_g_good.json"
jq -n --arg t "$recent" '{stargazers_count: 5, pushed_at: $t, archived: false}' >"${FAKE_DIR}/gh/repos_g_few.json"
jq -n --arg t "$old" '{stargazers_count: 99, pushed_at: $t, archived: false}' >"${FAKE_DIR}/gh/repos_g_stale.json"
jq -n --arg t "$recent" '{stargazers_count: 99, pushed_at: $t, archived: true}' >"${FAKE_DIR}/gh/repos_g_arch.json"
out="$(kit_github_search "code review")"
assert_eq "$(jq -c '[.[].id]' <<<"$out")" '["g/good"]' "スター 20 以上・180 日以内に push・アーカイブでないものだけ"
assert_eq "$(jq -r '.[0] | "\(.kind) \(.signals.stars) \(.signals.pushed_at) \(.description)"' <<<"$out")" "watch 30 ${recent:0:10} good" "ウォッチ候補として出す"
assert_contains "$(fake_calls)" "gh api -X GET search/code -f q=filename:marketplace.json path:.claude-plugin code review -f per_page=10" "marketplace.json を持つリポジトリをコード検索する"
assert_eq "$(export FAKE_GH_FAIL=1; kit_github_search "x")" "[]" "gh が失敗したら空"

# 導入済みのもの
fake_set '.plugins = [{"id":"x@m","enabled":true},{"id":"y@m","enabled":false,"scope":"project"}] | .marketplaces = [{"name":"m","source":"github","repo":"o/m"}]'
mkdir -p "${HOME}/.agents" "${HOME}/.claude/skills/my-skill"
echo '{"skills":{"s1":{"source":"o/r"}}}' >"${HOME}/.agents/.skill-lock.json"
assert_json_eq "$(kit_installed)" '{"plugins":["x@m","y@m"],"plugin_names":["x","y"],"skills":["my-skill","s1"],"marketplace_repos":["o/m"]}' \
  "導入済みのもの（プロジェクトスコープのプラグインと ~/.claude/skills も含む）"
t_done

. "$(dirname "$0")/helpers.sh"
t_tmp
t_machine A
. "${KIT_PLUGIN_DIR}/lib/common.sh"
. "${KIT_PLUGIN_DIR}/lib/local_state.sh"

fake_set '.marketplaces = [
    {"name":"official","source":"github","repo":"x/official"},
    {"name":"agents","source":"github","repo":"w/agents"},
    {"name":"dotfiles","source":"directory","path":"/d/claude"},
    {"name":"mylocal","source":"directory","path":"/m"}]
  | .plugins = [
    {"id":"a@official","enabled":true},
    {"id":"b@agents","enabled":false},
    {"id":"kit@dotfiles","enabled":true},
    {"id":"x@mylocal","enabled":true},
    {"id":"p@official","enabled":true,"scope":"project"}]'
mkdir -p "${HOME}/.agents"
echo '{"version":3,"skills":{"find-skills":{"source":"vercel-labs/skills"},"s1":{"source":"o/r","sourceType":"github"}}}' >"${HOME}/.agents/.skill-lock.json"

assert_json_eq "$(kit_local_state)" '{
  "marketplaces":{"official":{"source":"github","repo":"x/official"},"agents":{"source":"github","repo":"w/agents"}},
  "plugins":{"a@official":true,"b@agents":false},
  "skills":{"s1":{"source":"o/r"}}}' "除外対象（dotfiles、ローカルパス、プロジェクトスコープ、find-skills）を除いて読む"

rm "${HOME}/.agents/.skill-lock.json"
assert_json_eq "$(kit_local_state | jq -c .skills)" '{}' "lock ファイルがなければスキルは空"

echo '{' >"${HOME}/.agents/.skill-lock.json"
kit_local_state >/dev/null; rc=$?
assert_eq "$rc" "1" "lock ファイルが壊れていたら失敗する"
rm "${HOME}/.agents/.skill-lock.json"

(export FAKE_BROKEN=1; kit_local_state >/dev/null); rc=$?
assert_eq "$rc" "1" "claude が失敗したら失敗する（空として扱わない。Review Focus 1）"

# 作業ディレクトリのプロジェクト設定（enabledPlugins）に影響されない（レビュー I1）
mkdir -p "${T_TMP}/proj/.claude"
echo '{"enabledPlugins":{"a@official":false,"b@agents":true}}' >"${T_TMP}/proj/.claude/settings.json"
got="$(cd "${T_TMP}/proj" && kit_local_state | jq -c '[.plugins["a@official"], .plugins["b@agents"]]')"
assert_eq "$got" "[true,false]" "プロジェクトの設定で上書きされる前のユーザースコープの値を読む"

t_done

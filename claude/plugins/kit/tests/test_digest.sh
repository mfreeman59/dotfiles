. "$(dirname "$0")/helpers.sh"
t_tmp
t_machine A
. "${KIT_PLUGIN_DIR}/lib/common.sh"
. "${KIT_PLUGIN_DIR}/lib/digest.sh"

P="${HOME}/.claude/projects"
mkdir -p "${P}/-Users-me-proj-a/s1/subagents" "${P}/-Users-me-proj-b"
# u <timestamp> <sessionId> <cwd> <content の JSON> [追加するキーの JSON]: user の記録を 1 行出す
u() {
  jq -nc --arg ts "$1" --arg s "$2" --arg cwd "$3" --argjson c "$4" --argjson x "${5:-null}" \
    '{type: "user", timestamp: $ts, sessionId: $s, cwd: $cwd, message: {role: "user", content: $c}} + ($x // {})'
}

{
  u 2026-10-01T00:00:00.000Z s1 /Users/me/proj-a '"古いプロンプト"' '{"origin":{"kind":"human"}}'
  u 2026-10-10T00:00:00.000Z s1 /Users/me/proj-a '"PR をレビューして"' '{"origin":{"kind":"human"}}'
  u 2026-10-10T00:00:01.000Z s1 /Users/me/proj-a '"<command-name>/clear</command-name>"'
  u 2026-10-10T00:00:02.000Z s1 /Users/me/proj-a '[{"type":"text","text":"Base directory for this skill"}]' '{"isMeta":true}'
  u 2026-10-10T00:00:03.000Z s1 /Users/me/proj-a '"This session is being continued"' '{"isCompactSummary":true}'
  u 2026-10-10T00:00:04.000Z s1 /Users/me/proj-a '"タスクが終わりました"' '{"origin":{"kind":"task-notification"}}'
  u 2026-10-10T00:00:05.000Z s1 /Users/me/proj-a '[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]'
  u 2026-10-10T00:00:06.000Z s1 /Users/me/proj-a '[{"type":"text","text":"画像つきの質問"},{"type":"image","source":{}}]'
  echo '{"type":"assistant","timestamp":"2026-10-10T00:00:07.000Z","sessionId":"s1","cwd":"/Users/me/proj-a","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"FOO=1 git status"}},{"type":"tool_use","name":"Bash","input":{"command":"/usr/bin/git log"}},{"type":"tool_use","name":"Bash","input":{"command":"npm test"}},{"type":"tool_use","name":"Skill","input":{"skill":"superpowers:brainstorming"}},{"type":"tool_use","name":"mcp__slack__send","input":{}},{"type":"tool_use","name":"Read","input":{}}]}}'
  echo 'これは壊れた行'
} >"${P}/-Users-me-proj-a/s1.jsonl"
printf '%s' "$(u 2026-10-11T00:00:00.000Z s2 /Users/me/proj-b '"マイグレーションを作って"')" >"${P}/-Users-me-proj-b/s2.jsonl"   # 末尾に改行がない
u 2026-10-12T00:00:00.000Z s1 /Users/me/proj-a '"サブエージェントへの指示"' >"${P}/-Users-me-proj-a/s1/subagents/agent-1.jsonl"

d="$(kit_digest 2026-10-05T00:00:00Z)"
assert_eq "$(jq -r '[.prompts[].text] | join("|")' <<<"$d")" "マイグレーションを作って|画像つきの質問|PR をレビューして" \
  "自分のプロンプトだけを新しい順に（システム由来・メタ・要約・通知・tool_result・サブエージェント・前回より前を除く）"
assert_eq "$(jq -r '.prompts[0].project' <<<"$d")" "proj-b" "プロンプトにプロジェクト名をつける"
assert_json_eq "$(jq -c .bash_commands <<<"$d")" '[{"command":"git","count":2},{"command":"npm","count":1}]' "Bash の先頭語（環境変数の代入とパスを除く）"
assert_json_eq "$(jq -c .skills <<<"$d")" '[{"name":"superpowers:brainstorming","count":1}]' "スキルの利用回数"
assert_json_eq "$(jq -c .mcp_tools <<<"$d")" '[{"name":"mcp__slack__send","count":1}]' "MCP ツールの利用回数"
assert_json_eq "$(jq -c .projects <<<"$d")" '[{"project":"proj-a","sessions":1},{"project":"proj-b","sessions":1}]' "プロジェクトごとのセッション数"
assert_eq "$(jq -r .since <<<"$d")" "2026-10-05T00:00:00Z" "対象期間の始まり"
assert_ne "$(jq -r .until <<<"$d")" "" "対象期間の終わり"
assert_eq "$(kit_count_prompts 2026-10-05T00:00:00Z)" "3" "前回より後のプロンプトの件数"
assert_eq "$(kit_count_prompts "")" "4" "前回がなければすべて"

long="$(printf 'あ%.0s' $(seq 1 400))"
u 2026-10-13T00:00:00.000Z s3 /Users/me/proj-b "$(jq -nc --arg t "$long" '$t')" >"${P}/-Users-me-proj-b/s3.jsonl"
assert_eq "$(kit_digest 2026-10-12T00:00:00Z | jq -r '.prompts[0].text | length')" "300" "1 件 300 字まで"

big="${T_TMP}/big"
mkdir -p "${big}/p"
s300="$(printf 'あ%.0s' $(seq 1 300))"
jq -nc --arg t "$s300" 'range(0; 250) as $i
  | {type: "user", timestamp: "2026-10-15T00:00:00.\(("00" + ($i | tostring)) | .[-3:])Z", sessionId: "s9", cwd: "/x",
     message: {role: "user", content: "\($i) \($t)"}}' >"${big}/p/s9.jsonl"
d="$(KIT_TRANSCRIPTS_DIR="$big" kit_digest "")"
assert_lt "$(printf '%s' "$d" | wc -c | tr -d ' ')" "61441" "全体を 60KB 以内に切り詰める"
assert_eq "$(jq -r '.prompts[0].text | split(" ")[0]' <<<"$d")" "249" "新しいプロンプトを残す"
assert_lt "$(jq '.prompts | length' <<<"$d")" "201" "最大 200 件"
assert_eq "$(KIT_TRANSCRIPTS_DIR="${T_TMP}/none" kit_count_prompts "")" "0" "トランスクリプトがなければ 0 件"
t_done

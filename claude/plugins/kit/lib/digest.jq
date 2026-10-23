# 発見の ① 抽出（設計書 §8.2）。jq -nR で呼び、トランスクリプトを inputs で 1 行ずつ読む
# （全体をメモリに載せない。壊れた行は飛ばす）。

def kit_records: inputs | (fromjson? // null) | select(type == "object");

def kit_after($since): $since == "" or ((.timestamp // "") > $since);

# プロンプトの本文。文字列、または text / image ブロックだけの配列（画像つきのプロンプト）。tool_result などは null
def kit_prompt_text:
  (.message.content // null) as $c
  | if ($c | type) == "string" then $c
    elif ($c | type) == "array" and ($c | length) > 0 and ($c | all(.type == "text" or .type == "image"))
    then [$c[] | select(.type == "text") | .text] | join("\n")
    else null end;

# 自分が入力したプロンプトか。isMeta（スキルの本文など）、圧縮の要約、human 以外の origin（タスクの通知など）、
# < で始まるシステム由来のもの（コマンドの出力、通知など）を除く
def kit_is_prompt:
  .type == "user"
  and ((.isMeta // false) | not)
  and ((.isCompactSummary // false) | not)
  and ((.origin.kind // "human") == "human")
  and (kit_prompt_text as $t | $t != null and ($t | test("^\\s*<") | not) and ($t | test("\\S")));

# Bash コマンドの先頭語。先頭の環境変数の代入を飛ばし、パスはファイル名だけにする
def kit_bash_head:
  sub("^\\s*([A-Za-z_][A-Za-z0-9_]*=\\S*\\s+)*"; "")
  | ([match("^[^\\s;&|()]+").string] | first // "")
  | if . == "" then "" else (split("/") | last) end;

def kit_top($n): to_entries | sort_by(-.value, .key) | .[0:$n];

# 前回の分析（$since）より後の記録から digest を作る。61,440 バイトを超えたら古いプロンプトから削る
def kit_digest($since; $until):
  reduce (kit_records | select(kit_after($since))) as $r (
    {prompts: [], bash: {}, skills: {}, mcp: {}, sessions: {}};
    ((($r.cwd // "") | split("/") | last) // "") as $proj
    | (if ($r | kit_is_prompt)
       then .prompts += [{at: $r.timestamp, project: $proj, text: ($r | kit_prompt_text | .[0:300])}]
       else . end)
    | (if $r.type == "assistant" and (($r.message.content // null) | type) == "array" then
         reduce ($r.message.content[] | select(.type == "tool_use")) as $t (.;
           if $t.name == "Bash" then
             (($t.input.command // "") | kit_bash_head) as $w
             | if $w == "" then . else .bash[$w] += 1 end
           elif $t.name == "Skill" then .skills[($t.input.skill // "?")] += 1
           elif (($t.name // "") | startswith("mcp__")) then .mcp[$t.name] += 1
           else . end)
       else . end)
    | (if $proj != "" and ($r.sessionId | type) == "string" then .sessions[$proj][$r.sessionId] = true else . end))
  | {
      since: $since,
      until: $until,
      prompts: (.prompts | sort_by(.at) | reverse | .[0:200]),
      bash_commands: (.bash | kit_top(30) | map({command: .key, count: .value})),
      skills: (.skills | kit_top(50) | map({name: .key, count: .value})),
      mcp_tools: (.mcp | kit_top(50) | map({name: .key, count: .value})),
      projects: (.sessions | to_entries | map({project: .key, sessions: (.value | length)}) | sort_by(-.sessions, .project))
    }
  | def fit:
      if (tojson | utf8bytelength) > 61440 and (.prompts | length) > 0
      then .prompts |= .[0:((length * 4 / 5) | floor)] | fit
      else . end;
    fit;

def kit_count_prompts($since):
  reduce (kit_records | select(kit_after($since) and kit_is_prompt)) as $r (0; . + 1);

# このマシンの実状態 L を読む（設計書 §5）。

# kit_local_state: {marketplaces, plugins, skills} を 1 行の JSON で出す。
# 除外: マーケットプレイス dotfiles、ソースがローカルパス（directory / file）のマーケットプレイスとそのプラグイン、
#       プロジェクトスコープのプラグイン、スキル find-skills。
# どれかの読み取りに失敗したら 1 を返す。空として扱うと、全項目の削除が他のマシンに広がってしまうため。
kit_local_state() {
  local mkts plugins lock skills
  mkts="$(kit_claude plugin marketplace list --json </dev/null 2>/dev/null)" || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$mkts" || return 1
  plugins="$(kit_claude plugin list --json </dev/null 2>/dev/null)" || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$plugins" || return 1
  lock="${HOME}/.agents/.skill-lock.json"
  if [ -f "$lock" ]; then
    skills="$(jq -c '.skills // {}' "$lock" 2>/dev/null)" || return 1
  else
    skills='{}'
  fi
  jq -nc --argjson m "$mkts" --argjson p "$plugins" --argjson s "$skills" '
    [$m[] | select(.name == "dotfiles" or .source == "directory" or .source == "file") | .name] as $excluded
    | {
        marketplaces: ([$m[] | select(.name | IN($excluded[]) | not)
                        | {key: .name, value: del(.name, .installLocation)}] | from_entries),
        plugins: ([$p[] | select(.scope == "user")
                   | select(.id | split("@") | last | IN($excluded[]) | not)
                   | {key: .id, value: .enabled}] | from_entries),
        skills: ([$s | to_entries[] | select(.key != "find-skills")
                  | {key: .key, value: {source: .value.source}}] | from_entries)
      }'
}

# 発見の ③ 候補収集（設計書 §8.2）。

# kit_json_or <default> <json>: json が default と同じ型の JSON ならそれを、そうでなければ default を出す
# （1 つのソースの異常な出力で、候補収集の全体を止めない）
kit_json_or() {
  if jq -e --argjson d "$1" 'type == ($d | type)' >/dev/null 2>&1 <<<"${2:-null}"; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

# kit_collect_candidates <needs の JSON 配列>: needs（[{theme, keywords, ...}]）ごとに §8.1 のソースを検索し、
# 導入済み・却下済み・ウォッチ済みを除いた候補の JSON 配列を 1 行で出す。却下とウォッチは作業ツリーの manifest（W）から読む。
# GitHub にある候補には、リポジトリの情報を信頼性の目安（signals）として足す
kit_collect_candidates() {
  local needs="$1" w watch dismissed installed wplugins='[]' skills='{}' github='{}' n theme q gh_n=0 catalog cands
  w="$(kit_working_manifest 2>/dev/null)"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$w" || w="$KIT_EMPTY_MANIFEST"
  watch="$(jq -c '[.discovery.watch[]? | strings]' <<<"$w")"
  dismissed="$(jq -c '[.discovery.dismissed[]? | objects]' <<<"$w")"
  installed="$(kit_json_or '{}' "$(kit_installed)")"
  kit_require gh && wplugins="$(kit_json_or '[]' "$(kit_watch_candidates "$watch")")"
  while IFS= read -r n; do
    theme="$(jq -r .theme <<<"$n")"
    q="$(jq -r '.keywords | join(" ")' <<<"$n")"
    skills="$(jq -c --arg t "$theme" --argjson r "$(kit_json_or '[]' "$(kit_skills_search "$q" 5)")" '.[$t] = $r' <<<"$skills")"
    if kit_require gh && [ "$gh_n" -lt 5 ]; then
      github="$(jq -c --arg t "$theme" --argjson r "$(kit_json_or '[]' "$(kit_github_search "$q")")" '.[$t] = $r' <<<"$github")"
      gh_n=$((gh_n + 1))
    fi
  done < <(jq -c '.[]' <<<"$needs")
  catalog="$(kit_catalog_file)"
  cands="$(jq -nc --argjson needs "$needs" --argjson wp "$wplugins" --argjson s "$skills" --argjson g "$github" \
    --argjson i "$installed" --argjson d "$dismissed" --argjson wt "$watch" \
    '{needs: $needs, watch_plugins: $wp, skills: $s, github: $g, installed: $i, dismissed: $d, watch: $wt}' |
    jq -c -L "$KIT_LIB_DIR" --slurpfile c "$catalog" 'include "candidates"; .catalog = $c[0] | kit_collect')" || return 1
  kit_add_repo_signals "$cands"
}

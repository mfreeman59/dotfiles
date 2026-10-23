# 発見ソース（設計書 §8.1）: 登録済みカタログ、skills.sh、ウォッチリスト、GitHub 全体。
# どのソースも、失敗したら空を返してログに残す（1 つのソースの失敗で分析全体を止めない）。
# 検索のためにマーケットプレイスを Claude Code に登録することはしない（検索は広く、登録は狭く）。

KIT_CACHE_SECONDS="${KIT_CACHE_SECONDS:-86400}"
KIT_SKILLS_API="${KIT_SKILLS_API:-https://skills.sh}"
KIT_HTTP_TIMEOUT="${KIT_HTTP_TIMEOUT:-15}"
KIT_GITHUB_MIN_STARS="${KIT_GITHUB_MIN_STARS:-20}"
KIT_GITHUB_MAX_AGE_DAYS="${KIT_GITHUB_MAX_AGE_DAYS:-180}"
KIT_GITHUB_PARALLEL="${KIT_GITHUB_PARALLEL:-8}"

# kit_cache_fresh <path>: ファイルが空でなく、KIT_CACHE_SECONDS より新しければ 0
kit_cache_fresh() {
  local m
  [ -s "$1" ] || return 1
  m="$(stat -f %m "$1" 2>/dev/null || echo 0)"
  [ $(($(kit_now) - m)) -lt "$KIT_CACHE_SECONDS" ]
}

# kit_catalog_file: 登録済みカタログ（claude plugin list --available --json の available。Anthropic プラグインディレクトリを含む）の
# キャッシュを必要なら取り直し、読むべきファイルのパスを出す。2MB を超えるので、内容ではなくパスを渡す（引数の長さの上限を避ける）
kit_catalog_file() {
  local f="${KIT_STATE}/catalog.json" empty="${KIT_STATE}/discover/empty.json" tmp
  mkdir -p "${KIT_STATE}/discover"
  if ! kit_cache_fresh "$f"; then
    tmp="$(mktemp "${f}.XXXXXX")"
    if kit_claude plugin list --available --json </dev/null 2>/dev/null |
      jq -c '.available | select(type == "array")' >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp"
      kit_log "discover: catalog unavailable"
    fi
  fi
  if [ -s "$f" ]; then
    printf '%s' "$f"
  else
    printf '[]' >"$empty"
    printf '%s' "$empty"
  fi
}

# kit_skills_search <query> <limit>: skills.sh の検索 API（skills CLI の find が使うものと同じ）。CLI は結果をインストール数で
# 並べ替えて関連度の順を崩し、色付きのテキストで出すため、API を直接呼ぶ
kit_skills_search() {
  local out
  if ! out="$(curl -fsS -m "$KIT_HTTP_TIMEOUT" -G "${KIT_SKILLS_API}/api/search" \
    --data-urlencode "q=$1" --data-urlencode "limit=$2" </dev/null 2>/dev/null)"; then
    kit_log "discover: skills.sh search failed: $1"
    printf '[]'
    return 0
  fi
  jq -c '[.skills[]? | select((.source | type) == "string" and (.skillId | type) == "string")
    | {kind: "skill", id: "\(.source)@\(.skillId)", name: (.name // .skillId), description: "", source: .source,
       skill: .skillId, origin: "skills.sh", signals: {installs: (.installs // 0)}}]' <<<"$out" 2>/dev/null || printf '[]'
}

kit_watch_cache_path() { printf '%s/discover/watch-cache/%s%s' "$KIT_STATE" "$(printf '%s' "$1" | tr '/' '_')" "$2"; }

# kit_watch_marketplace <owner/repo>: そのリポジトリの .claude-plugin/marketplace.json（24 時間キャッシュ）
kit_watch_marketplace() {
  local f out
  f="$(kit_watch_cache_path "$1" .json)"
  if ! kit_cache_fresh "$f"; then
    if out="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$1/contents/.claude-plugin/marketplace.json" </dev/null 2>/dev/null)" &&
      jq -e '(.plugins | type) == "array"' >/dev/null 2>&1 <<<"$out"; then
      kit_write_json "$f" "$out"
    else
      kit_log "discover: watch $1 unavailable"
    fi
  fi
  kit_read_json "$f" '{}'
}

# kit_repo_info <owner/repo>: スター数・作成日・最終 push・アーカイブ済みか・説明・持ち主の種別（24 時間キャッシュ）
kit_repo_info() {
  local f out
  f="$(kit_watch_cache_path "$1" .repo.json)"
  if ! kit_cache_fresh "$f"; then
    if out="$(gh api "repos/$1" </dev/null 2>/dev/null)" &&
      jq -e '(.stargazers_count | type) == "number"' >/dev/null 2>&1 <<<"$out"; then
      kit_write_json "$f" "$(jq -c '{stargazers_count, created_at, pushed_at, archived, description, owner_type: .owner.type?}' <<<"$out")"
    fi
  fi
  kit_read_json "$f" '{}'
}

# kit_repo_contributors <owner/repo>: コントリビューターの数（1 ページの 100 人まで数える。24 時間キャッシュ）
kit_repo_contributors() {
  local f out
  f="$(kit_watch_cache_path "$1" .contributors.json)"
  if ! kit_cache_fresh "$f"; then
    if out="$(gh api -X GET "repos/$1/contributors" -f per_page=100 </dev/null 2>/dev/null)" &&
      jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out"; then
      kit_write_json "$f" "$(jq -c '{count: length}' <<<"$out")"
    fi
  fi
  kit_read_json "$f" '{}'
}

# kit_add_repo_signals <候補の JSON 配列>: GitHub にある候補の signals に、リポジトリの情報を足す（kit_with_repo_signals）。
# 候補は最大 60 件あるので、リポジトリごとに 1 回だけ、KIT_GITHUB_PARALLEL 件ずつ並列に取得してキャッシュに入れてから読む。
# gh がない・取得に失敗したものは元の signals のまま
kit_add_repo_signals() {
  local repos r pids="" n=0 acc='{}'
  kit_require gh || { printf '%s' "$1"; return 0; }
  repos="$(jq -r -L "$KIT_LIB_DIR" 'include "candidates"; [.[] | kit_candidate_repo | strings] | unique | .[]' <<<"$1" 2>/dev/null)"
  while IFS= read -r r; do
    kit_valid_repo "$r" || continue
    (kit_repo_info "$r" >/dev/null; kit_repo_contributors "$r" >/dev/null) &
    pids="${pids} $!"
    n=$((n + 1))
    if [ "$n" -ge "$KIT_GITHUB_PARALLEL" ]; then
      wait $pids
      pids="" n=0
    fi
  done <<<"$repos"
  [ -n "$pids" ] && wait $pids
  # 取得に失敗したリポジトリをここで取り直さないよう、キャッシュを直接読む
  while IFS= read -r r; do
    kit_valid_repo "$r" || continue
    acc="$(jq -c --arg r "$r" --argjson i "$(kit_read_json "$(kit_watch_cache_path "$r" .repo.json)" '{}')" \
      --argjson c "$(kit_read_json "$(kit_watch_cache_path "$r" .contributors.json)" '{}')" \
      '.[$r] = {info: $i, contributors: $c}' <<<"$acc")"
  done <<<"$repos"
  jq -c -L "$KIT_LIB_DIR" --argjson repos "$acc" 'include "candidates"; kit_with_repo_signals($repos)' <<<"$1" 2>/dev/null ||
    printf '%s' "$1"
}

# kit_valid_repo <s>: GitHub の owner/repo の形なら 0。パスとして悪用できる「.」「..」は認めない
# （ウォッチリストは他のマシンや手での編集から来るので、gh api のパスや clone の URL に入れる前に確かめる）
kit_valid_repo() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$' || return 1
  case "$1" in */. | */..) return 1 ;; esac
  return 0
}

# kit_watch_candidates <watch の JSON 配列>: ウォッチリストのマーケットプレイスにあるプラグイン → 候補。
# marketplace.json は第三者が書くので、形の崩れた項目は飛ばし、1 つのリポジトリで失敗しても他のリポジトリの候補は残す
kit_watch_candidates() {
  local repo m info out acc='[]'
  while IFS= read -r repo; do
    kit_valid_repo "$repo" || continue
    m="$(kit_watch_marketplace "$repo")"
    info="$(kit_repo_info "$repo")"
    out="$(jq -c --argjson m "$m" --argjson i "$info" --arg repo "$repo" '
      . + [($m.name // "") as $mk | select(($mk | type) == "string" and $mk != "") | $m.plugins[]? | objects
           | select((.name | type) == "string")
           | {kind: "plugin", id: "\(.name)@\($mk)", name,
              description: (if (.description | type) == "string" then .description[0:300] else "" end), source,
              marketplace: $mk, marketplace_source: $repo, origin: "watch",
              signals: ({stars: (($i.stargazers_count | numbers) // null),
                         pushed_at: (($i.pushed_at | strings | .[0:10]) // null)}
                        | with_entries(select(.value != null and .value != "")))}]' <<<"$acc" 2>/dev/null)" && acc="$out" ||
      kit_log "discover: watch $repo has an unexpected marketplace.json"
  done < <(jq -r '.[]? | strings' <<<"$1")
  printf '%s' "$acc"
}

# kit_github_search <query>: GitHub 全体から .claude-plugin/marketplace.json を持つリポジトリを探す（1 クエリ、上位 5 リポジトリ）。
# スターが KIT_GITHUB_MIN_STARS 以上、KIT_GITHUB_MAX_AGE_DAYS 日以内に push があり、アーカイブされていないものだけをウォッチ候補にする
kit_github_search() {
  local out r info cutoff next acc='[]'
  out="$(gh api -X GET search/code -f q="filename:marketplace.json path:.claude-plugin $1" -f per_page=10 </dev/null 2>/dev/null)" || {
    kit_log "discover: github search failed: $1"
    printf '[]'
    return 0
  }
  cutoff=$(($(kit_now) - KIT_GITHUB_MAX_AGE_DAYS * 86400))
  while IFS= read -r r; do
    kit_valid_repo "$r" || continue
    info="$(kit_repo_info "$r")"
    # 形の崩れた情報（日時でない pushed_at など）のリポジトリは候補にせず、他のリポジトリの候補は残す
    next="$(jq -c --argjson i "$info" --arg r "$r" --argjson min "$KIT_GITHUB_MIN_STARS" --argjson cutoff "$cutoff" '
      if ($i.stargazers_count // 0) >= $min and (($i.archived // false) | not)
         and ((try (($i.pushed_at // "1970-01-01T00:00:00Z") | fromdateiso8601) catch 0) >= $cutoff)
      then . + [{kind: "watch", id: $r, name: $r, description: ((($i.description // "") | tostring)[0:300]), source: $r,
                 origin: "github", signals: {stars: $i.stargazers_count, pushed_at: ($i.pushed_at[0:10])}}]
      else . end' <<<"$acc" 2>/dev/null)" && acc="$next"
  done < <(jq -r '[.items[]?.repository.full_name | strings] | unique | .[0:5][]' <<<"$out" 2>/dev/null)
  printf '%s' "$acc"
}

# kit_installed: 導入済みのもの。プラグインはスコープを問わない。スキルは skills.sh のロックファイルと ~/.claude/skills
kit_installed() {
  local plugins mkts skills
  plugins="$(kit_claude plugin list --json </dev/null 2>/dev/null | jq -c '[.[]?.id | strings]' 2>/dev/null)"
  mkts="$(kit_claude plugin marketplace list --json </dev/null 2>/dev/null | jq -c '[.[]?.repo | strings]' 2>/dev/null)"
  skills="$({
    jq -r '(.skills // {}) | keys[]' "${HOME}/.agents/.skill-lock.json" 2>/dev/null
    ls "${HOME}/.claude/skills" "${HOME}/.claude/skills/synced" 2>/dev/null
  } | jq -Rsc 'split("\n") | map(select(. != "" and (endswith(":") | not))) | unique')"
  jq -nc --argjson p "${plugins:-[]}" --argjson m "${mkts:-[]}" --argjson s "${skills:-[]}" \
    '{plugins: $p, plugin_names: ($p | map(split("@")[0]) | unique), skills: $s, marketplace_repos: $m}'
}

#!/usr/bin/env bash
# skillsh-router shared library.
#
# Sourced (not executed) by hooks/session-start, hooks/user-prompt-submit,
# and hooks/post-tool-use. Owns all reads/writes of data/routes.json and
# data/.pending-find.json, keyword normalization, and the promotion rule.
#
# Requires: jq. Every write goes through routes_atomic_write (write to a
# temp file in the same directory, then mv) so a crash mid-write never
# corrupts routes.json.

ROUTES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_ROOT="$(cd "${ROUTES_LIB_DIR}/.." && pwd)"
ROUTES_FILE="${CLAUDE_ROOT}/data/routes.json"
PENDING_FILE="${CLAUDE_ROOT}/data/.pending-find.json"

# How many times `skills add` must resolve to the same package before it's
# promoted from candidates{} to routes[] (the fast, find-skills-bypassing path).
ROUTES_THRESHOLD="${SKILLSH_ROUTER_THRESHOLD:-3}"

# How long a `skills find <query>` stays eligible to be correlated with a
# later `skills add`. 30 minutes covers "find, think, add" without picking up
# unrelated finds from a much earlier, unrelated part of the session.
PENDING_WINDOW_SECONDS="${SKILLSH_ROUTER_PENDING_WINDOW:-1800}"

routes_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
routes_now_epoch() { date -u +"%s"; }

# Create routes.json / .pending-find.json with an empty schema if missing.
# Safe to call at the top of every hook; idempotent.
routes_init() {
  mkdir -p "$(dirname "$ROUTES_FILE")"
  if [ ! -f "$ROUTES_FILE" ]; then
    printf '{"version":1,"threshold":%s,"candidates":{},"routes":[]}\n' "$ROUTES_THRESHOLD" >"$ROUTES_FILE"
  fi
  if [ ! -f "$PENDING_FILE" ]; then
    printf '[]\n' >"$PENDING_FILE"
  fi
}

# routes_atomic_write <json-content> <target-path>
# Writes via a same-directory temp file + mv so readers never see a partial file.
routes_atomic_write() {
  local content="$1" target="$2" tmp
  tmp="$(mktemp "${target}.XXXXXX")"
  printf '%s' "$content" >"$tmp"
  mv "$tmp" "$target"
}

# routes_normalize_keywords <free text>
# Prints a compact JSON array of lowercase alnum tokens (len > 2), stopwords
# and skills-CLI boilerplate words removed, deduped. Never fails: prints "[]"
# on any error (e.g. jq missing) so callers can treat the return as a value,
# not something that needs its own error handling.
routes_normalize_keywords() {
  local text="$1"
  jq -R -c '
    ascii_downcase
    | gsub("[^a-z0-9 ]"; " ")
    | split(" ")
    | map(select(length > 2))
    | unique
    | . - ["the","and","for","with","that","this","from","into","find","skill",
           "skills","npx","add","how","can","you","are","get","use","make",
           "want","need","please","help"]
  ' <<<"$text" 2>/dev/null || printf '[]'
}

# routes_pending_stash <keywords-json-array>
# Records a `skills find` query's keywords with a timestamp, to be picked up
# by the next routes_pending_collect within PENDING_WINDOW_SECONDS.
routes_pending_stash() {
  local keywords_json="$1" updated
  routes_init
  updated="$(jq -c --argjson kw "$keywords_json" --arg ts "$(routes_now_iso)" --argjson tse "$(routes_now_epoch)" \
    '. + [{"keywords": $kw, "ts": $ts, "ts_epoch": $tse}]' "$PENDING_FILE" 2>/dev/null)" || return 0
  [ -n "$updated" ] && routes_atomic_write "$updated" "$PENDING_FILE"
}

# routes_pending_collect
# Prints the union of keywords from all pending finds within the window, then
# clears the pending file (fire-and-forget correlation; a stale/huge pending
# file never accumulates unbounded).
routes_pending_collect() {
  local cutoff collected
  routes_init
  cutoff=$(($(routes_now_epoch) - PENDING_WINDOW_SECONDS))
  collected="$(jq -c --argjson cutoff "$cutoff" \
    '[.[] | select(.ts_epoch >= $cutoff) | .keywords[]] | unique' \
    "$PENDING_FILE" 2>/dev/null)" || collected='[]'
  routes_atomic_write '[]' "$PENDING_FILE"
  printf '%s' "${collected:-[]}"
}

# routes_record_hit <package> <skill_name> <install_path> <keywords-json-array>
# Increments candidates[package].hit_count, unions in the keywords, and
# promotes to routes[] the moment hit_count reaches ROUTES_THRESHOLD (only
# once — a package already present in routes[] is never re-added).
routes_record_hit() {
  local package="$1" skill_name="$2" install_path="$3" keywords_json="$4" updated
  routes_init
  updated="$(jq -c \
    --arg pkg "$package" \
    --arg name "$skill_name" \
    --arg path "$install_path" \
    --argjson kw "$keywords_json" \
    --arg ts "$(routes_now_iso)" \
    --argjson threshold "$ROUTES_THRESHOLD" \
    '
    .candidates[$pkg] //= {"package": $pkg, "skill_name": $name, "install_path": $path, "keywords": [], "hit_count": 0, "last_seen": null}
    | .candidates[$pkg].hit_count += 1
    | .candidates[$pkg].keywords = ((.candidates[$pkg].keywords + $kw) | unique)
    | .candidates[$pkg].skill_name = $name
    | .candidates[$pkg].install_path = $path
    | .candidates[$pkg].last_seen = $ts
    | if (.candidates[$pkg].hit_count >= $threshold) and ((.routes | map(.package) | index($pkg)) == null) then
        .routes += [{
          "id": $name,
          "skill_name": $name,
          "package": $pkg,
          "install_path": $path,
          "keywords": .candidates[$pkg].keywords,
          "hits": .candidates[$pkg].hit_count,
          "promoted_at": $ts
        }]
      else . end
    ' "$ROUTES_FILE" 2>/dev/null)" || return 0
  [ -n "$updated" ] && routes_atomic_write "$updated" "$ROUTES_FILE"
}

# routes_get_promoted
# Prints routes[] as compact JSON. "[]" if none yet or on any read error.
routes_get_promoted() {
  routes_init
  jq -c '.routes // []' "$ROUTES_FILE" 2>/dev/null || printf '[]'
}

# routes_parse_add_command <full bash command string>
# Parses an `npx skills add ...` (or `skills add ...`) invocation.
# Prints three fields separated by "|" (NOT a tab -- tab is IFS whitespace,
# so bash's `read` collapses consecutive tab delimiters and silently drops
# empty fields in between; "|" doesn't have that problem and can't appear in
# a package spec or skill name):
#   pkgspec|skill-flag-value|is_global(0/1)
# - pkgspec: the first non-flag positional token after "skills add"
#   (e.g. "vercel-labs/skills@pdf-tools" or "vercel-labs/skills")
# - skill-flag-value: first value passed to -s/--skill, if pkgspec has no "@skill"
# - is_global: 1 if -g/--global appears as its own token, else 0
# Deliberately conservative: unparseable input yields empty fields rather than
# a guess, and callers must treat empty pkgspec/skill_name as "skip".
routes_parse_add_command() {
  local cmd="$1" rest
  rest="$(printf '%s' "$cmd" | sed -E 's/.*skills[[:space:]]+add[[:space:]]*//')"
  # shellcheck disable=SC2206
  local tokens=($rest)
  local n=${#tokens[@]} i=0
  local pkgspec="" skill_val="" is_global=0

  while [ "$i" -lt "$n" ]; do
    local t="${tokens[$i]}"
    case "$t" in
      -g|--global)
        is_global=1
        i=$((i + 1))
        ;;
      -s|--skill)
        i=$((i + 1))
        while [ "$i" -lt "$n" ] && [[ "${tokens[$i]}" != -* ]]; do
          [ -z "$skill_val" ] && skill_val="${tokens[$i]}"
          i=$((i + 1))
        done
        ;;
      -a|--agent)
        i=$((i + 1))
        while [ "$i" -lt "$n" ] && [[ "${tokens[$i]}" != -* ]]; do
          i=$((i + 1))
        done
        ;;
      -*)
        i=$((i + 1))
        ;;
      *)
        [ -z "$pkgspec" ] && pkgspec="$t"
        i=$((i + 1))
        ;;
    esac
  done

  printf '%s|%s|%s' "$pkgspec" "$skill_val" "$is_global"
}

# routes_extract_find_query <full bash command string>
# Prints the free-text query portion of an `npx skills find <query>` command,
# with known value-taking flags (--owner <val>) and other flags stripped.
routes_extract_find_query() {
  local cmd="$1" rest
  rest="$(printf '%s' "$cmd" | sed -E 's/.*skills[[:space:]]+find[[:space:]]*//')"
  # shellcheck disable=SC2206
  local tokens=($rest)
  local n=${#tokens[@]} i=0
  local out=()

  while [ "$i" -lt "$n" ]; do
    local t="${tokens[$i]}"
    case "$t" in
      --owner)
        i=$((i + 2))
        ;;
      -*)
        i=$((i + 1))
        ;;
      *)
        out+=("$t")
        i=$((i + 1))
        ;;
    esac
  done

  printf '%s' "${out[*]:-}"
}

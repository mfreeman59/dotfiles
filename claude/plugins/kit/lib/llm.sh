# 発見の ② と ④ で使う claude -p（設計書 §8.2、§8.3）。
# ツールを渡さない（--tools ""）、個人設定を無効にする（--safe-mode。フック・プラグイン・CLAUDE.md・MCP サーバー）、
# トランスクリプトを残さない（--no-session-persistence）。念のため KIT_NESTED=1 も渡し、kit のフックを止める。

KIT_DISCOVER_MODEL="${KIT_DISCOVER_MODEL:-sonnet}"
KIT_DISCOVER_BUDGET_USD="${KIT_DISCOVER_BUDGET_USD:-1}"
KIT_LLM_TIMEOUT="${KIT_LLM_TIMEOUT:-300}"

# kit_llm <name> <data-json>: lib/prompts/<name>.md の指示に <data> を添えて渡し、lib/schemas/<name>.json に沿った
# 構造化出力を 1 行の JSON で出す。失敗（終了コードが 0 以外、時間切れ、is_error、構造化出力がない）なら何も出さずに 1
kit_llm() {
  local name="$1" data="$2" dir schema out
  dir="${KIT_STATE}/discover"
  mkdir -p "$dir"
  schema="$(jq -c . "${KIT_LIB_DIR}/schemas/${name}.json")" || return 1
  out="$({ cat "${KIT_LIB_DIR}/prompts/${name}.md"; printf '\n<data>\n%s\n</data>\n' "$data"; } |
    (cd "$dir" && export KIT_NESTED=1 && kit_with_timeout "$KIT_LLM_TIMEOUT" claude -p \
      --model "$KIT_DISCOVER_MODEL" --tools "" --safe-mode --no-session-persistence \
      --output-format json --json-schema "$schema" --max-budget-usd "$KIT_DISCOVER_BUDGET_USD" 2>/dev/null))" || {
    kit_log "discover: claude -p (${name}) failed"
    return 1
  }
  if ! jq -ec 'select(.is_error != true) | .structured_output | select(type == "object")' <<<"$out" 2>/dev/null; then
    kit_log "discover: claude -p (${name}) returned no structured output"
    return 1
  fi
}

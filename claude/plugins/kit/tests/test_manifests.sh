. "$(dirname "$0")/helpers.sh"
if [ -z "$REAL_CLAUDE" ]; then echo "  skip（claude がない）"; exit 0; fi
CLAUDE_DIR="$(cd "${KIT_PLUGIN_DIR}/../.." && pwd)"

jq -e '.name == "dotfiles" and (.plugins | any(.name == "kit" and .source == "./plugins/kit"))' \
  "${CLAUDE_DIR}/.claude-plugin/marketplace.json" >/dev/null 2>&1
assert_eq "$?" "0" "マーケットプレイス dotfiles が kit を ./plugins/kit から配る"
out="$("$REAL_CLAUDE" plugin validate "$CLAUDE_DIR" 2>&1)"; rc=$?
assert_eq "$rc" "0" "マーケットプレイスの検証が通る"
assert_contains "$out" "Validation passed" "マーケットプレイスの検証結果"
out="$("$REAL_CLAUDE" plugin validate "$KIT_PLUGIN_DIR" 2>&1)"; rc=$?
assert_eq "$rc" "0" "プラグインの検証が通る"
if [ -f "${KIT_PLUGIN_DIR}/hooks/hooks.json" ]; then
  jq -e '.hooks.SessionStart and .hooks.SessionEnd' "${KIT_PLUGIN_DIR}/hooks/hooks.json" >/dev/null
  assert_eq "$?" "0" "hooks.json に SessionStart と SessionEnd がある"
fi
f="${KIT_PLUGIN_DIR}/skills/discover/SKILL.md"
assert_eq "$(sed -n 2p "$f" 2>/dev/null)" "name: discover" "/kit:discover のスキルがある"
assert_contains "$(cat "$f" 2>/dev/null)" "kit discover adopt" "導入の手順を教える"
assert_contains "$(cat "$f" 2>/dev/null)" "kit discover inspect" "導入の前に中身を確かめさせる"
t_done

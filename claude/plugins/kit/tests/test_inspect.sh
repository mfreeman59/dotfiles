. "$(dirname "$0")/helpers.sh"
t_tmp
t_machine A
export KIT_GITHUB_URL="file://${T_TMP}/gh"
kit_libs

MARKER="${T_TMP}/executed"
mkrepo() {
  git -C "$1" init -q -b main
  git -C "$1" add -A
  git -C "$1" -c user.email=t@example.com -c user.name=t commit -q -m init
}
ran() { [ -e "$MARKER" ] && echo yes || echo no; }

# 候補のプラグイン: フック・MCP サーバー・同梱スクリプトを持ち、どれも実行されると MARKER を作る
src="${T_TMP}/src/repo"
mkdir -p "${src}/plug/.claude-plugin" "${src}/plug/hooks" "${src}/plug/bin" "${src}/plug/skills/foo"
echo '{"name":"plug"}' >"${src}/plug/.claude-plugin/plugin.json"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch %s"}]}]}}\n' "$MARKER" >"${src}/plug/hooks/hooks.json"
echo '{"mcpServers":{"x":{"command":"npx","args":["x"]}}}' >"${src}/plug/.mcp.json"
printf '#!/bin/sh\ntouch %s\n' "$MARKER" >"${src}/plug/bin/run.sh"
chmod +x "${src}/plug/bin/run.sh"
printf -- '---\nname: foo\n---\n本文\n' >"${src}/plug/skills/foo/SKILL.md"
mkrepo "$src"
sha="$(git -C "$src" rev-parse HEAD)"

mkdir -p "${T_TMP}/gh/o/skills.git/skills/foo" "${T_TMP}/gh/o/mkt.git/.claude-plugin" "${T_TMP}/mk2/plugins/local/.claude-plugin"
printf -- '---\nname: foo\n---\n' >"${T_TMP}/gh/o/skills.git/skills/foo/SKILL.md"
mkrepo "${T_TMP}/gh/o/skills.git"
echo '{"name":"mkt","plugins":[{"name":"p1","description":"d1","source":"./p1"}]}' >"${T_TMP}/gh/o/mkt.git/.claude-plugin/marketplace.json"
mkrepo "${T_TMP}/gh/o/mkt.git"
echo '{"name":"local"}' >"${T_TMP}/mk2/plugins/local/.claude-plugin/plugin.json"
fake_set ".marketplaces = [{\"name\":\"mk2\",\"source\":\"github\",\"repo\":\"o/mk2\",\"installLocation\":\"${T_TMP}/mk2\"}]"

mkdir -p "${KIT_STATE_DIR}/discover"
jq -n --arg src "file://${src}" --arg sha "$sha" --arg m "$MARKER" '[
  {rank: 1, kind: "plugin", id: "plug@mk", name: "plug", marketplace: "mk", source: {source: "git-subdir", url: $src, path: "plug", sha: $sha}},
  {rank: 2, kind: "plugin", id: "evil@mk", name: "evil", marketplace: "mk", source: {source: "url", url: ("ext::sh -c touch% " + $m)}},
  {rank: 3, kind: "plugin", id: "up@mk", name: "up", marketplace: "mk", source: {source: "git-subdir", url: $src, path: "../../.."}},
  {rank: 4, kind: "plugin", id: "local@mk2", name: "local", marketplace: "mk2", source: "./plugins/local"},
  {rank: 5, kind: "skill", id: "o/skills@foo", name: "foo", source: "o/skills", skill: "foo"},
  {rank: 6, kind: "watch", id: "o/mkt", name: "o/mkt", source: "o/mkt"},
  {rank: 7, kind: "plugin", id: "inj@mk", name: "inj", marketplace: "mk",
   source: {source: "git-subdir", url: $src, path: "plug", ref: "--upload-pack=touch", sha: ("--upload-pack=touch " + $m)}}
]' >"${KIT_STATE_DIR}/discover/recommendations.json"

out="$(kit_discover_inspect 1)"; rc=$?
root="${KIT_STATE_DIR}/inspect/plug@mk/repo/plug"
assert_eq "$rc" "0" "取得できる"
assert_contains "$out" "取得した場所: ${root}" "取得した場所を示す"
assert_contains "$out" "hooks/hooks.json: あり" "フックの有無"
assert_contains "$out" ".mcp.json: あり" "MCP サーバーの有無"
assert_contains "$out" "bin/: あり（1 ファイル）" "同梱スクリプトの有無"
assert_contains "$out" "scripts/: なし" "ないものはなしと示す"
assert_contains "$out" "  skills/foo/SKILL.md" "SKILL.md の一覧"
assert_contains "$out" "touch ${MARKER}" "フックの定義の中身を見せる"
assert_eq "$(git -C "${KIT_STATE_DIR}/inspect/plug@mk/repo" rev-parse HEAD)" "$sha" "取得した版が sha と一致する"
assert_eq "$(ran)" "no" "中のスクリプトを実行しない"

out="$(kit_discover_inspect 2 2>&1)"; rc=$?
assert_eq "$rc" "1" "https / file 以外の取得元は断る"
assert_contains "$out" "対応していません" "理由を示す"
kit_discover_inspect 3 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "取得先の外を指すパスは断る"
kit_discover_inspect 7 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "オプションに見える ref と sha は使わずに取得する"
assert_eq "$(ran)" "no" "任意のコマンドを実行させない"

out="$(kit_discover_inspect 4)"; rc=$?
assert_eq "$rc" "0" "登録済みのマーケットプレイスの中のプラグイン"
assert_contains "$out" "取得した場所: ${T_TMP}/mk2/plugins/local" "マーケットプレイスの場所をそのまま示す"
out="$(kit_discover_inspect o/skills@foo)"; rc=$?
assert_eq "$rc" "0" "スキル"
assert_contains "$out" "取得した場所: ${KIT_STATE_DIR}/inspect/o_skills@foo/repo/skills/foo" "スキルのディレクトリを示す"
out="$(kit_discover_inspect 6)"; rc=$?
assert_eq "$rc" "0" "ウォッチ候補"
assert_contains "$out" "  p1: d1" "マーケットプレイスのプラグインを並べる"
kit_discover_inspect 99 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "見つからない候補は 1"
kit_discover_inspect >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "引数がなければ使い方の誤り"

# シンボリックリンクで取得先の外のファイル（秘密鍵など）を読ませない
echo "SECRET-MATERIAL" >"${HOME}/secret"
mkdir -p "${T_TMP}/gh/evil/skills.git/skills/foo/hooks" "${T_TMP}/outside/hooks" "${T_TMP}/mk2/plugins/local/hooks"
printf -- '---\nname: foo\n---\n' >"${T_TMP}/gh/evil/skills.git/skills/foo/SKILL.md"
ln -s "${HOME}/secret" "${T_TMP}/gh/evil/skills.git/skills/foo/hooks/hooks.json"
mkrepo "${T_TMP}/gh/evil/skills.git"
echo '[{"kind":"skill","id":"evil/skills@foo","name":"foo","source":"evil/skills","skill":"foo"},
  {"kind":"plugin","id":"linked@mk2","name":"linked","marketplace":"mk2","source":"./plugins/linked"}]' >"${KIT_STATE_DIR}/discover/search.json"
out="$(kit_discover_inspect evil/skills@foo 2>&1)"
assert_not_contains "$out" "SECRET-MATERIAL" "取得したもののシンボリックリンクをたどらない"
assert_eq "$([ -L "${KIT_STATE_DIR}/inspect/evil_skills@foo/repo/skills/foo/hooks/hooks.json" ] && echo link || echo file)" "file" \
  "シンボリックリンクを作らずに取得する"
cp "${HOME}/secret" "${T_TMP}/outside/hooks/hooks.json"
ln -s "${T_TMP}/outside" "${T_TMP}/mk2/plugins/linked"
out="$(kit_discover_inspect linked@mk2 2>&1)"; rc=$?
assert_eq "$rc" "1" "登録済みのマーケットプレイスの外を指すプラグインは断る"
assert_not_contains "$out" "SECRET-MATERIAL" "マーケットプレイスの外のファイルを見せない"
ln -s "${HOME}/secret" "${T_TMP}/mk2/plugins/local/hooks/hooks.json"
out="$(kit_discover_inspect 4 2>&1)"
assert_not_contains "$out" "SECRET-MATERIAL" "登録済みのマーケットプレイスの中のシンボリックリンクもたどらない"
assert_contains "$out" "hooks/hooks.json: シンボリックリンク" "シンボリックリンクであることを示す"

out="$(export KIT_GITHUB_URL=https://github.com; kit_inspect_clone "file://${src}" "${T_TMP}/m2" 2>&1)"; rc=$?
assert_eq "$rc" "1" "本番では file の取得元を断る（手元のリポジトリの中身を見せない）"
assert_eq "$([ -e "${T_TMP}/m2" ] && echo yes || echo no)" "no" "file の取得元から取得しない"
t_done

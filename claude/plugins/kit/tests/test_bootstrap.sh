. "$(dirname "$0")/helpers.sh"
t_tmp
t_machine A
CLAUDE_DIR="$(cd "${KIT_PLUGIN_DIR}/../.." && pwd)"
export FAKE_MKT_NAME=dotfiles

mkdir -p "${HOME}/.claude/skills" "${HOME}/.agents"
cat >"${HOME}/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "\"/x/dotfiles/claude/hooks/run-hook.cmd\" session-start"}]},
      {"hooks": [{"type": "command", "command": "/other/status"}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "\"/x/dotfiles/claude/hooks/run-hook.cmd\" user-prompt-submit"}]}
    ],
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash guard.sh"}]}
    ]
  },
  "theme": "dark"
}
EOF
ln -s /nonexistent "${HOME}/.claude/skills/skillsh-router"
echo '{"version":3,"skills":{"find-skills":{"source":"vercel-labs/skills"}}}' >"${HOME}/.agents/.skill-lock.json"
chmod 600 "${HOME}/.claude/settings.json"

/bin/bash "${CLAUDE_DIR}/bootstrap.sh" --no-sync >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "成功する"
settings="$(cat "${HOME}/.claude/settings.json")"
assert_not_contains "$settings" "run-hook.cmd" "v1 のフックを外す"
assert_json_eq "$(jq -c .hooks.SessionStart <<<"$settings")" '[{"hooks":[{"type":"command","command":"/other/status"}]}]' "同じイベントの他のフックは残す"
assert_eq "$(jq -c '.hooks | has("UserPromptSubmit")' <<<"$settings")" "false" "空になったイベントは消す"
assert_eq "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' <<<"$settings")" "bash guard.sh" "無関係なフックは残す"
assert_eq "$(jq -r .theme <<<"$settings")" "dark" "他の設定は残す"
assert_eq "$(ls "${HOME}/.claude/backups" | wc -l | tr -d ' ')" "1" "バックアップを取る"
assert_eq "$(stat -f %Lp "${HOME}"/.claude/backups/*)" "600" "バックアップは元の権限（600）を保つ（レビュー M8）"
assert_eq "$([ -L "${HOME}/.claude/skills/skillsh-router" ] && echo yes || echo no)" "no" "v1 のリンクを消す"
assert_eq "$(jq -r '.skills | has("find-skills")' "${HOME}/.agents/.skill-lock.json")" "false" "find-skills を外す"
assert_eq "$(cat "${KIT_STATE_DIR}/dotfiles-path")" "$(cd "${CLAUDE_DIR}/.." && pwd)" "dotfiles の場所を記録する"
calls="$(fake_calls)"
assert_contains "$calls" "claude plugin marketplace add ${CLAUDE_DIR} --scope user" "マーケットプレイスを登録する"
assert_contains "$calls" "claude plugin install kit@dotfiles -s user" "kit を入れる"

: >"${FAKE_DIR}/calls.log"
/bin/bash "${CLAUDE_DIR}/bootstrap.sh" --no-sync >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "2 回目も成功する"
assert_eq "$(cat "${HOME}/.claude/settings.json")" "$settings" "2 回目は settings.json を変えない"
assert_not_contains "$(fake_calls)" "marketplace add" "2 回目は登録しない"
assert_not_contains "$(fake_calls)" "plugin install" "2 回目は入れない"
assert_eq "$(ls "${HOME}/.claude/backups" | wc -l | tr -d ' ')" "1" "2 回目はバックアップを増やさない"

t_done

#!/usr/bin/env bash
# skillsh-router uninstaller: reverses install.sh.
#   1. Removes our three hook entries from ~/.claude/settings.json (backed
#      up first), by filtering out any entry whose command points at our
#      hooks/run-hook.cmd -- leaves any other tool's hooks untouched.
#   2. Removes the ~/.claude/skills/skillsh-router symlink.
# Does NOT remove find-skills (it's not this project's to own) and does NOT
# delete data/routes.json (your learned routes -- delete claude/data/ by
# hand if you actually want to forget them).
set -euo pipefail

CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="${HOME}/.claude/settings.json"
BACKUP_DIR="${HOME}/.claude/backups"
SKILLS_DIR="${HOME}/.claude/skills"
HOOKS_CMD="${CLAUDE_DIR}/hooks/run-hook.cmd"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq)" >&2
  exit 1
fi

if [ -f "$SETTINGS_FILE" ]; then
  mkdir -p "$BACKUP_DIR"
  backup_path="${BACKUP_DIR}/settings.json.pre-skillsh-router-uninstall.$(date -u +%s)"
  cp "$SETTINGS_FILE" "$backup_path"
  echo "backed up settings.json -> ${backup_path}"

  cleaned="$(jq \
    --arg hooks_cmd "$HOOKS_CMD" \
    '
    def is_ours: (.hooks[0].command // "") | contains($hooks_cmd);

    if (.hooks // {}) == {} then .
    else
      .hooks.SessionStart = [(.hooks.SessionStart // [])[] | select(is_ours | not)]
      | .hooks.UserPromptSubmit = [(.hooks.UserPromptSubmit // [])[] | select(is_ours | not)]
      | .hooks.PostToolUse = [(.hooks.PostToolUse // [])[] | select(is_ours | not)]
    end
    ' "$SETTINGS_FILE")"

  printf '%s\n' "$cleaned" >"$SETTINGS_FILE"
  echo "removed skillsh-router hooks from settings.json"
fi

link_target="${SKILLS_DIR}/skillsh-router"
if [ -L "$link_target" ]; then
  rm -f "$link_target"
  echo "removed skill symlink ${link_target}"
fi

echo
echo "done. find-skills and claude/data/routes.json were left in place."

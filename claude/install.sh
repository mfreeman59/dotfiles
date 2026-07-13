#!/usr/bin/env bash
# skillsh-router installer.
#
# Idempotent: safe to re-run after `git pull` (e.g. on a machine you already
# installed on, or right after cloning dotfiles fresh elsewhere). Does three
# things:
#   1. Merges SessionStart/UserPromptSubmit/PostToolUse hook entries into
#      ~/.claude/settings.json (backed up first; never symlinked -- it's a
#      large live-state file this repo does not otherwise manage).
#   2. Symlinks the router skill into ~/.claude/skills/skillsh-router.
#   3. Installs find-skills globally via `npx skills` (the actual discovery
#      engine this router sits in front of).
set -euo pipefail

CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="${HOME}/.claude/settings.json"
BACKUP_DIR="${HOME}/.claude/backups"
SKILLS_DIR="${HOME}/.claude/skills"
HOOKS_CMD="${CLAUDE_DIR}/hooks/run-hook.cmd"

echo "skillsh-router install"
echo "  repo:     ${CLAUDE_DIR}"
echo "  settings: ${SETTINGS_FILE}"
echo

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq)" >&2
  exit 1
fi

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "error: ${SETTINGS_FILE} not found -- expected an existing Claude Code settings file" >&2
  exit 1
fi

# --- 1. Merge hooks into settings.json -------------------------------------

mkdir -p "$BACKUP_DIR"
backup_path="${BACKUP_DIR}/settings.json.pre-skillsh-router.$(date -u +%s)"
cp "$SETTINGS_FILE" "$backup_path"
echo "backed up settings.json -> ${backup_path}"

merged="$(jq \
  --arg hooks_cmd "$HOOKS_CMD" \
  '
  # Build our three hook entries fresh each run, then filter out any
  # pre-existing entry that already points at our hooks/run-hook.cmd before
  # re-adding -- this is what makes re-running the installer idempotent
  # instead of accumulating duplicate entries.
  def is_ours: (.hooks[0].command // "") | contains($hooks_cmd);
  def quoted_cmd(suffix): "\"" + $hooks_cmd + "\" " + suffix;

  (.hooks // {}) as $existing
  | .hooks = ($existing + {
      "SessionStart": (
        [($existing.SessionStart // [])[] | select(is_ours | not)]
        + [{
            "matcher": "startup|clear|compact",
            "hooks": [{"type": "command", "command": quoted_cmd("session-start"), "async": false}]
          }]
      ),
      "UserPromptSubmit": (
        [($existing.UserPromptSubmit // [])[] | select(is_ours | not)]
        + [{
            "hooks": [{"type": "command", "command": quoted_cmd("user-prompt-submit")}]
          }]
      ),
      "PostToolUse": (
        [($existing.PostToolUse // [])[] | select(is_ours | not)]
        + [{
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": quoted_cmd("post-tool-use")}]
          }]
      )
    })
  ' "$SETTINGS_FILE")"

printf '%s\n' "$merged" >"$SETTINGS_FILE"
echo "merged hooks into settings.json"

# --- 2. Symlink the router skill --------------------------------------------

mkdir -p "$SKILLS_DIR"
link_target="${SKILLS_DIR}/skillsh-router"
if [ -L "$link_target" ] || [ -e "$link_target" ]; then
  rm -rf "$link_target"
fi
ln -s "${CLAUDE_DIR}/skills/skillsh-router" "$link_target"
echo "linked skill -> ${link_target}"

# --- 3. Install find-skills --------------------------------------------------

echo "installing find-skills (vercel-labs/skills) globally..."
npx --yes skills add vercel-labs/skills --skill find-skills -g -y

# --- 4. Init the learning ledger --------------------------------------------

mkdir -p "${CLAUDE_DIR}/data"
if [ ! -f "${CLAUDE_DIR}/data/routes.json" ]; then
  printf '{"version":1,"threshold":3,"candidates":{},"routes":[]}\n' >"${CLAUDE_DIR}/data/routes.json"
  echo "initialized data/routes.json"
fi
touch "${CLAUDE_DIR}/data/.pending-find.json"
printf '[]\n' >"${CLAUDE_DIR}/data/.pending-find.json"

echo
echo "done. Start (or restart) a Claude Code session to pick up the SessionStart hook."

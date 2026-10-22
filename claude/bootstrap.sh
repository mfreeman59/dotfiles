#!/usr/bin/env bash
# claude-kit の初期化（設計書 §11）。新しいマシンで dotfiles を clone した後に 1 回実行する。
# 何度実行しても同じ結果になる。--no-sync を付けると最後の初回同期を省く（テスト用）。
set -euo pipefail

CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "${CLAUDE_DIR}/.." && pwd)"
KIT="${CLAUDE_DIR}/plugins/kit/bin/kit"
SETTINGS="${HOME}/.claude/settings.json"
STATE_DIR="${KIT_STATE_DIR:-${HOME}/.local/state/claude-kit}"
do_sync=1
[ "${1:-}" = "--no-sync" ] && do_sync=0

missing=""
for t in git jq gh node npx claude perl; do
  command -v "$t" >/dev/null 2>&1 || missing="${missing} ${t}"
done
if [ -n "$missing" ]; then
  echo "必要なコマンドが見つかりません:${missing}" >&2
  echo "  brew install git jq gh node（Claude Code は https://code.claude.com から）" >&2
  exit 1
fi

# 1. v1（skillsh-router）の残りを撤去する
if [ -f "$SETTINGS" ] &&
  jq -e '[(.hooks // {})[][] | .hooks[]? | .command // "" | select(contains("/claude/hooks/run-hook.cmd"))] | length > 0' "$SETTINGS" >/dev/null; then
  mkdir -p "${HOME}/.claude/backups"
  backup="${HOME}/.claude/backups/settings.json.pre-kit.$(date -u +%s)"
  cp "$SETTINGS" "$backup"
  tmp="$(mktemp "${SETTINGS}.XXXXXX")"
  jq --indent 2 '.hooks |= with_entries(
      .value |= map(select([.hooks[]? | .command // "" | contains("/claude/hooks/run-hook.cmd")] | any | not))
      | select(.value | length > 0))' "$SETTINGS" >"$tmp"
  mv "$tmp" "$SETTINGS"
  echo "v1 のフックを settings.json から外しました（バックアップ: ${backup}）"
fi
if [ -L "${HOME}/.claude/skills/skillsh-router" ]; then
  rm "${HOME}/.claude/skills/skillsh-router"
  echo "~/.claude/skills/skillsh-router を削除しました"
fi
lock="${HOME}/.agents/.skill-lock.json"
if [ -f "$lock" ] && jq -e '(.skills // {}) | has("find-skills")' "$lock" >/dev/null; then
  npx --yes skills remove find-skills -g -y </dev/null >/dev/null
  echo "find-skills を外しました"
fi

# 2. dotfiles の場所を記録する（kit がキャッシュのコピーから動いた場合に備える）
mkdir -p "$STATE_DIR"
printf '%s' "$DOTFILES_DIR" >"${STATE_DIR}/dotfiles-path"

# 3. マーケットプレイス dotfiles と kit を入れる
if ! claude plugin marketplace list --json </dev/null | jq -e 'any(.[]; .name == "dotfiles")' >/dev/null; then
  claude plugin marketplace add "$CLAUDE_DIR" --scope user </dev/null
fi
if ! claude plugin list --json </dev/null | jq -e 'any(.[]; .id == "kit@dotfiles" and .scope == "user")' >/dev/null; then
  claude plugin install kit@dotfiles -s user </dev/null
fi

# 4. 初回の同期
if [ "$do_sync" = 1 ]; then
  "$KIT" sync --force || echo "初回の同期で問題がありました。kit status で確認してください" >&2
fi
echo "完了しました。Claude Code を再起動してください。"

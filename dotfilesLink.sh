#!/usr/bin/env bash
# Symlinks this repo's dotfiles into $HOME.
# Idempotent: safe to re-run any time (e.g. after `git pull`) -- `ln -sfn`
# overwrites an existing symlink instead of failing with "File exists".
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

files=(
  .vimrc
  .bashrc
  .zshrc
  .gitconfig
  .gitignore_global
)

for f in "${files[@]}"; do
  ln -sfn "${DOTFILES_DIR}/${f}" "${HOME}/${f}"
  echo "linked: ~/${f} -> ${DOTFILES_DIR}/${f}"
done

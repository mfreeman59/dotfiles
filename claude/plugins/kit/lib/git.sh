# dotfiles リポジトリへの git 操作（設計書 §7.5、§7.7）。対象は常に KIT_DOTFILES。

kit_git() { git -C "$KIT_DOTFILES" "$@"; }
kit_git_remote_ref() { printf '%s/%s' "$KIT_REMOTE" "$KIT_BRANCH"; }

# kit_git_fetch: オフラインやタイムアウトなら 1
kit_git_fetch() {
  kit_with_timeout "$KIT_FETCH_TIMEOUT" git -C "$KIT_DOTFILES" fetch -q "$KIT_REMOTE" "$KIT_BRANCH" </dev/null >/dev/null 2>&1 || return 1
}

# kit_git_has_manifest <rev>: その版に manifest があれば 0
kit_git_has_manifest() { kit_git cat-file -e "$1:${KIT_MANIFEST_REL}" 2>/dev/null || return 1; }

# kit_git_show_manifest <rev>: その版の manifest。ない版は空の manifest。
# あるのに JSON のオブジェクトとして読めなければ、何も出さずに 2（空として扱うと、空の manifest が push されてしまう）
kit_git_show_manifest() {
  local m
  if ! kit_git_has_manifest "$1"; then
    printf '%s' "$KIT_EMPTY_MANIFEST"
    return 0
  fi
  m="$(kit_git show "$1:${KIT_MANIFEST_REL}" 2>/dev/null)"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$m" || return 2
  printf '%s' "$m"
}

# kit_git_foreign_commits <range>: range のうち kit のものでないコミットを 1 行 1 件で出す。
# kit のコミット = 件名が「chore(kit): sync from 」で始まり、かつ変更が manifest だけのもの（件名だけでは見分けない）
kit_git_foreign_commits() {
  local c subject files
  for c in $(kit_git rev-list "$1"); do
    subject="$(kit_git log -1 --format=%s "$c")"
    files="$(kit_git diff-tree --no-commit-id --name-only -r "$c")"
    case "$subject" in
      "chore(kit): sync from "*) [ "$files" = "$KIT_MANIFEST_REL" ] && continue ;;
    esac
    printf '%s\n' "$c"
  done
}

# kit_git_base_manifest: HEAD と upstream の merge-base の manifest（discovery のマージの基準 H。設計書 §7.4）
kit_git_base_manifest() {
  local up mb
  up="$(kit_git_remote_ref)"
  if kit_git rev-parse -q --verify "$up" >/dev/null && mb="$(kit_git merge-base HEAD "$up" 2>/dev/null)"; then
    kit_git_show_manifest "$mb"
  else
    kit_git_show_manifest HEAD
  fi
}

# kit_git_branch_ok: master 上で、rebase / merge / cherry-pick の途中でなければ 0
kit_git_branch_ok() {
  local branch p
  branch="$(kit_git symbolic-ref --short -q HEAD)" || return 1
  [ "$branch" = "$KIT_BRANCH" ] || return 1
  for p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
    [ -e "$(kit_git rev-parse --path-format=absolute --git-path "$p")" ] && return 1
  done
  return 0
}

# kit_git_update: 作業ツリーの manifest を HEAD に戻してから、HEAD を upstream に追いつかせる。
# 0 成功 / 1 未コミットの変更とぶつかった / 2 kit 以外のコミットで履歴が分岐している
kit_git_update() {
  local up
  up="$(kit_git_remote_ref)"
  if kit_git_has_manifest HEAD; then
    kit_git checkout -q HEAD -- "$KIT_MANIFEST_REL"
  else
    kit_git rm -q --cached --ignore-unmatch -- "$KIT_MANIFEST_REL" >/dev/null 2>&1
    rm -f "$KIT_MANIFEST"
  fi
  kit_git rev-parse -q --verify "$up" >/dev/null || return 0
  if kit_git merge-base --is-ancestor HEAD "$up"; then
    kit_git merge -q --ff-only "$up" >/dev/null 2>&1 || return 1
  elif kit_git merge-base --is-ancestor "$up" HEAD; then
    return 0
  elif [ -n "$(kit_git_foreign_commits "${up}..HEAD")" ]; then
    return 2
  else
    # 前回 push できなかった kit のコミットを捨てる（内容は 3 者比較で M に取り込み済み）
    kit_git reset -q --keep "$up" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# kit_git_commit_manifest: manifest に変更があれば、それだけをコミットする（他のステージ済みの変更は残る）
kit_git_commit_manifest() {
  kit_git add -- "$KIT_MANIFEST_REL" || return 1
  kit_git diff --cached --quiet -- "$KIT_MANIFEST_REL" && return 0
  kit_git commit -q -m "chore(kit): sync from $(hostname -s)" -- "$KIT_MANIFEST_REL" >/dev/null
}

# kit_git_foreign_unpushed: upstream にない、kit 以外のコミットがあれば 0
kit_git_foreign_unpushed() {
  local up
  up="$(kit_git_remote_ref)"
  kit_git rev-parse -q --verify "$up" >/dev/null || return 1
  [ -n "$(kit_git_foreign_commits "${up}..HEAD")" ]
}

kit_git_push() {
  kit_with_timeout "$KIT_PUSH_TIMEOUT" git -C "$KIT_DOTFILES" push -q "$KIT_REMOTE" "HEAD:${KIT_BRANCH}" </dev/null >/dev/null 2>&1 || return 1
}

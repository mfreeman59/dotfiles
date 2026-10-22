. "$(dirname "$0")/helpers.sh"

g_setup() {
  t_remote; t_clone A; t_clone B
  t_machine A
  . "${KIT_PLUGIN_DIR}/lib/common.sh"
  . "${KIT_PLUGIN_DIR}/lib/git.sh"
  A="${T_TMP}/A/dotfiles"; Bd="${T_TMP}/B/dotfiles"
}
b_push() {  # <ファイル> <内容> <メッセージ>: B でコミットして push する
  printf '%s\n' "$2" >"${Bd}/$1"
  git -C "$Bd" add -A && git -C "$Bd" commit -q -m "$3" && git -C "$Bd" push -q origin master
}
a_commit() {  # <ファイル> <内容> <メッセージ>
  mkdir -p "$(dirname "${A}/$1")"
  printf '%s\n' "$2" >"${A}/$1"
  git -C "$A" add -A && git -C "$A" commit -q -m "$3"
}

s_branch_ok() {
  g_setup
  kit_git_branch_ok; assert_eq "$?" "0" "master なら ok"
  git -C "$A" checkout -q -b feat
  kit_git_branch_ok; assert_eq "$?" "1" "master 以外は ng"
  git -C "$A" checkout -q master
  mkdir -p "${A}/.git/rebase-merge"
  kit_git_branch_ok; assert_eq "$?" "1" "rebase の途中は ng"
}
s_update_ff() {
  g_setup
  b_push other.txt b "feat: b"
  kit_git_fetch; assert_eq "$?" "0" "fetch できる"
  kit_git_update; assert_eq "$?" "0" "fast-forward できる"
  assert_eq "$(git -C "$A" rev-parse HEAD)" "$(git -C "$A" rev-parse origin/master)" "upstream に追いつく"
}
s_update_ahead() {
  g_setup
  a_commit claude/manifest.json '{}' "chore(kit): sync from x"
  kit_git_fetch; kit_git_update; assert_eq "$?" "0" "push していないコミットがあるだけなら何もしない"
  assert_eq "$(git -C "$A" log -1 --format=%s)" "chore(kit): sync from x" "HEAD はそのまま"
}
s_update_diverged_kit_only() {
  g_setup
  a_commit claude/manifest.json '{"x":1}' "chore(kit): sync from x"
  b_push other.txt b "feat: b"
  kit_git_fetch; kit_git_update; assert_eq "$?" "0" "kit のコミットだけで分岐していれば付け直せる"
  assert_eq "$(git -C "$A" rev-parse HEAD)" "$(git -C "$A" rev-parse origin/master)" "reset --keep で upstream に合わせる"
}
s_update_diverged_foreign() {
  g_setup
  a_commit mine.txt m "feat: mine"
  b_push other.txt b "feat: b"
  kit_git_fetch; kit_git_update; assert_eq "$?" "2" "kit 以外のコミットで分岐していれば 2"
}
s_update_dirty() {
  g_setup
  b_push other.txt b "feat: b"
  echo "local edit" >"${A}/other.txt"
  kit_git_fetch; kit_git_update; assert_eq "$?" "1" "未コミットの変更とぶつかれば 1"
  assert_eq "$(cat "${A}/other.txt")" "local edit" "未コミットの変更は残る"
}
s_untracked_manifest() {
  g_setup
  b_push claude/manifest.json '{"from":"B"}' "chore(kit): sync from B"
  echo '{"from":"A"}' >"${A}/claude/manifest.json"     # 未追跡（Review Focus 3）
  kit_git_fetch; kit_git_update; assert_eq "$?" "0" "未追跡の manifest があっても取り込める"
  assert_eq "$(jq -r .from "${A}/claude/manifest.json")" "B" "取り込んだ manifest になる"
}
s_foreign_unpushed() {
  g_setup
  kit_git_fetch
  a_commit claude/manifest.json '{}' "chore(kit): sync from x"
  kit_git_foreign_unpushed; assert_eq "$?" "1" "kit のコミットだけなら foreign ではない"
  a_commit mine.txt m "feat: mine"
  kit_git_foreign_unpushed; assert_eq "$?" "0" "kit 以外のコミットがあれば foreign"
}
s_base_manifest() {
  g_setup
  b_push claude/manifest.json '{"v":1}' "chore(kit): sync from B"
  kit_git_fetch; kit_git_update
  a_commit claude/manifest.json '{"v":2}' "chore(kit): sync from A"
  assert_eq "$(kit_git_base_manifest | jq -r .v)" "1" "merge-base の manifest を返す"
  assert_eq "$(kit_git_show_manifest HEAD | jq -r .v)" "2" "HEAD の manifest"
  assert_json_eq "$(kit_git_show_manifest HEAD~2)" "$KIT_EMPTY_MANIFEST" "manifest のない版は空の manifest"
}
s_commit_only_manifest() {
  g_setup
  echo "staged" >"${A}/other.txt"; git -C "$A" add other.txt
  echo '{"a":1}' >"${A}/claude/manifest.json"
  kit_git_commit_manifest; assert_eq "$?" "0" "コミットできる"
  assert_eq "$(git -C "$A" diff-tree --no-commit-id --name-only -r HEAD)" "claude/manifest.json" "manifest だけをコミットする"
  assert_eq "$(git -C "$A" diff --cached --name-only)" "other.txt" "他のステージ済みの変更は残る"
  assert_eq "$(git -C "$A" log -1 --format=%s)" "chore(kit): sync from $(hostname -s)" "コミットメッセージ"
  n="$(git -C "$A" rev-list --count HEAD)"
  kit_git_commit_manifest
  assert_eq "$(git -C "$A" rev-list --count HEAD)" "$n" "変更がなければコミットしない"
  kit_git_push; assert_eq "$?" "0" "push できる"
}
s_fetch_offline() {
  g_setup
  git -C "$A" remote set-url origin "${T_TMP}/nowhere.git"
  kit_git_fetch; assert_eq "$?" "1" "fetch できなければ 1"
}

t_scenario "master 上かどうか" s_branch_ok
t_scenario "fast-forward" s_update_ff
t_scenario "push していないコミットがあるだけ" s_update_ahead
t_scenario "kit のコミットだけで分岐" s_update_diverged_kit_only
t_scenario "kit 以外のコミットで分岐" s_update_diverged_foreign
t_scenario "未コミットの変更とぶつかる" s_update_dirty
t_scenario "未追跡の manifest" s_untracked_manifest
t_scenario "kit 以外の未 push コミット" s_foreign_unpushed
t_scenario "merge-base の manifest" s_base_manifest
t_scenario "manifest だけをコミット" s_commit_only_manifest
t_scenario "オフライン" s_fetch_offline
t_done

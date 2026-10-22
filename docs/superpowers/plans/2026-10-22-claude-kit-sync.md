# claude-kit 計画 1（骨格・同期・bootstrap・v1 撤去）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dotfiles をローカルマーケットプレイスにした自作プラグイン `kit` を作り、ユーザースコープのプラグイン・マーケットプレイス・skills.sh のスキルを `claude/manifest.json` 経由で複数マシンに自動同期する。あわせて v1（skillsh-router）を撤去する。

**Architecture:** `kit sync` が「このマシンの実状態 L」「前回合意した状態 B」「リモートの manifest R」を項目ごとに 3 者比較し（`lib/merge.jq`）、他のマシンの変更を `claude plugin` / `npx skills` CLI で反映し、このマシンの変更を manifest に書いて、manifest だけを自動でコミット・push する。SessionStart / SessionEnd フックは同期を完全に切り離したプロセスで起動してすぐ戻る。発見（`kit discover`、`/discover`）は計画 2 で扱う。

**Tech Stack:** bash（3.2 互換）、jq、git、perl（macOS 標準。タイムアウトとプロセスの切り離しに使う）、Claude Code の `claude plugin` CLI、skills.sh の `npx skills` CLI。

**Spec:** `docs/superpowers/specs/2026-10-22-claude-kit-design.md`

## Global Constraints

- 対象は macOS のみ。
- bash 3.2 互換で書く（連想配列、`mapfile`、`${var,,}`、負の配列添字を使わない。配列自体を避け、データは jq で扱う）。テストは `/bin/bash`（3.2）で実行して互換性を確かめる。
- jq は 1.6 互換の機能だけ使う（1.7 以降で追加された `pick`、`toarray`、`trim`、`abs` などを使わない）。
- 依存は git（2.31 以上。`rev-parse --path-format=absolute` を使う）、jq、perl、claude、npx だけ。新しいパッケージを入れない。
- `~/.claude/settings.json` を書き換えるのは `bootstrap.sh` の v1 撤去だけ（必ずバックアップを取る）。同期は `claude plugin` CLI 経由で行う。
- kit の自動コミットのメッセージは `chore(kit): sync from <hostname -s>`。`claude/manifest.json` 以外をコミットしない。
- manifest と状態ファイルは `jq -S --indent 2` で書く（キーをソートする）。
- フックから呼ばれる処理は常に終了コード 0 で終わる。SessionEnd フックは 1 秒以内に戻る。`KIT_NESTED=1` のときフックは何もしない。
- 状態ディレクトリは `${KIT_STATE_DIR:-$HOME/.local/state/claude-kit}`。
- 通知文、README、コードのコメントは日本語。
- テストは本物の `~/.claude`、本物の dotfiles リポジトリ、ネットワークに触れない（`HOME`・`KIT_STATE_DIR`・`KIT_DOTFILES` を一時ディレクトリに向け、`tests/fakes/` の偽の `claude` / `npx` を使う）。例外は `test_manifests.sh` の `claude plugin validate`（読み取りのみ）。

## Review Focus

1. **ローカル状態の読み取り失敗**（`claude plugin list` がエラー、空出力、未ログイン）: 同期を中止し、「全部消えた」として他のマシンに削除を広げない。→ Task 3 `test_local_state.sh` と Task 7 シナリオ「ローカル状態が読めないと中止する」。
2. **manifest.json が不正な JSON**（手での編集ミス、マージの衝突マーカー）: 同期を中止して通知し、空の manifest とみなして `discovery` を消さない。→ Task 7 シナリオ「manifest が壊れていたら中止する」。
3. **未追跡の manifest.json が残ったまま、リモートにも manifest が追加された**（オフラインで初回同期したマシンが後でオンラインになる）: 同期が通り、どちらの内容も失わない。→ Task 7 シナリオ「未追跡の manifest とリモートの manifest」。
4. **kit が git の外（キャッシュのコピー）から動いた**: dotfiles の場所を見失わず、bootstrap が記録したパスを使う。→ Task 1 `test_common.sh`。
5. **並列セッションからの同時起動**: ロックで 1 つだけが動き、manifest と base.json が壊れない。→ Task 7 シナリオ「同時に起動しても 1 つだけ動く」。

---

## ファイル構成

```
claude/
├─ .claude-plugin/marketplace.json   マーケットプレイス "dotfiles"（Task 1）
├─ bootstrap.sh                      新しいマシンの初期化（Task 9）
├─ manifest.json                     初回の同期で生成（Task 10）
├─ README.md                         kit の説明に書き直す（Task 10）
└─ plugins/kit/
   ├─ .claude-plugin/plugin.json     （Task 1）
   ├─ hooks/hooks.json               SessionStart / SessionEnd（Task 8）
   ├─ bin/kit                        CLI のディスパッチャ（Task 1）
   ├─ lib/common.sh                  設定値、ログ、通知、ロック、JSON 読み書き、タイムアウト（Task 1）
   ├─ lib/detach.sh                  完全に切り離したプロセスの起動（Task 2）
   ├─ lib/local_state.sh             実状態 L の読み取り（Task 3）
   ├─ lib/merge.jq                   3 者比較と base の更新規則（Task 4）
   ├─ lib/merge.sh                   merge.jq の呼び出し口（Task 4）
   ├─ lib/apply.sh                   このマシンへの操作（Task 5）
   ├─ lib/git.sh                     dotfiles への git 操作（Task 6）
   ├─ lib/sync.sh                    kit sync 本体（Task 7）
   ├─ lib/status.sh                  kit status（Task 7）
   ├─ lib/hook.sh                    kit hook（Task 8）
   └─ tests/
      ├─ run.sh                      全テストの実行（Task 1）
      ├─ helpers.sh                  アサーション、一時環境、マシンの切り替え（Task 1）
      ├─ fakes/claude, fakes/npx     偽 CLI（Task 3）
      └─ test_*.sh                   各 Task のテスト
```

v1 のファイル（`claude/hooks/`、`claude/lib/`、`claude/bin/`、`claude/data/`、`claude/skills/`、`claude/install.sh`、`claude/uninstall.sh`、`claude/.gitignore`）は Task 10 で削除する。それまで触らない。

---

### Task 1: プラグインの骨格、共通部品、テスト基盤

**Files:**
- Create: `claude/.claude-plugin/marketplace.json`
- Create: `claude/plugins/kit/.claude-plugin/plugin.json`
- Create: `claude/plugins/kit/bin/kit`
- Create: `claude/plugins/kit/lib/common.sh`
- Create: `claude/plugins/kit/tests/run.sh`
- Create: `claude/plugins/kit/tests/helpers.sh`
- Test: `claude/plugins/kit/tests/test_common.sh`、`claude/plugins/kit/tests/test_manifests.sh`

**Interfaces:**
- Produces（`lib/common.sh`）:
  - 変数: `KIT_LIB_DIR`、`KIT_ROOT`（プラグインのルート）、`KIT_STATE`、`KIT_DOTFILES`、`KIT_MANIFEST_REL`、`KIT_MANIFEST`、`KIT_BRANCH`、`KIT_REMOTE`、`KIT_THROTTLE_SECONDS`、`KIT_LOCK_STALE_SECONDS`、`KIT_FETCH_TIMEOUT`、`KIT_PUSH_TIMEOUT`、`KIT_MAX_FAILURES`、`KIT_NOTICE_SUPPRESS_SECONDS`、`KIT_EMPTY_MANIFEST`
  - `kit_init_state`、`kit_now`（epoch 秒）、`kit_iso_now`、`kit_log <msg>`、`kit_trim_log`
  - `kit_notice <info|warn> <message>`、`kit_take_notices`（JSON 配列を出して空にする）
  - `kit_write_json <path> <json>`（失敗で 1）、`kit_read_json <path> <default-json>`、`kit_json_eq <a> <b>`
  - `kit_with_timeout <seconds> <cmd...>`、`kit_lock`（取れなければ 1）、`kit_unlock`、`kit_require <cmd>`
- Produces（`tests/helpers.sh`）: `assert_eq`、`assert_ne`、`assert_lt`、`assert_json_eq`、`assert_contains`、`assert_not_contains`、`t_done`、`t_tmp`、`t_ms`、`t_scenario <説明> <関数>`、`t_machine <名前>`、`on <名前> <cmd...>`、`kit <args...>`、`fake_set <jq式>`、`fake_calls`、`t_remote`、`t_clone <名前>`、`state_file <名前> <ファイル>`、`notices_of`、`manifest_of`、`remote_manifest`、`calls_of`、`wait_log <名前> <文字列>`

- [ ] **Step 1: テスト基盤を書く**

`claude/plugins/kit/tests/run.sh`:

```bash
#!/usr/bin/env bash
# kit のテストを実行する。引数でファイルを指定しなければ test_*.sh をすべて実行する。
# 各テストは /bin/bash（3.2）で実行して、古い bash でも動くことを確かめる。
set -u
cd "$(dirname "$0")"
files="${*:-$(ls test_*.sh)}"
fails=0
for t in $files; do
  echo "== $t"
  /bin/bash "$t" || fails=$((fails + 1))
done
if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "${fails} 個のテストファイルが失敗しました"; exit 1; fi
```

`claude/plugins/kit/tests/helpers.sh`:

```bash
# テストの共通部品。各 test_*.sh から source する。
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_PLUGIN_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
KIT_BIN="${KIT_PLUGIN_DIR}/bin/kit"
REAL_CLAUDE="$(command -v claude || true)"
T_FAILS=0
T_COUNT=0

t_fail() { T_FAILS=$((T_FAILS + 1)); printf '    FAIL: %s\n' "$*"; }
assert_eq() { T_COUNT=$((T_COUNT + 1)); [ "$1" = "$2" ] || t_fail "$3: 期待 [$2] 実際 [$1]"; }
assert_ne() { T_COUNT=$((T_COUNT + 1)); [ "$1" != "$2" ] || t_fail "$3: [$1] 以外を期待"; }
assert_lt() { T_COUNT=$((T_COUNT + 1)); [ "$1" -lt "$2" ] || t_fail "$3: $1 < $2 ではない"; }
assert_json_eq() {
  T_COUNT=$((T_COUNT + 1))
  local a b
  a="$(jq -cS . <<<"$1" 2>&1)"; b="$(jq -cS . <<<"$2" 2>&1)"
  [ "$a" = "$b" ] || t_fail "$3: 期待 $b 実際 $a"
}
assert_contains() { T_COUNT=$((T_COUNT + 1)); case "$1" in *"$2"*) ;; *) t_fail "$3: [$2] が含まれていない。実際: [$1]" ;; esac; }
assert_not_contains() { T_COUNT=$((T_COUNT + 1)); case "$1" in *"$2"*) t_fail "$3: [$2] が含まれている" ;; esac; }
t_done() {
  if [ "$T_FAILS" -eq 0 ]; then echo "  ok (${T_COUNT})"; exit 0; fi
  echo "  ${T_FAILS} 件失敗 (${T_COUNT} 中)"; exit 1
}
t_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }

# 一時ディレクトリ（テストファイル全体で 1 つ）
t_tmp() { T_TMP="$(mktemp -d)"; trap 'rm -rf "$T_TMP"' EXIT; }

# t_scenario <説明> <関数>: 一時ディレクトリを分けたサブシェルで 1 シナリオを実行する
t_scenario() {
  printf '  - %s\n' "$1"
  T_COUNT=$((T_COUNT + 1))
  if ! (T_TMP="$(mktemp -d)"; trap 'rm -rf "$T_TMP"' EXIT; T_FAILS=0; "$2"; [ "$T_FAILS" -eq 0 ]); then
    T_FAILS=$((T_FAILS + 1))
  fi
}

# t_machine <名前>: そのマシン用の HOME・状態・偽コマンド・dotfiles に切り替える
t_machine() {
  export HOME="${T_TMP}/$1/home"
  export KIT_STATE_DIR="${HOME}/.local/state/claude-kit"
  export KIT_DOTFILES="${T_TMP}/$1/dotfiles"
  export FAKE_DIR="${T_TMP}/$1/fake"
  export KIT_THROTTLE_SECONDS="${KIT_THROTTLE_SECONDS:-0}"
  export KIT_NOTICE_SUPPRESS_SECONDS="${KIT_NOTICE_SUPPRESS_SECONDS:-0}"
  case ":${PATH}:" in *":${TESTS_DIR}/fakes:"*) ;; *) export PATH="${TESTS_DIR}/fakes:${PATH}" ;; esac
  mkdir -p "$HOME" "$FAKE_DIR"
  [ -f "${FAKE_DIR}/claude.json" ] || echo '{"plugins":[],"marketplaces":[],"fail":[],"command_source":[]}' >"${FAKE_DIR}/claude.json"
}
on() { local m="$1"; shift; (t_machine "$m"; "$@"); }
kit() { /bin/bash "$KIT_BIN" "$@"; }
fake_set() { local f="${FAKE_DIR}/claude.json" tmp; tmp="$(mktemp)"; jq "$1" "$f" >"$tmp" && mv "$tmp" "$f"; }
fake_calls() { cat "${FAKE_DIR}/calls.log" 2>/dev/null; }

# t_remote: bare リモートと、manifest を持たない最初のコミットを作る
t_remote() {
  local seed="${T_TMP}/seed"
  git init -q --bare -b master "${T_TMP}/remote.git"
  git init -q -b master "$seed"
  git -C "$seed" config user.email seed@example.com
  git -C "$seed" config user.name seed
  mkdir -p "${seed}/claude"
  echo "keep" >"${seed}/claude/.keep"
  echo "seed" >"${seed}/README.md"
  echo "a" >"${seed}/other.txt"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m init
  git -C "$seed" remote add origin "${T_TMP}/remote.git"
  git -C "$seed" push -q origin master
}
# t_clone <名前>: そのマシンの dotfiles を clone する
t_clone() {
  local d="${T_TMP}/$1/dotfiles"
  git clone -q "${T_TMP}/remote.git" "$d"
  git -C "$d" config user.email "$1@example.com"
  git -C "$d" config user.name "$1"
  git -C "$d" config commit.gpgsign false
}

state_file() { printf '%s/%s/home/.local/state/claude-kit/%s' "$T_TMP" "$1" "$2"; }
notices_of() { cat "$(state_file "$1" notices.jsonl)" 2>/dev/null; }
manifest_of() { cat "${T_TMP}/$1/dotfiles/claude/manifest.json" 2>/dev/null; }
remote_manifest() { git --git-dir="${T_TMP}/remote.git" show master:claude/manifest.json 2>/dev/null; }
calls_of() { cat "${T_TMP}/$1/fake/calls.log" 2>/dev/null; }
# wait_log <名前> <文字列> [回数]: そのマシンの sync.log に文字列が指定回数（既定 1）出るまで最大 15 秒待つ。
# 切り離した同期がシナリオの終了（一時ディレクトリの削除）より後まで動かないよう、終わりを待つのにも使う
wait_log() {
  local i=0 n="${3:-1}" c
  while [ "$i" -lt 150 ]; do
    c="$(grep -c -- "$2" "$(state_file "$1" sync.log)" 2>/dev/null || true)"
    [ "${c:-0}" -ge "$n" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
```

- [ ] **Step 2: 失敗するテストを書く**

`claude/plugins/kit/tests/test_common.sh`:

```bash
. "$(dirname "$0")/helpers.sh"
t_tmp
export HOME="${T_TMP}/home" KIT_STATE_DIR="${T_TMP}/state" KIT_DOTFILES="${T_TMP}/dot"
. "${KIT_PLUGIN_DIR}/lib/common.sh"

# kit_write_json / kit_read_json
kit_write_json "${T_TMP}/x.json" '{"b":1,"a":{"d":2,"c":3}}'
assert_eq "$(cat "${T_TMP}/x.json")" "$(printf '{\n  "a": {\n    "c": 3,\n    "d": 2\n  },\n  "b": 1\n}')" "キーをソートしインデント 2 で書く"
kit_write_json "${T_TMP}/x.json" '{'; rc=$?
assert_eq "$rc" "1" "不正な JSON は書かずに失敗する"
assert_eq "$(jq -c . "${T_TMP}/x.json")" '{"a":{"c":3,"d":2},"b":1}' "失敗しても元のファイルは残る"
assert_eq "$(kit_read_json "${T_TMP}/none.json" '{"d":1}')" '{"d":1}' "ないファイルは既定値"
kit_json_eq '{"a":1,"b":2}' '{"b":2,"a":1}'; assert_eq "$?" "0" "キーの順序は比較に影響しない"

# 通知
kit_notice info "一つ目"; kit_notice info "二つ目"; kit_notice info "一つ目"
got="$(kit_take_notices)"
assert_eq "$(jq length <<<"$got")" "2" "同じ文面はまとめる"
assert_eq "$(jq -r '.[0].level' <<<"$got")" "info" "level を持つ"
assert_eq "$(kit_take_notices)" "[]" "取り出したら空になる"
KIT_NOTICE_SUPPRESS_SECONDS=21600
kit_notice warn "警告A"; kit_notice warn "警告A"
assert_eq "$(kit_take_notices | jq length)" "1" "同じ警告は抑制期間中は 1 回だけ"
KIT_NOTICE_SUPPRESS_SECONDS=0
kit_notice warn "警告A"
assert_eq "$(kit_take_notices | jq length)" "1" "抑制期間が過ぎれば再び通知する"

# ロック
kit_lock; assert_eq "$?" "0" "ロックを取れる"
kit_lock; assert_eq "$?" "1" "取得済みなら取れない"
touch -t 202001010000 "${KIT_STATE}/lock"
kit_lock; assert_eq "$?" "0" "古いロックは消して取り直す"
kit_unlock
assert_eq "$([ -d "${KIT_STATE}/lock" ] && echo yes || echo no)" "no" "解除する"

# タイムアウト
start="$(t_ms)"; kit_with_timeout 1 sleep 5; rc=$?; end="$(t_ms)"
assert_ne "$rc" "0" "タイムアウトしたら 0 以外"
assert_lt "$((end - start))" "3000" "指定秒数で打ち切る"

# git の外（キャッシュのコピー）から動いても、記録したパスで dotfiles を見つける（Review Focus 4）
mkdir -p "${T_TMP}/copy" "${T_TMP}/state2"
cp -R "${KIT_PLUGIN_DIR}/lib" "${T_TMP}/copy/lib"
printf '%s' "/path/to/dotfiles" >"${T_TMP}/state2/dotfiles-path"
got="$(env -u KIT_DOTFILES KIT_STATE_DIR="${T_TMP}/state2" /bin/bash -c ". '${T_TMP}/copy/lib/common.sh'; printf '%s' \"\$KIT_DOTFILES\"")"
assert_eq "$got" "/path/to/dotfiles" "git の外からは記録したパスを使う"

# bin/kit
out="$(/bin/bash "$KIT_BIN" help)"; assert_contains "$out" "usage: kit" "help を表示する"
/bin/bash "$KIT_BIN" nosuch >/dev/null 2>&1; assert_eq "$?" "2" "不明なコマンドは 2"

t_done
```

`claude/plugins/kit/tests/test_manifests.sh`:

```bash
. "$(dirname "$0")/helpers.sh"
if [ -z "$REAL_CLAUDE" ]; then echo "  skip（claude がない）"; exit 0; fi
CLAUDE_DIR="$(cd "${KIT_PLUGIN_DIR}/../.." && pwd)"

out="$("$REAL_CLAUDE" plugin validate "$CLAUDE_DIR" 2>&1)"; rc=$?
assert_eq "$rc" "0" "マーケットプレイスの検証が通る"
assert_contains "$out" "Validation passed" "マーケットプレイスの検証結果"
out="$("$REAL_CLAUDE" plugin validate "$KIT_PLUGIN_DIR" 2>&1)"; rc=$?
assert_eq "$rc" "0" "プラグインの検証が通る"
if [ -f "${KIT_PLUGIN_DIR}/hooks/hooks.json" ]; then
  jq -e '.hooks.SessionStart and .hooks.SessionEnd' "${KIT_PLUGIN_DIR}/hooks/hooks.json" >/dev/null
  assert_eq "$?" "0" "hooks.json に SessionStart と SessionEnd がある"
fi
t_done
```

- [ ] **Step 3: テストが失敗することを確かめる**

Run: `chmod +x claude/plugins/kit/tests/run.sh && claude/plugins/kit/tests/run.sh test_common.sh test_manifests.sh`
Expected: FAIL（`lib/common.sh` も `bin/kit` もまだないため、`No such file or directory` で失敗する）

- [ ] **Step 4: 実装する**

`claude/.claude-plugin/marketplace.json`:

```json
{
  "name": "dotfiles",
  "owner": { "name": "MATSUDA Kengo" },
  "metadata": { "description": "dotfiles で管理する個人用の Claude Code プラグイン" },
  "plugins": [
    {
      "name": "kit",
      "source": "./plugins/kit",
      "description": "スキル・プラグインの発見と、複数マシン間の同期",
      "author": { "name": "MATSUDA Kengo" }
    }
  ]
}
```

`claude/plugins/kit/.claude-plugin/plugin.json`:

```json
{
  "name": "kit",
  "version": "0.1.0",
  "description": "スキル・プラグインの発見と、複数マシン間の同期",
  "author": { "name": "MATSUDA Kengo" }
}
```

`claude/plugins/kit/lib/common.sh`:

```bash
#!/usr/bin/env bash
# kit の共通部品: 設定値、状態ディレクトリ、ログ、通知、ロック、JSON の読み書き、タイムアウト。
# lib/*.sh は関数定義だけを持ち、bin/kit から source される。
# bash 3.2 互換（連想配列・mapfile・${var,,} を使わない）。設計書: docs/superpowers/specs/2026-10-22-claude-kit-design.md

KIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "${KIT_LIB_DIR}/.." && pwd)"
KIT_STATE="${KIT_STATE_DIR:-${HOME}/.local/state/claude-kit}"
KIT_MANIFEST_REL="${KIT_MANIFEST_REL:-claude/manifest.json}"
KIT_BRANCH="${KIT_BRANCH:-master}"
KIT_REMOTE="${KIT_REMOTE:-origin}"
KIT_THROTTLE_SECONDS="${KIT_THROTTLE_SECONDS:-600}"
KIT_LOCK_STALE_SECONDS="${KIT_LOCK_STALE_SECONDS:-600}"
KIT_FETCH_TIMEOUT="${KIT_FETCH_TIMEOUT:-10}"
KIT_PUSH_TIMEOUT="${KIT_PUSH_TIMEOUT:-20}"
KIT_MAX_FAILURES="${KIT_MAX_FAILURES:-3}"
KIT_NOTICE_SUPPRESS_SECONDS="${KIT_NOTICE_SUPPRESS_SECONDS:-21600}"
KIT_EMPTY_MANIFEST='{"version":1,"marketplaces":{},"plugins":{},"skills":{},"discovery":{"watch":[],"dismissed":[]}}'

# dotfiles の場所: 環境変数 → kit 自身を含む git リポジトリ → bootstrap.sh が記録したパス
kit_resolve_dotfiles() {
  local d
  if [ -n "${KIT_DOTFILES:-}" ]; then printf '%s' "$KIT_DOTFILES"; return 0; fi
  if d="$(git -C "$KIT_ROOT" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$d" ]; then
    printf '%s' "$d"; return 0
  fi
  if [ -f "${KIT_STATE}/dotfiles-path" ]; then cat "${KIT_STATE}/dotfiles-path"; fi
}
KIT_DOTFILES="$(kit_resolve_dotfiles)"
KIT_MANIFEST="${KIT_DOTFILES}/${KIT_MANIFEST_REL}"

kit_init_state() { mkdir -p "$KIT_STATE"; }
kit_now() { date +%s; }
kit_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
kit_require() { command -v "$1" >/dev/null 2>&1; }

kit_log() {
  kit_init_state
  printf '%s %s\n' "$(kit_iso_now)" "$*" >>"${KIT_STATE}/sync.log"
}

# sync.log を直近 1,000 行に切り詰める
kit_trim_log() {
  local f="${KIT_STATE}/sync.log" tmp
  [ -f "$f" ] || return 0
  tmp="$(mktemp "${f}.XXXXXX")"
  tail -n 1000 "$f" >"$tmp" && mv "$tmp" "$f"
}

# kit_write_json <path> <json>: キーをソートしインデント 2 で、一時ファイル経由で原子的に書く
kit_write_json() {
  local path="$1" json="$2" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp "${path}.XXXXXX")"
  if printf '%s' "$json" | jq -S --indent 2 . >"$tmp" 2>/dev/null; then
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    return 1
  fi
}

# kit_read_json <path> <default-json>: ファイルがないか壊れていれば既定値
kit_read_json() {
  if [ -f "$1" ]; then jq -c . "$1" 2>/dev/null || printf '%s' "$2"; else printf '%s' "$2"; fi
}

kit_json_eq() { [ "$(jq -cS . <<<"$1")" = "$(jq -cS . <<<"$2")" ]; }

# kit_notice <info|warn> <message>: 通知キュー（1 行 1 件の JSON）に追記する。
# 同じ文面の warn は KIT_NOTICE_SUPPRESS_SECONDS の間 1 回だけ（設計書 §8.4）。
kit_notice() {
  local level="$1" message="$2" hist now last
  kit_init_state
  hist="${KIT_STATE}/notice-history.json"
  now="$(kit_now)"
  if [ "$level" = warn ]; then
    last="$(kit_read_json "$hist" '{}' | jq -r --arg m "$message" '.[$m] // 0')"
    if [ $((now - ${last:-0})) -lt "$KIT_NOTICE_SUPPRESS_SECONDS" ]; then
      kit_log "notice[suppressed] ${message}"
      return 0
    fi
    kit_write_json "$hist" "$(kit_read_json "$hist" '{}' | jq -c --arg m "$message" --argjson t "$now" '.[$m] = $t')"
  fi
  jq -nc --arg level "$level" --arg message "$message" --arg at "$(kit_iso_now)" \
    '{level: $level, message: $message, at: $at}' >>"${KIT_STATE}/notices.jsonl"
  kit_log "notice[${level}] ${message}"
}

# kit_take_notices: 溜まった通知を JSON 配列で出し、キューを空にする。
# 先に rename してから読むので、取り出し中の追記は次回分として残る。
kit_take_notices() {
  local f="${KIT_STATE}/notices.jsonl" taking
  if [ ! -f "$f" ]; then printf '[]'; return 0; fi
  taking="${f}.taking.$$"
  mv "$f" "$taking" 2>/dev/null || { printf '[]'; return 0; }
  jq -sc 'unique_by(.message) | sort_by(.at)' "$taking" 2>/dev/null || printf '[]'
  rm -f "$taking"
}

# kit_with_timeout <seconds> <cmd...>: macOS 標準の perl で alarm をかけて exec する
kit_with_timeout() {
  local secs="$1"
  shift
  perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"
}

# kit_lock: mkdir の成否で排他する。KIT_LOCK_STALE_SECONDS より古いロックは異常終了の残骸とみなして消す
kit_lock() {
  local lock mtime
  kit_init_state
  lock="${KIT_STATE}/lock"
  if mkdir "$lock" 2>/dev/null; then return 0; fi
  mtime="$(stat -f %m "$lock" 2>/dev/null || echo 0)"
  if [ $(($(kit_now) - mtime)) -ge "$KIT_LOCK_STALE_SECONDS" ]; then
    rmdir "$lock" 2>/dev/null
    mkdir "$lock" 2>/dev/null && return 0
  fi
  return 1
}
kit_unlock() { rmdir "${KIT_STATE}/lock" 2>/dev/null || true; }
```

`claude/plugins/kit/bin/kit`:

```bash
#!/usr/bin/env bash
# kit: Claude Code のスキル・プラグインを複数マシンで同期する CLI。
# 設計書: docs/superpowers/specs/2026-10-22-claude-kit-design.md
set -uo pipefail

KIT_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${KIT_BIN_DIR}/../lib/common.sh"
for f in "${KIT_BIN_DIR}"/../lib/*.sh; do
  case "$f" in */common.sh) ;; *) . "$f" ;; esac
done

kit_usage() {
  cat <<'EOF'
usage: kit <command>
  sync [--dry-run] [--force] [--retry <section/key>]   manifest とこのマシンを同期する
  status                                               同期の状態と次の同期の計画を表示する
  hook session-start|session-end                       Claude Code のフック用
EOF
}

case "${1:-}" in
  sync) shift; kit_sync "$@" ;;
  status) kit_status ;;
  hook) shift; kit_hook "$@"; exit 0 ;;
  -h | --help | help) kit_usage ;;
  *) kit_usage >&2; exit 2 ;;
esac
```

- [ ] **Step 5: テストが通ることを確かめる**

Run: `chmod +x claude/plugins/kit/bin/kit && claude/plugins/kit/tests/run.sh test_common.sh test_manifests.sh`
Expected: `ALL PASSED`（`claude plugin validate` は author 未記入などの warning を出してもよいが、終了コードは 0）

- [ ] **Step 6: コミット**

```bash
git add claude/.claude-plugin claude/plugins/kit
git commit -m "feat(kit): プラグインの骨格と共通部品、テスト基盤を追加

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: 完全に切り離したプロセスの起動

**Files:**
- Create: `claude/plugins/kit/lib/detach.sh`
- Test: `claude/plugins/kit/tests/test_detach.sh`

**Interfaces:**
- Consumes: `kit_init_state`、`KIT_STATE`（Task 1）
- Produces: `kit_detach <cmd...>` — fork と setsid をして cmd を実行し、呼び出し元にはすぐ戻る。子の標準出力と標準エラーは `${KIT_STATE}/sync.log` に追記される。

- [ ] **Step 1: 失敗するテストを書く**

`claude/plugins/kit/tests/test_detach.sh`:

```bash
. "$(dirname "$0")/helpers.sh"
t_tmp
export HOME="${T_TMP}/home" KIT_STATE_DIR="${T_TMP}/state" KIT_DOTFILES="${T_TMP}/dot"
. "${KIT_PLUGIN_DIR}/lib/common.sh"
. "${KIT_PLUGIN_DIR}/lib/detach.sh"

# すぐ戻る
start="$(t_ms)"
kit_detach /bin/sh -c "sleep 2; echo done >'${T_TMP}/out1'"
end="$(t_ms)"
assert_lt "$((end - start))" "500" "kit_detach はすぐ戻る"

# 親のプロセスグループごと SIGTERM を送っても、子は動き続ける（Claude Code の終了を模す）
perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- /bin/bash -c "
  export HOME='${T_TMP}/home' KIT_STATE_DIR='${T_TMP}/state' KIT_DOTFILES='${T_TMP}/dot'
  . '${KIT_PLUGIN_DIR}/lib/common.sh'
  . '${KIT_PLUGIN_DIR}/lib/detach.sh'
  kit_detach /bin/sh -c \"sleep 2; echo survived >'${T_TMP}/out2'\"
  echo \$\$ >'${T_TMP}/parent.pid'
  sleep 30
" &
i=0
while [ ! -s "${T_TMP}/parent.pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM -- "-$(cat "${T_TMP}/parent.pid")" 2>/dev/null
sleep 3
assert_eq "$(cat "${T_TMP}/out2" 2>/dev/null)" "survived" "親のプロセスグループが終了しても子は生き残る"
assert_eq "$(cat "${T_TMP}/out1" 2>/dev/null)" "done" "切り離した処理は最後まで動く"

# 子の出力は sync.log に入る
kit_detach /bin/sh -c "echo from-child"
sleep 1
assert_contains "$(cat "${KIT_STATE}/sync.log" 2>/dev/null)" "from-child" "子の出力は sync.log に追記される"

t_done
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_detach.sh`
Expected: FAIL（`lib/detach.sh: No such file or directory`、`kit_detach: command not found`）

- [ ] **Step 3: 実装する**

`claude/plugins/kit/lib/detach.sh`:

```bash
# 完全に切り離したプロセスの起動（設計書 §7.1）。
# SessionEnd フックの持ち時間は 1.5 秒しかなく、Claude Code の終了とともにフックのプロセスグループが
# 終了させられる可能性がある。そこで fork してから setsid し、Claude Code のセッションとプロセスグループの
# 両方から外れた子で処理を続ける。macOS には setsid コマンドがないので perl を使う。

# kit_detach <cmd...>: 呼び出し元はすぐ戻る。子の出力は sync.log に追記する
kit_detach() {
  kit_init_state
  KIT_DETACH_LOG="${KIT_STATE}/sync.log" perl -MPOSIX -e '
    my $pid = fork;
    exit 1 unless defined $pid;
    exit 0 if $pid;
    POSIX::setsid();
    open STDIN, "<", "/dev/null";
    open STDOUT, ">>", $ENV{KIT_DETACH_LOG};
    open STDERR, ">&", \*STDOUT;
    exec @ARGV or exit 127;
  ' -- "$@"
}
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_detach.sh`
Expected: `ALL PASSED`

- [ ] **Step 5: コミット**

```bash
git add claude/plugins/kit/lib/detach.sh claude/plugins/kit/tests/test_detach.sh
git commit -m "feat(kit): フックから完全に切り離して処理を起動する kit_detach を追加

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: ローカルの実状態 L の読み取りと偽 CLI

**Files:**
- Create: `claude/plugins/kit/lib/local_state.sh`
- Create: `claude/plugins/kit/tests/fakes/claude`
- Create: `claude/plugins/kit/tests/fakes/npx`
- Test: `claude/plugins/kit/tests/test_local_state.sh`

**Interfaces:**
- Consumes: `kit_read_json`（Task 1）
- Produces: `kit_local_state` — `{"marketplaces":{name: {source,...}}, "plugins":{id: bool}, "skills":{name: {"source": "..."}}}` を 1 行で出す。読み取りに失敗したら終了コード 1。
- Produces（偽 CLI。状態は `$FAKE_DIR/claude.json` と `$HOME/.agents/.skill-lock.json`、呼び出しは `$FAKE_DIR/calls.log` に 1 行ずつ記録）:
  - `claude.json` の形: `{"plugins":[{"id","enabled","scope"?}], "marketplaces":[{"name","source","repo"|"path"...}], "fail":[id か source], "command_source":[id]}`
  - 環境変数 `FAKE_BROKEN=1` で `claude` が常に失敗、`FAKE_SLOW=<秒>` で `claude` が毎回その秒数待つ、`FAKE_MKT_NAME` で `marketplace add` したマーケットプレイスの名前を指定（省略時はソースの最後の `/` 以降）
  - `npx` の失敗させたいスキル名は `$FAKE_DIR/npx-fail` に 1 行 1 件

- [ ] **Step 1: 偽 CLI を書く**

`claude/plugins/kit/tests/fakes/claude`:

```bash
#!/usr/bin/env bash
# テスト用の偽 claude（plugin サブコマンドの一部だけ）。
# 状態は $FAKE_DIR/claude.json、呼び出しは $FAKE_DIR/calls.log に記録する。
set -uo pipefail
state="${FAKE_DIR}/claude.json"
echo "claude $*" >>"${FAKE_DIR}/calls.log"
[ -n "${FAKE_SLOW:-}" ] && sleep "$FAKE_SLOW"
[ "${FAKE_BROKEN:-}" = 1 ] && { echo "fake failure" >&2; exit 1; }
upd() { local tmp; tmp="$(mktemp)"; jq "$@" "$state" >"$tmp" && mv "$tmp" "$state"; }
in_list() { jq -e --arg x "$2" --arg l "$1" '.[$l] | index($x) != null' "$state" >/dev/null; }

[ "${1:-}" = plugin ] || exit 2
shift
case "${1:-} ${2:-}" in
  "list --json")
    jq -c '[.plugins[] | {id, scope: (.scope // "user"), enabled, version: "1.0.0"}]' "$state" ;;
  "marketplace list")
    jq -c '[.marketplaces[] | . + {installLocation: "/tmp/fake"}]' "$state" ;;
  "marketplace add")
    src="$3"
    in_list fail "$src" && { echo "fake: add failed" >&2; exit 1; }
    name="${FAKE_MKT_NAME:-${src##*/}}"
    upd --arg n "$name" --arg r "$src" '.marketplaces |= (map(select(.name != $n)) + [{name: $n, source: "github", repo: $r}])' ;;
  "marketplace remove")
    upd --arg n "$3" '.marketplaces |= map(select(.name != $n))' ;;
  install*)
    id="$2"
    if in_list command_source "$id"; then
      printf '{"command":"install","outcome":"failed","plugin":"%s","shownCommand":{"command":"make","sha256":"abc"}}\n' "$id"
      exit 1
    fi
    if in_list fail "$id"; then
      printf '{"command":"install","outcome":"failed","plugin":"%s","message":"boom"}\n' "$id"
      exit 1
    fi
    upd --arg id "$id" '.plugins |= (map(select(.id != $id)) + [{id: $id, enabled: true}])'
    printf '{"command":"install","outcome":"installed","plugin":"%s"}\n' "$id" ;;
  uninstall*) upd --arg id "$2" '.plugins |= map(select(.id != $id))' ;;
  enable*) upd --arg id "$2" '.plugins |= map(if .id == $id then .enabled = true else . end)' ;;
  disable*) upd --arg id "$2" '.plugins |= map(if .id == $id then .enabled = false else . end)' ;;
  *) echo "fake claude: 未対応: plugin $*" >&2; exit 2 ;;
esac
```

`claude/plugins/kit/tests/fakes/npx`:

```bash
#!/usr/bin/env bash
# テスト用の偽 npx（skills CLI の add と remove だけ）。状態は $HOME/.agents/.skill-lock.json。
set -uo pipefail
echo "npx $*" >>"${FAKE_DIR}/calls.log"
lock="${HOME}/.agents/.skill-lock.json"
mkdir -p "$(dirname "$lock")"
[ -f "$lock" ] || echo '{"version":3,"skills":{}}' >"$lock"
upd() { local tmp; tmp="$(mktemp)"; jq "$@" "$lock" >"$tmp" && mv "$tmp" "$lock"; }
[ "${1:-}" = "--yes" ] && shift
[ "${1:-}" = skills ] || exit 2
shift
case "${1:-}" in
  add)
    src="$2"; name=""
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in -s) name="$2"; shift ;; esac
      shift
    done
    if [ -f "${FAKE_DIR}/npx-fail" ] && grep -qx -- "$name" "${FAKE_DIR}/npx-fail"; then exit 1; fi
    upd --arg n "$name" --arg s "$src" '.skills[$n] = {source: $s, sourceType: "github"}' ;;
  remove) upd --arg n "$2" 'del(.skills[$n])' ;;
  *) exit 2 ;;
esac
```

- [ ] **Step 2: 失敗するテストを書く**

`claude/plugins/kit/tests/test_local_state.sh`:

```bash
. "$(dirname "$0")/helpers.sh"
t_tmp
t_machine A
. "${KIT_PLUGIN_DIR}/lib/common.sh"
. "${KIT_PLUGIN_DIR}/lib/local_state.sh"

fake_set '.marketplaces = [
    {"name":"official","source":"github","repo":"x/official"},
    {"name":"agents","source":"github","repo":"w/agents"},
    {"name":"dotfiles","source":"directory","path":"/d/claude"},
    {"name":"mylocal","source":"directory","path":"/m"}]
  | .plugins = [
    {"id":"a@official","enabled":true},
    {"id":"b@agents","enabled":false},
    {"id":"kit@dotfiles","enabled":true},
    {"id":"x@mylocal","enabled":true},
    {"id":"p@official","enabled":true,"scope":"project"}]'
mkdir -p "${HOME}/.agents"
echo '{"version":3,"skills":{"find-skills":{"source":"vercel-labs/skills"},"s1":{"source":"o/r","sourceType":"github"}}}' >"${HOME}/.agents/.skill-lock.json"

assert_json_eq "$(kit_local_state)" '{
  "marketplaces":{"official":{"source":"github","repo":"x/official"},"agents":{"source":"github","repo":"w/agents"}},
  "plugins":{"a@official":true,"b@agents":false},
  "skills":{"s1":{"source":"o/r"}}}' "除外対象（dotfiles、ローカルパス、プロジェクトスコープ、find-skills）を除いて読む"

rm "${HOME}/.agents/.skill-lock.json"
assert_json_eq "$(kit_local_state | jq -c .skills)" '{}' "lock ファイルがなければスキルは空"

echo '{' >"${HOME}/.agents/.skill-lock.json"
kit_local_state >/dev/null; rc=$?
assert_eq "$rc" "1" "lock ファイルが壊れていたら失敗する"
rm "${HOME}/.agents/.skill-lock.json"

(export FAKE_BROKEN=1; kit_local_state >/dev/null); rc=$?
assert_eq "$rc" "1" "claude が失敗したら失敗する（空として扱わない。Review Focus 1）"

t_done
```

- [ ] **Step 3: テストが失敗することを確かめる**

Run: `chmod +x claude/plugins/kit/tests/fakes/* && claude/plugins/kit/tests/run.sh test_local_state.sh`
Expected: FAIL（`kit_local_state: command not found`）

- [ ] **Step 4: 実装する**

`claude/plugins/kit/lib/local_state.sh`:

```bash
# このマシンの実状態 L を読む（設計書 §5）。

# kit_local_state: {marketplaces, plugins, skills} を 1 行の JSON で出す。
# 除外: マーケットプレイス dotfiles、ソースがローカルパス（directory / file）のマーケットプレイスとそのプラグイン、
#       プロジェクトスコープのプラグイン、スキル find-skills。
# どれかの読み取りに失敗したら 1 を返す。空として扱うと、全項目の削除が他のマシンに広がってしまうため。
kit_local_state() {
  local mkts plugins lock skills
  mkts="$(claude plugin marketplace list --json </dev/null 2>/dev/null)" || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$mkts" || return 1
  plugins="$(claude plugin list --json </dev/null 2>/dev/null)" || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$plugins" || return 1
  lock="${HOME}/.agents/.skill-lock.json"
  if [ -f "$lock" ]; then
    skills="$(jq -c '.skills // {}' "$lock" 2>/dev/null)" || return 1
  else
    skills='{}'
  fi
  jq -nc --argjson m "$mkts" --argjson p "$plugins" --argjson s "$skills" '
    [$m[] | select(.name == "dotfiles" or .source == "directory" or .source == "file") | .name] as $excluded
    | {
        marketplaces: ([$m[] | select(.name | IN($excluded[]) | not)
                        | {key: .name, value: del(.name, .installLocation)}] | from_entries),
        plugins: ([$p[] | select(.scope == "user")
                   | select(.id | split("@") | last | IN($excluded[]) | not)
                   | {key: .id, value: .enabled}] | from_entries),
        skills: ([$s | to_entries[] | select(.key != "find-skills")
                  | {key: .key, value: {source: .value.source}}] | from_entries)
      }'
}
```

- [ ] **Step 5: テストが通ることを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_local_state.sh`
Expected: `ALL PASSED`

- [ ] **Step 6: コミット**

```bash
git add claude/plugins/kit/lib/local_state.sh claude/plugins/kit/tests/fakes claude/plugins/kit/tests/test_local_state.sh
git commit -m "feat(kit): このマシンのプラグイン・スキルの実状態を読む kit_local_state を追加

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: 3 者比較と base の更新規則

**Files:**
- Create: `claude/plugins/kit/lib/merge.jq`
- Create: `claude/plugins/kit/lib/merge.sh`
- Test: `claude/plugins/kit/tests/test_merge.sh`

**Interfaces:**
- Consumes: `KIT_LIB_DIR`（Task 1）
- Produces:
  - `kit_merge3 <input-json>` — 入力 `{L, B, R, H, W, failures: {"<section>/<key>": 回数}, max_failures}`。出力 `{M: manifest, ops: [{section, key, op: "add"|"remove"|"change", from, to}], skipped: [{section, key}], conflicts: [{section, key, local, remote, chosen}], local_changes: [{section, key}]}`。L・B は管理セクション 3 つだけを持つ。R・H・W は manifest 全体。
  - `kit_base_update <input-json>` — 入力 `{M, L2, R2, B}`。出力は新しい base（管理セクション 3 つ）。

- [ ] **Step 1: 失敗するテストを書く**

`claude/plugins/kit/tests/test_merge.sh`:

```bash
. "$(dirname "$0")/helpers.sh"
t_tmp
export HOME="${T_TMP}/home" KIT_STATE_DIR="${T_TMP}/state" KIT_DOTFILES="${T_TMP}/dot"
. "${KIT_PLUGIN_DIR}/lib/common.sh"
. "${KIT_PLUGIN_DIR}/lib/merge.sh"

# m3 <L> <B> <R> [failures]: H と W は空、上限 3 で 3 者比較する
m3() {
  local f="${4:-}"
  [ -n "$f" ] || f='{}'
  kit_merge3 "$(jq -nc --argjson L "$1" --argjson B "$2" --argjson R "$3" --argjson f "$f" \
    '{L: $L, B: $B, R: $R, H: {}, W: {}, failures: $f, max_failures: 3}')"
}
p() { printf '{"plugins":%s}' "$1"; }
# check <説明> <L> <B> <R> <期待する M.plugins> <期待する ops（"op key to" の配列）> [failures]
check() {
  local r
  r="$(m3 "$(p "$2")" "$(p "$3")" "$(p "$4")" "${7:-}")"
  assert_json_eq "$(jq -c .M.plugins <<<"$r")" "$5" "$1: M"
  assert_json_eq "$(jq -c '[.ops[] | "\(.op) \(.key) \(.to | tojson)"]' <<<"$r")" "$6" "$1: ops"
}

# 設計書 §7.3 の表
check "変更なし"                 '{"a":true}' '{"a":true}' '{"a":true}' '{"a":true}' '[]'
check "このマシンで追加"         '{"a":true,"b":true}' '{"a":true}' '{"a":true}' '{"a":true,"b":true}' '[]'
check "このマシンで削除"         '{}' '{"a":true}' '{"a":true}' '{}' '[]'
check "他のマシンで追加"         '{}' '{}' '{"a":true}' '{"a":true}' '["add a true"]'
check "他のマシンで削除"         '{"a":true}' '{"a":true}' '{}' '{}' '["remove a null"]'
check "他のマシンで無効化"       '{"a":true}' '{"a":true}' '{"a":false}' '{"a":false}' '["change a false"]'
check "両方で同じ変更"           '{"a":false}' '{"a":true}' '{"a":false}' '{"a":false}' '[]'
check "衝突: 削除と無効化"       '{}' '{"a":true}' '{"a":false}' '{"a":false}' '["add a false"]'
check "衝突: true と false"      '{"a":true}' '{}' '{"a":false}' '{"a":true}' '[]'
check "初回同期は和集合"         '{"a":true}' '{}' '{"b":true}' '{"a":true,"b":true}' '["add b true"]'
check "false を「なし」と区別する" '{"a":false}' '{"a":false}' '{"a":false}' '{"a":false}' '[]'
check "失敗が上限の項目は操作しない" '{}' '{}' '{"a":true}' '{"a":true}' '[]' '{"plugins/a":3}'

r="$(m3 "$(p '{}')" "$(p '{}')" "$(p '{"a":true}')" '{"plugins/a":3}')"
assert_json_eq "$(jq -c .skipped <<<"$r")" '[{"section":"plugins","key":"a"}]' "上限の項目は skipped に入る"
r="$(m3 "$(p '{}')" "$(p '{"a":true}')" "$(p '{"a":false}')")"
assert_json_eq "$(jq -c .conflicts <<<"$r")" '[{"section":"plugins","key":"a","local":null,"remote":false,"chosen":false}]' "衝突を記録する"
r="$(m3 "$(p '{"a":true,"b":true}')" "$(p '{"a":true}')" "$(p '{"a":true}')")"
assert_json_eq "$(jq -c .local_changes <<<"$r")" '[{"section":"plugins","key":"b"}]' "このマシンでの変更を記録する"

# マーケットプレイスとスキル
r="$(m3 '{"marketplaces":{"m":{"source":"github","repo":"x/one"}}}' '{}' '{"marketplaces":{"m":{"source":"github","repo":"x/two"}}}')"
assert_json_eq "$(jq -c .M.marketplaces.m <<<"$r")" '{"source":"github","repo":"x/two"}' "マーケットプレイスの衝突は R を採る"
assert_eq "$(jq -r '.ops[0].op' <<<"$r")" "change" "マーケットプレイスのソース変更は change"
r="$(m3 '{"skills":{}}' '{}' '{"skills":{"s1":{"source":"o/r"}}}')"
assert_json_eq "$(jq -c .ops <<<"$r")" '[{"section":"skills","key":"s1","op":"add","from":null,"to":{"source":"o/r"}}]' "スキルの追加"
assert_json_eq "$(jq -c '.M | keys' <<<"$r")" '["discovery","marketplaces","plugins","skills","version"]' "M は manifest の全キーを持つ"

# discovery のマージ（設計書 §7.4）: (R ∪ (W − H)) − (H − W)
dm() {
  kit_merge3 "$(jq -nc --argjson H "$1" --argjson W "$2" --argjson R "$3" \
    '{L: {}, B: {}, R: $R, H: $H, W: $W, failures: {}, max_failures: 3}')" | jq -c .M.discovery
}
assert_json_eq "$(dm '{"discovery":{"watch":["x","y"],"dismissed":[]}}' \
                     '{"discovery":{"watch":["x"],"dismissed":[{"id":"p1"}]}}' \
                     '{"discovery":{"watch":["x","y","z"],"dismissed":[{"id":"p2"}]}}')" \
  '{"watch":["x","z"],"dismissed":[{"id":"p1"},{"id":"p2"}]}' "W で足したものは足し、W で消したものは消し、他は R に従う"
assert_json_eq "$(dm '{"discovery":{"watch":["x"]}}' '{"discovery":{"watch":["x","y"]}}' '{"discovery":{"watch":["x"]}}')" \
  '{"watch":["x","y"],"dismissed":[]}' "オフライン（R = H）なら W のまま"
assert_json_eq "$(dm '{}' '{"discovery":{"dismissed":[{"id":"p1","reason":"新"}]}}' '{"discovery":{"dismissed":[{"id":"p1","reason":"旧"}]}}')" \
  '{"watch":[],"dismissed":[{"id":"p1","reason":"新"}]}' "同じ id は W の内容を採る"

# base の更新規則（設計書 §7.5 手順 9）
bu() {
  kit_base_update "$(jq -nc --argjson M "$1" --argjson L2 "$2" --argjson R2 "$3" --argjson B "$4" \
    '{M: $M, L2: $L2, R2: $R2, B: $B}')" | jq -c .plugins
}
assert_json_eq "$(bu "$(p '{"a":true}')" "$(p '{"a":true}')" "$(p '{"a":true}')" '{}')" '{"a":true}' "push できたら合意する"
assert_json_eq "$(bu "$(p '{"a":true}')" "$(p '{"a":true}')" '{}' '{}')" '{}' "push できなければ合意しない"
assert_json_eq "$(bu "$(p '{"a":true}')" '{}' "$(p '{"a":true}')" '{}')" '{}' "反映に失敗したら合意しない"
assert_json_eq "$(bu '{}' '{}' '{}' "$(p '{"a":true}')")" '{}' "削除も合意する"
assert_json_eq "$(bu "$(p '{"a":false}')" "$(p '{"a":false}')" "$(p '{"a":false}')" '{}')" '{"a":false}' "false も合意する"

t_done
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_merge.sh`
Expected: FAIL（`lib/merge.sh: No such file or directory`）

- [ ] **Step 3: 実装する**

`claude/plugins/kit/lib/merge.jq`:

```jq
# kit の 3 者比較（設計書 §7.3、§7.4）と base の更新規則（§7.5 手順 9）。
# 値の有無を区別するため、各項目の値を {v: 値} で包み、ないことを null で表す
# （プラグインの false を「なし」と取り違えないため。`//` 演算子は false を「なし」扱いするので使わない）。

def kit_sections: ["marketplaces", "plugins", "skills"];

def kit_wrap($obj; $k): if ($obj // {}) | has($k) then {v: $obj[$k]} else null end;

# 衝突時は「残す・有効にする」側を採る。両方が値を持ち内容が違えば R
def kit_resolve($section; $l; $r):
  if $l == null then $r
  elif $r == null then $l
  elif $section == "plugins" then (if ($l.v == true or $r.v == true) then {v: true} else $r end)
  else $r end;

def kit_merge_section($section; $L; $B; $R; $failures):
  ([($L // {}), ($B // {}), ($R // {})] | map(keys) | add | unique) as $keys
  | [ $keys[] as $k
      | kit_wrap($L; $k) as $l | kit_wrap($B; $k) as $b | kit_wrap($R; $k) as $r
      | (if $l == $b and $r == $b then {kind: "same", m: $r}
         elif $l != $b and $r == $b then {kind: "local", m: $l}
         elif $l == $b and $r != $b then {kind: "remote", m: $r}
         elif $l == $r then {kind: "both", m: $l}
         else {kind: "conflict", m: kit_resolve($section; $l; $r)} end) as $d
      | {section: $section, key: $k, kind: $d.kind, l: $l, r: $r, m: $d.m,
         failures: (($failures // {})["\($section)/\($k)"] // 0)} ];

def kit_op($i): if $i.l == null then "add" elif $i.m == null then "remove" else "change" end;

# 文字列の集合: (R ∪ (W − H)) − (H − W)
def kit_set_merge($h; $w; $r): (($r + ($w - $h)) - ($h - $w)) | unique;

# id をキーとする集合。W で足した要素は W の内容を採る
def kit_by_id_merge($h; $w; $r):
  ([$h[].id]) as $hi | ([$w[].id]) as $wi
  | ([$w[] | select(.id | IN($hi[]) | not)]) as $added
  | ([$hi[] | select(IN($wi[]) | not)]) as $removed
  | ([$added[].id]) as $ai
  | ([$r[] | select(.id | IN($ai[]) | not)] + $added)
  | map(select(.id | IN($removed[]) | not))
  | sort_by(.id);

def kit_discovery_merge($H; $W; $R):
  { watch: kit_set_merge(($H.discovery.watch // []); ($W.discovery.watch // []); ($R.discovery.watch // [])),
    dismissed: kit_by_id_merge(($H.discovery.dismissed // []); ($W.discovery.dismissed // []); ($R.discovery.dismissed // [])) };

# 入力 {L, B, R, H, W, failures, max_failures}
def merge3:
  . as $in
  | ([kit_sections[] as $s | kit_merge_section($s; $in.L[$s]; $in.B[$s]; $in.R[$s]; $in.failures)] | add) as $items
  | { M: ({version: 1, discovery: kit_discovery_merge($in.H; $in.W; $in.R)}
          + ([kit_sections[] as $s
              | {key: $s, value: ([$items[] | select(.section == $s and .m != null) | {key, value: .m.v}] | from_entries)}]
             | from_entries)),
      ops: [$items[] | select(.m != .l and .failures < $in.max_failures)
            | {section, key, op: kit_op(.), from: .l.v, to: .m.v}],
      skipped: [$items[] | select(.m != .l and .failures >= $in.max_failures) | {section, key}],
      conflicts: [$items[] | select(.kind == "conflict") | {section, key, local: .l.v, remote: .r.v, chosen: .m.v}],
      local_changes: [$items[] | select(.kind == "local") | {section, key}] };

# 入力 {M, L2, R2, B}。反映後のローカル L2 と push 後のリモート R2 がどちらも M と一致する項目だけ M の値にし、
# それ以外は前の B の値を残す（B は「ローカルとリモートの両方で合意できた値」だけを表す）
def base_update:
  . as $in
  | [kit_sections[] as $s
     | ([($in.M[$s] // {}), ($in.L2[$s] // {}), ($in.R2[$s] // {}), ($in.B[$s] // {})] | map(keys) | add | unique) as $keys
     | {key: $s, value: ([$keys[] as $k
          | kit_wrap($in.M[$s]; $k) as $m
          | (if kit_wrap($in.L2[$s]; $k) == $m and kit_wrap($in.R2[$s]; $k) == $m then $m else kit_wrap($in.B[$s]; $k) end) as $nb
          | select($nb != null) | {key: $k, value: $nb.v}] | from_entries)}]
  | from_entries;
```

`claude/plugins/kit/lib/merge.sh`:

```bash
# 3 者比較と base の更新（実体は lib/merge.jq）。入力は 1 つの JSON。

kit_merge3() { jq -c -L "$KIT_LIB_DIR" 'include "merge"; merge3' <<<"$1"; }
kit_base_update() { jq -c -L "$KIT_LIB_DIR" 'include "merge"; base_update' <<<"$1"; }
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_merge.sh`
Expected: `ALL PASSED`

- [ ] **Step 5: コミット**

```bash
git add claude/plugins/kit/lib/merge.jq claude/plugins/kit/lib/merge.sh claude/plugins/kit/tests/test_merge.sh
git commit -m "feat(kit): manifest の 3 者比較と base の更新規則を追加

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: このマシンへの操作

**Files:**
- Create: `claude/plugins/kit/lib/apply.sh`
- Test: `claude/plugins/kit/tests/test_apply.sh`

**Interfaces:**
- Consumes: `kit_require`（Task 1）、`kit_merge3` の `ops` の形（Task 4）
- Produces: `kit_apply <ops-json> <M-json>` — ops を「マーケットプレイスの追加・変更 → プラグイン → スキル → マーケットプレイスの削除」の順に実行し、結果の配列 `[{section, key, op, status: "ok"|"failed"|"needs_approval"|"deferred", message}]` を 1 行で出す。

- [ ] **Step 1: 失敗するテストを書く**

`claude/plugins/kit/tests/test_apply.sh`:

```bash
. "$(dirname "$0")/helpers.sh"
t_tmp
t_machine A
. "${KIT_PLUGIN_DIR}/lib/common.sh"
. "${KIT_PLUGIN_DIR}/lib/apply.sh"
st() { jq -r --arg k "$1" '.[] | select(.key == $k) | .status' <<<"$res"; }

fake_set '.marketplaces = [{"name":"old","source":"github","repo":"x/old"}]
  | .plugins = [{"id":"c@official","enabled":true},{"id":"d@official","enabled":true}]
  | .fail = ["f@official"] | .command_source = ["g@official"]'
M='{"plugins":{"a@official":false,"x@old":true},"skills":{}}'
ops='[
  {"section":"marketplaces","key":"old","op":"remove","from":{"source":"github","repo":"x/old"},"to":null},
  {"section":"skills","key":"s1","op":"add","from":null,"to":{"source":"o/r"}},
  {"section":"plugins","key":"a@official","op":"add","from":null,"to":false},
  {"section":"marketplaces","key":"agents","op":"add","from":null,"to":{"source":"github","repo":"w/agents"}},
  {"section":"plugins","key":"c@official","op":"change","from":true,"to":false},
  {"section":"plugins","key":"d@official","op":"remove","from":true,"to":null},
  {"section":"plugins","key":"f@official","op":"add","from":null,"to":true},
  {"section":"plugins","key":"g@official","op":"add","from":null,"to":true}]'
res="$(kit_apply "$ops" "$M")"

assert_eq "$(jq length <<<"$res")" "8" "全部の操作に結果がある"
assert_eq "$(st agents)" "ok" "マーケットプレイスの追加"
assert_eq "$(st a@official)" "ok" "false で追加"
assert_eq "$(st c@official)" "ok" "無効化"
assert_eq "$(st d@official)" "ok" "削除"
assert_eq "$(st f@official)" "failed" "失敗"
assert_eq "$(jq -r '.[] | select(.key == "f@official") | .message' <<<"$res")" "boom" "失敗の理由を持つ"
assert_eq "$(st g@official)" "needs_approval" "コマンドを実行するプラグインは承認待ち"
assert_eq "$(st s1)" "ok" "スキルの追加"
assert_eq "$(st old)" "deferred" "プラグインが manifest に残るマーケットプレイスは削除を保留する"

calls="$(fake_calls)"
assert_eq "$(sed -n 1p <<<"$calls")" "claude plugin marketplace add w/agents --scope user" "マーケットプレイスの追加が最初"
assert_contains "$calls" "claude plugin install a@official -s user --json" "インストール"
assert_contains "$calls" "claude plugin disable a@official -s user" "false ならインストール後に無効化"
assert_contains "$calls" "claude plugin disable c@official -s user" "change false は disable"
assert_contains "$calls" "claude plugin uninstall d@official -s user" "remove は uninstall"
assert_eq "$(tail -n 1 <<<"$calls")" "npx --yes skills add o/r -s s1 -g -y -a claude-code" "スキルはプラグインの後"
assert_not_contains "$calls" "marketplace remove" "保留したマーケットプレイスは削除しない"
assert_eq "$(jq -r '.skills.s1.source' "${HOME}/.agents/.skill-lock.json")" "o/r" "スキルが入る"

: >"${FAKE_DIR}/calls.log"
res="$(kit_apply '[
  {"section":"marketplaces","key":"old","op":"remove","from":{"source":"github","repo":"x/old"},"to":null},
  {"section":"skills","key":"s1","op":"change","from":{"source":"o/r"},"to":{"source":"o/r2"}}]' '{"plugins":{}}')"
assert_eq "$(st old)" "ok" "プラグインが残っていなければ削除する"
assert_eq "$(fake_calls)" "$(printf '%s\n' \
  "npx --yes skills remove s1 -g -y" \
  "npx --yes skills add o/r2 -s s1 -g -y -a claude-code" \
  "claude plugin marketplace remove old --scope user")" "スキルの change は削除してから追加、マーケットプレイスの削除は最後"

assert_eq "$(kit_apply '[]' '{}')" "[]" "操作がなければ空の配列"

t_done
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_apply.sh`
Expected: FAIL（`kit_apply: command not found`）

- [ ] **Step 3: 実装する**

`claude/plugins/kit/lib/apply.sh`:

```bash
# このマシンへの操作（設計書 §7.6）。settings.json は直接書き換えず、claude / npx の CLI で操作する。

# kit_apply_result <section> <key> <op> <status> <message>
kit_apply_result() {
  jq -nc --arg s "$1" --arg k "$2" --arg o "$3" --arg st "$4" --arg m "$5" \
    '{section: $s, key: $k, op: $o, status: $st, message: $m}'
}

# kit_mkt_add_arg <marketplace-value-json>: `claude plugin marketplace add` に渡すソース
kit_mkt_add_arg() {
  jq -r 'if .source == "github" then .repo elif (.source == "git" or .source == "url") then .url else "" end' <<<"$1"
}

kit_apply_marketplace() {  # <op-json> <M-json>
  local op="$1" m="$2" key kind arg out
  key="$(jq -r .key <<<"$op")"
  kind="$(jq -r .op <<<"$op")"
  if [ "$kind" = remove ]; then
    if jq -e --arg k "$key" '(.plugins // {}) | keys | any(endswith("@" + $k))' <<<"$m" >/dev/null; then
      kit_apply_result marketplaces "$key" remove deferred "このマーケットプレイスのプラグインが manifest に残っているため、削除を保留しました"
    elif out="$(claude plugin marketplace remove "$key" --scope user 2>&1)"; then
      kit_apply_result marketplaces "$key" remove ok ""
    else
      kit_apply_result marketplaces "$key" remove failed "$out"
    fi
    return 0
  fi
  arg="$(kit_mkt_add_arg "$(jq -c .to <<<"$op")")"
  if [ -z "$arg" ]; then
    kit_apply_result marketplaces "$key" "$kind" failed "対応していないソースです"
    return 0
  fi
  [ "$kind" = change ] && claude plugin marketplace remove "$key" --scope user >/dev/null 2>&1
  if out="$(claude plugin marketplace add "$arg" --scope user 2>&1)"; then
    kit_apply_result marketplaces "$key" "$kind" ok ""
  else
    kit_apply_result marketplaces "$key" "$kind" failed "$out"
  fi
}

kit_apply_plugin() {  # <op-json>
  local op="$1" key kind to out msg verb
  key="$(jq -r .key <<<"$op")"
  kind="$(jq -r .op <<<"$op")"
  to="$(jq -r .to <<<"$op")"
  case "$kind" in
    add)
      if ! out="$(claude plugin install "$key" -s user --json 2>/dev/null)"; then
        if jq -e '.shownCommand' <<<"$out" >/dev/null 2>&1; then
          kit_apply_result plugins "$key" add needs_approval "インストール時にコマンドを実行するプラグインです"
        else
          msg="$(jq -r '.message // empty' <<<"$out" 2>/dev/null)"
          kit_apply_result plugins "$key" add failed "${msg:-install failed}"
        fi
        return 0
      fi
      if [ "$to" = false ] && ! claude plugin disable "$key" -s user >/dev/null 2>&1; then
        kit_apply_result plugins "$key" add failed "インストール後の無効化に失敗しました"
        return 0
      fi
      kit_apply_result plugins "$key" add ok "" ;;
    remove)
      if out="$(claude plugin uninstall "$key" -s user 2>&1)"; then
        kit_apply_result plugins "$key" remove ok ""
      else
        kit_apply_result plugins "$key" remove failed "$out"
      fi ;;
    change)
      verb=disable
      [ "$to" = true ] && verb=enable
      if out="$(claude plugin "$verb" "$key" -s user 2>&1)"; then
        kit_apply_result plugins "$key" change ok ""
      else
        kit_apply_result plugins "$key" change failed "$out"
      fi ;;
  esac
}

kit_apply_skill() {  # <op-json>
  local op="$1" key kind src out
  key="$(jq -r .key <<<"$op")"
  kind="$(jq -r .op <<<"$op")"
  src="$(jq -r '.to.source // empty' <<<"$op")"
  if ! kit_require npx; then
    kit_apply_result skills "$key" "$kind" deferred "npx が見つかりません"
    return 0
  fi
  if [ "$kind" != add ]; then
    if ! out="$(npx --yes skills remove "$key" -g -y 2>&1)"; then
      kit_apply_result skills "$key" "$kind" failed "$out"
      return 0
    fi
    if [ "$kind" = remove ]; then
      kit_apply_result skills "$key" remove ok ""
      return 0
    fi
  fi
  if out="$(npx --yes skills add "$src" -s "$key" -g -y -a claude-code 2>&1)"; then
    kit_apply_result skills "$key" "$kind" ok ""
  else
    kit_apply_result skills "$key" "$kind" failed "$out"
  fi
}

# kit_apply <ops-json> <M-json>: 決まった順序で実行し、結果の配列を 1 行で出す。
# 各操作の標準入力は /dev/null にする（CLI が操作リストを読み込んでしまわないように、リストは fd 3 で渡す）
kit_apply() {
  local ops="$1" m="$2" op
  while IFS= read -r op <&3; do
    case "$(jq -r .section <<<"$op")" in
      marketplaces) kit_apply_marketplace "$op" "$m" ;;
      plugins) kit_apply_plugin "$op" ;;
      skills) kit_apply_skill "$op" ;;
    esac </dev/null
  done 3< <(jq -c '[(.[] | select(.section == "marketplaces" and .op != "remove")),
                    (.[] | select(.section == "plugins")),
                    (.[] | select(.section == "skills")),
                    (.[] | select(.section == "marketplaces" and .op == "remove"))] | .[]' <<<"$ops") |
    jq -sc .
}
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_apply.sh`
Expected: `ALL PASSED`

- [ ] **Step 5: コミット**

```bash
git add claude/plugins/kit/lib/apply.sh claude/plugins/kit/tests/test_apply.sh
git commit -m "feat(kit): 他のマシンの変更をこのマシンに反映する kit_apply を追加

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: dotfiles への git 操作

**Files:**
- Create: `claude/plugins/kit/lib/git.sh`
- Test: `claude/plugins/kit/tests/test_git.sh`

**Interfaces:**
- Consumes: `KIT_DOTFILES`、`KIT_MANIFEST`、`KIT_MANIFEST_REL`、`KIT_BRANCH`、`KIT_REMOTE`、`KIT_EMPTY_MANIFEST`、`KIT_FETCH_TIMEOUT`、`KIT_PUSH_TIMEOUT`、`kit_with_timeout`（Task 1）
- Produces:
  - `kit_git <args...>`、`kit_git_remote_ref`（`origin/master` の形）
  - `kit_git_fetch` — 失敗で 1
  - `kit_git_show_manifest <rev>` — その版の manifest。なければ空の manifest
  - `kit_git_base_manifest` — HEAD と upstream の merge-base の manifest（upstream がなければ HEAD）
  - `kit_git_branch_ok` — master 上で作業途中でなければ 0
  - `kit_git_update` — 0 成功 / 1 未コミットの変更とぶつかった / 2 kit 以外のコミットで分岐している
  - `kit_git_commit_manifest` — manifest に変更があればそれだけをコミット
  - `kit_git_foreign_unpushed` — upstream にない kit 以外のコミットがあれば 0
  - `kit_git_push` — 失敗で 1

- [ ] **Step 1: 失敗するテストを書く**

`claude/plugins/kit/tests/test_git.sh`:

```bash
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
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_git.sh`
Expected: FAIL（`kit_git_branch_ok: command not found` など）

- [ ] **Step 3: 実装する**

`claude/plugins/kit/lib/git.sh`:

```bash
# dotfiles リポジトリへの git 操作（設計書 §7.5、§7.7）。対象は常に KIT_DOTFILES。

kit_git() { git -C "$KIT_DOTFILES" "$@"; }
kit_git_remote_ref() { printf '%s/%s' "$KIT_REMOTE" "$KIT_BRANCH"; }

# kit_git_fetch: オフラインやタイムアウトなら 1
kit_git_fetch() {
  kit_with_timeout "$KIT_FETCH_TIMEOUT" git -C "$KIT_DOTFILES" fetch -q "$KIT_REMOTE" "$KIT_BRANCH" </dev/null >/dev/null 2>&1
}

# kit_git_show_manifest <rev>: その版の manifest。なければ空の manifest
kit_git_show_manifest() {
  kit_git show "$1:${KIT_MANIFEST_REL}" 2>/dev/null || printf '%s' "$KIT_EMPTY_MANIFEST"
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
  if kit_git cat-file -e "HEAD:${KIT_MANIFEST_REL}" 2>/dev/null; then
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
  elif kit_git log --format=%s "${up}..HEAD" | grep -qv '^chore(kit):'; then
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
  kit_git log --format=%s "${up}..HEAD" | grep -qv '^chore(kit):'
}

kit_git_push() {
  kit_with_timeout "$KIT_PUSH_TIMEOUT" git -C "$KIT_DOTFILES" push -q "$KIT_REMOTE" "HEAD:${KIT_BRANCH}" </dev/null >/dev/null 2>&1
}
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_git.sh`
Expected: `ALL PASSED`

- [ ] **Step 5: コミット**

```bash
git add claude/plugins/kit/lib/git.sh claude/plugins/kit/tests/test_git.sh
git commit -m "feat(kit): dotfiles への git 操作（取り込み・manifest だけのコミット・push）を追加

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `kit sync` と `kit status`

**Files:**
- Create: `claude/plugins/kit/lib/sync.sh`
- Create: `claude/plugins/kit/lib/status.sh`
- Test: `claude/plugins/kit/tests/test_sync.sh`

**Interfaces:**
- Consumes: Task 1〜6 のすべて
- Produces:
  - `kit_sync [--dry-run] [--force] [--retry <section/key>]` — 終了コード 0 成功（何もしなかった場合を含む）/ 1 処理の失敗 / 2 使い方の誤り
  - `kit_status`
  - 状態ファイル: `base.json`（管理セクション 3 つ）、`sync.json`（`{"last_success": epoch, "failures": {"<section>/<key>": 回数}}`）
  - `sync.log` に残す決まった文字列: `sync: throttled`、`sync: another sync is running`、`sync: push rejected, retrying`、`sync: done`

- [ ] **Step 1: 失敗するテストを書く**

`claude/plugins/kit/tests/test_sync.sh`:

```bash
. "$(dirname "$0")/helpers.sh"

OFFICIAL='.marketplaces = [{"name":"official","source":"github","repo":"x/official"}]'
with_a() { on "$1" fake_set "${OFFICIAL} | .plugins = [{\"id\":\"a@official\",\"enabled\":true}]"; }
setup_ab_with_a() {
  t_remote; t_clone A; t_clone B
  with_a A
  on A kit sync
  on B kit sync
}
log_of() { cat "$(state_file "$1" sync.log)" 2>/dev/null; }

s_propagate_add() {
  t_remote; t_clone A; t_clone B
  with_a A
  on A kit sync
  assert_json_eq "$(remote_manifest | jq -c '{marketplaces, plugins}')" \
    '{"marketplaces":{"official":{"source":"github","repo":"x/official"}},"plugins":{"a@official":true}}' "A の追加がリモートに届く"
  assert_eq "$(git --git-dir="${T_TMP}/remote.git" log -1 --format=%s master)" "chore(kit): sync from $(hostname -s)" "kit のコミット"
  on B kit sync
  assert_contains "$(calls_of B)" "claude plugin marketplace add x/official --scope user" "B にマーケットプレイスが入る"
  assert_contains "$(calls_of B)" "claude plugin install a@official -s user --json" "B にプラグインが入る"
  assert_json_eq "$(manifest_of B | jq -c .plugins)" '{"a@official":true}' "B の manifest も同じ"
  assert_json_eq "$(jq -c .plugins "$(state_file B base.json)")" '{"a@official":true}' "B の base も合意する"
}
s_propagate_remove() {
  setup_ab_with_a
  on B fake_set '.plugins = []'
  on B kit sync
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{}' "B での削除がリモートに届く"
  on A kit sync
  assert_contains "$(calls_of A)" "claude plugin uninstall a@official -s user" "A からも削除される"
}
s_conflict() {
  setup_ab_with_a
  on A fake_set '.plugins[0].enabled = false'
  on A kit sync
  on B fake_set '.plugins = []'
  on B kit sync
  assert_contains "$(calls_of B)" "claude plugin disable a@official -s user" "衝突は残す側（false）を採って B に入れ直す"
  assert_contains "$(notices_of B)" "衝突" "衝突を通知する"
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":false}' "リモートは false のまま"
}
s_offline() {
  t_remote; t_clone A
  with_a A
  git -C "${T_TMP}/A/dotfiles" remote set-url origin "${T_TMP}/nowhere.git"
  on A kit sync
  assert_json_eq "$(manifest_of A | jq -c .plugins)" '{"a@official":true}' "オフラインでも manifest に書く"
  assert_eq "$(git -C "${T_TMP}/A/dotfiles" rev-list --count HEAD)" "1" "オフラインではコミットしない"
  assert_json_eq "$(jq -c .plugins "$(state_file A base.json)")" '{}' "push できていない変更は base に入れない"
  git -C "${T_TMP}/A/dotfiles" remote set-url origin "${T_TMP}/remote.git"
  on A kit sync
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true}' "オンラインに戻ったら push する"
}
s_push_rejected_once() {
  t_remote; t_clone A
  printf '#!/bin/sh\nif [ -f reject-once ]; then rm -f reject-once; echo rejected >&2; exit 1; fi\nexit 0\n' \
    >"${T_TMP}/remote.git/hooks/pre-receive"
  chmod +x "${T_TMP}/remote.git/hooks/pre-receive"
  touch "${T_TMP}/remote.git/reject-once"
  with_a A
  on A kit sync
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true}' "1 回拒否されても再試行で push できる"
  assert_contains "$(log_of A)" "sync: push rejected, retrying" "再試行したことがログに残る"
}
s_diverged_kit_only() {
  t_remote; t_clone A; t_clone B
  printf '#!/bin/sh\nexit 1\n' >"${T_TMP}/remote.git/hooks/pre-receive"
  chmod +x "${T_TMP}/remote.git/hooks/pre-receive"
  with_a A
  on A kit sync
  rm "${T_TMP}/remote.git/hooks/pre-receive"
  on B fake_set "${OFFICIAL} | .plugins = [{\"id\":\"b@official\",\"enabled\":true}]"
  on B kit sync
  on A kit sync
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true,"b@official":true}' "kit のコミットだけの分岐は付け直して push する"
}
s_non_master() {
  setup_ab_with_a
  git -C "${T_TMP}/B/dotfiles" checkout -q -b feat
  n="$(git -C "${T_TMP}/B/dotfiles" rev-list --count HEAD)"
  on B fake_set '.plugins += [{"id":"c@official","enabled":true}]'
  on B kit sync
  assert_eq "$(manifest_of B | jq -r '.plugins["c@official"]')" "true" "master 以外でも manifest に書く"
  assert_eq "$(git -C "${T_TMP}/B/dotfiles" rev-list --count HEAD)" "$n" "master 以外ではコミットしない"
  assert_contains "$(notices_of B)" "以外のブランチ" "通知する"
}
s_foreign_unpushed() {
  setup_ab_with_a
  echo mine >"${T_TMP}/B/dotfiles/mine.txt"
  git -C "${T_TMP}/B/dotfiles" add mine.txt
  git -C "${T_TMP}/B/dotfiles" commit -q -m "feat: mine"
  on B fake_set '.plugins += [{"id":"d@official","enabled":true}]'
  on B kit sync
  assert_eq "$(git -C "${T_TMP}/B/dotfiles" log -1 --format=%s)" "chore(kit): sync from $(hostname -s)" "コミットまではする"
  assert_eq "$(remote_manifest | jq -r '.plugins["d@official"] // "none"')" "none" "push はしない"
  assert_contains "$(notices_of B)" "push していないコミット" "通知する"
}
s_dirty_conflict() {
  setup_ab_with_a
  echo "from A" >"${T_TMP}/A/dotfiles/other.txt"
  git -C "${T_TMP}/A/dotfiles" commit -q -am "feat: other"
  git -C "${T_TMP}/A/dotfiles" push -q origin master
  echo "B local" >"${T_TMP}/B/dotfiles/other.txt"
  head_before="$(git -C "${T_TMP}/B/dotfiles" rev-parse HEAD)"
  on B kit sync
  assert_eq "$(git -C "${T_TMP}/B/dotfiles" rev-parse HEAD)" "$head_before" "取り込まない"
  assert_eq "$(cat "${T_TMP}/B/dotfiles/other.txt")" "B local" "未コミットの変更は残る"
  assert_contains "$(notices_of B)" "ぶつかる" "通知する"
}
s_failure_cap() {
  setup_ab_with_a
  on A fake_set '.plugins += [{"id":"e@official","enabled":true}]'
  on A kit sync
  on B fake_set '.fail = ["e@official"]'
  on B kit sync; on B kit sync; on B kit sync
  assert_eq "$(count_calls B "install e@official")" "3" "3 回まで試す"
  on B kit sync
  assert_eq "$(count_calls B "install e@official")" "3" "上限に達したら試さない"
  assert_contains "$(notices_of B)" "kit sync --retry plugins/e@official" "再開の方法を通知する"
  on B kit sync --retry plugins/e@official
  assert_eq "$(count_calls B "install e@official")" "4" "--retry で再開する"
}
count_calls() { grep -c -- "$2" <<<"$(calls_of "$1")" || true; }
s_command_source() {
  setup_ab_with_a
  on A fake_set '.plugins += [{"id":"g@official","enabled":true}]'
  on A kit sync
  on B fake_set '.command_source = ["g@official"]'
  on B kit sync
  assert_contains "$(notices_of B)" "承認が必要です" "承認が必要と通知する"
  assert_json_eq "$(jq -c .failures "$(state_file B sync.json)")" '{}' "失敗として数えない"
}
s_throttle_and_lock() {
  t_remote; t_clone A
  with_a A
  export KIT_THROTTLE_SECONDS=600
  on A kit sync
  on A kit sync
  assert_contains "$(log_of A)" "sync: throttled" "変更がなく 10 分以内なら何もしない"
  mkdir -p "$(state_file A lock)"
  on A kit sync --force
  assert_contains "$(log_of A)" "sync: another sync is running" "ロック中は何もしない"
  touch -t 202001010000 "$(state_file A lock)"
  : >"$(state_file A sync.log)"
  on A kit sync --force
  assert_contains "$(log_of A)" "sync: done" "古いロックは無視して動く"
}
s_concurrent() {
  t_remote; t_clone A
  with_a A
  (t_machine A; export FAKE_SLOW=1; kit sync) &
  sleep 0.3
  (t_machine A; export FAKE_SLOW=1; kit sync) &
  wait
  assert_contains "$(log_of A)" "sync: another sync is running" "同時に起動しても 1 つだけ動く（Review Focus 5）"
  jq -e . "$(state_file A base.json)" >/dev/null; assert_eq "$?" "0" "base.json は壊れない"
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true}' "manifest は正しく push される"
}
s_discovery() {
  setup_ab_with_a
  m="${T_TMP}/A/dotfiles/claude/manifest.json"
  jq '.discovery.watch += ["x/y"]' "$m" >"${m}.tmp" && mv "${m}.tmp" "$m"
  on A kit sync
  on B kit sync
  assert_json_eq "$(manifest_of B | jq -c .discovery.watch)" '["x/y"]' "A で足したウォッチが B に届く"
  m="${T_TMP}/B/dotfiles/claude/manifest.json"
  jq '.discovery.dismissed += [{"id":"p@m","at":"2026-10-22","reason":""}]' "$m" >"${m}.tmp" && mv "${m}.tmp" "$m"
  on B kit sync
  on A kit sync
  assert_json_eq "$(manifest_of A | jq -c '[.discovery.watch, [.discovery.dismissed[].id]]')" '[["x/y"],["p@m"]]' "両方の編集が残る"
}
s_dry_run() {
  t_remote; t_clone A; t_clone B
  with_a A
  on A kit sync
  out="$(on B kit sync --dry-run)"
  assert_contains "$out" "add plugins/a@official" "計画を表示する"
  assert_not_contains "$(calls_of B)" "install" "何も入れない"
  assert_eq "$(manifest_of B)" "" "manifest を書かない"
  out="$(on A kit status)"
  assert_contains "$out" "最後に成功した同期" "status は最後の同期を表示する"
  assert_contains "$out" "同期の計画" "status は計画を表示する"
}
s_broken_local_state() {
  setup_ab_with_a
  (t_machine A; export FAKE_BROKEN=1; kit sync)
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true}' "ローカル状態が読めなければ何も消さない（Review Focus 1）"
  assert_contains "$(notices_of A)" "読み取れなかった" "通知する"
}
s_invalid_manifest() {
  setup_ab_with_a
  m="${T_TMP}/A/dotfiles/claude/manifest.json"
  jq '.discovery.watch += ["x/y"]' "$m" >"${m}.tmp" && mv "${m}.tmp" "$m"
  on A kit sync
  printf '<<<<<<< HEAD\n{\n' >"$m"
  on A kit sync
  assert_contains "$(notices_of A)" "正しい JSON ではない" "壊れた manifest は通知する（Review Focus 2）"
  assert_json_eq "$(remote_manifest | jq -c .discovery.watch)" '["x/y"]' "discovery を消さない"
}
s_untracked_then_remote() {
  t_remote; t_clone A; t_clone B
  git -C "${T_TMP}/B/dotfiles" remote set-url origin "${T_TMP}/nowhere.git"
  on B fake_set "${OFFICIAL} | .plugins = [{\"id\":\"b@official\",\"enabled\":true}]"
  on B kit sync
  with_a A
  on A kit sync
  git -C "${T_TMP}/B/dotfiles" remote set-url origin "${T_TMP}/remote.git"
  on B kit sync
  assert_json_eq "$(remote_manifest | jq -c .plugins)" '{"a@official":true,"b@official":true}' "未追跡の manifest があっても両方残る（Review Focus 3）"
  assert_contains "$(calls_of B)" "claude plugin install a@official" "B に A の変更が入る"
}

t_scenario "追加が他のマシンに届く" s_propagate_add
t_scenario "削除が他のマシンに届く" s_propagate_remove
t_scenario "衝突は残す側を採る" s_conflict
t_scenario "オフライン" s_offline
t_scenario "push が 1 回拒否される" s_push_rejected_once
t_scenario "kit のコミットだけで分岐" s_diverged_kit_only
t_scenario "master 以外のブランチ" s_non_master
t_scenario "kit 以外の未 push コミット" s_foreign_unpushed
t_scenario "未コミットの変更とぶつかる" s_dirty_conflict
t_scenario "3 回失敗したら止める" s_failure_cap
t_scenario "コマンドを実行するプラグイン" s_command_source
t_scenario "間引きとロック" s_throttle_and_lock
t_scenario "同時に起動しても 1 つだけ動く" s_concurrent
t_scenario "discovery の編集を両方残す" s_discovery
t_scenario "dry-run と status" s_dry_run
t_scenario "ローカル状態が読めないと中止する" s_broken_local_state
t_scenario "manifest が壊れていたら中止する" s_invalid_manifest
t_scenario "未追跡の manifest とリモートの manifest" s_untracked_then_remote
t_done
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_sync.sh`
Expected: FAIL（`kit_sync: command not found`）

- [ ] **Step 3: 実装する**

`claude/plugins/kit/lib/sync.sh`:

```bash
# kit sync（設計書 §7）。

kit_sync_usage() { echo "usage: kit sync [--dry-run] [--force] [--retry <section/key>]"; }

kit_sync() {
  local dry=0 force=0 retry="" rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --force) force=1 ;;
      --retry)
        retry="${2:-}"
        [ -n "$retry" ] || { kit_sync_usage >&2; return 2; }
        shift ;;
      *) kit_sync_usage >&2; return 2 ;;
    esac
    shift
  done
  if ! kit_require jq || ! kit_require git; then
    echo "kit: jq と git が必要です" >&2
    return 1
  fi
  if ! kit_require claude; then
    kit_notice warn "claude コマンドが見つからないため、同期できませんでした"
    return 1
  fi
  if [ -z "$KIT_DOTFILES" ] || [ ! -e "${KIT_DOTFILES}/.git" ]; then
    kit_notice warn "dotfiles リポジトリが見つからないため、同期できませんでした"
    return 1
  fi
  kit_init_state
  if [ "$dry" = 1 ]; then
    kit_sync_run 1 0 ""
    return $?
  fi
  if ! kit_lock; then
    kit_log "sync: another sync is running"
    return 0
  fi
  kit_sync_run 0 "$force" "$retry"
  rc=$?
  kit_trim_log
  kit_unlock
  return "$rc"
}

# kit_managed <json>: 管理セクション 3 つだけを取り出す
kit_managed() {
  jq -c '{marketplaces: (.marketplaces // {}), plugins: (.plugins // {}), skills: (.skills // {})}' <<<"$1"
}

kit_sync_run() {  # <dry> <force> <retry>
  local dry="$1" force="$2" retry="$3"
  local L B W H R M result results st attempt online git_ok R2 L2 last up_rc
  if [ -f "$KIT_MANIFEST" ] && ! jq -e . "$KIT_MANIFEST" >/dev/null 2>&1; then
    kit_notice warn "claude/manifest.json が正しい JSON ではないため、同期を中止しました（衝突マーカーなどを直してください）"
    return 1
  fi
  if ! L="$(kit_local_state)"; then
    kit_notice warn "このマシンのプラグイン・スキルの状態を読み取れなかったため、同期を中止しました"
    return 1
  fi
  B="$(kit_managed "$(kit_read_json "${KIT_STATE}/base.json" '{}')")"
  st="$(kit_read_json "${KIT_STATE}/sync.json" '{"last_success":0,"failures":{}}')"
  [ -n "$retry" ] && st="$(jq -c --arg k "$retry" 'del(.failures[$k])' <<<"$st")"

  # 間引き（設計書 §7.2）
  if [ "$dry" = 0 ] && [ "$force" = 0 ] && [ -z "$retry" ]; then
    last="$(jq -r '.last_success // 0' <<<"$st")"
    if [ $(($(kit_now) - last)) -lt "$KIT_THROTTLE_SECONDS" ] &&
      kit_json_eq "$L" "$B" &&
      kit_json_eq "$(kit_read_json "$KIT_MANIFEST" "$KIT_EMPTY_MANIFEST")" "$(kit_git_show_manifest HEAD)"; then
      kit_log "sync: throttled"
      return 0
    fi
  fi

  for attempt in 1 2; do
    W="$(kit_read_json "$KIT_MANIFEST" "$KIT_EMPTY_MANIFEST")"
    online=1
    kit_git_fetch || online=0
    if [ "$online" = 1 ]; then
      R="$(kit_git_show_manifest "$(kit_git_remote_ref)")"
    else
      R="$(kit_git_show_manifest HEAD)"
    fi
    H="$(kit_git_base_manifest)"
    if ! result="$(kit_merge3 "$(jq -nc --argjson L "$L" --argjson B "$B" --argjson R "$R" --argjson H "$H" --argjson W "$W" \
      --argjson f "$(jq -c '.failures // {}' <<<"$st")" --argjson max "$KIT_MAX_FAILURES" \
      '{L: $L, B: $B, R: $R, H: $H, W: $W, failures: $f, max_failures: $max}')")"; then
      kit_notice warn "manifest の比較に失敗しました（リモートの manifest.json が壊れていないか確認してください）"
      return 1
    fi
    M="$(jq -c .M <<<"$result")"
    if [ "$dry" = 1 ]; then
      kit_sync_print_plan "$result" "$W" "$online"
      return 0
    fi

    results="$(kit_apply "$(jq -c .ops <<<"$result")" "$M")"
    st="$(kit_sync_record_results "$st" "$result" "$results")"

    R2="$R"
    git_ok=0
    if [ "$online" = 0 ]; then
      kit_write_json "$KIT_MANIFEST" "$M"
      kit_log "sync: offline, wrote manifest only"
    elif ! kit_git_branch_ok; then
      kit_write_json "$KIT_MANIFEST" "$M"
      kit_notice warn "dotfiles が ${KIT_BRANCH} 以外のブランチにあるか作業の途中のため、manifest の書き出しだけ行いました"
    else
      kit_git_update
      up_rc=$?
      kit_write_json "$KIT_MANIFEST" "$M"
      if [ "$up_rc" = 2 ]; then
        kit_notice warn "dotfiles の ${KIT_BRANCH} が ${KIT_REMOTE}/${KIT_BRANCH} と分岐しているため、同期を保留しました（rebase などで解消してください）"
      elif [ "$up_rc" != 0 ]; then
        kit_notice warn "dotfiles の未コミットの変更が ${KIT_REMOTE}/${KIT_BRANCH} の変更とぶつかるため、同期を保留しました"
      elif ! kit_git_commit_manifest; then
        kit_notice warn "manifest のコミットに失敗しました"
      elif kit_git_foreign_unpushed; then
        kit_notice warn "dotfiles の ${KIT_BRANCH} に kit 以外の push していないコミットがあるため、push しませんでした"
      elif kit_git_push; then
        R2="$M"
        git_ok=1
      elif [ "$attempt" = 1 ]; then
        kit_log "sync: push rejected, retrying"
        L="$(kit_local_state)" || return 1
        continue
      else
        kit_notice warn "dotfiles の push に失敗しました。次の同期で再試行します"
      fi
    fi
    break
  done

  # base の更新（設計書 §7.5 手順 9）。反映後の状態が読めなければ base は前のまま残す
  if L2="$(kit_local_state)"; then
    kit_write_json "${KIT_STATE}/base.json" \
      "$(kit_base_update "$(jq -nc --argjson M "$M" --argjson L2 "$L2" --argjson R2 "$R2" --argjson B "$B" \
        '{M: $M, L2: $L2, R2: $R2, B: $B}')")"
  fi
  [ "$git_ok" = 1 ] && st="$(jq -c --argjson t "$(kit_now)" '.last_success = $t' <<<"$st")"
  kit_write_json "${KIT_STATE}/sync.json" "$st"
  kit_log "sync: done (online=${online} git_ok=${git_ok} ops=$(jq length <<<"$results"))"
  return 0
}

# kit_sync_record_results <sync-state> <merge-result> <apply-results>: 通知を出し、新しい sync-state を出す
kit_sync_record_results() {
  local st="$1" result="$2" results="$3" line
  jq -r '.conflicts[] | "衝突: \(.section)/\(.key) はこのマシンと他のマシンで別々に変更されていたため、\(.chosen | tojson) にしました"' <<<"$result" |
    while IFS= read -r line; do kit_notice info "$line"; done
  jq -r '.[] | select(.status == "failed") | "反映に失敗しました: \(.section)/\(.key)（\(.message | split("\n")[0])）"' <<<"$results" |
    while IFS= read -r line; do kit_notice warn "$line"; done
  jq -r '.[] | select(.status == "needs_approval") | "承認が必要です: \(.key) はインストール時にコマンドを実行します。内容を確認してから claude plugin install \(.key) を実行してください"' <<<"$results" |
    while IFS= read -r line; do kit_notice warn "$line"; done
  jq -r '.[] | select(.status == "deferred") | "保留しました: \(.section)/\(.key)（\(.message)）"' <<<"$results" |
    while IFS= read -r line; do kit_notice info "$line"; done
  st="$(jq -c --argjson r "$results" '
    reduce $r[] as $x (.;
      ("\($x.section)/\($x.key)") as $k
      | if $x.status == "ok" then del(.failures[$k])
        elif $x.status == "failed" then .failures[$k] = ((.failures[$k] // 0) + 1)
        else . end)' <<<"$st")"
  jq -r --argjson max "$KIT_MAX_FAILURES" --argjson r "$results" '
    (.failures // {}) | to_entries[] | select(.value == $max)
    | select(.key as $k | $r | any("\(.section)/\(.key)" == $k))
    | "\(.key) は \($max) 回続けて反映に失敗したため、再試行を止めました（kit sync --retry \(.key) で再開できます）"' <<<"$st" |
    while IFS= read -r line; do kit_notice warn "$line"; done
  printf '%s' "$st"
}

# kit_sync_print_plan <merge-result> <W> <online>: --dry-run の表示（設計書 §7.8）
kit_sync_print_plan() {
  local result="$1" w="$2" online="$3" d
  if [ "$online" = 1 ]; then
    echo "比較対象: ${KIT_REMOTE}/${KIT_BRANCH} の manifest"
  else
    echo "比較対象: HEAD の manifest（fetch できませんでした）"
  fi
  jq -r '
    "このマシンでの変更（manifest に書く）: \(.local_changes | length) 件",
    (.local_changes[] | "  \(.section)/\(.key)"),
    "このマシンへの操作: \(.ops | length) 件",
    (.ops[] | "  \(.op) \(.section)/\(.key)\(if .op == "remove" then "" else " → \(.to | tojson)" end)"),
    "衝突: \(.conflicts | length) 件",
    (.conflicts[] | "  \(.section)/\(.key): このマシン=\(.local | tojson) 他=\(.remote | tojson) → \(.chosen | tojson)"),
    "再試行を止めている項目: \(.skipped | length) 件",
    (.skipped[] | "  \(.section)/\(.key)")' <<<"$result"
  echo "manifest の差分（作業ツリー → 同期後）:"
  d="$(diff -u <(jq -S . <<<"$w") <(jq -S .M <<<"$result") | sed '1,2d')"
  if [ -n "$d" ]; then printf '%s\n' "$d"; else echo "  （差分なし）"; fi
  if kit_git_branch_ok; then
    echo "git: ${KIT_BRANCH} 上なので、コミットと push を行う"
  else
    echo "git: ${KIT_BRANCH} 以外のブランチか作業の途中なので、manifest の書き出しだけ行う"
  fi
}
```

`claude/plugins/kit/lib/status.sh`:

```bash
# kit status（設計書 §9）。

kit_status() {
  local st last n
  st="$(kit_read_json "${KIT_STATE}/sync.json" '{"last_success":0,"failures":{}}')"
  last="$(jq -r '.last_success // 0' <<<"$st")"
  echo "dotfiles: ${KIT_DOTFILES:-（見つかりません）}"
  if [ "$last" = 0 ]; then
    echo "最後に成功した同期: まだありません"
  else
    echo "最後に成功した同期: $(date -r "$last" '+%Y-%m-%d %H:%M:%S')"
  fi
  n=0
  [ -f "${KIT_STATE}/notices.jsonl" ] && n="$(wc -l <"${KIT_STATE}/notices.jsonl" | tr -d ' ')"
  echo "まだ表示していない通知: ${n} 件"
  jq -r '(.failures // {}) | to_entries[] | "失敗が続いている項目: \(.key)（\(.value) 回）"' <<<"$st"
  claude plugin marketplace list --json </dev/null 2>/dev/null |
    jq -r '.[]? | select(.name != "dotfiles" and (.source == "directory" or .source == "file"))
      | "管理対象外: マーケットプレイス \(.name)（ローカルパスのため同期しません）"' 2>/dev/null
  echo "--- 同期の計画（kit sync --dry-run）"
  kit_sync --dry-run
}
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_sync.sh`
Expected: `ALL PASSED`（18 シナリオ）

- [ ] **Step 5: すべてのテストが通ることを確かめる**

Run: `claude/plugins/kit/tests/run.sh`
Expected: `ALL PASSED`

- [ ] **Step 6: コミット**

```bash
git add claude/plugins/kit/lib/sync.sh claude/plugins/kit/lib/status.sh claude/plugins/kit/tests/test_sync.sh
git commit -m "feat(kit): manifest とマシンを双方向に同期する kit sync と kit status を追加

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: フック

**Files:**
- Create: `claude/plugins/kit/lib/hook.sh`
- Create: `claude/plugins/kit/hooks/hooks.json`
- Test: `claude/plugins/kit/tests/test_hook.sh`（`test_manifests.sh` も再実行）

**Interfaces:**
- Consumes: `kit_take_notices`、`kit_detach`、`KIT_ROOT`（Task 1、2）
- Produces: `kit_hook session-start|session-end`。session-start は通知があれば `{"systemMessage": ..., "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ...}}` を 1 行出し、`kit sync` を切り離して起動する。session-end は `kit sync` を切り離して起動するだけ。

- [ ] **Step 1: 失敗するテストを書く**

`claude/plugins/kit/tests/test_hook.sh`:

```bash
. "$(dirname "$0")/helpers.sh"

s_nested() {
  t_remote; t_clone A
  out="$(t_machine A; export KIT_NESTED=1; kit hook session-start </dev/null)"; rc=$?
  assert_eq "$rc" "0" "入れ子でも終了コード 0"
  assert_eq "$out" "" "入れ子では何も出さない"
  assert_eq "$([ -e "$(state_file A sync.log)" ] && echo yes || echo no)" "no" "入れ子では同期しない"
}
s_notices() {
  t_remote; t_clone A
  (t_machine A; . "${KIT_PLUGIN_DIR}/lib/common.sh"; kit_notice info "テスト通知1"; kit_notice warn "テスト通知2")
  out="$(on A kit hook session-start </dev/null)"
  assert_contains "$(jq -r .systemMessage <<<"$out")" "テスト通知1" "通知をユーザーに見せる"
  assert_contains "$(jq -r .systemMessage <<<"$out")" "テスト通知2" "全部の通知を見せる"
  assert_eq "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")" "SessionStart" "SessionStart の形"
  assert_contains "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "テスト通知1" "Claude にも伝える"
  wait_log A "sync: done"; assert_eq "$?" "0" "切り離した同期が最後まで動く"
  assert_eq "$(on A kit hook session-start </dev/null)" "" "通知を出したら空になる"
  wait_log A "sync: done" 2
}
s_session_end_fast() {
  t_remote; t_clone A
  start="$(t_ms)"
  (t_machine A; export FAKE_SLOW=2; kit hook session-end </dev/null)
  end="$(t_ms)"
  assert_lt "$((end - start))" "1000" "SessionEnd は 1 秒以内に戻る"
  wait_log A "sync: done"; assert_eq "$?" "0" "戻った後も同期は動く"
}
s_always_zero() {
  t_remote; t_clone A
  (t_machine A; export KIT_DOTFILES="${T_TMP}/nowhere"; kit hook session-start </dev/null >/dev/null); rc=$?
  assert_eq "$rc" "0" "同期できない環境でも終了コード 0"
  wait_log A "dotfiles リポジトリが見つからない"; assert_eq "$?" "0" "切り離した同期は通知を残して終わる"
  (t_machine A; kit hook unknown </dev/null); rc=$?
  assert_eq "$rc" "0" "不明なフックでも終了コード 0"
}

t_scenario "入れ子では何もしない" s_nested
t_scenario "通知を出して同期を起動する" s_notices
t_scenario "SessionEnd はすぐ戻る" s_session_end_fast
t_scenario "常に終了コード 0" s_always_zero
t_done
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_hook.sh`
Expected: FAIL（`kit_hook: command not found` のため出力が空になり、通知のアサーションが失敗する）

- [ ] **Step 3: 実装する**

`claude/plugins/kit/lib/hook.sh`:

```bash
# Claude Code のフック（設計書 §7.1）。呼び出し元の bin/kit は常に終了コード 0 で終わる。
# 重い処理（同期）は kit_detach で切り離し、フック自体はすぐ戻る。

kit_hook() {
  [ "${KIT_NESTED:-}" = 1 ] && return 0
  cat >/dev/null 2>&1   # フックの入力 JSON は使わない
  case "${1:-}" in
    session-start) kit_hook_session_start ;;
    session-end) kit_detach "${KIT_ROOT}/bin/kit" sync ;;
  esac
  return 0
}

kit_hook_session_start() {
  local text
  text="$(kit_take_notices | jq -r 'map("・" + .message) | join("\n")')"
  if [ -n "$text" ]; then
    jq -nc --arg t "kit:
${text}" '{systemMessage: $t, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $t}}'
  fi
  kit_detach "${KIT_ROOT}/bin/kit" sync
}
```

`claude/plugins/kit/hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/bin/kit\" hook session-start",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/bin/kit\" hook session-end"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_hook.sh test_manifests.sh`
Expected: `ALL PASSED`

- [ ] **Step 5: コミット**

```bash
git add claude/plugins/kit/lib/hook.sh claude/plugins/kit/hooks/hooks.json claude/plugins/kit/tests/test_hook.sh
git commit -m "feat(kit): セッション開始・終了時に同期を起動し通知を出すフックを追加

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: bootstrap.sh

**Files:**
- Create: `claude/bootstrap.sh`
- Test: `claude/plugins/kit/tests/test_bootstrap.sh`

**Interfaces:**
- Consumes: `bin/kit sync --force`（Task 7）
- Produces: `claude/bootstrap.sh [--no-sync]`。`${KIT_STATE_DIR:-~/.local/state/claude-kit}/dotfiles-path` に dotfiles の場所を書く（Task 1 の `kit_resolve_dotfiles` が読む）。

- [ ] **Step 1: 失敗するテストを書く**

`claude/plugins/kit/tests/test_bootstrap.sh`:

```bash
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

/bin/bash "${CLAUDE_DIR}/bootstrap.sh" --no-sync >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "成功する"
settings="$(cat "${HOME}/.claude/settings.json")"
assert_not_contains "$settings" "run-hook.cmd" "v1 のフックを外す"
assert_json_eq "$(jq -c .hooks.SessionStart <<<"$settings")" '[{"hooks":[{"type":"command","command":"/other/status"}]}]' "同じイベントの他のフックは残す"
assert_eq "$(jq -c '.hooks | has("UserPromptSubmit")' <<<"$settings")" "false" "空になったイベントは消す"
assert_eq "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' <<<"$settings")" "bash guard.sh" "無関係なフックは残す"
assert_eq "$(jq -r .theme <<<"$settings")" "dark" "他の設定は残す"
assert_eq "$(ls "${HOME}/.claude/backups" | wc -l | tr -d ' ')" "1" "バックアップを取る"
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
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `claude/plugins/kit/tests/run.sh test_bootstrap.sh`
Expected: FAIL（`bootstrap.sh: No such file or directory`）

- [ ] **Step 3: 実装する**

`claude/bootstrap.sh`:

```bash
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
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `chmod +x claude/bootstrap.sh && claude/plugins/kit/tests/run.sh test_bootstrap.sh`
Expected: `ALL PASSED`

- [ ] **Step 5: コミット**

```bash
git add claude/bootstrap.sh claude/plugins/kit/tests/test_bootstrap.sh
git commit -m "feat(kit): 新しいマシンを初期化し v1 を撤去する bootstrap.sh を追加

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: このマシンでの移行と v1 の削除

このタスクは本物の環境（`~/.claude/settings.json`、インストール済みのプラグイン、dotfiles の git）を変更する。各チェックポイントでユーザーの承認を得てから次に進む。

**Files:**
- Create: `claude/manifest.json`（初回の同期が生成）
- Modify: `claude/README.md`（全面的に書き直す）
- Modify: `README.md`（`## claude/ — skillsh-router` の節）
- Delete: `claude/hooks/`、`claude/lib/`、`claude/bin/`、`claude/data/`、`claude/skills/`、`claude/install.sh`、`claude/uninstall.sh`、`claude/.gitignore`

- [ ] **Step 1: すべてのテストが通ることを確かめる**

Run: `claude/plugins/kit/tests/run.sh`
Expected: `ALL PASSED`

- [ ] **Step 2: 本物の環境で dry-run する**

Run: `claude/plugins/kit/bin/kit sync --dry-run`
Expected: 比較対象が `origin/master の manifest`。「このマシンでの変更」がマーケットプレイス 2 件（`claude-code-workflows`、`claude-plugins-official`）とユーザースコープのプラグイン 11 件。「このマシンへの操作: 0 件」。git は「master 以外のブランチ…書き出しだけ行う」（`feat/claude-kit` ブランチのため）。

**チェックポイント**: dry-run の出力をユーザーに見せ、承認を得る。

- [ ] **Step 3: bootstrap.sh を実行する**

Run: `claude/bootstrap.sh`
Expected:
- 「v1 のフックを settings.json から外しました（バックアップ: …）」
- 「~/.claude/skills/skillsh-router を削除しました」
- 「find-skills を外しました」
- マーケットプレイス `dotfiles` の登録と `kit@dotfiles` のインストール
- 初回の同期（ブランチが master 以外なので manifest の書き出しだけ）
- 「完了しました。Claude Code を再起動してください。」

確認:

```bash
jq '[.hooks[][] | .hooks[]?.command] | map(select(contains("run-hook.cmd"))) | length' ~/.claude/settings.json   # 0
claude plugin list --json | jq -r '.[] | select(.id == "kit@dotfiles") | "\(.scope) \(.enabled)"'           # user true
ls -la ~/.claude/skills/                                                                                      # skillsh-router と find-skills がない
jq -c '{m: (.marketplaces | keys), p: (.plugins | length), s: (.skills | length)}' claude/manifest.json       # m: 2 件, p: 11, s: 0
```

- [ ] **Step 4: v1 のファイルを削除する**

```bash
git rm -r -q -f claude/hooks claude/lib claude/bin claude/data claude/skills claude/install.sh claude/uninstall.sh claude/.gitignore
rm -rf claude/data claude/hooks claude/lib claude/bin claude/skills
git status --short claude/
```

Expected: v1 のファイルが `D`、`claude/README.md` が `M`（未コミットの日本語訳。次の Step で書き直す）、`claude/manifest.json` が `??`。

- [ ] **Step 5: README を書き直す**

`claude/README.md` を次の内容で全面的に置き換える（v1 の未コミットの日本語訳は破棄する）:

````markdown
# claude-kit

Claude Code のスキル・プラグインを、複数のマシンで同じ構成に保つ仕組み。dotfiles の `claude/` をローカルマーケットプレイス `dotfiles` にして、自作プラグイン `kit` として配布している。設計書: [docs/superpowers/specs/2026-10-22-claude-kit-design.md](../docs/superpowers/specs/2026-10-22-claude-kit-design.md)

> 発見（週 1 回の振り返りと `/discover`）は計画 2 で追加する。

## セットアップ

```bash
git clone git@github.com:mfreeman59/dotfiles.git ~/dotfiles
~/dotfiles/claude/bootstrap.sh
```

必要なコマンド: git、jq、gh、node（npx）、claude、perl（macOS 標準）。`bootstrap.sh` は何度実行してもよい。

## 普段の動き

- Claude Code のセッション開始時と終了時に、`kit sync` がバックグラウンドで動く。
- このマシンで入れた・外した・有効化／無効化したプラグイン、登録したマーケットプレイス、`npx skills add -g` で入れたスキルは、`claude/manifest.json` に記録され、自動でコミット・push される。
- 他のマシンの変更は、次のセッション開始時に自動で反映される（効くのはその次のセッションから。プラグインは `/reload-plugins` でも反映できる）。
- 問題があると、次のセッション開始時に「kit: …」という通知が出る。

同期するのはユーザースコープのものだけ。プロジェクトスコープのプラグイン、claude.ai から同期されるスキル・プラグイン、ローカルパスのマーケットプレイスは対象外。

## 自動で git 操作をしない場合

次のときは manifest の書き出しまでで止めて通知する。

- dotfiles が master 以外のブランチにある、または rebase などの途中
- master に kit 以外の push していないコミットがある（コミットまではする）
- 未コミットの変更と、取り込む変更がぶつかる
- master と origin/master の履歴が、kit 以外のコミットで分岐している
- オフライン

## コマンド

| コマンド | 内容 |
|---|---|
| `kit status` | 最後の同期、失敗が続いている項目、次の同期の計画を表示する |
| `kit sync` | 今すぐ同期する。`--dry-run` で計画だけ表示、`--force` で間引きを無視 |
| `kit sync --retry plugins/<id>` | 3 回続けて失敗して止まった項目の再試行を再開する |

Claude Code の中では `kit` を名前で呼べる。ターミナルからは `~/dotfiles/claude/plugins/kit/bin/kit`。

## ファイル

| パス | 内容 |
|---|---|
| `claude/manifest.json` | 同期の正本。`discovery` 以外は kit が生成するので手で編集しない |
| `claude/plugins/kit/` | kit プラグイン本体 |
| `~/.local/state/claude-kit/` | マシンごとの状態（`sync.log`、`base.json`、`sync.json`、通知） |

## テスト

```bash
~/dotfiles/claude/plugins/kit/tests/run.sh
```
````

ルートの `README.md` の `## claude/ — skillsh-router` の節（見出しから次のコードブロックの後の説明段落まで）を、次の内容に置き換える:

````markdown
## claude/ — claude-kit

`claude/` 配下は、Claude Code のスキル・プラグインを複数マシンで同期する **claude-kit**（dotfiles をローカルマーケットプレイスにした自作プラグイン `kit`）を含む。詳細は [claude/README.md](claude/README.md) を参照。

```bash
~/dotfiles/claude/bootstrap.sh
```

`dotfilesLink.sh` とは別系統のセットアップで、マーケットプレイス `dotfiles` の登録、`kit` プラグインの導入、初回の同期を行う。
````

- [ ] **Step 6: コミット**

```bash
git add -A claude README.md
git status --short
git commit -m "feat(kit): manifest を追加し、v1（skillsh-router）を削除

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected（`git status --short`）: `claude/manifest.json` の追加、v1 のファイルの削除、README 2 つの変更だけ。それ以外が含まれていたらコミットせずに確かめる。

- [ ] **Step 7: 通知の表示を確かめる（設計書 §13 の 1 つ目）**

```bash
/bin/bash -c '. claude/plugins/kit/lib/common.sh; kit_notice info "kit の通知のテストです（表示されれば OK）"'
```

**チェックポイント**: ユーザーに Claude Code の新しいセッションを開いてもらい、起動時に「kit: ・kit の通知のテストです（表示されれば OK）」が表示されるか確かめてもらう。

- 表示された → 何もしない。
- 表示されなかった → `claude/plugins/kit/lib/hook.sh` の `kit_hook_session_start` の `jq -nc ...` の行を次に置き換え、Task 8 のテストの `systemMessage` のアサーション 2 つを `additionalContext` に変えてから、`claude/plugins/kit/tests/run.sh test_hook.sh` を通してコミットする（メッセージ: `fix(kit): SessionStart の通知を Claude 経由で伝える`）。

```bash
    jq -nc --arg t "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ("kit からの通知です。最初の応答の冒頭で、次の内容をユーザーに一度だけ簡潔に伝えてください:\n" + $t)}}'
```

- [ ] **Step 8: master にマージして push する**

**チェックポイント**: master へのマージと push（GitHub への公開）について、ユーザーの承認を得る。

```bash
git switch master
git merge --ff-only feat/claude-kit
git push origin master
claude/plugins/kit/bin/kit sync --force
claude/plugins/kit/bin/kit status
```

Expected: `kit status` に最後に成功した同期の時刻が表示され、計画は「このマシンでの変更: 0 件」「このマシンへの操作: 0 件」「git: master 上なので、コミットと push を行う」。`git log origin/master -1` が Task 10 のコミット（manifest に変化がなければ kit のコミットは増えない）。

- [ ] **Step 9: 作業ブランチを片付ける**

```bash
git branch -d feat/claude-kit
```

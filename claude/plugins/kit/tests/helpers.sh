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

# kit_libs: bin/kit と同じように common.sh と lib/*.sh を読み込む（t_machine の後で呼ぶ）
kit_libs() {
  . "${KIT_PLUGIN_DIR}/lib/common.sh"
  local f
  for f in "${KIT_PLUGIN_DIR}"/lib/*.sh; do
    case "$f" in */common.sh) ;; *) . "$f" ;; esac
  done
}

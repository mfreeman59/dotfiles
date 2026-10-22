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
KIT_REMOVAL_GUARD="${KIT_REMOVAL_GUARD:-3}"
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

# kit_claude <args...>: claude を / で実行する。plugin list の enabled などは、作業ディレクトリの
# プロジェクト設定（.claude/settings*.json の enabledPlugins）で上書きされる。ユーザースコープの値を読み書きするため / で動かす
kit_claude() { (cd / && claude "$@"); }

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
  [ -n "$json" ] || return 1
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp "${path}.XXXXXX")"
  if printf '%s' "$json" | jq -S --indent 2 . >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
    return 1
  fi
}

# kit_read_json <path> <default-json>: ファイルがない・空・壊れていれば既定値
kit_read_json() {
  local out=""
  [ -f "$1" ] && out="$(jq -c . "$1" 2>/dev/null)"
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$2"; fi
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

# kit_with_timeout <seconds> <cmd...>: macOS 標準の perl で子を起動して待ち、時間切れなら子を止めて 124 で終わる。
# perl 自身を SIGALRM で終わらせると、シェルが「Alarm clock」と報告して sync.log に混ざるため、perl の中で処理する
kit_with_timeout() {
  local secs="$1"
  shift
  perl -e '
    my $secs = shift @ARGV;
    my $pid = fork;
    exit 127 unless defined $pid;
    if ($pid == 0) { exec @ARGV or exit 127; }
    $SIG{ALRM} = sub { kill "TERM", $pid; waitpid($pid, 0); exit 124; };
    alarm $secs;
    waitpid($pid, 0);
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
  ' "$secs" "$@"
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

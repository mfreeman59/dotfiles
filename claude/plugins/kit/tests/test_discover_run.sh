. "$(dirname "$0")/helpers.sh"

# prompts <件数> <日付>: そのマシンのトランスクリプトに自分のプロンプトを足す
prompts() {
  local p="${HOME}/.claude/projects/-Users-me-proj"
  mkdir -p "$p"
  jq -nc --argjson n "$1" --arg d "$2" 'range(0; $n) as $i
    | {type: "user", timestamp: "\($d)T00:00:00.\(("00" + ($i | tostring)) | .[-3:])Z", sessionId: "s", cwd: "/Users/me/proj",
       origin: {kind: "human"}, message: {role: "user", content: "Supabase のマイグレーションを作って \($i)"}}' >>"${p}/s.jsonl"
}
D() { state_file A "discover/$1"; }
exists() { [ -e "$1" ] && echo yes || echo no; }
setup() {
  t_remote; t_clone A
  t_machine A
  mkdir -p "$(state_file A discover)"
  echo '{"installed":[],"available":[
    {"pluginId":"db@official","name":"db","description":"Supabase migrations","marketplaceName":"official","source":"./db","installCount":50},
    {"pluginId":"x@official","name":"x","description":"Supabase x","marketplaceName":"official","source":"./x","installCount":5}]}' \
    >"${FAKE_DIR}/available.json"
  mkdir -p "${FAKE_DIR}/gh"
  echo '{"items":[]}' >"${FAKE_DIR}/gh/search_code.json"
  echo '{"needs":[{"theme":"DB のマイグレーション","evidence":["Supabase のマイグレーションを作って 1"],"keywords":["supabase"]}]}' \
    >"${FAKE_DIR}/p-needs.json"
  echo '{"recommendations":[
    {"id":"made-up@nowhere","need":"DB のマイグレーション","reason":"x","overlap":""},
    {"id":"db@official","need":"DB のマイグレーション","reason":"マイグレーションを作れる","overlap":""}]}' \
    >"${FAKE_DIR}/p-recommendations.json"
}

s_run() {
  setup; prompts 3 2026-10-10
  kit discover run; rc=$?
  assert_eq "$rc" "0" "成功"
  assert_eq "$(jq -c '[.[] | [.rank, .id, .kind, .reason]]' "$(D recommendations.json)")" '[[1,"db@official","plugin","マイグレーションを作れる"]]' \
    "候補にない id を捨てておすすめを保存する"
  assert_eq "$(jq '.prompts | length' "$(D digest.json)")" "3" "digest を保存する"
  assert_eq "$(jq -r '.[0].theme' "$(D needs.json)")" "DB のマイグレーション" "needs を保存する"
  assert_eq "$(jq -c '[.[].id]' "$(D candidates.json)")" '["db@official","x@official"]' "candidates を保存する"
  assert_contains "$(cat "${FAKE_DIR}/p-needs.prompt")" "Supabase のマイグレーションを作って" "digest をニーズ抽出に渡す"
  assert_contains "$(cat "${FAKE_DIR}/p-recommendations.prompt")" "x@official" "候補を順位付けに渡す"
  assert_contains "$(cat "$(state_file A sync.log)")" "discover: done (needs=1 candidates=2 recommendations=1)" "結果をログに残す"
  last="$(cat "$(D last-run)")"
  assert_ne "$last" "" "last-run を記録する"
  echo '{"needs":[]}' >"${FAKE_DIR}/p-needs.json"
  kit discover run; rc=$?
  assert_eq "$rc" "0" "続けて実行しても成功"
  assert_eq "$(jq -r .since "$(D digest.json)")" "$last" "次の分析は前回の分析より後の記録だけを使う"
  assert_eq "$(grep -c 'required":\["needs"' "${FAKE_DIR}/calls.log")" "1" "前回の後のプロンプトが少なければ claude -p を呼ばない"
  assert_eq "$(jq -c '[.[].id]' "$(D recommendations.json)")" '["db@official"]' "おすすめを空で置き換えない"
  assert_eq "$(cat "$(D last-run)")" "$last" "last-run も進めない"
  assert_contains "$(cat "$(state_file A sync.log)")" "discover: skip (0 prompts since ${last})" "分析しなかったことをログに残す"
}
s_no_candidates() {
  setup; prompts 3 2026-10-10
  echo '{"needs":[{"theme":"T","evidence":[],"keywords":["zzz"]}]}' >"${FAKE_DIR}/p-needs.json"
  kit discover run; rc=$?
  assert_eq "$rc" "0" "成功"
  assert_eq "$(cat "$(D recommendations.json)")" "[]" "候補がなければおすすめは 0 件"
  assert_eq "$(exists "${FAKE_DIR}/p-recommendations.prompt")" "no" "順位付けを呼ばない"
}
s_failure() {
  setup; prompts 3 2026-10-10
  echo '[{"rank":1,"id":"old@m"}]' >"$(D recommendations.json)"
  rm "${FAKE_DIR}/p-needs.json"
  kit discover run; rc=$?
  assert_eq "$rc" "1" "失敗"
  assert_ne "$(cat "$(D last-failed)" 2>/dev/null)" "" "失敗した時刻を記録する"
  assert_eq "$(exists "$(D last-run)")" "no" "last-run は進めない"
  assert_contains "$(notices_of A)" "発見の分析に失敗しました" "通知する"
  assert_eq "$(jq -c '[.[].id]' "$(D recommendations.json)")" '["old@m"]' "前回のおすすめを残す"
}
s_lock() {
  setup; prompts 3 2026-10-10
  mkdir -p "$(D lock)"
  kit discover run; rc=$?
  assert_eq "$rc" "0" "他の分析が動いていれば何もせずに 0"
  assert_contains "$(cat "$(state_file A sync.log)")" "discover: another run is in progress" "ログに残す"
  assert_eq "$(exists "${FAKE_DIR}/p-needs.prompt")" "no" "分析しない"
  touch -t 202001010000 "$(D lock)"
  kit discover run; rc=$?
  assert_eq "$rc" "0" "古いロックは異常終了の残骸とみなして分析する"
  assert_eq "$(exists "$(D lock)")" "no" "終わったらロックを外す"
}
s_maybe_run() {
  setup; prompts 3 2026-10-10
  export KIT_DISCOVER_MIN_PROMPTS=4
  kit discover maybe-run; rc=$?
  assert_eq "$rc" "0" "成功"
  assert_contains "$(cat "$(state_file A sync.log)")" "discover: skip (3 prompts since never)" "プロンプトが足りなければ分析しない"
  prompts 1 2026-10-11
  kit discover maybe-run
  wait_log A "discover: done"
  assert_eq "$?" "0" "前回の分析から 7 日以上経ち、プロンプトが足りていれば、分析を切り離して起動する"
  prompts 10 2026-10-12
  kit discover maybe-run
  sleep 1
  assert_eq "$(grep -c 'discover: done' "$(state_file A sync.log)")" "1" "前回の分析から 7 日経っていなければ分析しない"
}
s_retry() {
  setup; prompts 3 2026-10-10
  export KIT_DISCOVER_MIN_PROMPTS=1
  date +%s >"$(D last-failed)"
  kit discover maybe-run
  sleep 1
  assert_eq "$(exists "${FAKE_DIR}/p-needs.prompt")" "no" "失敗から 1 日以内は再試行しない"
  echo $(($(date +%s) - 86401)) >"$(D last-failed)"
  kit discover maybe-run
  wait_log A "discover: done"
  assert_eq "$?" "0" "1 日経てば再試行する"
  assert_eq "$(exists "$(D last-failed)")" "no" "成功したら失敗の記録を消す"
}
s_bad_watch() {
  setup; prompts 3 2026-10-10
  echo '{"version":1,"marketplaces":{},"plugins":{},"skills":{},"discovery":{"watch":["o/wm"],"dismissed":[]}}' >"${KIT_DOTFILES}/claude/manifest.json"
  echo '{"name":"wm","plugins":[{"name":"good","description":"supabase helper","source":"./good"},{"name":"bad","description":{"en":"supabase"},"source":"./bad"},7]}' \
    >"${FAKE_DIR}/gh/repos_o_wm_contents_.claude-plugin_marketplace.json.json"
  echo '{"stargazers_count":5,"pushed_at":"2026-10-01T00:00:00Z","archived":false}' >"${FAKE_DIR}/gh/repos_o_wm.json"
  kit discover run; rc=$?
  assert_eq "$rc" "0" "ウォッチ中のマーケットプレイスに形の崩れた項目があっても分析できる"
  assert_contains "$(jq -c '[.[].id]' "$(D candidates.json)")" '"good@wm"' "そのマーケットプレイスの他の候補も使う"
}
s_repo_signals() {
  setup; prompts 3 2026-10-10
  echo '{"installed":[],"available":[{"pluginId":"db@official","name":"db","description":"Supabase migrations","marketplaceName":"official","source":{"source":"url","url":"https://github.com/o/db.git"},"installCount":50}]}' \
    >"${FAKE_DIR}/available.json"
  echo '{"stargazers_count":40,"created_at":"2025-05-01T00:00:00Z","pushed_at":"2026-10-01T00:00:00Z","archived":false,"owner":{"login":"o","type":"Organization"}}' \
    >"${FAKE_DIR}/gh/repos_o_db.json"
  echo '[{"login":"a"},{"login":"b"}]' >"${FAKE_DIR}/gh/repos_o_db_contributors.json"
  kit discover run
  assert_json_eq "$(jq -c '.[0].signals' "$(D recommendations.json)")" \
    '{"installs":50,"stars":40,"contributors":2,"created_at":"2025-05-01","pushed_at":"2026-10-01","owner":"org"}' "おすすめにリポジトリの情報を残す"
  assert_contains "$(cat "${FAKE_DIR}/p-recommendations.prompt")" '"contributors":2' "順位付けにもリポジトリの情報を渡す"
}
s_defaults() {
  t_machine A
  kit_libs
  assert_eq "${KIT_DISCOVER_INTERVAL_SECONDS} ${KIT_DISCOVER_MIN_PROMPTS} ${KIT_DISCOVER_RETRY_SECONDS}" "604800 20 86400" "7 日・20 件・失敗から 1 日"
}

t_scenario "分析しておすすめを保存する" s_run
t_scenario "候補がなければ順位付けを呼ばない" s_no_candidates
t_scenario "失敗" s_failure
t_scenario "同時に 1 つだけ分析する" s_lock
t_scenario "分析の時期を判定する" s_maybe_run
t_scenario "失敗から 1 日以内は再試行しない" s_retry
t_scenario "形の崩れたウォッチ先があっても分析する" s_bad_watch
t_scenario "おすすめにリポジトリの情報を足す" s_repo_signals
t_scenario "既定値" s_defaults
t_done

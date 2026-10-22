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

# 本物の CLI の `marketplace remove` は、そのマーケットプレイスのプラグインを（スコープを問わず）アンインストールし、
# データも消す。そのため、ソースの変更を「削除して追加」で反映したり、プラグインが残っているのに削除したりすると、
# プラグインの削除が「このマシンでの変更」として全マシンに広がってしまう。どちらも自動では行わない。
kit_apply_marketplace() {  # <op-json> <M-json>
  local op="$1" m="$2" key kind arg out
  key="$(jq -r .key <<<"$op")"
  kind="$(jq -r .op <<<"$op")"
  case "$kind" in
    change)
      kit_apply_result marketplaces "$key" change deferred \
        "マーケットプレイス ${key} のソースが他のマシンで $(jq -c .to <<<"$op") に変わりました。プラグインを巻き込まないよう自動では登録し直しません。必要なら手動で登録し直してください"
      return 0 ;;
    remove)
      if jq -e --arg k "$key" '(.plugins // {}) | keys | any(endswith("@" + $k))' <<<"$m" >/dev/null ||
        kit_claude plugin list --json 2>/dev/null | jq -e --arg k "$key" 'any(.[]; .id | endswith("@" + $k))' >/dev/null; then
        kit_apply_result marketplaces "$key" remove deferred "マーケットプレイス ${key} のプラグインがまだ使われている（プロジェクトスコープを含む）ため、削除を保留しました"
      elif out="$(kit_claude plugin marketplace remove "$key" --scope user 2>&1)"; then
        kit_apply_result marketplaces "$key" remove ok ""
      else
        kit_apply_result marketplaces "$key" remove failed "$out"
      fi
      return 0 ;;
  esac
  arg="$(kit_mkt_add_arg "$(jq -c .to <<<"$op")")"
  if [ -z "$arg" ]; then
    kit_apply_result marketplaces "$key" "$kind" failed "対応していないソースです"
    return 0
  fi
  if out="$(kit_claude plugin marketplace add "$arg" --scope user 2>&1)"; then
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
      if ! out="$(kit_claude plugin install "$key" -s user --json 2>/dev/null)"; then
        if jq -e '.shownCommand' <<<"$out" >/dev/null 2>&1; then
          kit_apply_result plugins "$key" add needs_approval "インストール時にコマンドを実行するプラグインです"
        else
          msg="$(jq -r '.message // empty' <<<"$out" 2>/dev/null)"
          kit_apply_result plugins "$key" add failed "${msg:-install failed}"
        fi
        return 0
      fi
      if [ "$to" = false ] && ! kit_claude plugin disable "$key" -s user >/dev/null 2>&1; then
        kit_apply_result plugins "$key" add failed "インストール後の無効化に失敗しました"
        return 0
      fi
      kit_apply_result plugins "$key" add ok "" ;;
    remove)
      if out="$(kit_claude plugin uninstall "$key" -s user --keep-data 2>&1)"; then
        kit_apply_result plugins "$key" remove ok ""
      else
        kit_apply_result plugins "$key" remove failed "$out"
      fi ;;
    change)
      verb=disable
      [ "$to" = true ] && verb=enable
      if out="$(kit_claude plugin "$verb" "$key" -s user 2>&1)"; then
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

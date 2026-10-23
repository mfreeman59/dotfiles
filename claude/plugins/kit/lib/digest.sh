# 発見の ① 抽出（設計書 §8.2）。トランスクリプトは ${KIT_TRANSCRIPTS_DIR}/<プロジェクト>/<セッション>.jsonl。
# サブエージェントの記録（<セッション>/subagents/）は使わない。

KIT_TRANSCRIPTS_DIR="${KIT_TRANSCRIPTS_DIR:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/projects}"

# kit_transcripts: 対象のトランスクリプトを連結して出す。ファイルの末尾に改行がなくても次のファイルの行と
# つながらないよう、ファイルごとに改行を足す（空行は jq 側で読み飛ばす）
kit_transcripts() {
  local f
  [ -d "$KIT_TRANSCRIPTS_DIR" ] || return 0
  find "$KIT_TRANSCRIPTS_DIR" -maxdepth 2 -name '*.jsonl' -not -path '*/subagents/*' -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      cat "$f" 2>/dev/null
      echo
    done
}

# kit_digest <since-iso>: digest を 1 行の JSON で出す（since が空ならすべての記録）
kit_digest() {
  kit_transcripts | jq -cnR -L "$KIT_LIB_DIR" --arg since "$1" --arg until "$(kit_iso_now)" \
    'include "digest"; kit_digest($since; $until)'
}

# kit_count_prompts <since-iso>: since より後の自分のプロンプトの件数
kit_count_prompts() {
  kit_transcripts | jq -nR -L "$KIT_LIB_DIR" --arg since "$1" 'include "digest"; kit_count_prompts($since)'
}

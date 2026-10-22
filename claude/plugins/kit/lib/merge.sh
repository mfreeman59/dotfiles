# 3 者比較と base の更新（実体は lib/merge.jq）。入力は 1 つの JSON。

kit_merge3() { jq -c -L "$KIT_LIB_DIR" 'include "merge"; merge3' <<<"$1"; }
kit_base_update() { jq -c -L "$KIT_LIB_DIR" 'include "merge"; base_update' <<<"$1"; }

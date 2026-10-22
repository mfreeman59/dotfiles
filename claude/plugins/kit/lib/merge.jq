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

# 大量削除の歯止め: 1 回の同期での削除（このマシンでの削除と、他のマシンでの削除の反映）が removal_guard 件以上あり、
# allow_removals でなければ、すべて止める。CLI の異常（list が [] を返す）や manifest の取り違えで、
# 全マシンから一斉に消えるのを防ぐ。止めたこのマシンでの削除は manifest に書かず（m を R に戻す）、
# 止めた他のマシンでの削除は反映しない。どちらも base は更新されないので、次の同期でまた判定される。
def kit_guard_removals($items; $in):
  ([$items[] | select(.kind == "local" and .m == null) | {section, key, direction: "local"}]
   + [$items[] | select(.m == null and .l != null and .failures < $in.max_failures) | {section, key, direction: "remote"}]) as $removals
  | (if ($removals | length) >= ($in.removal_guard // 3) and (($in.allow_removals // false) | not)
     then $removals else [] end) as $blocked
  | { blocked: $blocked,
      items: [$items[] | . as $i
              | if any($blocked[]; .section == $i.section and .key == $i.key)
                then (if $i.kind == "local" then .m = .r else . end) + {blocked: true}
                else . end] };

# 入力 {L, B, R, H, W, failures, max_failures, allow_removals, removal_guard}
def merge3:
  . as $in
  | kit_guard_removals([kit_sections[] as $s | kit_merge_section($s; $in.L[$s]; $in.B[$s]; $in.R[$s]; $in.failures)] | add; $in) as $g
  | $g.items as $items
  | { M: ({version: 1, discovery: kit_discovery_merge($in.H; $in.W; $in.R)}
          + ([kit_sections[] as $s
              | {key: $s, value: ([$items[] | select(.section == $s and .m != null) | {key, value: .m.v}] | from_entries)}]
             | from_entries)),
      ops: [$items[] | select(.m != .l and .failures < $in.max_failures and (.blocked | not))
            | {section, key, op: kit_op(.), from: .l.v, to: .m.v}],
      skipped: [$items[] | select(.m != .l and .failures >= $in.max_failures) | {section, key}],
      conflicts: [$items[] | select(.kind == "conflict") | {section, key, local: .l.v, remote: .r.v, chosen: .m.v}],
      local_changes: [$items[] | select(.kind == "local" and (.blocked | not)) | {section, key}],
      blocked_removals: $g.blocked };

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

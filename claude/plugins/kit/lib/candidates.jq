# 発見の ③ 候補収集と ④ の検証の純粋な部分（設計書 §8.2）。

# 先に出たものを残して id の重複を除く（unique_by は並びを変えるので使わない）
def kit_dedupe:
  reduce .[] as $c ({seen: {}, out: []};
    if .seen[$c.id] then . else .seen[$c.id] = true | .out += [$c] end)
  | .out;

# 登録済みカタログ（claude plugin list --available の available）→ 候補
def kit_catalog_candidates:
  map(select((.pluginId | type) == "string")
      | {kind: "plugin", id: .pluginId, name: .name, description: ((.description // "")[0:300]), source: .source,
         marketplace: .marketplaceName, origin: "catalog",
         signals: ({installs: .installCount} | with_entries(select(.value != null)))});

# 名前と説明文に含まれるキーワードの数で並べ（同数ならインストール数の多い順）、上位 $limit 件。1 つも含まないものは除く
def kit_match($keywords; $limit):
  ($keywords | map(ascii_downcase)) as $kw
  | map(. as $c
        | ((($c.name // "") + " " + ($c.description // "")) | ascii_downcase) as $text
        | {c: $c, score: ([$kw[] | select(. as $k | $text | contains($k))] | length)})
  | map(select(.score > 0))
  | sort_by(-.score, -(.c.signals.installs // 0), .c.id)
  | .[0:$limit]
  | map(.c);

# 導入済み・却下済み・ウォッチ済み・登録済みのマーケットプレイスを除く。同じ名前のプラグインが別のマーケットプレイスで
# 導入済みなら、それも除く
def kit_exclude($installed; $dismissed; $watch):
  ([($dismissed // [])[] | .id?]) as $d
  | ($installed.plugins // []) as $ip
  | ($installed.plugin_names // []) as $names
  | ($installed.skills // []) as $is
  | (($installed.marketplace_repos // []) + ($watch // [])) as $iw
  | map(select(
      (.id | IN($d[]) | not)
      and (if .kind == "plugin" then (.id | IN($ip[]) | not) and (.name | IN($names[]) | not)
           elif .kind == "skill" then (.skill | IN($is[]) | not)
           elif .kind == "watch" then (.id | IN($iw[]) | not)
           else false end)));

# 配列の配列から、先頭から 1 件ずつ順に取って 1 つの配列にする（[[a1, a2], [b1]] → [a1, b1, a2]）
def kit_interleave: (map(length) | max // 0) as $n | [range(0; $n) as $i | .[] | .[$i] // empty];

# 入力 {needs, catalog, watch_plugins, skills: {<theme>: [...]}, github: {<theme>: [...]}, installed, dismissed, watch}。
# テーマごとに、カタログ 10 件・ウォッチリスト 10 件・skills.sh 5 件・GitHub 5 件を集めて除外し、ソースから順に 1 件ずつ取って
# 12 件まで（1 つのソースが枠を埋めて他のソースを押し出さないように）。全体で 60 件まで
def kit_collect:
  . as $in
  | ($in.catalog | kit_catalog_candidates) as $catalog
  | [ $in.needs[] as $n
      | [ ($catalog | kit_match($n.keywords; 10)),
          (($in.watch_plugins // []) | kit_match($n.keywords; 10)),
          ((($in.skills // {})[$n.theme] // []) | .[0:5]),
          ((($in.github // {})[$n.theme] // []) | .[0:5]) ]
      | map(map(. + {need: $n.theme}) | kit_exclude($in.installed; $in.dismissed; $in.watch))
      | kit_interleave
      | kit_dedupe
      | .[0:12] ]
  | (add // [])
  | kit_dedupe
  | .[0:60];

# 候補の GitHub リポジトリ（owner/repo）。マーケットプレイスの中の相対パスのプラグインは、ウォッチリスト由来ならその
# マーケットプレイスのリポジトリ。GitHub 以外の取得元や、どのリポジトリにあるか分からないもの、形の崩れたものは null
def kit_candidate_repo:
  (if .kind == "watch" then .id
   elif .kind == "skill" then .source
   elif .kind == "plugin" then
     ((.source | if type != "object" then empty
                 elif .source == "github" then .repo
                 elif .source == "url" or .source == "git-subdir" then
                   ((.url // "") | tostring | capture("^https://github\\.com/(?<r>[^/]+/[^/]+?)(\\.git)?/?$") | .r)
                 else empty end)
      // .marketplace_source)
   else null end)
  | if type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$") then . else null end;

# 候補の signals に、リポジトリの情報（$repos: {<owner/repo>: {info: kit_repo_info の出力, contributors: {count}}}）を足す。
# コントリビューターは 100 人までしか数えないので、100 なら "100+"。値のないものは足さない
def kit_with_repo_signals($repos):
  map((kit_candidate_repo) as $r
      | if $r != null and $repos[$r] != null then
          .signals = ((.signals // {}) + ($repos[$r] | {
              stars: ((.info.stargazers_count | numbers) // null),
              contributors: ((.contributors.count | numbers | if . >= 100 then "100+" else . end) // null),
              created_at: ((.info.created_at | strings | .[0:10]) // null),
              pushed_at: ((.info.pushed_at | strings | .[0:10]) // null),
              owner: ((.info.owner_type | strings | if . == "Organization" then "org" else "user" end) // null),
              archived: (if .info.archived == true then true else null end)}
            | with_entries(select(.value != null))))
        else . end);

# ④ の出力を検証して整える。候補にない id は捨てる（モデルの作り話や、説明文に仕込まれた指示で一覧にない導入元へ
# 誘導されるのを防ぐ）。種別・導入元・信頼性の目安は候補の値を使い、モデルからは need・reason・overlap だけを採る。最大 5 件
def kit_recommendations($cands):
  ($cands | INDEX(.id)) as $by
  | [.recommendations[]? | select((.id | type) == "string") | select($by[.id] != null)]
  | kit_dedupe
  | .[0:5]
  | to_entries
  | map(.value as $r
        | $by[$r.id] + {rank: (.key + 1),
                         need: (if (($r.need // "") | tostring) == "" then $by[$r.id].need else ($r.need | tostring) end),
                         reason: (($r.reason // "") | tostring),
                         overlap: (($r.overlap // "") | tostring)});

# 候補 1 件の出どころ（kit discover list の表示用）
def kit_source_label:
  if .kind == "plugin" then
    "マーケットプレイス \(.marketplace)" + (if (.marketplace_source // "") != "" then "（\(.marketplace_source)、未登録）" else "" end)
  elif .kind == "skill" then "skills.sh \(.source)"
  else "GitHub \(.id)" end;

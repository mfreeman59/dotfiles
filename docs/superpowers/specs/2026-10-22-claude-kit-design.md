# claude-kit 設計書 — スキル・プラグインの発見と複数マシン同期

- 日付: 2026-10-22
- 状態: レビュー待ち
- 置き換え対象: skillsh-router（v1、`claude/` 配下）

## 1. 背景

skillsh-router（v1）は、`npx skills add -g` で同じパッケージが 3 回インストールされたらルートに昇格し、以後のプロンプトで直接そのスキルを提案する仕組みだった。導入から 3 ヶ月、`claude/data/routes.json` は一度も更新されなかった。

調査で分かった原因:

1. 学習のトリガー（Claude 経由の `npx skills add -g` の成功）が一度も起きていない。グローバルに入っているのは install.sh が導入した find-skills だけで、9/9 以降のトランスクリプト 122 件にも `skills find` / `skills add` の実行や find-skills の起動はない。
2. 「同一パッケージを 3 回インストール」は 1 台のマシンでは到達できない。一度入れたスキルは残り、以後は Claude Code のスキル一覧から直接起動されるので、再び `skills add` されることがない。
3. ルートの提案内容（導入済みスキルを直接使う）は、Claude Code 標準のスキル一覧と重複している。

ここから得た教訓:

- **L1**: 「Claude が能力ギャップを自覚したら探しに行く」は発火しない。発見は決まったタイミングで、実際の利用データから行う。
- **L2**: コマンド文字列の解析ではなく、ディスク上の実状態を正とする。`/plugin` UI 経由の導入はフックでは拾えない。
- **L3**: 手作業の git 操作に依存すると止まる（dotfiles は 7/13 以降コミットがない）。

## 2. 目的と成功基準

目的:

- **G1**: 日々のセッションの中で、適切なスキルやプラグインが見つかるようにする。
- **G2**: 見つけて使うようになったスキルやプラグインを、複数のマシン間で同期する。

成功基準:

- **S1**: 新しいマシンで dotfiles を clone し、`claude/bootstrap.sh` を 1 回実行すれば同じ構成になる。
- **S2**: あるマシンで入れた・外した・有効化／無効化したものが、手作業なしで他のマシンの次のセッションに反映される。
- **S3**: 週 1 回の分析で関連する候補があれば提案が表示され、`/discover` から確認・導入・却下まで完結する。
- **S4**: 却下した候補は、全マシンで二度と提案されない。

## 3. スコープ

対象:

- ユーザースコープのプラグイン（有効／無効の状態を含む）
- ユーザースコープで登録したマーケットプレイス
- skills.sh から `-g` で導入したスキル
- 自作スキル（kit プラグインの `skills/` に置き、git で同期する）

対象外:

- プロジェクトスコープのプラグインと、各リポジトリの `.claude/skills`（各リポジトリで管理済み）
- claude.ai から同期されるスキル・プラグイン（`~/.claude/skills/synced/`、`~/.claude/plugins/synced/`。一方向でアカウント単位の別の仕組み）
- `settings.json` のその他の設定（permissions、hooks など）
- DB 破壊ガード `guard-db-destructive.sh`（barista 固有。barista リポジトリの `.claude/hooks/` と `.claude/settings.json` で管理する。dotfiles にあった重複コピーと `~/.claude/settings.json` からの登録は 2026-10-22 に削除済み）
- 使っていないスキルの削除提案、スキルの自動アップデート、macOS 以外への対応

## 4. 全体構成

`claude/` をローカルパスのマーケットプレイス `dotfiles` とし、その中に自作プラグイン `kit`（ID は `kit@dotfiles`）を置く。ローカルパスのマーケットプレイスのプラグインはコピーされずに作業ツリーから読み込まれるので、`git pull` した内容が次のセッションからそのまま効く。

```
claude/
├─ .claude-plugin/marketplace.json   マーケットプレイス "dotfiles"（plugins: kit → ./plugins/kit）
├─ manifest.json                     同期の正本（git 管理）
├─ bootstrap.sh                      新しいマシンの初期化（冪等）
├─ README.md
└─ plugins/kit/
   ├─ .claude-plugin/plugin.json
   ├─ hooks/hooks.json               SessionStart、SessionEnd（どちらも bin/kit hook を呼ぶ）
   ├─ skills/discover/SKILL.md       /discover
   ├─ bin/kit                        CLI 本体（§9）
   ├─ lib/                           state.sh / merge.jq / apply.sh / git.sh / catalog.sh / digest.sh / detach.sh
   └─ tests/run.sh
```

| 部品 | 役割 |
|---|---|
| `manifest.json` | 何を入れておくべきかの宣言。全マシン共通 |
| `bin/kit sync` | 実状態・前回同期時点・manifest を 3 者比較し、双方向に反映して git にコミット・プッシュする（§7） |
| `bin/kit discover` | 利用履歴の分析、候補の収集・順位付け、導入・却下（§8） |
| `hooks/hooks.json` | sync と discover を決まったタイミングで起動し、通知を表示する |
| `skills/discover` | `/discover` の操作手順を Claude に教えるスキル |
| `bootstrap.sh` | マーケットプレイス登録、kit の導入、初回同期 |

前提とする Claude Code の仕様（公式ドキュメント code.claude.com/docs/en/plugins/ の install / loading / cli-reference / components より）:

- `claude plugin marketplace add <path>` でローカルディレクトリをマーケットプレイスにでき、そのプラグインは作業ツリーから読み込まれる。
- `claude plugin install|uninstall|enable|disable <id> -s user` で、プラグインを非対話で操作できる。
- プラグインは `hooks/hooks.json` と `bin/` を持てる。フックのコマンドでは `${CLAUDE_PLUGIN_ROOT}` を使う。`bin/` が `PATH` に入るのは Claude の Bash ツールの中だけなので、フックからは `"${CLAUDE_PLUGIN_ROOT}/bin/kit"` と絶対パスで呼ぶ。
- SessionEnd フックの持ち時間は 1.5 秒で、プラグインのフックでは延長できない。フックの `async: true` がプラグインで使えるかはドキュメントに記載がない。そのため kit のフックは、重い処理を完全に切り離したプロセス（§7.1）で起動し、すぐに終わる。
- `settings.json` の `enabledPlugins` / `extraKnownMarketplaces` に載っていて未導入のものは、起動後にバックグラウンドで自動導入される。kit はこの経路に頼らず CLI で明示的に操作するが、CLI の操作結果は同じ `settings.json` に反映される。

依存ツール: `git`、`jq`、`gh`（認証済み）、`node` / `npx`、`claude`。

## 5. manifest.json

```json
{
  "version": 1,
  "marketplaces": {
    "claude-code-workflows": { "source": "github", "repo": "wshobson/agents" },
    "claude-plugins-official": { "source": "github", "repo": "anthropics/claude-plugins-official" }
  },
  "plugins": {
    "figma@claude-plugins-official": true,
    "superpowers@claude-plugins-official": true
  },
  "skills": {
    "some-skill": { "source": "owner/repo" }
  },
  "discovery": {
    "watch": ["owner/repo"],
    "dismissed": [
      { "id": "foo@bar", "at": "2026-10-22", "reason": "既存の superpowers と重複" }
    ]
  }
}
```

| キー | 内容 | 実状態の読み取り元 |
|---|---|---|
| `marketplaces` | ユーザースコープで登録済みのマーケットプレイス。値は `claude plugin marketplace list --json` の要素から `name` と `installLocation` を除いたもの | `claude plugin marketplace list --json` |
| `plugins` | ユーザースコープのプラグイン。値は有効なら `true`、無効なら `false`。未導入のものはキーを持たない | `claude plugin list --json` の `scope == "user"` の要素 |
| `skills` | skills.sh から `-g` で導入したスキル。キーはスキル名、値の `source` は導入元 | `~/.agents/.skill-lock.json` の `.skills` |
| `discovery.watch` | 発見ソースのウォッチリスト（§8.1）。GitHub の `owner/repo` | なし（manifest にのみ存在） |
| `discovery.dismissed` | 却下した候補。`id` はプラグインなら `name@marketplace`、スキルなら `source@name`、ウォッチ候補なら `owner/repo` | なし（manifest にのみ存在） |

管理対象から除外するもの（読み取り時に取り除く）:

- マーケットプレイス `dotfiles` と、プラグイン `kit@dotfiles`（パスがマシンごとに異なるため bootstrap.sh が登録する）
- ソースがローカルパス（`directory` / `file`）のマーケットプレイスと、そのプラグイン（マシンに依存するため。見つけたら `kit status` で「管理対象外」と表示する）
- `~/.agents/.skill-lock.json` 上の `find-skills`（v1 の遺物。移行で削除する）

書式: `jq -S --indent 2` で出力し、キーを常にソートする。差分とマージが行単位で読めるようにするため。

`marketplaces` / `plugins` / `skills` の 3 つを **管理セクション** と呼ぶ。管理セクションは kit が実状態から生成するもので、手で編集しても反映しない（次の同期で上書きされる）。`discovery` は手で編集してよい。

## 6. マシンごとの状態

`~/.local/state/claude-kit/`（git の管理外）

| パス | 内容 |
|---|---|
| `base.json` | 前回の同期で合意した管理セクション（3 者比較の基準 B） |
| `sync.json` | 最後に同期が成功した時刻、項目ごとの連続失敗回数 |
| `notices.json` | ユーザーに表示する通知の待ち行列（`[{level, message, at}]`） |
| `lock/` | 排他用ディレクトリ（`mkdir` の成否でロックする） |
| `sync.log` | 実行ログ（直近 1,000 行まで残す） |
| `catalog.json` | `claude plugin list --available --json` のキャッシュ（24 時間有効） |
| `discover/` | `last-run`、`digest.json`、`needs.json`、`candidates.json`、`recommendations.json`、`watch-cache/` |
| `inspect/<id>/` | 導入前の確認用に shallow clone した候補（読むだけで実行しない） |

## 7. 同期（`kit sync`）

### 7.1 起動するタイミング

| きっかけ | 動作 |
|---|---|
| SessionStart（matcher `startup|resume`、`kit hook session-start`） | ① `notices.json` と未処理のおすすめを読んで通知を出力し（§8.4）、`notices.json` を空にする。② `kit sync` と、それに続く `kit discover maybe-run`（§8.2）を切り離したプロセスで起動する。① はネットワークにアクセスしないので、フックはすぐ終わる |
| SessionEnd（`kit hook session-end`） | `kit sync` を切り離したプロセスで起動して、すぐ終わる |
| `/discover` で導入・却下した直後 | `kit sync` |
| 手動 | `kit sync`、`kit sync --dry-run`、`kit status` |

**切り離したプロセス**: `lib/detach.sh` が perl で fork と `setsid` を行い、標準入出力を `/dev/null` に向けてから `exec` する。子は Claude Code のプロセスグループからもセッションからも外れるので、Claude Code が終了しても動き続ける（このマシンで、親のプロセスグループごと SIGTERM を送っても子が生き残ることを確認済み）。macOS には `setsid` コマンドがないので perl を使う。

SessionEnd の同期は補助的なもの。これが途中で止まっても、次の SessionStart の同期が「ローカルの変更」（L ≠ B）として拾うので、変更が失われることはない。

kit のすべてのフックは、環境変数 `KIT_NESTED=1` が設定されていたら何もせずに終わる（§8.3 の入れ子実行の対策）。

### 7.2 間引きと排他

- 次の両方を満たすときは、何もせずに終わる。並列セッションが多い環境（arabica-01〜05 など）で git にアクセスしすぎないようにするため。
  - ローカルに変更がない（実状態 L が base.json と一致し、作業ツリーの manifest が HEAD と一致する）
  - 最後に同期が成功してから 10 分経っていない
- 同時に起動されたときは `mkdir lock/` に成功した 1 つだけが動き、他は何もせずに終わる。`lock/` が 10 分より古ければ、前回の異常終了とみなして削除する。

### 7.3 管理セクションの 3 者比較

項目（マーケットプレイス名、プラグイン ID、スキル名）ごとに、次の 3 つの値を比べる。値がないことも 1 つの値として扱う。

- **L**: ローカルの実状態
- **B**: `base.json`（前回の同期で合意した値）
- **R**: リモートの manifest（`git show origin/master:claude/manifest.json`。作業ツリーには触れずに読む）

| L と B | R と B | 判定 | 結果 M | このマシンへの操作 |
|---|---|---|---|---|
| 同じ | 同じ | 変更なし | R | なし |
| 違う | 同じ | このマシンで変更された | L | なし（manifest に書く） |
| 同じ | 違う | 他のマシンで変更された | R | R に合わせる |
| 違う | 違う、かつ L = R | 両方で同じ変更 | L | なし |
| 違う | 違う、かつ L ≠ R | 衝突 | 下記 | 下記 |

衝突時は「残す・有効にする」側を採り、通知する（勝手に消す方向には倒さない）:

- 片方が「なし」、もう片方が値を持つ → 値を持つ側
- プラグインが `true` と `false` → `true`
- 両方が値を持ち内容が違う（マーケットプレイスやスキルの導入元が違う）→ R を採る

初めて同期するマシンでは B が空なので、結果は L と R の和集合になる。初回の同期で何かが削除されることはない。

### 7.4 discovery セクションのマージ

`discovery` は実状態を持たないので、git の 3 者として扱う。

- **H**: HEAD の manifest
- **W**: 作業ツリーの manifest（`kit dismiss` / `kit watch add` や手での編集を含む）
- **R**: リモートの manifest

`watch`（文字列の集合）と `dismissed`（`id` をキーとする集合）それぞれについて、次の式で求める。

```
結果 = (R ∪ (W − H)) − (H − W)
```

W で足したものは足し、W で消したものは消し、それ以外は R に従う。

### 7.5 手順

1. 排他ロックを取る（§7.2）。間引きの条件に当てはまれば終わる。
2. L を読む（§5 の読み取り元。除外対象は取り除く）。
3. `git -C <dotfiles> fetch origin`（タイムアウト 10 秒）。失敗したら「オフライン」として扱い、R = HEAD の manifest で手順 4〜5 を行い、M を作業ツリーに書き出して手順 9 に進む（7 と 8 は行わない）。
4. 3 者比較（§7.3）と discovery のマージ（§7.4）で、新しい manifest M と、このマシンへの操作リストを作る。
5. 操作リストを実行する（§7.6）。失敗した項目は `sync.json` の連続失敗回数を増やし、成功した項目は 0 に戻す。失敗した項目も M では R の値のままにする（他のマシンの変更を manifest 上で取り消さないため）。
6. git の前提条件を確認する。dotfiles が master 以外のブランチにある、または rebase / merge / cherry-pick の途中なら、M を作業ツリーに書いて通知し、手順 9 に進む。
7. 作業ツリーの manifest を HEAD に戻してから `git merge --ff-only origin/master`、M を書き出し、`git commit -m "chore(kit): sync from <hostname>" -- claude/manifest.json`（変更があるときだけ）。
8. `origin/master..master` に `chore(kit):` 以外のコミットがあれば push せずに通知する。なければ `git push origin master`。拒否されたら手順 3 からもう 1 回だけやり直す。それでも駄目なら通知して、次回に回す。
9. `base.json` を更新する（下記の規則）。git 操作まで含めて成功したときだけ `sync.json` の成功時刻を更新する。ロックを解除する。

**base.json の更新規則**: 項目ごとに、反映後のローカルの実状態 L′ と、push 後のリモートの manifest R′（push できなかったときは R のまま）が、どちらも M と一致するときだけ B に M の値を書く。それ以外の項目は B を前の値のまま残す。B は「ローカルとリモートの両方で合意できた値」だけを表す。

| 状況 | 次回の判定 |
|---|---|
| ローカルの変更を push できた | L = B = R。変更なし |
| ローカルの変更を push できなかった（オフラインなど） | L ≠ B、R = B。もう一度「このマシンでの変更」として拾う |
| 他のマシンの変更の反映に成功した | L = B = R。変更なし |
| 他のマシンの変更の反映に失敗した | L = B、R ≠ B。もう一度「他のマシンでの変更」として再試行する |

操作の結果が効くのは次のセッションから。プラグインは `/reload-plugins` で現在のセッションにも反映できる。

### 7.6 このマシンへの操作

| 対象 | 追加 | 削除 | 値の変更 |
|---|---|---|---|
| マーケットプレイス | `claude plugin marketplace add <owner/repo か URL> --scope user` | そのマーケットプレイスのプラグインが M にひとつもなければ `claude plugin marketplace remove <name> --scope user`。あれば削除を保留して通知 | 削除してから追加 |
| プラグイン | `claude plugin install <id> -s user`。値が `false` なら続けて `claude plugin disable <id> -s user` | `claude plugin uninstall <id> -s user` | `claude plugin enable|disable <id> -s user` |
| スキル | `npx --yes skills add <source> -s <name> -g -y -a claude-code` | `npx --yes skills remove <name> -g -y` | 削除してから追加 |

マーケットプレイスの追加はプラグインより先に、削除はプラグインより後に行う。`settings.json` を直接書き換えることはしない。

インストール時にコマンドの実行を求めるプラグイン（command-source、`claude plugin install --json` の結果に `shownCommand` が含まれるもの）は自動で入れず、「承認が必要」と通知する。

### 7.7 異常時の動作

git 操作は安全側に倒して止め、必ず通知する。

| 状況 | 動作 |
|---|---|
| オフライン、または fetch に失敗した | ローカルへの反映と manifest の書き出しだけ行う。コミットと push は次回 |
| push が拒否された | fetch からもう 1 回だけやり直す。駄目なら次回 |
| dotfiles が master 以外のブランチ、または rebase / merge / cherry-pick の途中 | git 操作をしない。通知する |
| master に `chore(kit):` 以外のまだ push していないコミットがある | コミットまでは行い、push しない（作業中のコミットを勝手に公開しない）。通知する |
| `merge --ff-only` が、手元の未コミットの変更とぶつかって失敗した | M を作業ツリーに書いて保留し、通知する |
| 項目の反映に失敗した | ログに残して通知し、次回再試行する。同じ項目が 3 回続けて失敗したら、それ以降は再試行せずに通知だけにする（manifest から消えるか、手で `kit sync --retry <項目>` するまで） |
| command-source のプラグイン | 自動では入れない。通知する |
| jq / gh / npx / claude のいずれかがない | 必要とする処理だけ飛ばして通知する。jq か git がなければ何もしない |

### 7.8 `--dry-run`

手順 2〜4 だけ行い、M と manifest の差分、このマシンへの操作リスト、git の前提条件の判定結果を表示して終わる。何も書き換えない。

## 8. 発見（`kit discover`）

### 8.1 発見ソース

原則: **検索は広く、登録は狭く**。検索のためにマーケットプレイスを Claude Code に登録することはしない。

| # | ソース | 取得方法 | 品質の目安 |
|---|---|---|---|
| 1 | 登録済みカタログ（Anthropic プラグインディレクトリ約 3,590 件、claude-plugins-official 約 300 件、登録済みのその他） | `claude plugin list --available --json`（24 時間キャッシュ） | 公式はインストール数。ディレクトリは出どころ |
| 2 | skills.sh | `npx --yes skills find <keywords>` | インストール数 |
| 3 | ウォッチリスト（`discovery.watch`） | `gh api repos/<owner/repo>/contents/.claude-plugin/marketplace.json`（24 時間キャッシュ） | リポジトリのスター数、最終更新日 |
| 4 | GitHub 全体 | `gh api search/code -f q='filename:marketplace.json path:.claude-plugin <keyword>'`（1 回の分析で最大 5 クエリ）、続けて `gh api repos/<r>` | スター 20 以上、180 日以内に push があるものだけ残す |

ソース 4 で見つかったものは個別のプラグインとしては推さず、「ウォッチリストに追加しませんか」という候補（種別 `watch`）として出す。

未登録のマーケットプレイスは、そこにあるプラグインを `/discover` で導入したときに初めて登録され、manifest に記録される。

### 8.2 分析ジョブ

`kit discover maybe-run` は、次の両方を満たすときだけ `kit discover run` を切り離したプロセス（§7.1）で起動する。

- `discover/last-run` から 7 日以上経っている（ファイルがなければ満たす）
- 前回の分析以降、このマシンのトランスクリプトに自分のプロンプトが 20 件以上ある

`kit discover run` の流れ:

| 段階 | 担当 | 入力 → 出力 |
|---|---|---|
| ① 抽出 | スクリプト | `~/.claude/projects/*/*.jsonl`（`subagents/` は除く）のうち前回分析以降の記録 → `digest.json`。自分のプロンプト（`<` で始まるシステム由来のものは除き、1 件 300 字まで、最大 200 件）、Bash コマンドの先頭語の頻度上位 30、Skill / MCP ツールの利用回数、プロジェクト名ごとのセッション数。全体を 60KB 以内に切り詰める |
| ② ニーズ抽出 | `claude -p` | `digest.json` と導入済みのプラグイン・スキルの一覧 → `needs.json`。繰り返している作業のテーマを最大 5 件。各テーマは `theme`（日本語の要約）、`evidence`（根拠となるプロンプトやコマンドの例）、`keywords`（英語の検索語 1〜4 個） |
| ③ 候補収集 | スクリプト | `needs.json` → `candidates.json`。テーマごとに §8.1 のソースを検索し、ソース 1 は名前と説明文の部分一致で上位 10 件、ソース 2 は上位 5 件、ソース 3 はすべて、ソース 4 は条件を満たすもの。導入済みと `dismissed` を除き、全体で最大 60 件 |
| ④ 順位付け | `claude -p` | `needs.json` と `candidates.json` → `recommendations.json`。最大 5 件。合うものがなければ 0 件でよいと指示する |
| ⑤ 保存 | スクリプト | `recommendations.json` を保存し、`last-run` を更新する |

`recommendations.json` の各要素:

```json
{
  "rank": 1,
  "kind": "plugin | skill | watch",
  "id": "name@marketplace | owner/repo@skill | owner/repo",
  "name": "表示名",
  "source": "導入元（マーケットプレイスのソース、skills.sh のパッケージ、GitHub リポジトリ）",
  "need": "対応する needs.json の theme",
  "reason": "推す理由（日本語、2 文以内）",
  "overlap": "既存の機能と重なる点（なければ空文字）",
  "signals": { "installs": 0, "stars": 0, "pushed_at": "YYYY-MM-DD" }
}
```

②と④の `claude -p` は次の形で呼ぶ。

```
cd ~/.local/state/claude-kit/discover && \
KIT_NESTED=1 claude -p \
  --model "${KIT_DISCOVER_MODEL:-sonnet}" \
  --tools "" \
  --safe-mode \
  --no-session-persistence \
  --output-format json \
  --json-schema "<段階ごとのスキーマ>" \
  --max-budget-usd "${KIT_DISCOVER_BUDGET_USD:-1}"
```

### 8.3 安全性

- **プロンプトインジェクション**: 候補の説明文は第三者が書いたテキスト。②と④のモデルには `--tools ""` でツールを一切渡さないので、説明文に指示が仕込まれていても実行される操作はない。影響は順位がゆがむ程度に収まり、最後は必ず人が承認する。
- **入れ子実行**: `--safe-mode` で、フック・インストール済みプラグイン（kit 自身を含む）・CLAUDE.md・スキル・MCP サーバーなどの個人設定をすべて無効にする。認証とモデル選択はそのまま使えるので、claude.ai のログインで動く（`--bare` は API キー認証を必須とするため使わない）。念のため `KIT_NESTED=1` も渡し、kit のフックはこれを見て何もせずに終わる（§7.1）。
- **履歴の汚染**: `--no-session-persistence` で、分析用のセッションがトランスクリプトに残らないようにする（次回の分析の材料に混ざらない）。
- **候補の中身の確認**: `kit discover inspect` は候補を `inspect/<id>/` に `git clone --depth 1` して読むだけで、中のスクリプトは実行しない。

### 8.4 通知

`kit hook session-start` が、次の JSON を標準出力に出す。

```json
{
  "systemMessage": "<ユーザーに見せる通知文>",
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<同じ通知文。Claude が /discover などの話題に応じられるようにするため>"
  }
}
```

`systemMessage` は、フックの共通出力として「ユーザーに表示される」とドキュメントにある。ただし SessionStart で表示されるかは明記されていないため、実装の最初に確かめる（§13）。

- `notices.json` に溜まった通知はすべて表示して、空にする。同じ文面のものは 1 つにまとめる。
- 未処理のおすすめが 1 件以上あれば「🔎 おすすめ N 件 — /discover で確認」と表示する。並列セッションでうるさくならないよう、同じ日には 1 回だけ（`discover/last-notified` に日付を記録）。
- おすすめは、次の分析で置き換わるまで、または `/discover` で全件を処理するまで「未処理」とする。

### 8.5 `/discover`

`skills/discover/SKILL.md` が、Claude に次の手順を教える。

1. **一覧**: `kit discover list` の出力を表で見せる。番号、種別、名前、出どころ、理由、既存との重なり、信頼性の目安（インストール数・スター数・最終更新日）。
2. **「N を入れて」と言われたとき**:
   1. `kit discover inspect <N>` を実行する。候補を shallow clone し、`SKILL.md`、`hooks/hooks.json`、`.mcp.json`、`bin/` / `scripts/` の有無、インストール時に実行されるコマンドを報告する。
   2. Claude がその内容を読み、何をするものか、フック・MCP サーバー・同梱スクリプトの有無、不審な指示（外部への送信、認証情報への言及、無関係なコマンドの実行など）がないかを要約して見せる。
   3. ユーザーの最終的な OK をもらってから `kit discover adopt <N>` を実行する（§8.6）。
3. **「N はいらない」と言われたとき**: 理由を聞き（なければ空でよい）、`kit discover dismiss <N> --reason "<理由>"` を実行する。
4. **ウォッチ候補を承認されたとき**: `kit discover adopt <N>`（種別 `watch` なら `kit watch add <owner/repo>` と同じ動作）。
5. **`/discover <自由文>`**: その場で検索する。Claude が自由文から英語のキーワードを作り、`kit discover search <keywords...>`（§8.2 の③と同じ処理）で候補を得て、このセッションの中で順位付けして見せる。以降は 2〜4 と同じ。v1 の find-skills の役割を置き換える。

`adopt` / `dismiss` / `watch add` は、処理の後に必ず `kit sync` を実行する。`adopt` / `dismiss` した候補は `recommendations.json` から外す（全件なくなれば「未処理のおすすめ」はなくなる）。

### 8.6 導入のコマンド

| 種別 | 条件 | コマンド |
|---|---|---|
| プラグイン | マーケットプレイスが登録済み、または Anthropic プラグインディレクトリ | `claude plugin install <name>@<marketplace> -s user`（ディレクトリなら `<name>@anthropic-plugin-directory`） |
| プラグイン | ウォッチリストなど、未登録のマーケットプレイス | `claude plugin install <name> --marketplace <owner/repo> -s user`（マーケットプレイスも同時に登録される） |
| プラグイン | command-source | まず `--json` を付けて実行し、`shownCommand` をユーザーに見せる。承認されたら `--accept-command <sha256>` を付けて再実行する |
| スキル | — | `npx --yes skills add <owner/repo> -s <name> -g -y -a claude-code` |
| ウォッチ | — | manifest の `discovery.watch` に追加する |

導入したものは、次の `kit sync` で manifest に記録され、他のマシンに広がる。

## 9. `kit` CLI

`plugins/kit/bin/kit`。プラグインが有効な間、Claude の Bash ツールからは名前で呼べる。フックからは `"${CLAUDE_PLUGIN_ROOT}/bin/kit"` で呼ぶ。

| サブコマンド | 動作 |
|---|---|
| `kit hook session-start` / `kit hook session-end` | §7.1。フック専用 |
| `kit sync [--dry-run] [--force] [--retry <項目>]` | §7。`--force` は間引きを無視する。`--retry` は連続失敗で止まった項目を再試行の対象に戻す |
| `kit status` | L と manifest の差分、最後の同期結果、git の前提条件、未処理の通知とおすすめの件数を表示する |
| `kit discover maybe-run` | §8.2 の起動条件を判定し、満たせば `run` を切り離して起動する |
| `kit discover run` | §8.2 の分析ジョブ |
| `kit discover list` | `recommendations.json` を表示する |
| `kit discover search <keywords...>` | §8.2 の③を、指定したキーワードで行い、結果を JSON で出す |
| `kit discover inspect <N か id>` | §8.5 の 2-1 |
| `kit discover adopt <N か id>` | §8.6 を実行し、`kit sync` |
| `kit discover dismiss <N か id> [--reason <text>]` | manifest の `discovery.dismissed` に追加し、`kit sync` |
| `kit watch add|remove <owner/repo>` | manifest の `discovery.watch` を編集し、`kit sync` |

終了コード: 0 は成功（何もしなかった場合を含む）、1 は処理の失敗、2 は使い方の誤り。フックから呼ぶときは常に 0 で終わる（フックの失敗でセッションを止めない）。

## 10. 移行（このマシン）

1. `feat/claude-kit` ブランチで kit を実装し、テストを通す（この間も v1 は動いたまま）。
2. `kit sync --dry-run` で、最初の manifest の内容を確認する（ユーザースコープのプラグイン 11 個、マーケットプレイス 2 件、スキル 0 件になる見込み）。
3. v1 を撤去する。
   1. `claude/uninstall.sh` で、`settings.json` から v1 のフック（SessionStart / UserPromptSubmit / PostToolUse の `run-hook.cmd` を指すもの）を外す。
   2. `~/.claude/skills/skillsh-router` のシンボリックリンクを削除する。
   3. `npx --yes skills remove find-skills -g -y` で find-skills を外す。
4. `bootstrap.sh` を実行する。初回の同期で manifest が作業ツリーに書き出される（このときはまだ `feat/claude-kit` ブランチなので、§7.7 によりコミットと push はされない）。これを実装と一緒にコミットする。
5. リポジトリから v1 一式を削除する: `claude/hooks/`、`claude/lib/`、`claude/bin/`、`claude/data/`、`claude/skills/`、`claude/install.sh`、`claude/uninstall.sh`、`claude/.gitignore` の v1 用の記述。v1 ドキュメントの未コミットの日本語訳（`claude/README.md`、`claude/skills/skillsh-router/SKILL.md`）は破棄する。
6. `claude/README.md` を kit の説明に書き直し、ルートの `README.md` の `claude/` の節を更新する。
7. master にマージして push する。以後は kit の自動同期が動く。

## 11. bootstrap.sh

冪等で、何度実行しても同じ結果になる。

1. 依存ツール（§4）を確認する。足りなければ、入れ方を表示して終わる。
2. v1 が残っていれば撤去する（`settings.json` の `run-hook.cmd` を指すフック、`~/.claude/skills/skillsh-router`、find-skills）。`settings.json` を書き換える前に `~/.claude/backups/` にバックアップを取る。
3. `claude plugin marketplace add <dotfiles>/claude --scope user`（登録済みならスキップ）。
4. `claude plugin install kit@dotfiles -s user`（導入済みならスキップ）。
5. `kit sync --force` で初回の同期を行う。
6. 「Claude Code を再起動してください」と表示する。

## 12. テスト

`plugins/kit/tests/run.sh`（bash と jq だけで動く。外部のテストフレームワークは使わない）。

- **3 者比較**: `lib/merge.jq` を、L・B・R を入力として期待する M と操作リストを並べた表形式のフィクスチャで検証する。§7.3 の表の全行、衝突の 3 パターン、初回同期（B が空）、除外対象を含める。§7.4 の discovery マージも同様に検証する。
- **同期の結合テスト**: 一時ディレクトリに bare リモートと 2 つのクローン（マシン A・B）を作り、`claude`、`npx`、`gh` は呼び出しを記録して決まった JSON を返す偽物に `PATH` で差し替える。`HOME` と状態ディレクトリも一時ディレクトリに向ける。確認するケース:
  - A で追加したものが B に反映される
  - B で削除したものが A からも消える
  - A と B で同じ項目を別々に変更する（衝突）
  - オフライン（fetch が失敗する）
  - push の競合（A と B がほぼ同時に push する）
  - master 以外のブランチ
  - `chore(kit):` 以外の未 push のコミットがある
  - 取り込む変更が未コミットの変更とぶつかる
  - 反映に 3 回続けて失敗する
  - 間引きと排他（10 分以内の再実行、同時起動）
- **発見**: ①の抽出は、フィクスチャのトランスクリプト（システム由来のプロンプトや `subagents/` を含む）で検証する。③の候補収集はフィクスチャのカタログと偽の `npx` / `gh` で検証する。②と④の `claude -p` は、決まった JSON を返す偽物にする。
- **フック**: `KIT_NESTED=1` で何もしないこと、失敗しても終了コードが 0 であること、`kit hook session-end` が 1 秒以内に終わることを確認する。
- **切り離し**: `lib/detach.sh` で起動した子が、親のプロセスグループに SIGTERM を送っても動き続けることを確認する。
- **本番での確認**: 最初は必ず `kit sync --dry-run` で計画を確認してから実行する。

## 13. 実装の最初に確かめること

ドキュメントで確認しきれなかった点。実装の最初の段階で実機で確かめ、結果に応じて対応を切り替える。

| 確かめること | 期待どおりなら | 違ったら |
|---|---|---|
| SessionStart フックの `systemMessage` がユーザーに表示される | §8.4 のとおり | `additionalContext` に「最初の応答の冒頭で、次の通知をユーザーに一度だけ伝える」という指示を入れて、Claude に伝えてもらう |
| `claude plugin install <name>@anthropic-plugin-directory` がマーケットプレイスの追加なしで動く | §8.6 のとおり | そのプラグインのソース（`git-subdir` / `url`）を `--marketplace` に渡す方式に切り替え、manifest にはそのマーケットプレイスを記録する |
| `claude -p --safe-mode --tools "" --json-schema ...` が、claude.ai のログインのまま構造化出力を返す | §8.2 のとおり | `--safe-mode` の代わりに `--setting-sources project` と `KIT_NESTED=1` で入れ子実行を防ぐ |

## 14. 決定事項

| 項目 | 決定 |
|---|---|
| 発見のタイミング | 振り返り型（週 1 回、利用履歴を分析） |
| git 操作の自動化 | 完全自動（manifest だけをコミット・push。条件を満たさないときは止めて通知） |
| 導入の承認 | 候補ごとに承認。却下は全マシンで共有 |
| 全体の構成 | dotfiles をローカルマーケットプレイスにして、自作プラグイン kit として配布する |
| 発見ソース | 公式以外のマーケットプレイスも対象。検索は広く、登録は導入時だけ |
| guard-db-destructive.sh | barista 固有なので同期しない。barista リポジトリ側に一本化し、dotfiles の重複とユーザー設定からの登録は削除した |
| v1 ドキュメントの未コミットの日本語訳 | 破棄する |

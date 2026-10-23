# claude-kit

Claude Code のスキル・プラグインを、日々の利用から見つけ（発見）、複数のマシンで同じ構成に保つ（同期）仕組み。dotfiles の `claude/` をローカルマーケットプレイス `dotfiles` にして、自作プラグイン `kit` として配布している。設計書: [docs/superpowers/specs/2026-10-22-claude-kit-design.md](../docs/superpowers/specs/2026-10-22-claude-kit-design.md)

## セットアップ

```bash
git clone git@github.com:mfreeman59/dotfiles.git ~/dotfiles
~/dotfiles/claude/bootstrap.sh
```

必要なコマンド: git、jq、gh（認証済み）、curl、node（npx）、claude、perl（macOS 標準）。`bootstrap.sh` は何度実行してもよい。

## 普段の動き

- Claude Code のセッション開始時と終了時に、`kit sync` がバックグラウンドで動く。
- このマシンで入れた・外した・有効化／無効化したプラグイン、登録したマーケットプレイス、`npx skills add -g` で入れたスキルは、`claude/manifest.json` に記録され、自動でコミット・push される。
- 他のマシンの変更は、次のセッション開始時に自動で反映される（効くのはその次のセッションから。プラグインは `/reload-plugins` でも反映できる）。
- 問題があると、次のセッション開始時に「kit: …」という通知が出る。

同期するのはユーザースコープのものだけ。プロジェクトスコープのプラグイン、claude.ai から同期されるスキル・プラグイン、ローカルパスのマーケットプレイスは対象外。

## 発見

週に 1 回、Claude Code の利用履歴（`~/.claude/projects` のトランスクリプト）を分析し、繰り返している作業に合うスキル・プラグインを最大 5 件おすすめする。

- セッション開始時に、前回の分析から 7 日以上経ち、その後のプロンプトが 20 件以上あれば、バックグラウンドで分析する。`claude -p` を 2 回使う（ツールなし・個人設定なし・履歴に残さない。モデルは `KIT_DISCOVER_MODEL`、1 回の予算は `KIT_DISCOVER_BUDGET_USD` で変えられる）。失敗したら 1 日後に再試行する。
- おすすめがあると、セッション開始時に「🔎 おすすめ N 件 — /kit:discover で確認」と伝えられる（1 日 1 回）。
- `/kit:discover` で一覧を見て、「N を入れて」「N はいらない」と答える。入れる前に中身を取得して、フック・MCP サーバー・同梱スクリプトを確かめる。
- `/kit:discover <探したいこと>` で、その場で探すこともできる。
- 却下したものは manifest の `discovery.dismissed` に記録され、全マシンで二度と提案されない。

探すところ: 登録済みのマーケットプレイスと Anthropic のプラグインディレクトリ、skills.sh、ウォッチリスト（`discovery.watch`）のマーケットプレイス、GitHub 全体（`.claude-plugin/marketplace.json` を持つリポジトリのうち、スター 20 以上・180 日以内に更新されたもの。ウォッチリストに加えるかを提案する）。検索のためにマーケットプレイスを Claude Code に登録することはしない。登録されるのは、そこにあるプラグインを導入したときだけ。

## 自動で git 操作をしない場合

次のときは manifest の書き出しまでで止めて通知する。

- dotfiles が master 以外のブランチにある、または rebase などの途中
- master に kit 以外の push していないコミットがある（コミットまではする）
- 未コミットの変更と、取り込む変更がぶつかる
- master と origin/master の履歴が、kit 以外のコミットで分岐している
- オフライン（fetch / push できない状態が 24 時間続くと通知する）

## 削除を広げないための歯止め

1 台で起きたことが全マシンでの削除に広がらないよう、次のときは同期を止めて通知する。

- 1 回の同期で 3 件以上の削除（このマシンでの削除と、他のマシンでの削除の反映の合計）を検出した。意図した削除なら `kit sync --allow-removals` で確定する
- `claude/manifest.json` が JSON として壊れている（衝突マーカーなど）
- origin/master の manifest が壊れている、または以前は同期できていたのに見つからない

また、次の操作は自動では行わない。

- マーケットプレイスのソースが他のマシンで変わったときの入れ直し（通知だけする）
- そのマーケットプレイスのプラグインがまだ入っているあいだの、マーケットプレイスの削除（保留する）

プラグインをアンインストールするときは、プラグインのデータを残す（`--keep-data`）。

## コマンド

| コマンド | 内容 |
|---|---|
| `kit status` | 最後の同期、失敗が続いている項目、次の同期の計画を表示する |
| `kit sync` | 今すぐ同期する。`--dry-run` で計画だけ表示、`--force` で間引きを無視 |
| `kit sync --allow-removals` | 歯止めで止めた削除をまとめて確定する |
| `kit sync --retry plugins/<id>` | 3 回続けて失敗して止まった項目の再試行を再開する |
| `kit discover list` | 未処理のおすすめを表示する |
| `kit discover run` | 今すぐ分析する（`claude -p` を使う。前回の分析の後のプロンプトが 20 件未満なら何もしない） |
| `kit discover search <語句...>` | キーワードで候補を探す |
| `kit discover inspect\|adopt\|dismiss <N か id>` | 候補の中身の確認・導入・却下（普段は `/kit:discover` から使う） |
| `kit watch add\|remove <owner/repo>` | 発見のウォッチリストを編集する |

Claude Code の中では `kit` を名前で呼べる。ターミナルからは `~/dotfiles/claude/plugins/kit/bin/kit`。

## ファイル

| パス | 内容 |
|---|---|
| `claude/manifest.json` | 同期の正本。`discovery` 以外は kit が生成するので手で編集しない |
| `claude/plugins/kit/` | kit プラグイン本体 |
| `claude/plugins/kit/skills/discover/` | `/kit:discover` |
| `~/.local/state/claude-kit/` | マシンごとの状態（`sync.log`、`base.json`、`sync.json`、通知、`catalog.json`、発見の分析結果 `discover/`、導入前に取得した候補 `inspect/`） |

## テスト

```bash
~/dotfiles/claude/plugins/kit/tests/run.sh
```

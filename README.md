# dotfiles

macOS 上のシェル・エディタ・git 設定を管理する個人用 dotfiles リポジトリ。

## セットアップ

```bash
git clone <this-repo> ~/dotfiles
~/dotfiles/dotfilesLink.sh
```

`dotfilesLink.sh` は以下のファイルを `$HOME` にシンボリックリンクする（`ln -sfn` で冪等なので、`git pull` 後に何度でも再実行できる）。

- `.vimrc`
- `.bashrc`
- `.zshrc`
- `.gitconfig`
- `.gitignore_global`

## 構成

| ファイル | 役割 |
| --- | --- |
| `.zshrc` | zsh 設定。エイリアス、git 補完のロード、`.zprofile` の読み込み |
| `.bashrc` | bash 設定（Ubuntu 標準ベース） |
| `.gitconfig` | git のユーザー設定、`lg`/`lga` ログエイリアスなど |
| `.gitignore_global` | 全リポジトリ共通の除外パターン（`*~`, `.DS_Store`, `*.swp`） |
| `.vimrc` | vim 設定（インデント、ウィンドウ操作キーマップ、syntastic） |
| `_git` | zsh 用 git 補完スクリプト |
| `.git-completion.bash` | bash 用 git 補完の実体スクリプト |
| `dotfilesLink.sh` | 上記 5 ファイルを `$HOME` にリンクするセットアップスクリプト |

### git 補完の仕組み

zsh と bash で読み込み経路が異なる。

- **bash**: `.bashrc` が `.git-completion.bash` を直接 `source` する。
- **zsh**: `.zshrc` が `fpath` に `~/dotfiles` を追加し、`compinit` が `_git` を zsh 補完関数として検出する。`_git` は `zstyle ':completion:*:*:git:*' script ~/dotfiles/.git-completion.bash`（`.zshrc` で設定）で指定されたパスを使い、`.git-completion.bash` を `GIT_SOURCING_ZSH_COMPLETION=y` 環境下で読み込んで、bash 補完のロジックをそのまま再利用している。

`_git` と `.git-completion.bash` は `dotfilesLink.sh` の対象外で、絶対パス参照のまま使う設計（シンボリックリンクしない）。

## claude/ — skillsh-router

`claude/` 配下は独立したサブシステムで、Claude Code の find-skills に学習型ルーティング層を追加する **skillsh-router** を含む。セットアップ・仕組みの詳細は [claude/README.md](claude/README.md) を参照。

```bash
cd ~/dotfiles/claude
./install.sh
```

`dotfilesLink.sh` とは別系統のインストーラーで、`~/.claude/settings.json` へのフック登録（SessionStart / UserPromptSubmit / PostToolUse）と `~/.claude/skills/skillsh-router` へのシンボリックリンクを行う。

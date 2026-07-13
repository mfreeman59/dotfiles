# some more ls aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# claude code
alias cc='claude'
alias ccc='claude --continue'
alias ccd='claude --dangerously-skip-permissions'
alias ccr='claude --resume'

# gitの補完
zstyle ':completion:*:*:git:*' script ~/dotfiles/.git-completion.bash
fpath=(~/dotfiles $fpath)
autoload -Uz compinit && compinit

# .zprofileの読み込み
# ログインシェルでは zsh が .zprofile → /etc/zshrc → ~/.zshrc の順で
# 読み込まれ、/etc/zshrc が PS1 をデフォルト値にリセットしてしまう
# （starship 等 .zprofile 側の PROMPT 設定が消える）。そのため
# ログインシェルでも .zshrc の最後で再度 .zprofile を読み込み直す
[ -f ~/.zprofile ] && source ~/.zprofile

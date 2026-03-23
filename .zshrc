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
source ~/.zprofile
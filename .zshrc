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
source ~/dotfiles/.git-completion.bash

# .zprofileの読み込み
source ~/.zprofile
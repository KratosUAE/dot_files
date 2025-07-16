 # Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="fino-time"

plugins=(
git compleat 
zsh-autosuggestions 
colorize 
history
zsh-syntax-highlighting
colored-man-pages)

ZSH_COLORIZE_STYLE="colorful"

source $ZSH/oh-my-zsh.sh

# User configuration

alias apdate="sudo apt update"
alias apgrade="sudo apt upgrade"
alias apti="sudo apt install"
alias du="du -h"
alias df='df -h'
alias duh='du -sh *'
alias ccat="pygmentize -g"
alias catc="batcat --style=plain --paging=never"
alias SmokeT="sudo nano /etc/smokeping/config.d/Targets"
alias SmokeP="sudo nano /etc/smokeping/config.d/Probes"
alias docker="sudo docker"
alias dhist="history -d"
alias zshrc='nano ~/.zshrc'
alias myip='curl ifconfig.me'
alias -g G='| grep'
alias ll='ls -alF --color=auto'
alias gs='git status'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias rm='rm -i'
alias grep='grep --color=auto'
alias psg='ps aux | grep -v grep | grep'
alias ports='sudo lsof -i -P -n'
alias f='find . -name'
alias netcon='ss -tulwn'
alias usage='du -sh .'


#Functions

source ~/.aux/functions/zsh_functions
source ~/.aux/functions/language


# Directories

export REPOS="$HOME/Repos"
export GITUSER="kensi-rus"
export GHREPOS="$REPOS/github.com/$GITUSER"
export DOTFILES="$GHREPOS/dotfiles"
export LAB="$GHREPOS/lab"
export SCRIPTS="$DOTFILES/scripts"

export GOBIN="$HOME/.local/bin"
export GOPRIVATE="github.com/$GITUSER/*,gitlab.com/$GITUSER/*"


# Path


export PATH=$PATH:/usr/local/go/bin
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin
export PATH=$PATH:/usr/local/tinygo/bin


path=(
    $path                           # Keep existing PATH entries
    $HOME/.aux/bin
    $HOME/.aux/scripts
    $HOME/.local/bin
    $SCRIPTS
)


### Remove duplicate entries and non-existent directories
typeset -U path
path=($^path(N-/))
###
export PATH


# Настройки истории
HISTFILE=~/.zsh_history       # Файл для сохранения истории
HISTSIZE=100000               # Количество строк в истории
SAVEHIST=100000               # Количество строк для сохранения между сессиями
setopt EXTENDED_HISTORY       # Включаем таймстемпы в истории
setopt HIST_IGNORE_SPACE  # Don't save when prefixed with space
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY
setopt SHARE_HISTORY
setopt INC_APPEND_HISTORY

#ZSH settings
setopt AUTO_CD
setopt CORRECT
setopt NUMERIC_GLOB_SORT
setopt HIST_FIND_NO_DUPS
setopt AUTO_PARAM_SLASH
setopt EXTENDED_GLOB
setopt PUSHD_SILENT
setopt ALWAYS_TO_END
setopt INTERACTIVE_COMMENTS




# Key Bindings
bindkey '^R' history-incremental-search-backward
bindkey '^A' beginning-of-line
bindkey '^E' end-of-line






export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
REPORTTIME=3

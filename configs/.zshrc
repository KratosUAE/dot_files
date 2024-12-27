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
alias ccat="pygmentize -g"
alias catc="batcat --style=plain --paging=never"
alias SmokeT="sudo nano /etc/smokeping/config.d/Targets"
alias SmokeP="sudo nano /etc/smokeping/config.d/Probes"
alias docker="sudo docker"
alias dhist="history -d"

#Functions

source ~/.aux/functions/zsh_functions



# Directories

export REPOS="$HOME/Repos"
export GITUSER="kensi-rus"
export GHREPOS="$REPOS/github.com/$GITUSER"
export DOTFILES="$GHREPOS/dotfiles"
export LAB="$GHREPOS/lab"
export SCRIPTS="$DOTFILES/scripts"

export GOBIN="$HOME/.local/bin"
export GOPRIVATE="github.com/$GITUSER/*,gitlab.com/$GITUSER/*"

export TMUX_CONF=~/.aux/configs/tmux.config




export PATH=$PATH:/usr/local/go/bin
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin

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


##export NVM_DIR="$HOME/.nvm"
##[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
##[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_comple


# Включаем формат таймстемпа (например, дату и время)
#export HIST_STAMPS="yyyy-mm-dd hh:mm:ss"

# Настройки истории
HISTFILE=~/.zsh_history       # Файл для сохранения истории
HISTSIZE=100000               # Количество строк в истории
SAVEHIST=100000               # Количество строк для сохранения между сессиями
setopt EXTENDED_HISTORY       # Включаем таймстемпы в истории
setopt HIST_IGNORE_SPACE  # Don't save when prefixed with space
setopt HIST_IGNORE_DUPS   # Don't save duplicate lines




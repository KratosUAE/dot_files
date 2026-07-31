# ============================================================
#  ~/.zshrc — чистый zsh + starship (перенос Windows/PowerShell-сетапа)
#  Бэкап прежнего oh-my-zsh конфига: ~/.zshrc.omz-backup-*
# ============================================================

# ------------------------------------------------------------
#  Directories / переменные окружения
# ------------------------------------------------------------
export REPOS="$HOME/Repos"
export GITUSER="kensi-rus"
export GHREPOS="$REPOS/github.com/$GITUSER"
export DOTFILES="$GHREPOS/dotfiles"
export LAB="$GHREPOS/lab"
export SCRIPTS="$DOTFILES/scripts"
export GOBIN="$HOME/.local/bin"
export GOPRIVATE="github.com/$GITUSER/*,gitlab.com/$GITUSER/*"

# ------------------------------------------------------------
#  PATH
# ------------------------------------------------------------
export PATH=$PATH:/usr/local/go/bin
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin
export PATH=$PATH:/usr/local/tinygo/bin

path=(
    $HOME/.local/bin                # ПЕРВЫМ: свежие starship/fzf важнее системных
    $HOME/.aux/bin
    $HOME/.aux/scripts
    $SCRIPTS
    $path                           # Keep existing PATH entries
)
### Remove duplicate entries and non-existent directories
typeset -U path
path=($^path(N-/))
###
export PATH

# ------------------------------------------------------------
#  История
# ------------------------------------------------------------
HISTFILE=~/.zsh_history       # Файл для сохранения истории
HISTSIZE=100000               # Количество строк в истории
SAVEHIST=100000               # Количество строк для сохранения между сессиями
setopt EXTENDED_HISTORY       # Включаем таймстемпы в истории
setopt HIST_IGNORE_SPACE      # Don't save when prefixed with space
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY
setopt SHARE_HISTORY
setopt INC_APPEND_HISTORY
setopt HIST_FIND_NO_DUPS

# ------------------------------------------------------------
#  ZSH settings
# ------------------------------------------------------------
setopt AUTO_CD
setopt CORRECT
setopt NUMERIC_GLOB_SORT
setopt AUTO_PARAM_SLASH
setopt EXTENDED_GLOB
setopt PUSHD_SILENT
setopt ALWAYS_TO_END
setopt INTERACTIVE_COMMENTS

REPORTTIME=3

# ------------------------------------------------------------
#  Автодополнение (раньше это делал oh-my-zsh)
# ------------------------------------------------------------
autoload -Uz compinit && compinit -d "$HOME/.zcompdump"

zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' special-dirs true
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'

# ------------------------------------------------------------
#  Плагины
# ------------------------------------------------------------
# Серые подсказки по истории (аналог PSReadLine predictions)
[[ -f ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && \
    source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh

# ------------------------------------------------------------
#  fzf: Ctrl+R история, Ctrl+T файлы, Alt+C переход в каталог
# ------------------------------------------------------------
if command -v fzf >/dev/null 2>&1; then
    source <(fzf --zsh)
    # ВНИМАНИЕ: fd в Debian/Ubuntu называется fdfind. В этих переменных
    # алиасы не работают (команда идёт через sh), поэтому именно fdfind.
    export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --exclude .git'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
fi

#Functions
# ВАЖНО: подключается ДО алиасов — там есть свой блок алиасов (exa/bat/rg),
# и алиасы ниже должны иметь приоритет над ним.
[[ -f ~/.aux/.env ]] && source ~/.aux/.env
source ~/.aux/functions/zsh_functions
source ~/.aux/functions/language

# ------------------------------------------------------------
#  Алиасы: rust-утилиты (аналог Terminal-Icons)
# ------------------------------------------------------------
if command -v eza >/dev/null 2>&1; then
    alias ls='eza --icons'
    alias ll='eza -la --icons --git'
    alias la='eza -a --icons'
    alias l='eza --icons'
    alias tree='eza --tree --icons'
else
    alias ll='ls -alF --color=auto'
    alias la='ls -A --color=auto'
    alias l='ls -CF --color=auto'
fi

# В Debian/Ubuntu бинарь bat называется batcat
if command -v batcat >/dev/null 2>&1; then
    export BAT_THEME="Dracula"   # тема подсветки: markdown-разметка не красная
    alias bat='batcat'       # полный вид: номера строк, рамка, имя файла
    alias cat='batcat -pp'   # -pp = --style=plain --paging=never: без номеров и без less
fi

command -v btop >/dev/null 2>&1 && alias htop='btop'

# ------------------------------------------------------------
#  Алиасы: собственные
# ------------------------------------------------------------
alias apdate="sudo apt update"
alias apgrade="sudo apt upgrade"
alias apti="sudo apt install"
alias du="du -h"
alias df='df -h'
alias duh='du -sh *'
# ccat намеренно не задаётся здесь — используется функция colorize_cat
# из ~/.aux/functions/zsh_functions
alias catc="batcat --style=plain --paging=never"
alias SmokeT="sudo nano /etc/smokeping/config.d/Targets"
alias SmokeP="sudo nano /etc/smokeping/config.d/Probes"
alias dhist="history -d"
alias zshrc='nano ~/.zshrc'
alias myip='curl ifconfig.me'
alias -g G='| grep'
alias gs='git status'
alias rm='rm -i'
# grep намеренно не задаётся здесь — в zsh_functions он уже назначен на rg
alias psg='ps aux | grep -v grep | grep'
alias ports='sudo lsof -i -P -n'
alias f='find . -name'
alias netcon='ss -tulwn'
alias usage='du -sh .'
alias agentos="$HOME/.agent-os/setup/project.sh"
alias bl='~/.aux/scripts/bl.sh'
alias whl='~/.aux/scripts/whl.sh'
alias traefik='~/.aux/scripts/traefik.sh'
alias waf='~/.aux/scripts/waf.sh'
alias clippy='cargo clippy -- -D warnings'
alias cargofmt='cargo fmt -- --check'
alias check_code_lines='cloc . --exclude-dir=node_modules,dist,build,target,.git,.next,out,coverage --exclude-lang=D\n'
alias restart_resolve='sudo systemctl restart systemd-resolved'
alias s='cd $(fd --type d --hidden . ~ | fzf)'
alias back='docker compose exec crawler /teams_con crawl --backfill 1'
alias cap='claude update'
alias clac='claude -c'

# ------------------------------------------------------------
#  Key Bindings (раньше это делал oh-my-zsh)
# ------------------------------------------------------------
bindkey -e

autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search

bindkey '^[[A' up-line-or-beginning-search    # ↑ — поиск по началу строки
bindkey '^[[B' down-line-or-beginning-search  # ↓
bindkey '^[OA' up-line-or-beginning-search
bindkey '^[OB' down-line-or-beginning-search
bindkey '^[[H' beginning-of-line              # Home
bindkey '^[[F' end-of-line                    # End
bindkey '^[[3~' delete-char                   # Delete
bindkey '^[[1;5C' forward-word                # Ctrl+→
bindkey '^[[1;5D' backward-word               # Ctrl+←
bindkey '^A' beginning-of-line
bindkey '^E' end-of-line

# Ctrl+T перехватывается клиентом Termius (новая вкладка), поэтому вставка
# пути к файлу через fzf перевешена на Ctrl+F. Прежнее значение ^F было
# forward-char — та же функция доступна стрелкой →.
bindkey '^F' fzf-file-widget

# Ctrl+R намеренно НЕ переопределяется — он занят fzf (см. секцию fzf выше).
# Прежнее значение было: bindkey '^R' history-incremental-search-backward

# ------------------------------------------------------------
#  NVM (ленивая загрузка)
# ------------------------------------------------------------
export NVM_DIR="$HOME/.nvm"
nvm() {
    unset -f nvm
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    nvm "$@"
}

# Активная версия Node сразу в PATH — БЕЗ загрузки самого nvm.
# Это экономит ~1.8 с на каждом старте шелла (profiling: nvm_auto = 97% времени).
# node/npm/npx/corepack/tsc доступны мгновенно; сам nvm подгрузится лениво
# функцией nvm() выше при первом вызове `nvm ...`.
# Обёртки node()/npm() намеренно убраны — они будили бы nvm и сводили выигрыш к нулю.
if [[ -d "$NVM_DIR/versions/node" ]]; then
    _nvm_versions=("$NVM_DIR"/versions/node/*(N/on))
    (( $#_nvm_versions )) && path=("${_nvm_versions[-1]}/bin" $path)
    unset _nvm_versions
fi

# Show active tmux sessions on login
if command -v tmux &> /dev/null && [[ -o interactive ]] && [[ -z "$TMUX" ]]; then
    tmux_sessions=$(tmux list-sessions 2>/dev/null)
    if [[ $? -eq 0 && -n "$tmux_sessions" ]]; then
        echo "Active tmux sessions:"
        echo "$tmux_sessions"
        echo "Use 'tmux attach -t <session>' to connect or 'tmux attach' for the last session"
        echo ""
    fi
fi

# Полная загрузка NVM здесь намеренно удалена — она занимала 1.8 с при каждом
# старте шелла. Заменена на добавление bin активной версии в PATH (см. выше).
# Вернуть прежнее поведение, если понадобится:
#   [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
#   [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Android SDK
export ANDROID_HOME=$HOME/Android/Sdk
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools

export PATH="$HOME/.local/share/ragcode/bin:$PATH"

# ------------------------------------------------------------
#  Промпт starship
# ------------------------------------------------------------
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"

# ------------------------------------------------------------
#  zoxide (после compinit)
# ------------------------------------------------------------
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"

# ------------------------------------------------------------
#  Подсветка синтаксиса — ДОЛЖНА быть самой последней строкой
# ------------------------------------------------------------
[[ -f ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && \
    source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

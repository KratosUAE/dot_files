#!/bin/bash
#
# Развёртывание shell-окружения на новой машине.
#
# Схема: чистый zsh (без oh-my-zsh) + starship + fzf/zoxide/bat/eza/ripgrep.
# Плагины zsh лежат в ~/.zsh/, конфиги — симлинками из этого репозитория.
#
# Скрипт идемпотентен: повторный запуск не ломает уже установленное.

set -u

CONFIG_DIR="$HOME/.aux/configs"
ZSH_PLUGIN_DIR="$HOME/.zsh"
LOCAL_BIN="$HOME/.local/bin"

# Файлы, которые симлинкуются в $HOME
FILES=(".tmux.conf" ".nanorc" ".zshrc" ".zshenv")

# Плагины zsh: имя → репозиторий
PLUGINS=("zsh-autosuggestions" "zsh-syntax-highlighting")

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
warn()  { echo -e "\033[1;33m[!]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[✓]\033[0m $*"; }

# ------------------------------------------------------------
#  Пакетный менеджер
# ------------------------------------------------------------
detect_pm() {
  if   command -v apt    &>/dev/null; then echo "apt"
  elif command -v dnf    &>/dev/null; then echo "dnf"
  elif command -v pacman &>/dev/null; then echo "pacman"
  elif command -v zypper &>/dev/null; then echo "zypper"
  else echo ""; fi
}

PM=$(detect_pm)
if [ -z "$PM" ]; then
  warn "Пакетный менеджер не определён — системные пакеты придётся ставить вручную."
fi

pkg_install() {
  local pkgs=("$@")
  [ ${#pkgs[@]} -eq 0 ] && return 0
  case "$PM" in
    apt)    sudo apt update -qq && sudo apt install -y "${pkgs[@]}" ;;
    dnf)    sudo dnf install -y "${pkgs[@]}" ;;
    pacman) sudo pacman -S --noconfirm "${pkgs[@]}" ;;
    zypper) sudo zypper install -y "${pkgs[@]}" ;;
    *)      warn "Пропускаю установку: ${pkgs[*]}" ;;
  esac
}

mkdir -p "$LOCAL_BIN" "$ZSH_PLUGIN_DIR" "$HOME/.config"

# ------------------------------------------------------------
#  1. Базовые пакеты
# ------------------------------------------------------------
info "Проверяю системные пакеты..."

NEED=()
command -v zsh     &>/dev/null || NEED+=("zsh")
command -v git     &>/dev/null || NEED+=("git")
command -v curl    &>/dev/null || NEED+=("curl")
command -v zoxide  &>/dev/null || NEED+=("zoxide")
command -v btop    &>/dev/null || NEED+=("btop")
# В Debian/Ubuntu бинари называются batcat и fdfind
command -v batcat  &>/dev/null || command -v bat &>/dev/null || NEED+=("bat")
command -v fdfind  &>/dev/null || command -v fd  &>/dev/null || NEED+=("fd-find")
command -v eza     &>/dev/null || NEED+=("eza")
command -v rg      &>/dev/null || NEED+=("ripgrep")

if [ ${#NEED[@]} -gt 0 ]; then
  info "Устанавливаю: ${NEED[*]}"
  pkg_install "${NEED[@]}"
else
  ok "Все системные пакеты уже на месте."
fi

# ------------------------------------------------------------
#  2. starship (промпт)
# ------------------------------------------------------------
if command -v starship &>/dev/null; then
  ok "starship уже установлен ($(starship --version | head -1))."
else
  info "Устанавливаю starship в $LOCAL_BIN..."
  curl -sS https://starship.rs/install.sh | sh -s -- -b "$LOCAL_BIN" -y
fi

# ------------------------------------------------------------
#  3. fzf
# ------------------------------------------------------------
# Нужна версия с поддержкой `fzf --zsh` (0.48+). В репах Ubuntu 24.04
# лежит 0.44, которая её не умеет — тогда берём бинарь с GitHub.
if command -v fzf &>/dev/null && fzf --zsh &>/dev/null; then
  ok "fzf подходящей версии уже установлен ($(fzf --version))."
else
  info "Ставлю свежий fzf в $LOCAL_BIN (системный отсутствует или слишком старый)..."
  FZF_TAG=$(curl -s https://api.github.com/repos/junegunn/fzf/releases/latest \
            | grep -oP '"tag_name": "\K[^"]+')
  if [ -n "${FZF_TAG:-}" ]; then
    FZF_VER="${FZF_TAG#v}"
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)  FZF_ARCH="amd64" ;;
      aarch64) FZF_ARCH="arm64" ;;
      *)       FZF_ARCH="" ;;
    esac
    if [ -n "$FZF_ARCH" ]; then
      TMP=$(mktemp -d)
      curl -sSL -o "$TMP/fzf.tgz" \
        "https://github.com/junegunn/fzf/releases/download/${FZF_TAG}/fzf-${FZF_VER}-linux_${FZF_ARCH}.tar.gz" \
        && tar xzf "$TMP/fzf.tgz" -C "$LOCAL_BIN" fzf \
        && ok "fzf ${FZF_VER} установлен."
      rm -rf "$TMP"
    else
      warn "Неизвестная архитектура $ARCH — fzf пропущен."
    fi
  else
    warn "Не удалось узнать последнюю версию fzf — пропускаю."
  fi
fi

# ------------------------------------------------------------
#  4. Плагины zsh (в ~/.zsh/, НЕ в oh-my-zsh)
# ------------------------------------------------------------
for PLUGIN in "${PLUGINS[@]}"; do
  if [ -d "$ZSH_PLUGIN_DIR/$PLUGIN" ]; then
    ok "Плагин $PLUGIN уже установлен."
  else
    info "Клонирую $PLUGIN..."
    git clone --depth 1 "https://github.com/zsh-users/$PLUGIN" "$ZSH_PLUGIN_DIR/$PLUGIN"
  fi
done

# ------------------------------------------------------------
#  5. Симлинки конфигов
# ------------------------------------------------------------
info "Создаю симлинки конфигов..."

for FILE in "${FILES[@]}"; do
  if [ ! -f "$CONFIG_DIR/$FILE" ]; then
    warn "Пропускаю $FILE: нет в $CONFIG_DIR"
    continue
  fi
  # Существующий обычный файл сохраняем, симлинк просто заменяем
  if [ -f "$HOME/$FILE" ] && [ ! -L "$HOME/$FILE" ]; then
    mv "$HOME/$FILE" "$HOME/$FILE.backup-$(date +%Y%m%d-%H%M%S)"
    warn "$FILE существовал — сохранён как $FILE.backup-*"
  fi
  ln -sfn "$CONFIG_DIR/$FILE" "$HOME/$FILE"
  ok "$FILE → $CONFIG_DIR/$FILE"
done

# Конфиг starship живёт в ~/.config/
if [ -f "$CONFIG_DIR/starship.toml" ]; then
  if [ -f "$HOME/.config/starship.toml" ] && [ ! -L "$HOME/.config/starship.toml" ]; then
    mv "$HOME/.config/starship.toml" "$HOME/.config/starship.toml.backup-$(date +%Y%m%d-%H%M%S)"
    warn "starship.toml существовал — сохранён как starship.toml.backup-*"
  fi
  ln -sfn "$CONFIG_DIR/starship.toml" "$HOME/.config/starship.toml"
  ok "starship.toml → $CONFIG_DIR/starship.toml"
fi

# ------------------------------------------------------------
#  6. Агенты Claude Code
# ------------------------------------------------------------
info "Настраиваю агентов Claude Code..."
mkdir -p "$HOME/.config/claude-code"
ln -sfn "$HOME/.aux/claude-agents" "$HOME/.config/claude-code/agents"
ok "Симлинк агентов создан."

# ------------------------------------------------------------
#  7. Шелл по умолчанию
# ------------------------------------------------------------
if [ "$SHELL" != "$(command -v zsh)" ]; then
  info "Переключаю шелл по умолчанию на zsh..."
  chsh -s "$(command -v zsh)"
else
  ok "zsh уже шелл по умолчанию."
fi

# ------------------------------------------------------------
#  Итог
# ------------------------------------------------------------
echo
ok "Готово. Выполните 'exec zsh' или откройте новый терминал."
echo
warn "Nerd Font ставится на КЛИЕНТЕ, а не здесь: если работаете по SSH,"
warn "шрифт (JetBrainsMono Nerd Font) нужен в вашем терминале, иначе"
warn "иконки в промпте будут квадратиками."

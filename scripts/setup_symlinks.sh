#!/bin/bash

# Директория, откуда будут перенесены конфигурационные файлы
CONFIG_DIR="$HOME/.aux/configs"

# Список файлов для переноса и создания симлинков
FILES=(".tmux.conf" ".nanorc" ".zshrc")

# Проверка наличия Zsh
if ! command -v zsh &>/dev/null; then
  echo "Zsh не установлен. Устанавливаем..."
  sudo apt update && sudo apt install -y zsh || sudo yum install -y zsh
else
  echo "Zsh уже установлен."
fi

# Проверка наличия Oh My Zsh
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  echo "Oh My Zsh не найден. Устанавливаем..."
  sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)" --unattended
else
  echo "Oh My Zsh уже установлен."
fi

# Перенос файлов и создание символических ссылок
for FILE in "${FILES[@]}"; do
  if [ -f "$HOME/$FILE" ] || [ -L "$HOME/$FILE" ]; then
    echo "Removing existing $FILE..."
    rm -f "$HOME/$FILE"  # Удаление существующего файла или симлинка
  fi

  if [ -f "$CONFIG_DIR/$FILE" ]; then
    echo "Creating symlink for $FILE..."
    ln -s "$CONFIG_DIR/$FILE" "$HOME/$FILE"
  else
    echo "Skipping $FILE: not found in $CONFIG_DIR"
  fi
done

# Установка плагинов Oh My Zsh
ZSH_CUSTOM=${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}
PLUGINS=("zsh-autosuggestions" "zsh-syntax-highlighting")

for PLUGIN in "${PLUGINS[@]}"; do
  if [ ! -d "$ZSH_CUSTOM/plugins/$PLUGIN" ]; then
    echo "Installing plugin: $PLUGIN..."
    git clone "https://github.com/zsh-users/$PLUGIN" "$ZSH_CUSTOM/plugins/$PLUGIN"
  else
    echo "Plugin $PLUGIN already installed."
  fi
done

# Setup Claude Code agents symlink
echo "Setting up Claude Code agents..."
mkdir -p "$HOME/.config/claude-code"
if [ -L "$HOME/.config/claude-code/agents" ]; then
    rm -f "$HOME/.config/claude-code/agents"
fi
ln -sf "$HOME/.aux/claude-agents" "$HOME/.config/claude-code/agents"
echo "Claude Code agents symlink created."

# Обновление конфигурации
echo "Переключение на Zsh..."
chsh -s $(which zsh)

echo "All done! Перезапустите терминал или выполните команду 'zsh' для входа в новую оболочку."

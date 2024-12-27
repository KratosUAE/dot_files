#!/bin/bash

# Директория, куда будут перенесены конфигурационные файлы
CONFIG_DIR="$HOME/.aux/configs"

# Список файлов для переноса и создания симлинков
FILES=(".tmux.conf" ".nanorc" ".zshrc")

# Создание директории для конфигов, если её ещё нет
#mkdir -p "$CONFIG_DIR"

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

echo "All done!"

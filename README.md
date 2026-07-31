# .aux

Dotfiles + скрипты для администрирования Linux серверов. Конфиги синхронизируются между машинами через git.

## Установка

```bash
git clone https://github.com/KratosUAE/dot_files.git ~/.aux
~/.aux/scripts/setup_symlinks.sh
```

Скрипт установит zsh, starship, fzf/zoxide/bat/eza/ripgrep, создаст симлинки на конфиги
и подтянет плагины zsh в `~/.zsh/`. Повторный запуск безопасен — уже установленное пропускается.

> **Nerd Font ставится на клиенте, а не на сервере.** При работе по SSH шрифт
> (JetBrainsMono Nerd Font) нужен в вашем терминале, иначе иконки в промпте
> будут квадратиками.

## Структура

```
scripts/        # Скрипты администрирования
functions/      # Функции zsh (lazy load, systemctl обёртки, tmux, git)
configs/        # Конфиги zsh, tmux, nano (симлинкуются в ~/)
claude-agents/  # Custom агенты для Claude Code
.env            # Переменные окружения (git profile, API токены)
```

## Скрипты

| Команда | Описание |
|---------|----------|
| `bl` | CrowdSec blocklist — бан/разбан IP, список решений |
| `whl` | CrowdSec whitelist — добавить/удалить IP из whitelist |
| `traefik` | Мониторинг Traefik — логи, SSL сертификаты, аналитика top IP/URL/статусов, geo по ipinfo.io |
| `waf` | ModSecurity CRS — статус, блокировки, paranoia level, whitelist, тестирование |
| `deploy.sh` | Развёртывание бинарника в /opt с конфигами и правами |
| `create_unit.sh` | Генератор systemd unit файлов |
| `sscontrol.sh` | Управление ShadowSocks (Docker) + iptables NAT |
| `pull_zammad.sh` | Бэкап Zammad с remote сервера, ротация по дням |
| `go-check.sh` | Валидация Go проектов — vet, fmt, staticcheck, tests, vulncheck |
| `vasp-mount.sh` | Монтирование/размонтирование образов дисков |
| `setup_symlinks.sh` | Bootstrap — zsh, starship, CLI-утилиты, симлинки, плагины |

## Функции zsh

**Systemctl обёртки:** `sstatus`, `sstart`, `sstop`, `srestart`

**Tmux:** `tmux2` (2 панели), `tmux3` (3 панели T-layout)

**Git синхронизация:** `conf2git "msg"` — коммит + push, `git2conf` — pull

**Lazy loading:** cargo/rustc/rustup, colorize, colored-man-pages — загружаются при первом вызове для быстрого старта shell.

## Конфиги

- **.zshrc** — чистый zsh (без фреймворка): compinit, алиасы, PATH, история, keybindings
- **.zshenv** — `skip_global_compinit=1` (гасит compinit из `/etc/zsh/zshrc`), cargo env
- **starship.toml** — промпт: палитра Ubuntu, модули git/python/go/rust/node/react/docker,
  правая строка с памятью и временем выполнения. Симлинкуется в `~/.config/`
- **.tmux.conf** — keybindings, theme, TPM плагины, status bar
- **.nanorc** — подсветка синтаксиса

### Shell-окружение

| Компонент | Назначение |
|-----------|------------|
| starship | промпт (`~/.local/bin`, конфиг в `~/.config/starship.toml`) |
| fzf | Ctrl+R история, Ctrl+F файлы, Alt+C каталоги. Нужна версия ≥0.48 (`fzf --zsh`) |
| zoxide | умный `cd` по частоте переходов, заменил плагин `z` |
| eza / bat / ripgrep / fd | замены ls / cat / grep / find |
| zsh-autosuggestions | серые подсказки из истории (`~/.zsh/`) |
| zsh-syntax-highlighting | подсветка команд, подключается последней строкой `.zshrc` |

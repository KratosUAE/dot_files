# Гасим compinit из /etc/zsh/zshrc (Ubuntu вызывает его глобально):
# .zshrc вызывает compinit сам, двойной вызов только замедляет старт.
skip_global_compinit=1

. "$HOME/.cargo/env"

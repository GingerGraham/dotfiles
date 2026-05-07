#!/usr/bin/env bash
# Core aliases — general-purpose; sourced unconditionally on every shell start.
# Tool-specific aliases live in tools/<tool>.sh and are guarded by command -v.

# ── Filesystem ────────────────────────────────────────────────────────────────
alias lsa="ls -Alhi"
alias lsr="ls -Alhitr"
alias dirsize="du -sh"
alias cls="clear"

# ── Network diagnostics ───────────────────────────────────────────────────────
alias routeprint="netstat -rn"
alias printrt="netstat -rn"

# ── SSH agent ─────────────────────────────────────────────────────────────────
alias sshclear="ssh-add -D"

# ── Better cat/bat ────────────────────────────────────────────────────────────
if command -v batcat &>/dev/null; then
    alias cat="batcat -p"
    alias bat="batcat"
elif command -v bat &>/dev/null; then
    alias cat="bat -p"
fi

# ── Better top ────────────────────────────────────────────────────────────────
if command -v btop &>/dev/null; then
    alias top="btop"
elif command -v htop &>/dev/null; then
    alias top="htop"
fi

# ── Python ────────────────────────────────────────────────────────────────────
command -v python3 &>/dev/null && alias python="python3"
command -v pip3    &>/dev/null && alias pip="pip3"

# ── acpi power ────────────────────────────────────────────────────────────────
if command -v acpi &>/dev/null; then
    alias battery="acpi -bi"
    alias power="acpi -a"
fi

# ── Tmux ─────────────────────────────────────────────────────────────────────
if command -v tmux &>/dev/null; then
    alias tmux-new='tmux new-session -s main'
    alias tmux-attach='tmux attach-session -t main'
    alias tmux-reload='tmux source-file "${HOME}/.tmux.conf"'
fi

# ── VS Code ───────────────────────────────────────────────────────────────────
command -v code-insiders &>/dev/null && alias code="code-insiders"

# ── Clipboard (Wayland) ───────────────────────────────────────────────────────
if command -v wl-copy &>/dev/null; then
    alias copy="wl-copy"
    alias clip="wl-copy"
fi

# ── File manager ─────────────────────────────────────────────────────────────
command -v nautilus &>/dev/null && alias explorer="nautilus --browser &"

# ── VPN ───────────────────────────────────────────────────────────────────────
if command -v nordvpn &>/dev/null; then
    alias nordc="nordvpn connect"
    alias nordd="nordvpn disconnect"
fi

# ── Fun ───────────────────────────────────────────────────────────────────────
command -v cmatrix &>/dev/null && alias matrix="cmatrix -abs"

# ── uv ────────────────────────────────────────────────────────────────────────
if command -v uv &>/dev/null; then
    alias install-specify="uv tool install specify-cli --force --from git+https://github.com/github/spec-kit.git"
fi

# ── get-my-functions shortcut ─────────────────────────────────────────────────
if command -v get-my-functions &>/dev/null; then
    alias aliases="get-my-functions"
    alias reset-shell="clear && get-my-functions"
    alias rs="clear && get-my-functions"
fi

# ── SSH hosts ─────────────────────────────────────────────────────────────────
# Overridden by core/ssh.sh once list-ssh-hosts is defined
alias sshhosts='grep -E "^Host\s" "${HOME}/.ssh/config"'

# ── iTerm2 ────────────────────────────────────────────────────────────────────
if command -v it2profile &>/dev/null; then
    alias solarized="it2profile -s Solarized"
    alias black="it2profile -s Black"
    alias smooth="it2profile -s Smooth"
fi

# ── Shell-specific ────────────────────────────────────────────────────────────
if [[ -n "${ZSH_VERSION}" ]]; then
    alias zshconfig='${VISUAL:-vim} "${HOME}/.zshrc"'
    alias zshsource='source "${HOME}/.zshrc"'
    alias zshreload="exec zsh"
    alias history="history 1"
fi

if [[ -n "${BASH_VERSION}" ]]; then
    alias bashconfig='${VISUAL:-vim} "${HOME}/.bashrc"'
    alias bashsource='source "${HOME}/.bashrc"'
    alias bashreload="exec bash"
fi

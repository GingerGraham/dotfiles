#!/usr/bin/env zsh
# Zsh-specific interactive shell configuration.
# Sourced by loader.sh only when DOTFILES_SHELL == "zsh".
# Must not be sourced in bash — all constructs here are zsh-only.

# ── History ───────────────────────────────────────────────────────────────────
HISTFILE="${HOME}/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
HISTDUP=erase

setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups
setopt hist_verify

# ── Completion system ─────────────────────────────────────────────────────────
autoload -Uz compinit
# Regenerate compinit dump at most once per day to keep startup fast.
# The glob (#qN.mh+24) matches the dump file if it is older than 24 hours.
if [[ -n "${ZDOTDIR:-${HOME}}/.zcompdump"(#qN.mh+24) ]]; then
    compinit
else
    compinit -C
fi

zstyle ':completion:*' auto-description 'specify: %d'
zstyle ':completion:*' completer _expand _complete _correct _approximate
zstyle ':completion:*' format 'Completing %d'
zstyle ':completion:*' group-name ''
zstyle ':completion:*' menu select=2
zstyle ':completion:*' list-colors ''
zstyle ':completion:*' list-prompt '%SAt %p: Hit TAB for more, or the character to insert%s'
zstyle ':completion:*' matcher-list '' 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=* l:|=*'
zstyle ':completion:*' menu select=long
zstyle ':completion:*' select-prompt '%SScrolling active: current selection at %p%s'
zstyle ':completion:*' use-compctl false
zstyle ':completion:*' verbose true
zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'
# Note: ':completion:*:default' list-colors is set in platform/linux.sh after
# dircolors runs and LS_COLORS is populated. Setting it here would produce an
# empty array because platform/ loads after core/.

# ── Key bindings ──────────────────────────────────────────────────────────────
# Edit the current command line buffer in $EDITOR
autoload -Uz edit-command-line
zle -N edit-command-line
bindkey '^X^E' edit-command-line

# Expand history references on space (e.g. !! becomes the last command)
bindkey ' ' magic-space
# Undo last edit
bindkey '^_' undo

# ── Directory change hook ─────────────────────────────────────────────────────
# Auto-list directory contents after every cd
chpwd() {
    ls -Alh --color=auto
}

log_debug "zsh: shell-specific config loaded"

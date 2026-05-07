#!/usr/bin/env bash
# Git tool configuration — aliases and helper functions.
# Sourced only when git is present (guarded in loader.sh).

# ── aliases ───────────────────────────────────────────────────────────────────
alias gitgraph="git log --oneline --graph --decorate --all"
alias gst="git status"
alias gpl="git pull"
alias gps="git push"
alias gpsh="git push"
alias gf="git fetch"
alias gsw="git switch"
alias gswm="git switch main"
alias gba="git branch -a"
alias gbd="git branch -D"
alias gitkeep='find . -type d -empty -exec touch {}/.gitkeep \;'
alias gitcleanup="git-cleanup"
alias git-remove-untracked="git-cleanup"

# GitHub Copilot CLI shortcut
if command -v gh &>/dev/null && gh extension list 2>/dev/null | grep -q "gh copilot"; then
    alias copilot="gh copilot"
    alias upgrade-copilot="gh extension upgrade gh-copilot"
fi

# ── functions ─────────────────────────────────────────────────────────────────
# git-cleanup and gwt/gwt-cd are defined in core/functions.sh (used broadly)

#!/usr/bin/env bash
# Git tool configuration — aliases and helper functions.
# Sourced only when git is present (guarded in loader.sh).

# ── aliases ───────────────────────────────────────────────────────────────────
alias gitgraph="git log --oneline --graph --decorate --all"
alias gst="git status"
alias gcl="git clone"
alias gcm="git commit -m"
alias gca="git commit --amend --no-edit"
alias gco="git checkout"
alias gcb="git checkout -b"
alias gpl="git pull"
alias gps="git push"
alias gpsh="git push"
alias gf="git fetch"
alias gfa="git fetch --all"
alias gfp="git fetch --prune"
alias grs="git restore"
alias grst="git restore"
alias gsw="git switch"
alias gswm="git switch main"
alias gswc="git switch -c"
alias gba="git branch -a"
alias gbd="git branch -D"
alias gitkeep='find . -type d -empty -exec touch {}/.gitkeep \;'
alias git-remove-untracked="git-cleanup"

# GitHub Copilot CLI shortcut
if command -v gh &>/dev/null && gh extension list 2>/dev/null | grep -q "gh copilot"; then
    alias copilot="gh copilot"
    alias upgrade-copilot="gh extension upgrade gh-copilot"
fi

# ── functions ─────────────────────────────────────────────────────────────────

# ── Git helpers ───────────────────────────────────────────────────────────────
git-cleanup() {
    git fetch -p
    for branch in $(git branch -vv | grep ': gone]' | awk '{print $1}'); do
        log_info "Deleting branch ${branch}"
        git branch -D "${branch}"
    done
}

alias gitcleanup="git-cleanup"

# ── Git worktree helper ───────────────────────────────────────────────────────
gwt() {
    local branch use_local=false create_new=false base_branch="" worktree_dir=".worktrees"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --local) use_local=true; shift ;;
            -b)
                create_new=true; shift
                branch="$1"; shift
                if [[ -n "$1" && "$1" != --* ]]; then
                    base_branch="$1"; shift
                fi
                ;;
            *)
                [[ -z "${branch}" ]] && branch="$1"
                shift
                ;;
        esac
    done

    if [[ -z "${branch}" ]]; then
        echo "Usage: gwt [--local] <branch-name>"
        echo "   or: gwt [--local] -b <new-branch> [base-branch]"
        return 1
    fi

    if [[ "${create_new}" == false ]]; then
        if ! git rev-parse --verify "${branch}" &>/dev/null; then
            echo "Error: branch '${branch}' does not exist"
            echo "Available branches:"; git branch -a | sed 's/^/  /'
            echo; echo "To create: gwt -b ${branch}"
            return 1
        fi
    fi

    mkdir -p "${worktree_dir}"

    local ignore_file
    if [[ "${use_local}" == true ]]; then
        ignore_file=".git/info/exclude"
    else
        ignore_file=".gitignore"
    fi

    grep -q "^${worktree_dir}/$" "${ignore_file}" 2>/dev/null \
        || { echo "${worktree_dir}/" >> "${ignore_file}"
             [[ "${use_local}" == false ]] && echo "Added ${worktree_dir}/ to .gitignore"; }

    if [[ "${create_new}" == true ]]; then
        if [[ -n "${base_branch}" ]]; then
            git worktree add -b "${branch}" "${worktree_dir}/${branch}" "${base_branch}"
        else
            git worktree add -b "${branch}" "${worktree_dir}/${branch}"
        fi
    else
        git worktree add "${worktree_dir}/${branch}" "${branch}"
    fi
}

gwt-cd() {
    local branch="$1"

    if [[ -z "${branch}" ]]; then
        echo "Usage: gwt-cd <branch-name|main>"
        return 1
    fi

    if [[ "${branch}" == "main" || "${branch}" == "master" ]]; then
        local repo_root
        repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
        if [[ -n "${repo_root}" ]]; then
            cd "${repo_root}" || return 1
        else
            echo "Not in a git repository"; return 1
        fi
    elif [[ -d ".worktrees/${branch}" ]]; then
        cd ".worktrees/${branch}" || return 1
    else
        echo "Worktree for '${branch}' not found"; return 1
    fi
}

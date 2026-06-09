#!/usr/bin/env bash
# shell/config/tools/git.sh
# Git tool configuration — aliases and helper functions.
# Sourced only when git is present (guarded in loader.sh).
#
# Project management functions manage three things in sync:
#   1. ~/.config/git/projects.yml        — on-machine manifest (source of truth)
#   2. ~/.config/git/project-includes    — includeIf file sourced by ~/.gitconfig
#   3. ~/.config/git/profiles/<n>.inc    — per-project identity files
#
# When DOTFILES_REPO_DIR is set they also update:
#   4. $DOTFILES_REPO_DIR/ansible/host_vars/localhost.yml
#
# Requires: yq v4 (mikefarah/yq) for manifest operations.

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
alias gpf="git push --force-with-lease"
alias gf="git fetch"
alias gfa="git fetch --all"
alias gfp="git fetch --prune"
alias grs="git restore"
alias grst="git restore"
alias gsw="git switch"
alias gswm="git switch main"
alias gswc="git switch -c"
alias gaa="git add --all"
alias gd="git diff"
alias gds="git diff --staged"
alias glo="git log --oneline --graph --decorate"
alias grb="git rebase"
alias grbi="git rebase -i"
alias gstash="git stash"
alias gpop="git stash pop"
alias gbr="git branch"
alias gba="git branch -a"
alias gbdl="git branch -d"
alias gbd="git branch -D"
alias gitkeep='find . -type d -empty -exec touch {}/.gitkeep \;'
alias git-remove-untracked="git-cleanup"
alias gitcleanup="git-cleanup"

if command -v gh &>/dev/null; then
    _gh_copilot_found=false
    for _gh_ext_dir in \
        "${HOME}/.local/share/gh/extensions/gh-copilot" \
        "${HOME}/.config/gh/extensions/gh-copilot"; do
        [[ -d "${_gh_ext_dir}" ]] && { _gh_copilot_found=true; break; }
    done
    if [[ "${_gh_copilot_found}" == "true" ]]; then
        alias copilot="gh copilot"
        alias upgrade-copilot="gh extension upgrade gh-copilot"
    fi
    unset _gh_copilot_found _gh_ext_dir
fi

# ── functions: git helpers ────────────────────────────────────────────────────

# Remove local branches whose remote tracking branch is gone.
git-cleanup() {
    git fetch -p
    for branch in $(git branch -vv | grep ': gone]' | awk '{print $1}'); do
        log_info "Deleting branch ${branch}"
        git branch -D "${branch}"
    done
}

# Git worktree helper — checkout or create a worktree for a branch.
#
# Usage:
#   gwt <branch>                   Checkout existing branch into .worktrees/
#   gwt --local <branch>           Use current directory instead of .worktrees/
#   gwt -b <new-branch> [base]     Create new branch from base (default: current)
#
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
        echo "Git worktree helper"
        echo "Create or checkout a git worktree for a branch."
        echo ""
        echo "Usage: gwt [--local] <branch-name>"
        echo "   or: gwt [--local] -b <new-branch> [base-branch]"
        return 1
    fi

    if [[ "${create_new}" == false ]]; then
        if ! git branch --list "${branch}" | grep -q "${branch}" && \
           ! git branch -r --list "origin/${branch}" | grep -q "${branch}"; then
            log_error "Branch '${branch}' not found locally or in origin."
            return 1
        fi
    fi

    local target_dir
    if "${use_local}"; then
        target_dir="."
    else
        target_dir="${worktree_dir}/${branch//\//-}"
        mkdir -p "${worktree_dir}"
    fi

    if "${create_new}"; then
        if [[ -n "${base_branch}" ]]; then
            git worktree add -b "${branch}" "${target_dir}" "${base_branch}"
        else
            git worktree add -b "${branch}" "${target_dir}"
        fi
    else
        git worktree add "${target_dir}" "${branch}"
    fi
}

gwt-cd() {
    local branch="$1"

    if [[ -z "${branch}" ]]; then
        echo "Git worktree cd helper"
        echo "Change directory to the worktree for a branch."
        echo ""
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

# ── functions: git project management ────────────────────────────────────────
#
# Internal helpers are prefixed with _git_. Do not call them directly.

_git_require_yq() {
    if ! command -v yq &>/dev/null; then
        log_error "yq is required for git project management."
        log_error "Fedora:  sudo dnf install yq"
        log_error "Snap:    sudo snap install yq"
        log_error "See:     https://github.com/mikefarah/yq#install"
        return 1
    fi
    if ! yq --version 2>&1 | grep -qE 'mikefarah|version v4|yq \(https'; then
        log_warn "yq found but may not be mikefarah/yq v4 — expressions may fail."
    fi
}

_git_manifest() {
    echo "${HOME}/.config/git/projects.yml"
}

_git_includes_file() {
    echo "${HOME}/.config/git/project-includes"
}

# Return host_vars path, or warn and return 1 if unreachable.
_git_host_vars() {
    if [[ -z "${DOTFILES_REPO_DIR:-}" ]]; then
        log_warn "DOTFILES_REPO_DIR is not set — host_vars/localhost.yml was not updated."
        log_warn "Set DOTFILES_REPO_DIR in env/00-core.sh to keep Ansible re-runs in sync."
        return 1
    fi
    local hv="${DOTFILES_REPO_DIR}/ansible/host_vars/localhost.yml"
    if [[ ! -f "${hv}" ]]; then
        log_warn "host_vars/localhost.yml not found at ${hv} — skipping host_vars update."
        return 1
    fi
    echo "${hv}"
}

# Normalise context+provider to a profile filename stem: Personal GitHub → personal-github
_git_profile_name() {
    echo "${1}-${2}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
}

_git_manifest_project_exists() {
    local manifest; manifest="$(_git_manifest)"
    [[ ! -f "${manifest}" ]] && return 1
    local result
    result=$(CTX="${1}" PROV="${2}" \
        yq '.projects[] | select(.context == env(CTX) and .provider == env(PROV)) | .context' \
        "${manifest}" 2>/dev/null)
    [[ -n "${result}" ]]
}

_git_host_vars_project_exists() {
    local hv; hv="$(_git_host_vars)" || return 1
    local result
    result=$(CTX="${1}" PROV="${2}" \
        yq '.git_projects[] | select(.context == env(CTX) and .provider == env(PROV)) | .context' \
        "${hv}" 2>/dev/null)
    [[ -n "${result}" ]]
}

_git_manifest_add() {
    local context="$1" provider="$2" email="$3" signing_key="${4:-}" name="${5:-}"
    local manifest; manifest="$(_git_manifest)"
    [[ "$(yq '.projects' "${manifest}")" == "null" ]] && yq -i '.projects = []' "${manifest}"
    CTX="${context}" PROV="${provider}" EMAIL="${email}" \
        yq -i '.projects += [{"context": env(CTX), "provider": env(PROV), "email": env(EMAIL)}]' \
        "${manifest}"
    [[ -n "${signing_key}" ]] && CTX="${context}" PROV="${provider}" VAL="${signing_key}" \
        yq -i '(.projects[] | select(.context == env(CTX) and .provider == env(PROV))).signing_key = env(VAL)' \
        "${manifest}"
    [[ -n "${name}" ]] && CTX="${context}" PROV="${provider}" VAL="${name}" \
        yq -i '(.projects[] | select(.context == env(CTX) and .provider == env(PROV))).name = env(VAL)' \
        "${manifest}"
}

# field: email | signing_key | name | ssh_key
_git_manifest_update_field() {
    local context="$1" provider="$2" field="$3" value="$4"
    local manifest; manifest="$(_git_manifest)"
    case "${field}" in
        email)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.projects[] | select(.context == env(CTX) and .provider == env(PROV))).email = env(VAL)' \
                "${manifest}" ;;
        signing_key)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.projects[] | select(.context == env(CTX) and .provider == env(PROV))).signing_key = env(VAL)' \
                "${manifest}" ;;
        name)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.projects[] | select(.context == env(CTX) and .provider == env(PROV))).name = env(VAL)' \
                "${manifest}" ;;
        ssh_key)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.projects[] | select(.context == env(CTX) and .provider == env(PROV))).ssh_key = env(VAL)' \
                "${manifest}" ;;
        *) log_error "_git_manifest_update_field: unknown field '${field}'" ;;
    esac
}

_git_manifest_remove() {
    local manifest; manifest="$(_git_manifest)"
    CTX="${1}" PROV="${2}" \
        yq -i 'del(.projects[] | select(.context == env(CTX) and .provider == env(PROV)))' \
        "${manifest}"
}

_git_host_vars_add() {
    local context="$1" provider="$2" email="$3" signing_key="${4:-}" name="${5:-}"
    local hv; hv="$(_git_host_vars)" || return 0
    [[ "$(yq '.git_projects' "${hv}")" == "null" ]] && yq -i '.git_projects = []' "${hv}"
    _git_host_vars_project_exists "${context}" "${provider}" && return 0
    CTX="${context}" PROV="${provider}" EMAIL="${email}" \
        yq -i '.git_projects += [{"context": env(CTX), "provider": env(PROV), "email": env(EMAIL)}]' \
        "${hv}"
    [[ -n "${signing_key}" ]] && CTX="${context}" PROV="${provider}" VAL="${signing_key}" \
        yq -i '(.git_projects[] | select(.context == env(CTX) and .provider == env(PROV))).signing_key = env(VAL)' \
        "${hv}"
    [[ -n "${name}" ]] && CTX="${context}" PROV="${provider}" VAL="${name}" \
        yq -i '(.git_projects[] | select(.context == env(CTX) and .provider == env(PROV))).name = env(VAL)' \
        "${hv}"
    log_info "host_vars updated: ${context}/${provider}"
}

_git_host_vars_update_field() {
    local context="$1" provider="$2" field="$3" value="$4"
    local hv; hv="$(_git_host_vars)" || return 0
    _git_host_vars_project_exists "${context}" "${provider}" || return 0
    case "${field}" in
        email)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.git_projects[] | select(.context == env(CTX) and .provider == env(PROV))).email = env(VAL)' \
                "${hv}" ;;
        signing_key)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.git_projects[] | select(.context == env(CTX) and .provider == env(PROV))).signing_key = env(VAL)' \
                "${hv}" ;;
        name)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.git_projects[] | select(.context == env(CTX) and .provider == env(PROV))).name = env(VAL)' \
                "${hv}" ;;
        ssh_key)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.git_projects[] | select(.context == env(CTX) and .provider == env(PROV))).ssh_key = env(VAL)' \
                "${hv}" ;;
    esac
}

_git_host_vars_remove() {
    local hv; hv="$(_git_host_vars)" || return 0
    CTX="${1}" PROV="${2}" \
        yq -i 'del(.git_projects[] | select(.context == env(CTX) and .provider == env(PROV)))' \
        "${hv}"
    log_info "host_vars updated: removed ${1}/${2}"
}

# Write (or update) a profile .inc file using git's own config parser.
_git_write_profile() {
    local profile_path="$1" email="$2" signing_key="${3:-}" name="${4:-}"
    git config --file "${profile_path}" user.email "${email}"
    [[ -n "${name}" ]]        && git config --file "${profile_path}" user.name "${name}"
    if [[ -n "${signing_key}" ]]; then
        git config --file "${profile_path}" user.signingkey "${signing_key}"
        git config --file "${profile_path}" commit.gpgsign true
        git config --file "${profile_path}" tag.gpgsign true
    fi
}

# Rebuild ~/.config/git/project-includes from the manifest.
_git_regenerate_includes() {
    local manifest; manifest="$(_git_manifest)"
    local includes_file; includes_file="$(_git_includes_file)"
    [[ ! -f "${manifest}" ]] && { log_error "Manifest not found: ${manifest}"; return 1; }

    local projects_base_raw projects_base_exp
    projects_base_raw=$(yq '.projects_base' "${manifest}")
    projects_base_exp="${projects_base_raw/\~/$HOME}"

    local count; count=$(yq '.projects | length' "${manifest}")
    local tmp; tmp=$(mktemp)

    {
        printf '# Generated by git project functions — do not edit directly.\n'
        printf '# To add a project: git-add-project <context> <provider> <email>\n\n'
        local i context provider profile_name
        for (( i=0; i<count; i++ )); do
            context=$(yq  ".projects[${i}].context"  "${manifest}")
            provider=$(yq ".projects[${i}].provider" "${manifest}")
            profile_name=$(_git_profile_name "${context}" "${provider}")
            printf '[includeIf "gitdir:%s/%s/%s/"]\n' "${projects_base_exp}" "${context}" "${provider}"
            printf '    path = ~/.config/git/profiles/%s.inc\n\n' "${profile_name}"
        done
    } > "${tmp}"

    mv "${tmp}" "${includes_file}"
    log_info "Regenerated: ${includes_file} (${count} projects)"
}

# ── functions: public project management ─────────────────────────────────────

# Print the resolved projects base directory.
git-projects-base() {
    local manifest; manifest="$(_git_manifest)"
    if [[ -f "${manifest}" ]]; then
        local base; base=$(yq '.projects_base' "${manifest}" 2>/dev/null)
        echo "${base/\~/$HOME}"
    else
        echo "${HOME}/Projects"
    fi
}

# Tabular list of all configured projects.
git-list-projects() {
    _git_require_yq || return 1
    local manifest; manifest="$(_git_manifest)"
    if [[ ! -f "${manifest}" ]]; then
        log_warn "No manifest found at ${manifest}. Has Ansible been run?"
        return 1
    fi

    local count; count=$(yq '.projects | length' "${manifest}")
    local base;  base=$(yq '.projects_base' "${manifest}")

    if [[ "${count}" -eq 0 ]]; then
        echo "No projects configured."
        return 0
    fi

    printf '\n%-20s %-20s %-35s %s\n' "CONTEXT" "PROVIDER" "EMAIL" "SIGNING KEY"
    printf '%-20s %-20s %-35s %s\n'   "-------" "--------" "-----" "-----------"
    local i
    for (( i=0; i<count; i++ )); do
        printf '%-20s %-20s %-35s %s\n' \
            "$(yq ".projects[${i}].context"              "${manifest}")" \
            "$(yq ".projects[${i}].provider"             "${manifest}")" \
            "$(yq ".projects[${i}].email"                "${manifest}")" \
            "$(yq ".projects[${i}].signing_key // \"\""  "${manifest}" | sed 's/^$/\(none\)/')"
    done
    printf '\nProjects base: %s\n\n' "${base}"
}

# Add a new context/provider project.
#
# Usage: git-add-project <context> <provider> <email> [signing-key] [name]
#
# Creates the directory, profile .inc, updates the manifest,
# project-includes, and host_vars/localhost.yml (if DOTFILES_REPO_DIR is set).
#
git-add-project() {
    local context="${1:-}" provider="${2:-}" email="${3:-}"
    local signing_key="${4:-}" name="${5:-}"

    if [[ -z "${context}" || -z "${provider}" || -z "${email}" ]]; then
        log_error "Usage: git-add-project <context> <provider> <email> [signing-key] [name]"
        log_error "Example: git-add-project Personal GitHub me@example.com"
        log_error "Example: git-add-project Acme AzureDevOps me@acme.com GPGFINGERPRINT"
        return 1
    fi

    _git_require_yq || return 1

    local manifest; manifest="$(_git_manifest)"
    if [[ ! -f "${manifest}" ]]; then
        log_error "Manifest not found: ${manifest}"
        log_error "Run Ansible first to create the manifest, or: git-sync-projects --from-host-vars"
        return 1
    fi

    if _git_manifest_project_exists "${context}" "${provider}"; then
        log_warn "Project ${context}/${provider} is already configured."
        log_warn "Use git-update-project to modify it."
        return 0
    fi

    local profile_name; profile_name="$(_git_profile_name "${context}" "${provider}")"
    local profile_path="${HOME}/.config/git/profiles/${profile_name}.inc"
    local project_dir; project_dir="$(git-projects-base)/${context}/${provider}"

    mkdir -p "${project_dir}"
    log_info "Directory: ${project_dir}"

    if [[ ! -f "${profile_path}" ]]; then
        _git_write_profile "${profile_path}" "${email}" "${signing_key}" "${name}"
        log_info "Profile:   ${profile_path}"
    else
        log_warn "Profile already exists (not overwritten): ${profile_path}"
    fi

    _git_manifest_add "${context}" "${provider}" "${email}" "${signing_key}" "${name}"
    log_info "Manifest:  updated"

    _git_host_vars_add "${context}" "${provider}" "${email}" "${signing_key}" "${name}"
    _git_regenerate_includes

    log_info "Done: ${context}/${provider} → ${email}"
}

# Update fields on an existing project.
#
# Usage: git-update-project <context> <provider> [--email <e>] [--signing-key <k>] [--name <n>]
#
# Updates the manifest, profile .inc file, and host_vars in sync.
# Multiple flags can be combined in a single call.
#
git-update-project() {
    local context="${1:-}" provider="${2:-}"
    shift 2 2>/dev/null || true

    if [[ -z "${context}" || -z "${provider}" ]]; then
        log_error "Usage: git-update-project <context> <provider> [--email <e>] [--signing-key <k>] [--name <n>]"
        return 1
    fi

    _git_require_yq || return 1

    if ! _git_manifest_project_exists "${context}" "${provider}"; then
        log_error "Project ${context}/${provider} not found. Use git-list-projects to review."
        return 1
    fi

    local profile_name; profile_name="$(_git_profile_name "${context}" "${provider}")"
    local profile_path="${HOME}/.config/git/profiles/${profile_name}.inc"

    # Recreate profile from manifest if somehow missing
    if [[ ! -f "${profile_path}" ]]; then
        log_warn "Profile missing — recreating from manifest."
        local manifest; manifest="$(_git_manifest)"
        local cur_email cur_key
        cur_email=$(CTX="${context}" PROV="${provider}" \
            yq '.projects[] | select(.context == env(CTX) and .provider == env(PROV)) | .email' \
            "${manifest}")
        cur_key=$(CTX="${context}" PROV="${provider}" \
            yq '.projects[] | select(.context == env(CTX) and .provider == env(PROV)) | .signing_key // ""' \
            "${manifest}")
        _git_write_profile "${profile_path}" "${cur_email}" "${cur_key}"
    fi

    local updated=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --email)
                [[ -z "${2:-}" ]] && { log_error "--email requires a value"; return 1; }
                git config --file "${profile_path}" user.email "${2}"
                _git_manifest_update_field   "${context}" "${provider}" email "${2}"
                _git_host_vars_update_field  "${context}" "${provider}" email "${2}"
                log_info "Updated email → ${2}"
                updated=true; shift 2 ;;
            --signing-key)
                [[ -z "${2:-}" ]] && { log_error "--signing-key requires a value"; return 1; }
                git config --file "${profile_path}" user.signingkey "${2}"
                git config --file "${profile_path}" commit.gpgsign true
                git config --file "${profile_path}" tag.gpgsign true
                _git_manifest_update_field   "${context}" "${provider}" signing_key "${2}"
                _git_host_vars_update_field  "${context}" "${provider}" signing_key "${2}"
                log_info "Updated signing key → ${2}"
                updated=true; shift 2 ;;
            --name)
                [[ -z "${2:-}" ]] && { log_error "--name requires a value"; return 1; }
                git config --file "${profile_path}" user.name "${2}"
                _git_manifest_update_field   "${context}" "${provider}" name "${2}"
                _git_host_vars_update_field  "${context}" "${provider}" name "${2}"
                log_info "Updated name → ${2}"
                updated=true; shift 2 ;;
            *)
                log_error "Unknown option: $1  (valid: --email, --signing-key, --name)"
                return 1 ;;
        esac
    done

    "${updated}" || log_warn "No fields specified — nothing changed."
}

# Remove a project from config. Does NOT delete the directory or repos.
#
# Usage: git-remove-project <context> <provider>
#
git-remove-project() {
    local context="${1:-}" provider="${2:-}"

    if [[ -z "${context}" || -z "${provider}" ]]; then
        log_error "Usage: git-remove-project <context> <provider>"
        return 1
    fi

    _git_require_yq || return 1

    if ! _git_manifest_project_exists "${context}" "${provider}"; then
        log_warn "Project ${context}/${provider} not in manifest — nothing to remove."
        return 0
    fi

    local project_dir; project_dir="$(git-projects-base)/${context}/${provider}"
    echo ""
    log_warn "This removes ${context}/${provider} from git config."
    log_warn "Directory ${project_dir} and its repos will NOT be deleted."
    echo ""
    read -rp "Confirm removal of ${context}/${provider}? [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { echo "Aborted."; return 0; }

    local profile_name; profile_name="$(_git_profile_name "${context}" "${provider}")"
    local profile_path="${HOME}/.config/git/profiles/${profile_name}.inc"

    [[ -f "${profile_path}" ]] && { rm "${profile_path}"; log_info "Removed profile: ${profile_path}"; }
    _git_manifest_remove  "${context}" "${provider}"
    _git_host_vars_remove "${context}" "${provider}"
    _git_regenerate_includes

    log_info "Done: ${context}/${provider} removed. Repos in ${project_dir} are untouched."
}

# Reconcile the manifest with the filesystem.
#
# Usage: git-sync-projects [--status] [--from-host-vars]
#
#   (no flags)          Ensure all manifest entries have directory and profile.
#   --status            Show what's missing without making changes.
#   --from-host-vars    Rebuild the manifest from host_vars/localhost.yml.
#
git-sync-projects() {
    local mode="sync"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status)         mode="status";        shift ;;
            --from-host-vars) mode="from-host-vars"; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    _git_require_yq || return 1
    local manifest; manifest="$(_git_manifest)"

    if [[ "${mode}" == "from-host-vars" ]]; then
        local hv; hv="$(_git_host_vars)" || return 1
        log_info "Rebuilding manifest from ${hv} ..."
        local count; count=$(yq '.git_projects | length' "${hv}")
        local base;  base=$(yq '.projects_base' "${hv}")
        {
            printf 'projects_base: %s\n' "${base}"
            printf 'projects:\n'
            local i
            for (( i=0; i<count; i++ )); do
                local ctx prov email key name
                ctx=$(yq   ".git_projects[${i}].context"           "${hv}")
                prov=$(yq  ".git_projects[${i}].provider"          "${hv}")
                email=$(yq ".git_projects[${i}].email"             "${hv}")
                key=$(yq   ".git_projects[${i}].signing_key // \"\"" "${hv}")
                name=$(yq  ".git_projects[${i}].name // \"\""      "${hv}")
                printf '  - context: %s\n    provider: %s\n    email: %s\n' \
                    "${ctx}" "${prov}" "${email}"
                [[ -n "${key}"  ]] && printf '    signing_key: %s\n' "${key}"
                [[ -n "${name}" ]] && printf '    name: %s\n' "${name}"
            done
        } > "${manifest}"
        log_info "Manifest rebuilt with ${count} projects."
        _git_regenerate_includes
        return 0
    fi

    if [[ ! -f "${manifest}" ]]; then
        log_error "Manifest not found: ${manifest}"
        log_error "Run Ansible first, or use --from-host-vars to bootstrap."
        return 1
    fi

    local count; count=$(yq '.projects | length' "${manifest}")
    local projects_base; projects_base="$(git-projects-base)"

    if [[ "${mode}" == "status" ]]; then
        echo ""
        echo "Git project status (${count} in manifest):"
        echo ""
        local i
        for (( i=0; i<count; i++ )); do
            local ctx prov profile_name project_dir profile_path dir_s prof_s
            ctx=$(yq   ".projects[${i}].context"  "${manifest}")
            prov=$(yq  ".projects[${i}].provider" "${manifest}")
            profile_name=$(_git_profile_name "${ctx}" "${prov}")
            project_dir="${projects_base}/${ctx}/${prov}"
            profile_path="${HOME}/.config/git/profiles/${profile_name}.inc"
            [[ -d "${project_dir}"  ]] && dir_s="✓" || dir_s="✗ missing"
            [[ -f "${profile_path}" ]] && prof_s="✓" || prof_s="✗ missing"
            printf '  %-20s %-20s  dir: %-12s  profile: %s\n' \
                "${ctx}" "${prov}" "${dir_s}" "${prof_s}"
        done
        echo ""
        return 0
    fi

    # sync
    log_info "Syncing ${count} projects from manifest ..."
    local i
    for (( i=0; i<count; i++ )); do
        local ctx prov email key name profile_name project_dir profile_path
        ctx=$(yq      ".projects[${i}].context"              "${manifest}")
        prov=$(yq     ".projects[${i}].provider"             "${manifest}")
        email=$(yq    ".projects[${i}].email"                "${manifest}")
        key=$(yq      ".projects[${i}].signing_key // \"\""  "${manifest}")
        name=$(yq     ".projects[${i}].name // \"\""         "${manifest}")
        profile_name=$(_git_profile_name "${ctx}" "${prov}")
        project_dir="${projects_base}/${ctx}/${prov}"
        profile_path="${HOME}/.config/git/profiles/${profile_name}.inc"

        [[ ! -d "${project_dir}" ]] && { mkdir -p "${project_dir}"; log_info "Created: ${project_dir}"; }
        [[ ! -f "${profile_path}" ]] && { _git_write_profile "${profile_path}" "${email}" "${key}" "${name}"; log_info "Created: ${profile_path}"; }
    done

    _git_regenerate_includes
    log_info "Sync complete."
}

# ── GitHub CLI token export ───────────────────────────────────────────────────
# Sets GITHUB_PERSONAL_ACCESS_TOKEN from the local gh credential store.
# Uses gh auth token directly (local keyring read) — no network call.
# Falls back cleanly if gh is not authenticated.
if command -v gh &>/dev/null; then
    _gh_token="$(gh auth token 2>/dev/null)"
    if [[ -n "${_gh_token}" ]]; then
        export GITHUB_PERSONAL_ACCESS_TOKEN="${_gh_token}"
        log_debug "git: GITHUB_PERSONAL_ACCESS_TOKEN set from gh auth token"
    else
        log_debug "git: gh present but no token found — skipping GITHUB_PERSONAL_ACCESS_TOKEN"
    fi
    unset _gh_token
fi

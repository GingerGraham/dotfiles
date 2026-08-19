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
# DOTFILES_REPO_DIR is set by Ansible on first run (see
# ansible/roles/shell/templates/env/90-local.sh.j2) — when present, these
# functions also update:
#   4. $DOTFILES_REPO_DIR/ansible/host_vars/localhost.yml
#
# Projects with a `cli` (gh|glab) set additionally get, via the CLI wiring
# routine (_git_wire_project_cli):
#   5. ~/.config/git/<gh|glab>/<context-slug>/  — per-context CLI config dir
#   6. <project-dir>/.envrc                     — direnv activation of it
#   7. the [credential] section in the profile .inc from #3
# See the "CLI context" section in ansible/roles/git/README.md.
#
# Requires: yq v4 (mikefarah/yq) for manifest operations.

# ── aliases ───────────────────────────────────────────────────────────────────

alias gitgraph="git log --oneline --graph --decorate --all"
alias gst="git status"
alias gstp="git status --porcelain"
alias gcl="git clone"
alias gcm="git commit -m"
alias gca="git commit --amend --no-edit"
alias gco="git checkout"
alias gcb="git checkout -b"
alias gpl="git pull"
alias gplr="git pull --rebase"
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
alias gap="git add -p"
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
        log_error "Install: https://github.com/mikefarah/yq#install"
        return 1
    fi
    if ! yq --version 2>&1 | grep -qE 'mikefarah|version v4|yq \(https://github.com/mikefarah'; then
        log_error "Wrong yq detected — mikefarah/yq v4 is required."
        log_error "Found: $(yq --version 2>&1)"
        log_error "Install: https://github.com/mikefarah/yq#install"
        log_error "On Ubuntu, python3-yq may be shadowing the correct binary."
        return 1
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
        log_warn "It's normally set by Ansible on first run — re-run install.sh, or set it"
        log_warn "yourself in ~/.config/dotfiles/local/90-local.sh."
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

# ── CLI context helpers (gh/glab) ─────────────────────────────────────────────

# Provider → inferred CLI. Case-insensitive. Empty output means "no inference".
_git_infer_cli() {
    case "$(_str_lower "${1:-}")" in
        github) echo "gh" ;;
        gitlab) echo "glab" ;;
        *) echo "" ;;
    esac
}

# Context slug used to key CLI config directories: Personal → personal.
# Uses _str_lower (not ${var,,} — bash-only, breaks zsh and bash 3.2 on macOS).
# Must match the Jinja slug expression in ansible/roles/git/tasks/main.yml
# (`| lower | replace(' ', '-')`) exactly — see tests/check-git-cli-contexts.sh.
_git_context_slug() { _str_lower "$1" | tr ' ' '-'; }

_git_project_dir() {
    echo "$(git-projects-base)/${1}/${2}"
}

_git_envrc_path() {
    echo "$(_git_project_dir "${1}" "${2}")/.envrc"
}

_git_cli_config_dir() {
    echo "${HOME}/.config/git/${1}/$(_git_context_slug "${2}")"
}

_git_cli_sentinel_file() {
    echo "${XDG_STATE_HOME:-${HOME}/.local/state}/dotfiles/git-cli-contexts"
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

# field: email | signing_key | name | ssh_key | cli | cli_host
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
        cli)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.projects[] | select(.context == env(CTX) and .provider == env(PROV))).cli = env(VAL)' \
                "${manifest}" ;;
        cli_host)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.projects[] | select(.context == env(CTX) and .provider == env(PROV))).cli_host = env(VAL)' \
                "${manifest}" ;;
        *) log_error "_git_manifest_update_field: unknown field '${field}'" ;;
    esac
}

# Read a single field for a context/provider from the manifest ("" if unset).
_git_manifest_field() {
    local context="$1" provider="$2" field="$3"
    local manifest; manifest="$(_git_manifest)"
    [[ ! -f "${manifest}" ]] && return 0
    CTX="${context}" PROV="${provider}" FIELD="${field}" \
        yq '(.projects[] | select(.context == env(CTX) and .provider == env(PROV))) | .[env(FIELD)] // ""' \
        "${manifest}" 2>/dev/null
}

_git_manifest_del_field() {
    local context="$1" provider="$2" field="$3"
    local manifest; manifest="$(_git_manifest)"
    CTX="${context}" PROV="${provider}" FIELD="${field}" \
        yq -i 'del((.projects[] | select(.context == env(CTX) and .provider == env(PROV))) | .[env(FIELD)])' \
        "${manifest}"
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
        cli)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.git_projects[] | select(.context == env(CTX) and .provider == env(PROV))).cli = env(VAL)' \
                "${hv}" ;;
        cli_host)
            CTX="${context}" PROV="${provider}" VAL="${value}" \
                yq -i '(.git_projects[] | select(.context == env(CTX) and .provider == env(PROV))).cli_host = env(VAL)' \
                "${hv}" ;;
    esac
}

_git_host_vars_del_field() {
    local context="$1" provider="$2" field="$3"
    local hv; hv="$(_git_host_vars)" || return 0
    _git_host_vars_project_exists "${context}" "${provider}" || return 0
    CTX="${context}" PROV="${provider}" FIELD="${field}" \
        yq -i 'del((.git_projects[] | select(.context == env(CTX) and .provider == env(PROV))) | .[env(FIELD)])' \
        "${hv}"
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

# ── functions: CLI context wiring (gh/glab) ───────────────────────────────────
#
# See "CLI context" in ansible/roles/git/README.md for the full design.

_GIT_ENVRC_MARKER='# Generated by the dotfiles git role — do not edit.'
# Shorter, stable substring used for *detecting* a generated .envrc (here and
# in direnv-init-project in tools/direnv.sh). Deliberately narrower than the
# full marker line above so a punctuation-only tweak to that line (the em
# dash, trailing period) can't silently break detection — keep both copies
# of this literal in sync if the wording ever changes.
_GIT_ENVRC_MARKER_PREFIX='# Generated by the dotfiles git role'

_git_envrc_is_generated() {
    [[ -f "$1" ]] && head -n1 "$1" 2>/dev/null | grep -qF "${_GIT_ENVRC_MARKER_PREFIX}"
}

# Write the generated .envrc for a project. Overwrites unconditionally —
# mirrors the Ansible envrc.j2 template byte-for-byte so re-runs from either
# side produce identical content. Skips (rather than failing) when the
# project directory doesn't exist yet — e.g. git-sync-projects
# --from-host-vars can rebuild a manifest with cli-set entries before any
# directory has been created; the next plain git-sync-projects (which
# creates directories first) picks it up.
_git_write_envrc() {
    local context="$1" provider="$2" cli="$3" host="${4:-}"
    local slug; slug="$(_git_context_slug "${context}")"
    local envrc_path; envrc_path="$(_git_envrc_path "${context}" "${provider}")"
    local project_dir; project_dir="$(dirname "${envrc_path}")"
    if [[ ! -d "${project_dir}" ]]; then
        log_warn "Project directory not found — skipping .envrc: ${project_dir}"
        return 0
    fi
    local use_line="use git_context ${cli} ${slug}"
    [[ -n "${host}" ]] && use_line+=" ${host}"

    local content
    content="$(cat <<EOF
${_GIT_ENVRC_MARKER}
# Per-project overrides belong in .envrc.local (never touched by dotfiles).
# Regenerate: git-sync-projects   |   Add a project: git-add-project

${use_line}

source_env_if_exists .envrc.local
EOF
)"

    # Only log at info level (and only touch the file) when content actually
    # changes — git-sync-projects re-wires every cli-set project on every
    # run, so an unconditional log_info here printed one line per project
    # even when nothing changed.
    if [[ -f "${envrc_path}" && "$(cat "${envrc_path}" 2>/dev/null)" == "${content}" ]]; then
        log_debug "Unchanged: ${envrc_path}"
        return 0
    fi

    printf '%s\n' "${content}" > "${envrc_path}"
    log_info "Wrote: ${envrc_path}"
}

# Reset and write the git credential helper for a CLI into a profile .inc.
# The bare "helper =" resets the inherited helper list so a globally
# configured libsecret/store/osxkeychain helper isn't consulted first inside
# the project tree — see the known limitation in the git role README.
_git_write_credential_helper() {
    local profile_path="$1" cli="$2" host="${3:-}"
    local default_host cred_cmd
    case "${cli}" in
        gh)   default_host="github.com"; cred_cmd="!gh auth git-credential" ;;
        glab) default_host="gitlab.com"; cred_cmd="!glab auth git-credential" ;;
        *) log_error "_git_write_credential_helper: unknown CLI '${cli}'"; return 1 ;;
    esac
    local section_key="credential.https://${host:-${default_host}}.helper"

    git config --file "${profile_path}" --unset-all "${section_key}" 2>/dev/null || true
    git config --file "${profile_path}" --add "${section_key}" ""
    git config --file "${profile_path}" --add "${section_key}" "${cred_cmd}"
}

_git_remove_credential_helper() {
    local profile_path="$1" cli="$2" host="${3:-}"
    local default_host
    case "${cli}" in
        gh)   default_host="github.com" ;;
        glab) default_host="gitlab.com" ;;
        *) return 0 ;;
    esac
    [[ -f "${profile_path}" ]] || return 0
    git config --file "${profile_path}" --remove-section "credential.https://${host:-${default_host}}" 2>/dev/null || true
}

# Create or drop the sentinel file whose existence gates the direnv-absent
# warning — a cheap [[ -f ]] test rather than a yq read at shell start (D1/§5.9).
_git_update_cli_sentinel() {
    local manifest; manifest="$(_git_manifest)"
    local sentinel; sentinel="$(_git_cli_sentinel_file)"
    [[ ! -f "${manifest}" ]] && return 0
    local any_cli; any_cli=$(yq '[.projects[] | select(.cli != null and .cli != "")] | length' "${manifest}" 2>/dev/null)
    if [[ "${any_cli:-0}" -gt 0 ]]; then
        mkdir -p "$(dirname "${sentinel}")"
        touch "${sentinel}"
    else
        rm -f "${sentinel}"
    fi
}

# Idempotent: wire CLI config dir, credential helper, and .envrc for a project.
#
# Usage: _git_wire_project_cli <context> <provider> <cli> [host] [skip-adopt-probe]
#
# skip-adopt-probe (default false): pass "true" when the caller is about to
# run its own explicit adoption (git-add-project-cli --adopt), so the
# candidate probe below doesn't race it and populate the config dir first.
_git_wire_project_cli() {
    local context="$1" provider="$2" cli="$3" host="${4:-}" skip_adopt_probe="${5:-false}"

    local lib="${XDG_CONFIG_HOME:-${HOME}/.config}/direnv/lib/dotfiles-git-context.sh"
    [[ -f "${lib}" ]] || log_warn "direnv stdlib function missing (${lib}) — the generated .envrc will fail until Ansible re-runs the git role. Run: ansible-playbook site.yml --tags git"

    local cli_dir; cli_dir="$(_git_cli_config_dir "${cli}" "${context}")"
    mkdir -p "${cli_dir}"
    chmod 0700 "${cli_dir}"
    log_info "CLI config dir: ${cli_dir}"

    local profile_name; profile_name="$(_git_profile_name "${context}" "${provider}")"
    local profile_path="${HOME}/.config/git/profiles/${profile_name}.inc"
    if [[ -f "${profile_path}" ]]; then
        _git_write_credential_helper "${profile_path}" "${cli}" "${host}"
        log_info "Credential helper: ${profile_path}"
    else
        log_warn "Profile not found — skipping credential helper: ${profile_path}"
    fi

    _git_write_envrc "${context}" "${provider}" "${cli}" "${host}"

    # Offer to carry over an already-authenticated store when the config dir
    # is still empty — reachable from every caller (git-add-project's CLI
    # step, git-add-project-cli, git-update-project --cli/--cli-host, and
    # git-sync-projects), not just the explicit --adopt flag.
    [[ "${skip_adopt_probe}" == "true" ]] || _git_probe_adopt_candidate "${cli}" "${context}" "${cli_dir}"
}

# Clear CLI wiring for a project: manifest/host_vars fields, credential
# helper, generated .envrc. Only prompts to delete the CLI config directory
# (which holds live credentials) when asked to.
#
# Usage: _git_unwire_project_cli <context> <provider> [--prompt-delete-dir]
#
_git_unwire_project_cli() {
    local context="$1" provider="$2" prompt_delete=false
    [[ "${3:-}" == "--prompt-delete-dir" ]] && prompt_delete=true

    local cli; cli="$(_git_manifest_field "${context}" "${provider}" cli)"
    if [[ -z "${cli}" ]]; then
        log_warn "Project ${context}/${provider} has no CLI wiring — nothing to remove."
        return 0
    fi
    local host; host="$(_git_manifest_field "${context}" "${provider}" cli_host)"

    local profile_name; profile_name="$(_git_profile_name "${context}" "${provider}")"
    local profile_path="${HOME}/.config/git/profiles/${profile_name}.inc"
    _git_remove_credential_helper "${profile_path}" "${cli}" "${host}"

    local envrc_path; envrc_path="$(_git_envrc_path "${context}" "${provider}")"
    if _git_envrc_is_generated "${envrc_path}"; then
        rm -f "${envrc_path}"
        log_info "Removed generated .envrc: ${envrc_path}"
    fi

    _git_manifest_del_field  "${context}" "${provider}" cli
    _git_manifest_del_field  "${context}" "${provider}" cli_host
    _git_host_vars_del_field "${context}" "${provider}" cli
    _git_host_vars_del_field "${context}" "${provider}" cli_host

    _git_regenerate_envrc
    log_info "CLI wiring removed for ${context}/${provider}."

    if "${prompt_delete}"; then
        local cli_dir; cli_dir="$(_git_cli_config_dir "${cli}" "${context}")"
        echo ""
        log_warn "${cli_dir} holds live credentials."
        local confirm=""
        _read_prompt "Also delete it? [y/N]: " confirm
        if [[ "$(_str_lower "${confirm}")" == "y" ]]; then
            rm -rf "${cli_dir}"
            log_info "Removed: ${cli_dir}"
        fi
    fi
}

# Copy an existing gh/glab config directory (hosts.yml / config.yml) into a
# new per-context config dir. Never moves or deletes the source, never
# overwrites a non-empty target.
_git_adopt_cli_store() {
    local src="$1" dst="$2"
    if [[ ! -d "${src}" ]]; then
        log_error "Adopt source not found: ${src}"
        return 1
    fi
    if [[ -n "$(ls -A "${dst}" 2>/dev/null)" ]]; then
        log_warn "Target already has content — not overwriting: ${dst}"
        return 1
    fi
    mkdir -p "${dst}"
    cp -R "${src}/." "${dst}/"
    log_info "Adopted ${src} -> ${dst}"
}

# Echo the first plausible pre-existing CLI config store for this context
# (the ad-hoc `~/.config/gh-<slug>` convention, then the CLI's own default),
# or nothing if none is found. Detection only — no prompting, no side
# effects. Shared by _git_probe_adopt_candidate and git-sync-projects --status.
_git_find_adopt_candidate() {
    local cli="$1" context="$2"
    local slug; slug="$(_git_context_slug "${context}")"
    local c
    if [[ "${cli}" == "gh" ]]; then
        for c in "${HOME}/.config/gh-${slug}" "${HOME}/.config/gh"; do
            [[ -n "$(ls -A "${c}" 2>/dev/null)" ]] && { echo "${c}"; return 0; }
        done
    else
        for c in "${HOME}/.config/glab-${slug}" "${HOME}/.config/glab-cli"; do
            [[ -n "$(ls -A "${c}" 2>/dev/null)" ]] && { echo "${c}"; return 0; }
        done
    fi
}

# Probe likely locations for an already-authenticated CLI store and offer to
# adopt one into the new per-context config dir. No-op unless the target dir
# is empty and stdin is a TTY. Shared by git-add-project-cli (explicit) and
# _git_wire_project_cli (so git-sync-projects offers the same carry-over,
# not just the dedicated command).
_git_probe_adopt_candidate() {
    local cli="$1" context="$2" cli_dir="$3"
    [[ -n "$(ls -A "${cli_dir}" 2>/dev/null)" ]] && return 0
    [[ -t 0 ]] || return 0

    # Skip when already inside an active wired tree for this CLI —
    # GH_CONFIG_DIR/GLAB_CONFIG_DIR already points at our own managed
    # structure, so there's nothing meaningful left to adopt.
    local active_dir=""
    case "${cli}" in
        gh)   active_dir="${GH_CONFIG_DIR:-}" ;;
        glab) active_dir="${GLAB_CONFIG_DIR:-}" ;;
    esac
    [[ "${active_dir}" == "${HOME}/.config/git/${cli}/"* ]] && return 0

    local candidate; candidate="$(_git_find_adopt_candidate "${cli}" "${context}")"
    if [[ -n "${candidate}" ]]; then
        local ans=""
        _read_prompt "Found an existing ${cli} config at ${candidate} — copy it into ${cli_dir}? [y/N]: " ans
        [[ "$(_str_lower "${ans}")" == "y" ]] && _git_adopt_cli_store "${candidate}" "${cli_dir}"
    fi
}

# Rebuild generated .envrc files from the manifest. Writes one per project
# with cli set; removes stale generated .envrc for projects that no longer
# have cli set (only if it still carries the generated marker — a
# hand-written .envrc is left alone). Also updates the direnv-absent-warning
# sentinel. Mirrors _git_regenerate_includes — call it wherever that is called.
_git_regenerate_envrc() {
    local manifest; manifest="$(_git_manifest)"
    [[ ! -f "${manifest}" ]] && { log_error "Manifest not found: ${manifest}"; return 1; }

    local count; count=$(yq '.projects | length' "${manifest}")
    local i ctx prov cli host envrc_path
    for (( i=0; i<count; i++ )); do
        ctx=$(yq  ".projects[${i}].context"          "${manifest}")
        prov=$(yq ".projects[${i}].provider"         "${manifest}")
        cli=$(yq  ".projects[${i}].cli // \"\""      "${manifest}")
        host=$(yq ".projects[${i}].cli_host // \"\"" "${manifest}")
        envrc_path="$(_git_envrc_path "${ctx}" "${prov}")"

        if [[ -n "${cli}" ]]; then
            _git_write_envrc "${ctx}" "${prov}" "${cli}" "${host}"
        elif _git_envrc_is_generated "${envrc_path}"; then
            rm -f "${envrc_path}"
            log_info "Removed stale .envrc: ${envrc_path}"
        fi
    done

    _git_update_cli_sentinel
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

    printf '\n%-20s %-20s %-35s %-42s %s\n' "CONTEXT" "PROVIDER" "EMAIL" "SIGNING KEY" "CLI"
    printf '%-20s %-20s %-35s %-42s %s\n'   "-------" "--------" "-----" "-----------" "---"
    local i cli host cli_col
    for (( i=0; i<count; i++ )); do
        cli=$(yq  ".projects[${i}].cli // \"\""      "${manifest}")
        host=$(yq ".projects[${i}].cli_host // \"\"" "${manifest}")
        if [[ -n "${cli}" && -n "${host}" ]]; then
            cli_col="${cli}@${host}"
        elif [[ -n "${cli}" ]]; then
            cli_col="${cli}"
        else
            cli_col="-"
        fi
        printf '%-20s %-20s %-35s %-42s %s\n' \
            "$(yq ".projects[${i}].context"              "${manifest}")" \
            "$(yq ".projects[${i}].provider"             "${manifest}")" \
            "$(yq ".projects[${i}].email"                "${manifest}")" \
            "$(yq ".projects[${i}].signing_key // \"\""  "${manifest}" | sed 's/^$/\(none\)/')" \
            "${cli_col}"
    done
    printf '\nProjects base: %s\n\n' "${base}"
}

# Add a new context/provider project.
#
# Usage: git-add-project <context> <provider> <email> [signing-key] [name] [--no-cli]
#
# Creates the directory, profile .inc, updates the manifest,
# project-includes, and host_vars/localhost.yml (if DOTFILES_REPO_DIR is set).
#
# When stdin is a TTY and --no-cli was not given, also offers to wire the gh
# or glab CLI for the new project (see _git_wire_project_cli). --no-cli skips
# the prompt entirely for scripted use.
#
git-add-project() {
    local no_cli=false
    local -a positional=()
    local a
    for a in "$@"; do
        case "${a}" in
            --no-cli) no_cli=true ;;
            *) positional+=("${a}") ;;
        esac
    done
    set -- "${positional[@]}"

    local context="${1:-}" provider="${2:-}" email="${3:-}"
    local signing_key="${4:-}" name="${5:-}"

    if [[ -z "${context}" || -z "${provider}" || -z "${email}" ]]; then
        log_error "Usage: git-add-project <context> <provider> <email> [signing-key] [name] [--no-cli]"
        log_error "Example: git-add-project Personal GitHub me@example.com"
        log_error "Example: git-add-project Acme AzureDevOps me@acme.com GPGFINGERPRINT"
        return 1
    fi

    _git_require_yq || return 1

    # Validate/resolve the signing key — corrects the common mistake of
    # supplying a master key ID (or its fingerprint) instead of its [S]
    # signing subkey.
    if [[ -n "${signing_key}" ]] && command -v gpg &>/dev/null; then
        signing_key="$(_gpg_resolve_signing_key "${signing_key}")" || return 1
    fi

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

    # ── CLI wiring (interactive only) ────────────────────────────────────────
    if [[ "${no_cli}" != true && -t 0 ]]; then
        local inferred_cli; inferred_cli="$(_git_infer_cli "${provider}")"
        local chosen_cli="" chosen_host="" ans=""

        if [[ -n "${inferred_cli}" ]]; then
            _read_prompt "Configure the ${inferred_cli} CLI for ${context}/${provider}? [Y/n]: " ans
            case "$(_str_lower "${ans}")" in
                n|no) chosen_cli="" ;;
                *)    chosen_cli="${inferred_cli}" ;;
            esac
        else
            _read_prompt "Configure a CLI for ${context}/${provider}? [gh/glab/none] (none): " ans
            case "$(_str_lower "${ans}")" in
                gh)   chosen_cli="gh" ;;
                glab) chosen_cli="glab" ;;
                *)    chosen_cli="" ;;
            esac
        fi

        if [[ -n "${chosen_cli}" ]]; then
            _read_prompt "Non-default host for ${chosen_cli} (Enter to skip): " chosen_host

            _git_manifest_update_field  "${context}" "${provider}" cli "${chosen_cli}"
            _git_host_vars_update_field "${context}" "${provider}" cli "${chosen_cli}"
            if [[ -n "${chosen_host}" ]]; then
                _git_manifest_update_field  "${context}" "${provider}" cli_host "${chosen_host}"
                _git_host_vars_update_field "${context}" "${provider}" cli_host "${chosen_host}"
            fi

            _git_wire_project_cli "${context}" "${provider}" "${chosen_cli}" "${chosen_host}"
            _git_regenerate_envrc

            cat <<CLIEOF

  CLI wiring complete for ${context}/${provider}.

  Authenticate from inside the project tree so the credentials land in the
  right store:

    cd $(_git_project_dir "${context}" "${provider}")
    ${chosen_cli} auth login

  Verify with:  ${chosen_cli} auth status

CLIEOF
        fi
    fi
}

# Add CLI wiring to an existing project.
#
# Usage: git-add-project-cli <context> <provider> [--cli gh|glab] [--host <hostname>] [--adopt <path>]
#
# Same prompts as the git-add-project CLI step when flags are omitted.
# Errors if the project is not in the manifest. If the project already has
# cli set, reports it and suggests git-update-project --cli instead.
#
# --adopt <path> copies an existing hosts.yml (gh) or config.yml (glab) from
# <path> into the new config directory instead of re-running auth login.
#
git-add-project-cli() {
    local context="${1:-}" provider="${2:-}"
    shift 2 2>/dev/null || true

    local cli="" host="" adopt_path=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cli)
                [[ -z "${2:-}" ]] && { log_error "--cli requires a value"; return 1; }
                cli="$2"; shift 2 ;;
            --host)
                [[ -z "${2:-}" ]] && { log_error "--host requires a value"; return 1; }
                host="$2"; shift 2 ;;
            --adopt)
                [[ -z "${2:-}" ]] && { log_error "--adopt requires a path"; return 1; }
                adopt_path="$2"; shift 2 ;;
            *) log_error "Unknown option: $1  (valid: --cli, --host, --adopt)"; return 1 ;;
        esac
    done

    if [[ -z "${context}" || -z "${provider}" ]]; then
        log_error "Usage: git-add-project-cli <context> <provider> [--cli gh|glab] [--host <hostname>] [--adopt <path>]"
        return 1
    fi

    _git_require_yq || return 1

    if ! _git_manifest_project_exists "${context}" "${provider}"; then
        log_error "Project ${context}/${provider} not found. Use git-add-project first."
        return 1
    fi

    local existing_cli; existing_cli="$(_git_manifest_field "${context}" "${provider}" cli)"
    if [[ -n "${existing_cli}" ]]; then
        log_warn "Project ${context}/${provider} already has cli=${existing_cli} configured."
        log_warn "Use: git-update-project ${context} ${provider} --cli <gh|glab>"
        return 0
    fi

    if [[ -z "${cli}" ]]; then
        local inferred; inferred="$(_git_infer_cli "${provider}")"
        local ans=""
        if [[ -n "${inferred}" ]]; then
            _read_prompt "Configure the ${inferred} CLI for ${context}/${provider}? [Y/n]: " ans
            case "$(_str_lower "${ans}")" in
                n|no) log_info "Skipped."; return 0 ;;
                *)    cli="${inferred}" ;;
            esac
        else
            _read_prompt "Configure a CLI for ${context}/${provider}? [gh/glab/none] (none): " ans
            case "$(_str_lower "${ans}")" in
                gh)   cli="gh" ;;
                glab) cli="glab" ;;
                *)    log_info "Skipped."; return 0 ;;
            esac
        fi
    fi

    if [[ "${cli}" != "gh" && "${cli}" != "glab" ]]; then
        log_error "Invalid --cli value '${cli}' (must be gh or glab)"
        return 1
    fi

    if [[ -z "${host}" && -t 0 ]]; then
        _read_prompt "Non-default host for ${cli} (Enter to skip): " host
    fi

    _git_manifest_update_field  "${context}" "${provider}" cli "${cli}"
    _git_host_vars_update_field "${context}" "${provider}" cli "${cli}"
    if [[ -n "${host}" ]]; then
        _git_manifest_update_field  "${context}" "${provider}" cli_host "${host}"
        _git_host_vars_update_field "${context}" "${provider}" cli_host "${host}"
    fi

    # When --adopt is explicit, skip _git_wire_project_cli's own candidate
    # probe (it would otherwise race the explicit adopt below over who gets
    # to populate the still-empty config dir first) and adopt directly.
    if [[ -n "${adopt_path}" ]]; then
        _git_wire_project_cli "${context}" "${provider}" "${cli}" "${host}" true
        _git_regenerate_envrc
        local cli_dir; cli_dir="$(_git_cli_config_dir "${cli}" "${context}")"
        _git_adopt_cli_store "${adopt_path}" "${cli_dir}"
    else
        _git_wire_project_cli "${context}" "${provider}" "${cli}" "${host}"
        _git_regenerate_envrc
    fi

    cat <<CLIEOF

  CLI wiring complete for ${context}/${provider}.

  Authenticate from inside the project tree so the credentials land in the
  right store:

    cd $(_git_project_dir "${context}" "${provider}")
    ${cli} auth login

  Verify with:  ${cli} auth status

CLIEOF
}

# Remove CLI wiring from a project. Does NOT delete the project directory,
# profile, or repos — only the CLI wiring (manifest/host_vars fields,
# credential helper, generated .envrc). Prompts separately before deleting
# the CLI config directory, defaulting to no (it holds live credentials).
#
# Usage: git-remove-project-cli <context> <provider>
#
git-remove-project-cli() {
    local context="${1:-}" provider="${2:-}"

    if [[ -z "${context}" || -z "${provider}" ]]; then
        log_error "Usage: git-remove-project-cli <context> <provider>"
        return 1
    fi

    _git_require_yq || return 1

    if ! _git_manifest_project_exists "${context}" "${provider}"; then
        log_warn "Project ${context}/${provider} not in manifest — nothing to remove."
        return 0
    fi

    _git_unwire_project_cli "${context}" "${provider}" --prompt-delete-dir
}

# Update fields on an existing project.
#
# Usage: git-update-project <context> <provider> [--email <e>] [--signing-key <k>]
#                            [--name <n>] [--cli <gh|glab|none>] [--cli-host <hostname>]
#
# Updates the manifest, profile .inc file, and host_vars in sync.
# Multiple flags can be combined in a single call. After any --cli/--cli-host
# change, the CLI wiring routine re-runs so .envrc and the profile .inc stay
# consistent. --cli none is equivalent to git-remove-project-cli without the
# config-directory deletion prompt.
#
git-update-project() {
    local context="${1:-}" provider="${2:-}"
    shift 2 2>/dev/null || true

    if [[ -z "${context}" || -z "${provider}" ]]; then
        log_error "Usage: git-update-project <context> <provider> [--email <e>] [--signing-key <k>] [--name <n>] [--cli <gh|glab|none>] [--cli-host <hostname>]"
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
                local resolved_key="${2}"
                if command -v gpg &>/dev/null; then
                    resolved_key="$(_gpg_resolve_signing_key "${2}")" || return 1
                fi
                git config --file "${profile_path}" user.signingkey "${resolved_key}"
                git config --file "${profile_path}" commit.gpgsign true
                git config --file "${profile_path}" tag.gpgsign true
                _git_manifest_update_field   "${context}" "${provider}" signing_key "${resolved_key}"
                _git_host_vars_update_field  "${context}" "${provider}" signing_key "${resolved_key}"
                log_info "Updated signing key → ${resolved_key}"
                updated=true; shift 2 ;;
            --name)
                [[ -z "${2:-}" ]] && { log_error "--name requires a value"; return 1; }
                git config --file "${profile_path}" user.name "${2}"
                _git_manifest_update_field   "${context}" "${provider}" name "${2}"
                _git_host_vars_update_field  "${context}" "${provider}" name "${2}"
                log_info "Updated name → ${2}"
                updated=true; shift 2 ;;
            --cli)
                [[ -z "${2:-}" ]] && { log_error "--cli requires a value (gh|glab|none)"; return 1; }
                case "${2}" in
                    gh|glab)
                        # Read the currently-wired cli/host before mutating the
                        # manifest, so a cli switch (e.g. gh -> glab) can remove
                        # the previous credential-helper section rather than
                        # leaving it behind alongside the new one.
                        local prev_cli prev_host
                        prev_cli="$(_git_manifest_field "${context}" "${provider}" cli)"
                        prev_host="$(_git_manifest_field "${context}" "${provider}" cli_host)"
                        if [[ -n "${prev_cli}" && "${prev_cli}" != "${2}" ]]; then
                            _git_remove_credential_helper "${profile_path}" "${prev_cli}" "${prev_host}"
                            local prev_cli_dir; prev_cli_dir="$(_git_cli_config_dir "${prev_cli}" "${context}")"
                            log_warn "Previous ${prev_cli} config dir left in place (holds credentials, not auto-removed): ${prev_cli_dir}"
                        fi

                        _git_manifest_update_field  "${context}" "${provider}" cli "${2}"
                        _git_host_vars_update_field "${context}" "${provider}" cli "${2}"
                        local cur_host; cur_host="$(_git_manifest_field "${context}" "${provider}" cli_host)"
                        _git_wire_project_cli "${context}" "${provider}" "${2}" "${cur_host}"
                        _git_regenerate_envrc
                        log_info "Updated cli → ${2}"
                        ;;
                    none)
                        _git_unwire_project_cli "${context}" "${provider}"
                        ;;
                    *) log_error "--cli must be gh, glab, or none"; return 1 ;;
                esac
                updated=true; shift 2 ;;
            --cli-host)
                [[ -z "${2:-}" ]] && { log_error "--cli-host requires a value"; return 1; }
                # Same reasoning as --cli above: a host change re-keys the
                # credential helper section (it's scoped to "https://<host>"),
                # so the old section must be dropped explicitly.
                local prev_cli prev_host
                prev_cli="$(_git_manifest_field "${context}" "${provider}" cli)"
                prev_host="$(_git_manifest_field "${context}" "${provider}" cli_host)"
                if [[ -n "${prev_cli}" && "${prev_host}" != "${2}" ]]; then
                    _git_remove_credential_helper "${profile_path}" "${prev_cli}" "${prev_host}"
                fi

                _git_manifest_update_field  "${context}" "${provider}" cli_host "${2}"
                _git_host_vars_update_field "${context}" "${provider}" cli_host "${2}"
                local cur_cli; cur_cli="$(_git_manifest_field "${context}" "${provider}" cli)"
                if [[ -n "${cur_cli}" ]]; then
                    _git_wire_project_cli "${context}" "${provider}" "${cur_cli}" "${2}"
                    _git_regenerate_envrc
                    log_info "Updated cli_host → ${2}"
                else
                    log_warn "cli_host set, but no cli configured for ${context}/${provider} — set --cli too."
                fi
                updated=true; shift 2 ;;
            *)
                log_error "Unknown option: $1  (valid: --email, --signing-key, --name, --cli, --cli-host)"
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
    local confirm=""
    _read_prompt "Confirm removal of ${context}/${provider}? [y/N]: " confirm
    [[ "$(_str_lower "${confirm}")" != "y" ]] && { echo "Aborted."; return 0; }

    local profile_name; profile_name="$(_git_profile_name "${context}" "${provider}")"
    local profile_path="${HOME}/.config/git/profiles/${profile_name}.inc"

    local existing_cli; existing_cli="$(_git_manifest_field "${context}" "${provider}" cli)"
    [[ -n "${existing_cli}" ]] && _git_unwire_project_cli "${context}" "${provider}" --prompt-delete-dir

    [[ -f "${profile_path}" ]] && { rm "${profile_path}"; log_info "Removed profile: ${profile_path}"; }
    _git_manifest_remove  "${context}" "${provider}"
    _git_host_vars_remove "${context}" "${provider}"
    _git_regenerate_includes
    _git_regenerate_envrc

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
                local ctx prov email key name cli host
                ctx=$(yq   ".git_projects[${i}].context"           "${hv}")
                prov=$(yq  ".git_projects[${i}].provider"          "${hv}")
                email=$(yq ".git_projects[${i}].email"             "${hv}")
                key=$(yq   ".git_projects[${i}].signing_key // \"\"" "${hv}")
                name=$(yq  ".git_projects[${i}].name // \"\""      "${hv}")
                cli=$(yq   ".git_projects[${i}].cli // \"\""       "${hv}")
                host=$(yq  ".git_projects[${i}].cli_host // \"\""  "${hv}")
                printf '  - context: %s\n    provider: %s\n    email: %s\n' \
                    "${ctx}" "${prov}" "${email}"
                [[ -n "${key}"  ]] && printf '    signing_key: %s\n' "${key}"
                [[ -n "${name}" ]] && printf '    name: %s\n' "${name}"
                [[ -n "${cli}"  ]] && printf '    cli: %s\n' "${cli}"
                [[ -n "${host}" ]] && printf '    cli_host: %s\n' "${host}"
            done
        } > "${manifest}"
        log_info "Manifest rebuilt with ${count} projects."
        _git_regenerate_includes
        _git_regenerate_envrc
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
            local cli host cli_dir envrc_path cli_dir_s envrc_s auth_s
            ctx=$(yq   ".projects[${i}].context"  "${manifest}")
            prov=$(yq  ".projects[${i}].provider" "${manifest}")
            cli=$(yq   ".projects[${i}].cli // \"\""      "${manifest}")
            host=$(yq  ".projects[${i}].cli_host // \"\"" "${manifest}")
            profile_name=$(_git_profile_name "${ctx}" "${prov}")
            project_dir="${projects_base}/${ctx}/${prov}"
            profile_path="${HOME}/.config/git/profiles/${profile_name}.inc"
            [[ -d "${project_dir}"  ]] && dir_s="✓" || dir_s="✗ missing"
            [[ -f "${profile_path}" ]] && prof_s="✓" || prof_s="✗ missing"
            printf '  %-20s %-20s  dir: %-12s  profile: %s\n' \
                "${ctx}" "${prov}" "${dir_s}" "${prof_s}"

            if [[ -n "${cli}" ]]; then
                cli_dir="$(_git_cli_config_dir "${cli}" "${ctx}")"
                envrc_path="${project_dir}/.envrc"
                [[ -d "${cli_dir}"   ]] && cli_dir_s="✓" || cli_dir_s="✗ missing"
                [[ -f "${envrc_path}" ]] && envrc_s="✓" || envrc_s="✗ missing"

                # Local-only check — no network call. `gh auth token` is a
                # keyring read; glab has no non-interactive equivalent, so
                # its check falls back to "does the config file have
                # content". Neither validates the token against the API, so
                # this is a cheap reconciliation report, not a live auth
                # check — consistent with what dir_s/prof_s already do.
                if [[ "${cli}" == "gh" ]]; then
                    if command -v gh &>/dev/null; then
                        if GH_CONFIG_DIR="${cli_dir}" GH_HOST="${host:-github.com}" \
                           gh auth token &>/dev/null; then
                            auth_s="stored"
                        else
                            auth_s="none"
                        fi
                    else
                        auth_s="?"
                    fi
                else
                    [[ -s "${cli_dir}/config.yml" ]] && auth_s="stored" || auth_s="none"
                fi

                local adopt_hint=""
                if [[ "${auth_s}" == "none" && -z "$(ls -A "${cli_dir}" 2>/dev/null)" ]]; then
                    local candidate; candidate="$(_git_find_adopt_candidate "${cli}" "${ctx}")"
                    [[ -n "${candidate}" ]] && adopt_hint=" (candidate store found at ${candidate} — see git-add-project-cli --adopt)"
                fi

                printf '  %-20s %-20s  cli: %-10s config: %-12s envrc: %-12s auth: %s%s\n' \
                    "" "" "${cli}${host:+@${host}}" "${cli_dir_s}" "${envrc_s}" "${auth_s}" "${adopt_hint}"
            fi
        done
        echo ""
        return 0
    fi

    # sync
    log_info "Syncing ${count} projects from manifest ..."
    local i
    for (( i=0; i<count; i++ )); do
        local ctx prov email key name cli host profile_name project_dir profile_path
        ctx=$(yq      ".projects[${i}].context"              "${manifest}")
        prov=$(yq     ".projects[${i}].provider"             "${manifest}")
        email=$(yq    ".projects[${i}].email"                "${manifest}")
        key=$(yq      ".projects[${i}].signing_key // \"\""  "${manifest}")
        name=$(yq     ".projects[${i}].name // \"\""         "${manifest}")
        cli=$(yq      ".projects[${i}].cli // \"\""          "${manifest}")
        host=$(yq     ".projects[${i}].cli_host // \"\""     "${manifest}")
        profile_name=$(_git_profile_name "${ctx}" "${prov}")
        project_dir="${projects_base}/${ctx}/${prov}"
        profile_path="${HOME}/.config/git/profiles/${profile_name}.inc"

        [[ ! -d "${project_dir}" ]] && { mkdir -p "${project_dir}"; log_info "Created: ${project_dir}"; }
        [[ ! -f "${profile_path}" ]] && { _git_write_profile "${profile_path}" "${email}" "${key}" "${name}"; log_info "Created: ${profile_path}"; }

        [[ -n "${cli}" ]] && _git_wire_project_cli "${ctx}" "${prov}" "${cli}" "${host}"
    done

    _git_regenerate_includes
    _git_regenerate_envrc
    log_info "Sync complete."
}

# ── direnv presence check (D1) ─────────────────────────────────────────────────
# CLI contexts (gh/glab wiring) rely entirely on direnv to activate per-project
# — there is no chpwd/PROMPT_COMMAND fallback. Warn once if at least one
# project has cli set but direnv isn't installed, so the gap is visible
# instead of silently falling back to the default (unscoped) credential
# store. Gated on the sentinel file (touched by _git_wire_project_cli /
# _git_regenerate_envrc) rather than a yq read, to keep this eager path cheap.
if [[ -f "$(_git_cli_sentinel_file)" ]] && ! command -v direnv &>/dev/null; then
    log_warn "git: CLI contexts are configured but direnv is not installed — gh/glab credentials will not follow the working directory. Install: https://direnv.net"
fi

# ── GitHub CLI token export ───────────────────────────────────────────────────
# Two-tier arrangement:
#   1. This block runs once, eagerly, at shell start — it sets
#      GITHUB_PERSONAL_ACCESS_TOKEN from the default (unscoped) gh credential
#      store, as an out-of-tree fallback for shells that never cd into a
#      project directory.
#   2. use_git_context (the direnv stdlib function this role deploys)
#      overrides it inside a project tree with the token from that context's
#      GH_CONFIG_DIR. direnv's hook runs at first prompt, after this file is
#      sourced, so its export wins there — and restores this outer value on
#      leaving the tree.
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

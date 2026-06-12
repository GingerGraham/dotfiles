#!/usr/bin/env bash
# Lazy-loaded maintenance — managed-tool update orchestration.
# Sourced via stub in loader.sh on first call to a public function here.
#
# update-tools walks a registry of managed tools and, for each one that is
# actually installed, runs its individual installer/updater. Installers live in
# lazy/installers.sh; per-tool update helpers live in tools/*.sh. A tool that
# isn't installed is reported (with the command that would install it) rather
# than silently skipped.
#
# Registry rows are pipe-separated, five fields:
#   <name>|<detect>|<updater-fn>|<installer-cmd>|<label>
#     name        canonical id the user types and that --list shows
#     detect      `command -v` target, OR `path:<file>` for non-PATH installs
#     updater-fn  function run to update the tool when it is present
#     installer-cmd  command suggested when the tool is NOT present
#     label       human-readable description
#
# Order matters — tenv is first so it claims the terraform/tofu proxies before
# their own rows are evaluated.
#
# NOTE: detect tokens for claude/copilot/bw/bitwarden/noteshub assume the binary
# names below. Adjust any that differ on your machines.
_managed_tools_registry() {
    cat <<'EOF'
1password|1password|install-1password|install-1password|1Password Desktop
ansible|ansible|install-ansible|install-ansible|Ansible
aws|aws|_update_aws|aws-update|AWS CLI
az|az|_update_az|az-update|Azure CLI
bitwarden|bitwarden|install-bitwarden|install-bitwarden|Bitwarden Desktop
bw|bw|install-bw-cli|install-bw-cli|Bitwarden CLI
claude|claude|install-claude-code|install-claude-code|Claude Code
copilot|copilot|install-copilot-cli|install-copilot-cli|GitHub Copilot CLI
cosign|cosign|install-cosign|install-cosign|cosign
edit|edit|install-edit|install-edit|Microsoft Edit
gh|gh|install-gh|install-gh|GitHub CLI
glab|glab|install-glab|install-glab|GitLab CLI
helm|helm|install-helm|install-helm|Helm
kubectl|kubectl|_update_kubectl|set-kubectl|kubectl
oh-my-posh|oh-my-posh|_update_omp|install-oh-my-posh|oh-my-posh
oh-my-zsh|path:~/.oh-my-zsh|_update_omz|install-oh-my-zsh|oh-my-zsh
op|op|install-op-cli|install-op-cli|1Password CLI
noteshub|noteshub|install-noteshub|install-noteshub|NotesHubgh|gh|install-gh|install-gh|GitHub CLI
nvm|nvm|install-nvm|install-nvm|nvm (Node)
tenv|tenv|_update_tenv_managed|install-tenv|tenv (Terraform/OpenTofu)
terraform|terraform|_update_terraform|install-tenv|Terraform
tflint|tflint|install-tflint|install-tflint|TFLint
tofu|tofu|_update_tofu|install-tenv|OpenTofu
trivy|trivy|install-trivy|install-trivy|Trivy
EOF
}

# Presence check supporting both `command -v` and `path:<file>` detect tokens.
_update_detect() {
    local token="$1"
    case "${token}" in
        path:*)
            local p="${token#path:}"
            [[ "$p" =~ ^~/ ]] && p="${HOME}/${p#\~/}"
            [[ -e "${p}" ]]
            ;;
        *)
            command -v "${token}" &>/dev/null
            ;;
    esac
}

# Return the full registry row for a given name (exact match), or non-zero.
_managed_tool_row() {
    local want="$1" n d u i l
    while IFS='|' read -r n d u i l; do
        [[ -z "${n}" ]] && continue
        if [[ "${n}" == "${want}" ]]; then
            printf '%s|%s|%s|%s|%s\n' "${n}" "${d}" "${u}" "${i}" "${l}"
            return 0
        fi
    done < <(_managed_tools_registry)
    return 1
}

# Source a tools/ file if the named function isn't already loaded.
_update_ensure_fn() {
    local fn="$1" rel="$2"
    command -v "${fn}" &>/dev/null && return 0
    # shellcheck disable=SC1090
    [[ -f "${SHELL_CONFIG_DIR}/${rel}" ]] && source "${SHELL_CONFIG_DIR}/${rel}"
    command -v "${fn}" &>/dev/null
}

_update_aws() { _update_ensure_fn aws-update tools/aws.sh   && aws-update; }
_update_az()  { _update_ensure_fn az-update  tools/azure.sh && az-update; }
_update_omp() { _update_ensure_fn update-omp tools/omp.sh   && update-omp; }

_update_kubectl() {
    _update_ensure_fn set-kubectl tools/kubernetes.sh || { log_warn "set-kubectl not available"; return 1; }
    set-kubectl -s
}

_update_omz() {
    local zsh_dir="${ZSH:-${HOME}/.oh-my-zsh}"
    if [[ -x "${zsh_dir}/tools/upgrade.sh" ]]; then
        log_info "oh-my-zsh: running upgrade.sh ..."
        "${zsh_dir}/tools/upgrade.sh"
    elif command -v omz &>/dev/null; then
        omz update
    else
        log_warn "oh-my-zsh: no upgrade mechanism found (expected ${zsh_dir}/tools/upgrade.sh)"
        return 1
    fi
}

# Terraform / OpenTofu are tenv proxies once tenv is installed, so tenv owns
# their updates. install-tenv refreshes the manager; then we pull the newest
# version of whichever tools already have a tenv-managed version (without
# changing the pinned `use` version).
_update_tenv_managed() {
    install-tenv || return 1
    command -v tenv &>/dev/null || return 1
    local tool
    for tool in tofu tf; do
        if tenv "${tool}" list 2>/dev/null | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'; then
            log_info "tenv: installing latest ${tool} ..."
            tenv "${tool}" install latest
        fi
    done
}

_update_terraform() {
    if command -v tenv &>/dev/null; then
        log_info "Terraform is managed by tenv (handled with tenv above)."
        return 0
    fi
    install-terraform
}

_update_tofu() {
    if command -v tenv &>/dev/null; then
        log_info "OpenTofu is managed by tenv (handled with tenv above)."
        return 0
    fi
    log_warn "OpenTofu present without tenv and no standalone updater — run install-tenv to manage it."
    return 0
}

# Run one row's updater; record the outcome into the caller's result arrays.
# $1 name  $2 detect  $3 updater  $4 installer  $5 label
_update_run_row() {
    local n="$1" d="$2" u="$3" i="$4" l="$5"
    if ! _update_detect "${d}"; then
        log_info "${l} is not installed — install it with: ${i}"
        not_installed+=("${n}")
        return 0
    fi
    log_info "-- ${l} --"
    if "${u}"; then
        done_ok+=("${n}")
    else
        log_warn "update-tools: ${l} updater returned non-zero"
        failed+=("${n}")
    fi
}

update-tools() {
    # Usage:
    #   update-tools             update every managed tool that is installed
    #   update-tools <tool>...   update only the named tools (by name)
    #   update-tools --list      show the registry and install status
    local list_only=false
    local -a wanted=()
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --list|-l) list_only=true ;;
            -h|--help)
                printf '%s\n' \
                    "update-tools [--list] [tool ...]" \
                    "  (no args) update all installed managed tools" \
                    "  tool...   update only named tools" \
                    "  --list    list managed tools and install status"
                return 0 ;;
            *) wanted+=("${arg}") ;;
        esac
    done

    local n d u i l
    if [[ "${list_only}" == "true" ]]; then
        printf '%-12s %-10s %s\n' "TOOL" "INSTALLED" "DESCRIPTION"
        while IFS='|' read -r n d u i l; do
            [[ -z "${n}" ]] && continue
            if _update_detect "${d}"; then
                printf '%-12s %-10s %s\n' "${n}" "yes" "${l}"
            else
                printf '%-12s %-10s %s\n' "${n}" "-"   "${l}"
            fi
        done < <(_managed_tools_registry)
        return 0
    fi

    log_info "== update-tools: refreshing managed tools =="
    local -a done_ok=() failed=() not_installed=() unknown=()

    if [[ ${#wanted[@]} -gt 0 ]]; then
        local w row
        for w in "${wanted[@]}"; do
            if ! row="$(_managed_tool_row "${w}")"; then
                log_warn "update-tools: '${w}' is not a managed tool. Run 'update-tools --list' to see managed tools."
                unknown+=("${w}")
                continue
            fi
            IFS='|' read -r n d u i l <<< "${row}"
            _update_run_row "${n}" "${d}" "${u}" "${i}" "${l}"
        done
    else
        while IFS='|' read -r n d u i l; do
            [[ -z "${n}" ]] && continue
            _update_run_row "${n}" "${d}" "${u}" "${i}" "${l}"
        done < <(_managed_tools_registry)
    fi

    echo
    log_info "== update-tools summary =="
    [[ ${#done_ok[@]}       -gt 0 ]] && log_info "updated       : ${done_ok[*]}"
    [[ ${#failed[@]}        -gt 0 ]] && log_warn "failed        : ${failed[*]}"
    [[ ${#not_installed[@]} -gt 0 ]] && log_info "not installed : ${not_installed[*]}"
    [[ ${#unknown[@]}       -gt 0 ]] && log_warn "unknown       : ${unknown[*]}"
    [[ ${#failed[@]} -eq 0 && ${#unknown[@]} -eq 0 ]]
}

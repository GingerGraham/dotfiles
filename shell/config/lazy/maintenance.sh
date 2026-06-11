#!/usr/bin/env bash
# Lazy-loaded maintenance — managed-tool update orchestration.
# Sourced via stub in loader.sh on first call to a public function here.
#
# update-tools walks a registry of managed tools and, for each one that is
# actually installed, runs its individual installer/updater. Installers live in
# lazy/installers.sh; per-tool update helpers live in tools/*.sh. Nothing here
# installs a tool that isn't already present — use the install-* commands
# (see: installers) for first-time installs.

# Registry: one row per managed tool, pipe-separated as
#   <detect-command>|<updater-function>|<label>
# detect-command is what `command -v` is tested against; updater-function runs
# only when that command exists. Order matters — tenv is first so it claims the
# terraform/tofu proxies before their own rows are evaluated.
#
# NOTE: detect-commands for claude/copilot/bw assume the binary names `claude`,
# `copilot`, `bw`. Adjust if your install exposes different names.
_managed_tools_registry() {
    cat <<'EOF'
tenv|_update_tenv_managed|tenv (Terraform/OpenTofu)
terraform|_update_terraform|Terraform
tofu|_update_tofu|OpenTofu
aws|_update_aws|AWS CLI
az|_update_az|Azure CLI
kubectl|_update_kubectl|kubectl
helm|install-helm|Helm
tflint|install-tflint|TFLint
trivy|install-trivy|Trivy
ansible|install-ansible|Ansible
gh|install-gh|GitHub CLI
oh-my-posh|_update_omp|oh-my-posh
edit|install-edit|Microsoft Edit
claude|install-claude-code|Claude Code
copilot|install-copilot-cli|GitHub Copilot CLI
bw|install-bw-cli|Bitwarden CLI
EOF
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

update-tools() {
    # Usage:
    #   update-tools             update every managed tool that is installed
    #   update-tools <tool>...   update only the named tools (detect-command names)
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
                    "  tool...   update only named tools (detect-command names)" \
                    "  --list    list managed tools and install status"
                return 0 ;;
            *) wanted+=("${arg}") ;;
        esac
    done

    local d u l
    if [[ "${list_only}" == "true" ]]; then
        printf '%-12s %-10s %s\n' "TOOL" "INSTALLED" "DESCRIPTION"
        while IFS='|' read -r d u l; do
            [[ -z "${d}" ]] && continue
            if command -v "${d}" &>/dev/null; then
                printf '%-12s %-10s %s\n' "${d}" "yes" "${l}"
            else
                printf '%-12s %-10s %s\n' "${d}" "-"   "${l}"
            fi
        done < <(_managed_tools_registry)
        return 0
    fi

    log_info "== update-tools: refreshing managed tools =="
    local -a done_ok=() failed=() skipped=()
    while IFS='|' read -r d u l; do
        [[ -z "${d}" ]] && continue

        if [[ ${#wanted[@]} -gt 0 ]]; then
            local match=false w
            for w in "${wanted[@]}"; do [[ "${w}" == "${d}" ]] && match=true; done
            [[ "${match}" == "true" ]] || continue
        fi

        if ! command -v "${d}" &>/dev/null; then
            skipped+=("${d}")
            continue
        fi

        log_info "-- ${l} --"
        if "${u}"; then
            done_ok+=("${d}")
        else
            log_warn "update-tools: ${l} updater returned non-zero"
            failed+=("${d}")
        fi
    done < <(_managed_tools_registry)

    echo
    log_info "== update-tools summary =="
    [[ ${#done_ok[@]} -gt 0 ]] && log_info "updated : ${done_ok[*]}"
    [[ ${#failed[@]}  -gt 0 ]] && log_warn "failed  : ${failed[*]}"
    if [[ ${#wanted[@]} -eq 0 && ${#skipped[@]} -gt 0 ]]; then
        log_debug "skipped (not installed): ${skipped[*]}"
    fi
    [[ ${#failed[@]} -eq 0 ]]
}

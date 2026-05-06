#!/usr/bin/env bash
# Lazy-loaded maintenance functions — system-wide tool update orchestration.
# Sourced via stub in loader.sh on first call to update-tools.

update-tools() {
    log_info "== Updating all tools =="

    log_info "== Updating AWS CLI =="
    if command -v aws-update &>/dev/null; then
        aws-update
    elif [[ -f "${SHELL_CONFIG_DIR}/tools/aws.sh" ]]; then
        # shellcheck disable=SC1091
        source "${SHELL_CONFIG_DIR}/tools/aws.sh"
        aws-update
    fi

    log_info "== Updating kubectl =="
    set-kubectl -s

    log_info "== Installing/updating Helm =="
    helm-install

    log_info "== Updating Terraform =="
    terraform-install

    log_info "== Updating Ansible =="
    ansible-install

    log_info "== Updating Microsoft Edit =="
    install-edit

    log_info "== Update complete =="
}

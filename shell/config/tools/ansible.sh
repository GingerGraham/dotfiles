#!/usr/bin/env bash
# Ansible tool configuration — aliases and vault helpers.
# Sourced only when ansible is present (guarded in loader.sh).

# ── functions ─────────────────────────────────────────────────────────────────
if command -v ansible &>/dev/null; then
    ansible-vault-decrypt() {
        local VAULT_PASS="" FILES=()

        if ! command -v ansible &>/dev/null; then
            log_error "ansible is not installed"; return 1
        fi

        while getopts ":p:" opt; do
            case ${opt} in
                p) VAULT_PASS="${OPTARG}" ;;
                \?) log_error "Invalid option: -${OPTARG}"; return 1 ;;
            esac
        done
        shift $((OPTIND - 1))

        for arg in "$@"; do
            [[ ! "${arg}" =~ ^- ]] && FILES+=("${arg}")
        done

        if [[ ${#FILES[@]} -eq 0 ]]; then
            log_error "No files to decrypt"; return 1
        fi

        # Honour vault_password_file from ansible.cfg if present
        if [[ -f "ansible.cfg" ]] && grep -q "vault_password_file" "ansible.cfg"; then
            local cfg_vaultfile
            cfg_vaultfile="$(grep vault_password_file ansible.cfg | cut -d= -f2 | tr -d ' ')"
            if [[ -f "${cfg_vaultfile}" ]]; then
                for file in "${FILES[@]}"; do ansible-vault decrypt "${file}"; done
                return 0
            fi
        fi

        [[ -n "${VAULT_PASS}" && ! -f "${VAULT_PASS}" ]] && { log_warn "Vault pass file not found"; VAULT_PASS=""; }

        if [[ -n "${VAULT_PASS}" ]]; then
            for file in "${FILES[@]}"; do ansible-vault decrypt --vault-password-file "${VAULT_PASS}" "${file}"; done
        else
            for file in "${FILES[@]}"; do ansible-vault decrypt "${file}"; done
        fi
    }

    ansible-vault-encrypt() {
        local VAULT_PASS="" FILES=()

        if ! command -v ansible &>/dev/null; then
            log_error "ansible is not installed"; return 1
        fi

        while getopts ":p:" opt; do
            case ${opt} in
                p) VAULT_PASS="${OPTARG}" ;;
                \?) log_error "Invalid option: -${OPTARG}"; return 1 ;;
            esac
        done
        shift $((OPTIND - 1))

        for arg in "$@"; do
            [[ ! "${arg}" =~ ^- ]] && FILES+=("${arg}")
        done

        if [[ ${#FILES[@]} -eq 0 ]]; then
            log_error "No files to encrypt"; return 1
        fi

        if [[ -f "ansible.cfg" ]] && grep -q "vault_password_file" "ansible.cfg"; then
            local cfg_vaultfile
            cfg_vaultfile="$(grep vault_password_file ansible.cfg | cut -d= -f2 | tr -d ' ')"
            if [[ -f "${cfg_vaultfile}" ]]; then
                for file in "${FILES[@]}"; do ansible-vault encrypt "${file}"; done
                return 0
            fi
        fi

        [[ -n "${VAULT_PASS}" && ! -f "${VAULT_PASS}" ]] && { log_warn "Vault pass file not found"; VAULT_PASS=""; }

        if [[ -n "${VAULT_PASS}" ]]; then
            for file in "${FILES[@]}"; do ansible-vault encrypt --vault-password-file "${VAULT_PASS}" "${file}"; done
        else
            for file in "${FILES[@]}"; do ansible-vault encrypt "${file}"; done
        fi
    }

    # ── aliases ───────────────────────────────────────────────────────────────────
    alias ap="ansible-playbook"
    if command -v ansible-vault-decrypt &>/dev/null; then
        alias avd="ansible-vault decrypt"
    fi
    if command -v ansible-vault-encrypt &>/dev/null; then
        alias ave="ansible-vault encrypt"
    fi
fi

#!/usr/bin/env bash
# SSH helpers — listing hosts and key management.

# ── List SSH hosts ─────────────────────────────────────────────────────────────
list-ssh-hosts() {
    local config_dir="${HOME}/.ssh/config.d"
    local main_config="${HOME}/.ssh/config"

    if [[ -f "${main_config}" ]]; then
        echo "=== Main Config ==="
        grep -E "^Host\s" "${main_config}" | sed 's/Host //'
        echo
    fi

    if [[ -d "${config_dir}" ]]; then
        for config_file in "${config_dir}"/*; do
            [[ -f "${config_file}" ]] || continue
            echo "=== $(basename "${config_file}") ==="
            grep -E "^Host\s" "${config_file}" | sed 's/Host //'
            echo
        done
    fi
}

# ── Copy SSH keys from agent to a remote host ─────────────────────────────────
ssh-copy-bw() {
    local usage="Usage: ssh-copy-bw [--all] <user@host|user host> [key_pattern]

Examples:
  ssh-copy-bw user@server.example.com \"My Key\"
  ssh-copy-bw user server.example.com \"2025-01-30\"
  ssh-copy-bw --all user@server.example.com"

    local copy_all=false user_host="" key_pattern=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)   copy_all=true; shift ;;
            -h|--help) echo "${usage}"; return 0 ;;
            *)
                if [[ -z "${user_host}" ]]; then
                    user_host="$1"
                elif [[ "${user_host}" != *"@"* && -z "${key_pattern}" ]]; then
                    user_host="${user_host}@$1"
                elif [[ -z "${key_pattern}" ]]; then
                    key_pattern="$1"
                else
                    log_error "Too many arguments"; echo "${usage}"; return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${user_host}" ]]; then
        log_error "user@host is required"; echo "${usage}"; return 1
    fi

    if [[ "${copy_all}" == false && -z "${key_pattern}" ]]; then
        log_error "key pattern is required unless --all is specified"
        echo "${usage}"; return 1
    fi

    local available_keys
    available_keys="$(ssh-add -L 2>/dev/null)" || {
        log_error "No SSH keys found in agent"; return 1
    }

    if [[ -z "${available_keys}" ]]; then
        log_error "No SSH keys available in agent"; return 1
    fi

    local keys_to_copy
    if [[ "${copy_all}" == true ]]; then
        keys_to_copy="${available_keys}"
        log_info "Copying all $(echo "${available_keys}" | wc -l) key(s) to ${user_host}..."
    else
        keys_to_copy="$(echo "${available_keys}" | grep "${key_pattern}")"
        if [[ -z "${keys_to_copy}" ]]; then
            log_error "No keys matching '${key_pattern}'"
            log_info "Available keys:"; echo "${available_keys}"; return 1
        fi
        log_info "Copying $(echo "${keys_to_copy}" | wc -l) key(s) to ${user_host}..."
    fi

    if echo "${keys_to_copy}" | ssh "${user_host}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo 'Keys added'"; then
        log_info "SSH keys copied successfully"
    else
        log_error "Failed to copy SSH keys to ${user_host}"; return 1
    fi
}

#!/usr/bin/env bash
# Core functions — general-purpose utilities available in every shell.

# ── Shared interactive helpers ────────────────────────────────────────────────
# Used by lazy/ files (installers, gpg-management). Defined here so they are
# available regardless of which lazy file is sourced first.

# _read_prompt <prompt_string> <variable_name>
# Portable prompt+read for bash and zsh. zsh's `read -p` means "read from
# coprocess", so we drive prompt and input through /dev/tty directly.
_read_prompt() {
    local _rp_prompt="$1"
    local _rp_var="$2"
    local _rp_value
    printf '%s' "${_rp_prompt}" >/dev/tty
    IFS= read -r _rp_value </dev/tty
    eval "${_rp_var}=\${_rp_value}"
}

# _read_prompt_silent <prompt_string> <variable_name>
# Silent prompt + read (no echo) for bash and zsh.
# The explicit printf '\n' after read is required because the suppressed
# Enter keypress produces no newline on screen.
_read_prompt_silent() {
    local _rp_prompt="$1"
    local _rp_var="$2"
    local _rp_value
    printf '%s' "${_rp_prompt}" >/dev/tty
    IFS= read -rs _rp_value </dev/tty
    printf '\n' >/dev/tty
    eval "${_rp_var}=\${_rp_value}"
}

# _str_lower <string>
# Portable lowercase — bash ${var,,} is not supported in zsh.
_str_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# _array_get <array_name> <1-based-index>
# Portable 1-based array access for bash and zsh.
_array_get() {
    local _ag_arr="$1" _ag_idx="$2"
    if [[ -n "${ZSH_VERSION}" ]]; then
        eval "printf '%s' \"\${${_ag_arr}[${_ag_idx}]}\""
    else
        eval "printf '%s' \"\${${_ag_arr}[$((${_ag_idx} - 1))]}\""
    fi
}

# ── cheat.sh lookup ───────────────────────────────────────────────────────────
cheat() {
    curl "https://cheat.sh/$1"
}

# ── PATH deduplication ────────────────────────────────────────────────────────
dedupe-path() {
    if ! command -v awk &>/dev/null || ! command -v tr &>/dev/null || ! command -v sed &>/dev/null; then
        log_error "dedupe-path: awk, tr, and sed are required"
        return 1
    fi
    # shellcheck disable=SC2155
    export PATH="$(echo "${PATH}" | tr ':' '\n' | awk '!seen[$0]++' | tr '\n' ':' | sed 's/:$//')"
}

# ── Package manager detection ─────────────────────────────────────────────────
detect-package-manager() {
    if command -v apt     &>/dev/null; then PACKAGE_MANAGER="apt"
    elif command -v dnf   &>/dev/null; then PACKAGE_MANAGER="dnf"
    elif command -v yum   &>/dev/null; then PACKAGE_MANAGER="yum"
    elif command -v zypper &>/dev/null; then PACKAGE_MANAGER="zypper"
    elif command -v pacman &>/dev/null; then PACKAGE_MANAGER="pacman"
    elif command -v brew  &>/dev/null; then PACKAGE_MANAGER="brew"
    else
        log_error "detect-package-manager: no supported package manager found"
        return 1
    fi
    export PACKAGE_MANAGER
    log_info "Using package manager: ${PACKAGE_MANAGER}"
}

# ── Distro detection ──────────────────────────────────────────────────────────
detect-distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        [[ -n "${NAME}" ]] && OS="${NAME}"
    fi
    if [[ -z "${OS}" ]]; then
        log_error "detect-distro: unable to detect OS"
        return 1
    fi
    log_info "Detected OS: ${OS}"
}

# ── Privilege elevation helpers ───────────────────────────────────────────────
sudo-test() {
    if sudo -l -U "${USER}" &>/dev/null; then
        return 0
    elif command -v run0 &>/dev/null && run0 -l -U "${USER}" &>/dev/null; then
        log_debug "User has run0 access"
        return 0
    fi
    log_error "No sudo/run0 access for ${USER}"
    return 1
}

get-elevation-command() {
    if command -v sudo &>/dev/null && sudo -l -U "${USER}" &>/dev/null; then
        echo "sudo"
        return 0
    elif command -v run0 &>/dev/null && run0 -l -U "${USER}" &>/dev/null; then
        log_debug "Using run0 for privilege elevation"
        echo "run0"
        return 0
    fi
    log_error "No privilege elevation mechanism available"
    return 1
}

elevate-cmd() {
    local cmd_to_run="$*"
    local elevation_cmd

    if [[ -z "${cmd_to_run}" ]]; then
        log_error "elevate-cmd: no command specified"
        return 1
    fi

    elevation_cmd="$(get-elevation-command)" || return 1

    if [[ "${elevation_cmd}" == "run0" ]]; then
        log_warn "Using run0 — you may be prompted multiple times (no credential caching)"
    fi

    log_debug "Executing with ${elevation_cmd}: ${cmd_to_run}"
    ${elevation_cmd} ${cmd_to_run}
}

# ── Introspection: list loaded functions and aliases ──────────────────────────
# install-* functions are excluded — use get-my-installers (alias: installers) to list them.
get-my-functions() {
    local _config_dir="${SHELL_CONFIG_DIR:-${HOME}/.config/shell}"
    echo
    echo "[INFO] Loaded functions:"
    if [[ -n "${BASH_VERSION}" ]]; then
        # shellcheck disable=SC2016
        declare -F \
            | awk '{print $3}' \
            | grep -v '^_' \
            | grep -v '^install-' \
            | while read -r fn; do
                grep -rlq "^${fn}[[:space:]]*()" "${_config_dir}" 2>/dev/null \
                    && echo "${fn}"
              done \
            | sort | column
    elif [[ -n "${ZSH_VERSION}" ]]; then
        grep -Eho '^[a-zA-Z_-][a-zA-Z0-9_-]*[[:space:]]*\(\)' \
            "${_config_dir}"/**/*.sh 2>/dev/null \
            | sed 's/[[:space:]]*()//' | awk -F: '{print $NF}' \
            | grep -v '^_' \
            | grep -v '^install-' \
            | sort -u | column
    fi

    echo
    echo "[INFO] Loaded aliases:"
    if [[ -n "${BASH_VERSION}" ]]; then
        alias | sed 's/alias //g' | awk -F= '{print $1}' | sort | column
    elif [[ -n "${ZSH_VERSION}" ]]; then
        # shellcheck disable=SC2154
        alias -L | sed 's/alias //g' | awk -F= '{print $1}' | sort | column
    fi
    echo
    echo "[INFO] Run 'get-my-installers' (or 'installers') to list install commands."
}

# ── Introspection: list install-* functions ───────────────────────────────────
get-my-installers() {
    local _config_dir="${SHELL_CONFIG_DIR:-${HOME}/.config/shell}"
    echo
    echo "[INFO] Install commands (lazy-loaded on first use):"
    if [[ -n "${BASH_VERSION}" ]]; then
        declare -F \
            | awk '{print $3}' \
            | grep '^install-' \
            | sort | column
    elif [[ -n "${ZSH_VERSION}" ]]; then
        grep -Eho '^install-[a-zA-Z0-9_-]+[[:space:]]*\(\)' \
            "${_config_dir}"/**/*.sh 2>/dev/null \
            | sed 's/[[:space:]]*()//' \
            | sort -u | column
    fi
    echo
}

# ── Introspection: list GPG functions ─────────────────────────────────────────
# Shows functions from tools/gpg.sh (always loaded when gpg present) and
# lazy/gpg-management.sh (loaded on first call). Grouped by tier.
get-gpg-functions() {
    local _config_dir="${SHELL_CONFIG_DIR:-${HOME}/.config/shell}"
    local _tools_file="${_config_dir}/tools/gpg.sh"
    local _lazy_file="${_config_dir}/lazy/gpg-management.sh"

    local _extract_fns
    _extract_fns() {
        grep -Eo '^[a-zA-Z_-][a-zA-Z0-9_-]*[[:space:]]*\(\)' "$1" 2>/dev/null \
            | sed 's/[[:space:]]*()//' \
            | grep -v '^_' \
            | sort
    }

    echo
    echo "[INFO] GPG functions — tools/gpg.sh (Tier 2, always loaded when gpg present):"
    if [[ -f "${_tools_file}" ]]; then
        _extract_fns "${_tools_file}" | column
    else
        echo "  (file not found: ${_tools_file})"
    fi

    echo
    echo "[INFO] GPG functions — lazy/gpg-management.sh (Tier 3, lazy-loaded on first call):"
    if [[ -f "${_lazy_file}" ]]; then
        _extract_fns "${_lazy_file}" | column
    else
        echo "  (file not found: ${_lazy_file})"
    fi
    echo

    unset -f _extract_fns
}

# ── Introspection: list git functions ─────────────────────────────────────────
# Shows functions from tools/git.sh, grouped into project management and
# general helpers. Private helpers (prefixed _) are excluded.
get-git-functions() {
    local _config_dir="${SHELL_CONFIG_DIR:-${HOME}/.config/shell}"
    local _tools_file="${_config_dir}/tools/git.sh"

    if [[ ! -f "${_tools_file}" ]]; then
        echo
        echo "  (file not found: ${_tools_file})"
        echo
        return 1
    fi

    local _all_fns
    _all_fns="$(grep -Eo '^[a-zA-Z_-][a-zA-Z0-9_-]*[[:space:]]*\(\)' "${_tools_file}" \
        | sed 's/[[:space:]]*()//' \
        | grep -v '^_' \
        | sort)"

    echo
    echo "[INFO] Git project management functions (tools/git.sh):"
    echo "${_all_fns}" | grep -E '^git-(add|update|remove|list|sync|projects)-' | column

    echo
    echo "[INFO] Git helper functions (tools/git.sh):"
    echo "${_all_fns}" | grep -vE '^git-(add|update|remove|list|sync|projects)-' | column
    echo
}

# ── Shell Sourcing ────────────────────────────────────────
# Private helper — not intended to be called directly.
# Usage: _dotfiles_source_rc <rc_file> <logger_name> [--debug|--info|--notice|
#                             --warn|--error|--critical|--alert|--emergency]
_dotfiles_source_rc() {
    local rc_file="$1"
    local logger_name="$2"
    shift 2
    local log_level="INFO"

    for arg in "$@"; do
        case "$arg" in
            --debug)     log_level="DEBUG"     ;;
            --info)      log_level="INFO"       ;;
            --notice)    log_level="NOTICE"     ;;
            --warn)      log_level="WARN"       ;;
            --error)     log_level="ERROR"      ;;
            --critical)  log_level="CRITICAL"   ;;
            --alert)     log_level="ALERT"      ;;
            --emergency) log_level="EMERGENCY"  ;;
            *)
                echo "dotfiles: unknown option: $arg" >&2
                echo "  valid levels: --debug --info --notice --warn --error --critical --alert --emergency" >&2
                return 1
                ;;
        esac
    done

    export DOTFILES_LOG_LEVEL="$log_level"
    export DOTFILES_LOGGER_NAME="$logger_name"
    # shellcheck disable=SC1090
    source "$rc_file"
    unset DOTFILES_LOG_LEVEL DOTFILES_LOGGER_NAME 2>/dev/null || true
}

if [[ -n "${BASH_VERSION:-}" ]]; then
    bashsource() { _dotfiles_source_rc ~/.bashrc "bashrc" "$@"; }
fi
if [[ -n "${ZSH_VERSION:-}" ]]; then
    zshsource() { _dotfiles_source_rc ~/.zshrc "zshrc" "$@"; }
fi

# ── Misc utilities ────────────────────────────────────────────────────────────
get-python-versions() {
    echo "[INFO] Python versions found:"
    for version in /usr/bin/python3*; do
        [[ "${version}" == *-config ]] && continue
        echo "$(basename "${version}"): $("${version}" --version 2>&1)"
    done
}

get-public-ip() {
    if command -v dig &>/dev/null; then
        echo "IPv4: $(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | awk -F'"' '{print $2}')"
        echo "IPv6: $(dig -6 TXT +short o-o.myaddr.l.google.com @ns1.google.com | awk -F'"' '{print $2}')"
    else
        echo "IPv4: $(curl -s https://ipv4.icanhazip.com)"
        echo "IPv6: $(curl -s https://ipv6.icanhazip.com)"
    fi
}

open-workspace() {
    if ! command -v code &>/dev/null && ! command -v code-insiders &>/dev/null; then
        log_error "Visual Studio Code is not installed"
        return 1
    fi

    local workspace_path="${1:-${HOME}/Development/workspaces}"
    local workspaces_full_path=()

    [[ -L "${workspace_path}" ]] && workspace_path="$(readlink -f "${workspace_path}")"

    if [[ -d "${workspace_path}" ]]; then
        if command -v mapfile &>/dev/null; then
            mapfile -t workspaces_full_path < <(find "${workspace_path}" -type f -name "*.code-workspace")
        else
            # shellcheck disable=SC2207
            workspaces_full_path=($(find "${workspace_path}" -type f -name "*.code-workspace"))
        fi
    fi

    if [[ ${#workspaces_full_path[@]} -eq 0 ]]; then
        log_error "No workspaces found in ${workspace_path}"
        return 1
    fi

    local workspaces=()
    for workspace in "${workspaces_full_path[@]}"; do
        workspaces+=("$(basename "${workspace}" .code-workspace)")
    done

    echo "Available workspaces:"
    PS3="Select workspace: "
    select workspace in "${workspaces[@]}"; do
        if [[ -n "${workspace}" ]]; then
            for wsp in "${workspaces_full_path[@]}"; do
                if [[ "${workspace}" == "$(basename "${wsp}" .code-workspace)" ]]; then
                    if command -v code-insiders &>/dev/null; then
                        code-insiders "${wsp}"
                    else
                        code "${wsp}"
                    fi
                    break
                fi
            done
            break
        else
            log_error "Invalid selection, try again"
        fi
    done
}

show-ssh-tunnel() {
    pgrep -f 'ssh[[:space:]]+(-[fNL]+[[:space:]]+)*-?[fNL]+'
}

register-tpm() {
    local IFS=$'\n'
    local luks_devices=() partition_device="" enrolled_count=0

    for cmd in lsblk tpm2 dracut cryptsetup systemd-cryptenroll; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "register-tpm: required tool '${cmd}' is not installed"
            return 1
        fi
    done

    sudo-test || return 1

    while read -r line; do
        [[ "${line}" =~ ^NAME ]] && continue
        if [[ "${line}" =~ p[0-9]+[[:space:]] && ! "${line}" =~ crypt ]]; then
            partition_device="$(echo "${line}" | awk '{print $1}' | tr -d '└─├─')"
            read -r next_line
            if [[ "${next_line}" =~ crypt ]]; then
                local device_path="/dev/${partition_device}"
                if sudo cryptsetup isLuks "${device_path}" 2>/dev/null; then
                    echo "[INFO] Found LUKS partition: ${device_path}"
                    luks_devices+=("${device_path}")
                fi
            fi
        fi
    done < <(lsblk)

    for device_path in "${luks_devices[@]}"; do
        echo "[INFO] Enrolling TPM2 for ${device_path}..."
        if sudo systemd-cryptenroll \
                --wipe-slot=tpm2 \
                --tpm2-device=auto \
                --tpm2-pcrs="0+2+4+5+7" \
                "${device_path}"; then
            log_info "Successfully enrolled TPM2 for ${device_path}"
            ((enrolled_count++))
        else
            log_error "Failed to enroll TPM2 for ${device_path}"
        fi
    done

    log_info "TPM2 enrollment complete. Enrolled ${enrolled_count} device(s)."
    luks_devices=()
}

# ── Completion cache management ───────────────────────────────────────────────
refresh-completions() {
    rm -rf "${XDG_CACHE_HOME:-${HOME}/.cache}/dotfiles/completions/"
    log_info "Completion cache cleared — will regenerate on next shell start or source your rc file."
}

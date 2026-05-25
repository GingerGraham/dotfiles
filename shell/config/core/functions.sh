#!/usr/bin/env bash
# Core functions — general-purpose utilities available in every shell.

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
get-my-functions() {
    echo
    echo "[INFO] Loaded functions:"
    if [[ -n "${BASH_VERSION}" ]]; then
        # shellcheck disable=SC2016
        declare -F \
            | awk '{print $3}' \
            | grep -v '^_' \
            | while read -r fn; do
                grep -rlq "^${fn}[[:space:]]*()" "${SHELL_CONFIG_DIR:-${HOME}/.config/shell}" 2>/dev/null \
                    && echo "${fn}"
              done \
            | sort | column
    elif [[ -n "${ZSH_VERSION}" ]]; then
        grep -Eho '^[a-zA-Z_-][a-zA-Z0-9_-]*[[:space:]]*\(\)' \
            "${SHELL_CONFIG_DIR:-${HOME}/.config/shell}"/**/*.sh 2>/dev/null \
            | sed 's/()//' | awk -F: '{print $NF}' | grep -v '^_' | sort | column
    fi

    echo
    echo "[INFO] Loaded aliases:"
    if [[ -n "${BASH_VERSION}" ]]; then
        alias | sed 's/alias //g' | awk -F= '{print $1}' | sort | column
    elif [[ -n "${ZSH_VERSION}" ]]; then
        # shellcheck disable=SC2154
        alias -L | sed 's/alias //g' | awk -F= '{print $1}' | sort | column
    fi
}

# ── Misc utilities ────────────────────────────────────────────────────────────
get-go-version() {
    if command -v go &>/dev/null; then
        GO_VERSION="$(go version | awk '{print $3}' | tr -d 'go')"
        export GO_VERSION
    else
        log_error "go is not installed"
        return 1
    fi
}

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

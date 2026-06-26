#!/usr/bin/env bash
# Core functions — general-purpose utilities available in every shell.

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

# _resolve_realpath <path>
# Portable symlink resolution for Linux and macOS.
#   1. readlink -f  — GNU coreutils; available on all Linux distros
#   2. python3      — macOS ships Python 3 but not GNU coreutils by default
#   3. raw path     — last resort; only hit if both tools are absent
_resolve_realpath() {
    local _path="$1"
    if readlink -f "${_path}" &>/dev/null 2>&1; then
        readlink -f "${_path}"
    elif command -v python3 &>/dev/null; then
        python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${_path}"
    else
        echo "${_path}"
    fi
}

# _restore_managed_shell_files
# Resets all repo-managed shell stub files to their committed state via
# git restore. Used after third-party installers (nvm, antigravity, etc.)
# inject lines into managed RC files, leaving the working tree dirty and
# blocking the sync timer from pulling.
#
# The five files match shell_stubs in ansible/roles/shell/defaults/main.yml.
# Each is a symlink into the dotfiles repo; _resolve_realpath follows the
# link so git restore operates on the real file path inside the working tree.
_restore_managed_shell_files() {
    local -a _stubs=(
        "${HOME}/.bash_profile"
        "${HOME}/.bashrc"
        "${HOME}/.zprofile"
        "${HOME}/.zshrc"
        "${HOME}/.zshenv"
    )

    local _f _real _repo_root
    local _restored=0 _failed=0

    for _f in "${_stubs[@]}"; do
        # Skip stubs that don't exist on this machine (e.g. zsh files on a
        # bash-only server profile).
        [[ -e "${_f}" ]] || continue

        _real="$(_resolve_realpath "${_f}")"

        # Derive git repo root from the resolved path so git -C works correctly
        # regardless of cwd.
        _repo_root="$(git -C "$(dirname "${_real}")" rev-parse --show-toplevel 2>/dev/null)"
        if [[ -z "${_repo_root}" ]]; then
            log_warn "_restore_managed_shell_files: ${_real} is not inside a git repo — skipping"
            (( _failed++ )) || true
            continue
        fi

        if git -C "${_repo_root}" restore "${_real}" 2>/dev/null; then
            log_info "  restored: ${_real}"
            (( _restored++ )) || true
        else
            log_warn "  git restore failed: ${_real}"
            (( _failed++ )) || true
        fi
    done

    if (( _failed > 0 )); then
        log_warn "_restore_managed_shell_files: ${_failed} file(s) could not be restored"
        return 1
    fi

    log_info "_restore_managed_shell_files: ${_restored} file(s) restored to committed state"
    return 0
}

# unblock-sync
# Public entry point for clearing installer-injected debris from managed shell
# files. Restores all stub files to their committed state and reports the
# outcome. Useful after any installer that pollutes RC files (nvm, antigravity,
# etc.) or any time the dotfiles sync timer is blocked by a dirty working tree.
unblock-sync() {
    log_info "Restoring managed shell files to committed state..."

    if ! _restore_managed_shell_files; then
        log_warn "unblock-sync: some files could not be restored — check the output above"
        return 1
    fi

    # Show remaining git status for the managed files so the user can see if
    # anything is still dirty (e.g. a non-stub managed file was also modified).
    local _repo_root
    _repo_root="$(git -C "$(dirname "$(_resolve_realpath "${HOME}/.bashrc")")" \
        rev-parse --show-toplevel 2>/dev/null)"

    if [[ -n "${_repo_root}" ]]; then
        local _status
        _status="$(git -C "${_repo_root}" status --short 2>/dev/null)"
        if [[ -z "${_status}" ]]; then
            log_info "Working tree is clean — sync timer will proceed normally"
        else
            log_warn "Working tree still has changes (non-stub files?):"
            printf '%s\n' "${_status}" | while IFS= read -r _line; do
                log_warn "  ${_line}"
            done
        fi
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

# ── Getter pattern ──────────────────────────────────────────────────────────
# Two generic primitives that every "get-<domain>-functions" getter is built
# from — one for function names, one for alias names. Both take a label, an
# optional ERE pattern ("" = no filter, leading "!" = exclude matches instead
# of include), and one or more files. Private (_-prefixed) functions are
# always excluded; there's no equivalent alias convention so none are.
_extract_function_names() {
    grep -Eho '^[[:space:]]*[a-zA-Z_-][a-zA-Z0-9_-]*[[:space:]]*\(\)' "$@" 2>/dev/null \
        | sed -E 's/^[[:space:]]*//; s/[[:space:]]*\(\)$//' \
        | grep -v '^_' \
        | sort -u
}

_extract_alias_names() {
    grep -Eho '^[[:space:]]*alias [a-zA-Z0-9_-]+=' "$@" 2>/dev/null \
        | sed -E 's/^[[:space:]]*alias ([a-zA-Z0-9_-]+)=.*/\1/' \
        | sort -u
}

# $1 label   $2 pattern (ERE, "" = none, leading "!" = exclude)   $3.. files
_get_functions_in() {
    local _label="$1" _pattern="$2"; shift 2
    echo
    echo "[INFO] ${_label}:"
    if [[ $# -eq 0 ]]; then
        echo "  (no files given)"; echo; return 1
    fi
    local _names; _names="$(_extract_function_names "$@")"
    if [[ "${_pattern}" == \!* ]]; then
        _names="$(printf '%s\n' "${_names}" | grep -Ev "${_pattern#!}")"
    elif [[ -n "${_pattern}" ]]; then
        _names="$(printf '%s\n' "${_names}" | grep -E "${_pattern}")"
    fi
    if [[ -z "${_names}" ]]; then
        echo "  (none)"
    else
        printf '%s\n' "${_names}" | column
    fi
    echo
}

# $1 label   $2 pattern (ERE, "" = none, leading "!" = exclude)   $3.. files
# Live-state gate: only aliases actually defined in the current shell session
# are shown. Mirrors the declare -f gate used for functions — aliases that
# exist in source files but weren't loaded (e.g. distro-specific aliases on
# the wrong distro) are silently excluded. Works identically in bash and zsh:
# `alias name` exits 0 if defined, non-zero if not.
_get_aliases_in() {
    local _label="$1" _pattern="$2"; shift 2
    echo
    echo "[INFO] ${_label}:"
    if [[ $# -eq 0 ]]; then
        echo "  (no files given)"; echo; return 1
    fi
    local _names; _names="$(_extract_alias_names "$@")"
    if [[ "${_pattern}" == \!* ]]; then
        _names="$(printf '%s\n' "${_names}" | grep -Ev "${_pattern#!}")"
    elif [[ -n "${_pattern}" ]]; then
        _names="$(printf '%s\n' "${_names}" | grep -E "${_pattern}")"
    fi
    # Live-state gate: drop any alias not defined in this shell session.
    _names="$(printf '%s\n' "${_names}" | while IFS= read -r _an; do
        [[ -z "${_an}" ]] && continue
        alias "${_an}" &>/dev/null && echo "${_an}"
    done)"
    if [[ -z "${_names}" ]]; then
        echo "  (none)"
    else
        printf '%s\n' "${_names}" | column
    fi
    echo
}

# ── Getter registry ────────────────────────────────────────────────────────
# Maps each domain getter to what it covers. get-functions reads this to (a)
# exclude already-curated functions/aliases from its own output and (b) print
# the Getters section. Two filter forms, same idea as _managed_tools_registry's
# command/path: tokens:
#   file:<comma-separated paths relative to $SHELL_CONFIG_DIR>
#   prefix:<name prefix>
# Add a row here whenever a new get-<domain>-functions getter is added — see
# docs/shell-config.md for the full contract.
_function_getters_registry() {
    cat <<'EOF'
gpg|file:tools/gpg.sh,lazy/gpg-management.sh|get-gpg-functions|GPG key, signing & Git integration helpers
git|file:tools/git.sh|get-git-functions|Git project management & worktree helpers
terraform|file:tools/terraform.sh|get-terraform-functions|Terraform/OpenTofu/Terragrunt aliases & helpers
installers|prefix:install-|get-installers|Lazy-loaded install-* commands
EOF
}

# ── Introspection: list loaded functions and aliases ─────────────────────────
# Lists only functions and aliases defined in $SHELL_CONFIG_DIR — nothing from
# bash-logger, nvm stubs, zsh plugins, or any other external source can appear.
# loader.sh is excluded: it contains only infrastructure (fallback log_* stubs,
# detection logic) and no user-facing functions or aliases.
# Excludes private (_-prefixed) names and anything covered by a getter in the
# registry above — run that getter for full detail on each area.
get-functions() {
    local _config_dir="${SHELL_CONFIG_DIR:-${HOME}/.config/shell}"
    local _name _filter _getter _label _rel _f

    local -a _exclude_fn_names=() _exclude_alias_names=() _exclude_prefixes=()
    while IFS='|' read -r _name _filter _getter _label; do
        [[ -z "${_name}" ]] && continue
        case "${_filter}" in
            file:*)
                while IFS= read -r _rel; do
                    [[ -z "${_rel}" ]] && continue
                    _f="${_config_dir}/${_rel}"
                    [[ -f "${_f}" ]] || continue
                    while IFS= read -r _fn; do
                        [[ -n "${_fn}" ]] && _exclude_fn_names+=("${_fn}")
                    done < <(_extract_function_names "${_f}")
                    while IFS= read -r _an; do
                        [[ -n "${_an}" ]] && _exclude_alias_names+=("${_an}")
                    done < <(_extract_alias_names "${_f}")
                done < <(printf '%s\n' "${_filter#file:}" | tr ',' '\n')
                ;;
            prefix:*)
                _exclude_prefixes+=("${_filter#prefix:}")
                ;;
        esac
    done < <(_function_getters_registry)

    _getfns_excluded() {
        local _fn="$1" _e _p
        for _e in "${_exclude_fn_names[@]}"; do [[ "${_fn}" == "${_e}" ]] && return 0; done
        for _p in "${_exclude_prefixes[@]}"; do [[ "${_fn}" == "${_p}"* ]] && return 0; done
        return 1
    }
    _getalias_excluded() {
        local _an="$1" _e
        for _e in "${_exclude_alias_names[@]}"; do [[ "${_an}" == "${_e}" ]] && return 0; done
        return 1
    }

    # Collect source files: all .sh under $SHELL_CONFIG_DIR, excluding loader.sh
    # (loader.sh is infrastructure — fallback log_* stubs, detection — not user API)
    local _globstar_was_off=0
    local -a _source_files=()
    if [[ -n "${BASH_VERSION}" ]]; then
        shopt -q globstar || { shopt -s globstar; _globstar_was_off=1; }
    fi
    while IFS= read -r _sf; do
        [[ -n "${_sf}" ]] && _source_files+=("${_sf}")
    done < <(printf '%s\n' "${_config_dir}"/**/*.sh 2>/dev/null \
        | grep -v "/${_config_dir##*/}/loader\.sh$" \
        | grep -Fv "/loader.sh")
    if [[ -n "${BASH_VERSION}" && "${_globstar_was_off}" -eq 1 ]]; then
        shopt -u globstar
    fi

    # ── Functions ─────────────────────────────────────────────────────────────
    echo
    echo "[INFO] Loaded functions:"
    if [[ "${#_source_files[@]}" -gt 0 ]]; then
        _extract_function_names "${_source_files[@]}" \
            | sort -u \
            | while read -r fn; do
                [[ -z "${fn}" ]] && continue
                declare -f "${fn}" &>/dev/null || continue
                _getfns_excluded "${fn}" || echo "${fn}"
              done \
            | column
    fi

    # ── Aliases ───────────────────────────────────────────────────────────────
    # Live-state gate: `alias name` exits 0 if defined in this shell session,
    # non-zero otherwise — works identically in bash and zsh. This ensures
    # distro-specific aliases (apt-update, dnf-update, etc.) never appear on
    # systems where their source file wasn't loaded.
    echo
    echo "[INFO] Loaded aliases:"
    if [[ "${#_source_files[@]}" -gt 0 ]]; then
        _extract_alias_names "${_source_files[@]}" \
            | sort -u \
            | while read -r an; do
                [[ -z "${an}" ]] && continue
                alias "${an}" &>/dev/null || continue
                _getalias_excluded "${an}" || echo "${an}"
              done \
            | column
    fi

    echo
    echo "[INFO] Getters — run any of these for full detail on that area:"
    while IFS='|' read -r _name _filter _getter _label; do
        [[ -z "${_name}" ]] && continue
        printf '  %-22s %s\n' "${_getter}" "${_label}"
    done < <(_function_getters_registry)
    echo

    unset -f _getfns_excluded _getalias_excluded
}

# ── Introspection: list install-* functions ───────────────────────────────────
get-installers() {
     local _config_dir="${SHELL_CONFIG_DIR:-${HOME}/.config/shell}"
     local -a _installer_files=( "${_config_dir}"/lazy/installers*.sh )
     if [[ "${DOTFILES_OPTIONAL_INSTALLERS:-false}" == "true" ]]; then
         _installer_files+=( "${_config_dir}"/lazy/optional/installers*.sh )
     fi
     _get_functions_in "Install commands (lazy-loaded on first use)" '^install-' \
         "${_installer_files[@]}"
 }

# ── Introspection: list GPG functions and aliases ─────────────────────────────
get-gpg-functions() {
    local _config_dir="${SHELL_CONFIG_DIR:-${HOME}/.config/shell}"
    _get_functions_in "GPG functions — tools/gpg.sh (Tier 2, always loaded when gpg present)" \
        "" "${_config_dir}/tools/gpg.sh"
    _get_aliases_in "GPG aliases — tools/gpg.sh" \
        "" "${_config_dir}/tools/gpg.sh"
    _get_functions_in "GPG functions — lazy/gpg-management.sh (Tier 3, lazy-loaded on first call)" \
        "" "${_config_dir}/lazy/gpg-management.sh"
}

# ── Introspection: list git functions ─────────────────────────────────────────
get-git-functions() {
    local _config_dir="${SHELL_CONFIG_DIR:-${HOME}/.config/shell}"
    local _f="${_config_dir}/tools/git.sh"
    _get_aliases_in "Git aliases (tools/git.sh)" \
        "" "${_f}"
    _get_functions_in "Git project management functions (tools/git.sh)" \
        '^git-(add|update|remove|list|sync|projects)-' "${_f}"
    _get_functions_in "Git helper functions (tools/git.sh)" \
        '!^git-(add|update|remove|list|sync|projects)-' "${_f}"
}

# ── Introspection: list Terraform/OpenTofu/Terragrunt functions and aliases ──
get-terraform-functions() {
    local _config_dir="${SHELL_CONFIG_DIR:-${HOME}/.config/shell}"
    local _f="${_config_dir}/tools/terraform.sh"
    _get_aliases_in "Terraform / OpenTofu / Terragrunt aliases (tools/terraform.sh)" \
        "" "${_f}"
    _get_functions_in "Terraform / OpenTofu functions (tools/terraform.sh)" \
        "" "${_f}"
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
    log_info "Python versions found:"
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

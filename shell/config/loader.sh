#!/usr/bin/env bash
# Shell configuration loader — sources all tiers in order.
# This file is the single entry point; stubs in ~/.bashrc and ~/.zshrc source it.

SHELL_CONFIG_DIR="${HOME}/.config/shell"
export SHELL_CONFIG_DIR

# ── bash-logger ───────────────────────────────────────────────────────────────
# Check user install first, then system-wide. Either satisfies the requirement.
_bash_logger_loaded=false

for _bl_path in \
    "${HOME}/.local/lib/bash-logger/logging.sh" \
    "/usr/local/lib/bash-logger/logging.sh"; do
    if [[ -f "${_bl_path}" ]]; then
        # shellcheck disable=SC1090
        source "${_bl_path}"
        # init_logger must be called after sourcing — script name auto-detection
        # returns "unknown" from RC file context so we set it explicitly.
        # DOTFILES_LOGGER_NAME and DOTFILES_LOG_LEVEL are injected by the
        # bashsource/zshsource functions; both fall back to safe defaults for
        # a normal shell startup.
        init_logger \
            --name  "${DOTFILES_LOGGER_NAME:-shell}" \
            --level "${DOTFILES_LOG_LEVEL:-INFO}"
        unset DOTFILES_LOG_LEVEL DOTFILES_LOGGER_NAME
        _bash_logger_loaded=true
        break
    fi
done
unset _bl_path

if [[ "${_bash_logger_loaded}" == "false" ]]; then
    # bash-logger is not installed — emit to stderr so output is never silently
    # dropped. log_debug is a no-op to avoid noise from conditional debug calls.
    log_info()  { printf '[INFO]  %s\n' "$*" >&2; }
    log_warn()  { printf '[WARN]  %s\n' "$*" >&2; }
    log_error() { printf '[ERROR] %s\n' "$*" >&2; }
    log_debug() { :; }
fi
unset _bash_logger_loaded

# ── OS / WSL / Distro detection (runs once) ──────────────────────────────────
_raw_os="$(uname -s)"
case "${_raw_os}" in
    Linux)  DOTFILES_OS="Linux" ;;
    Darwin) DOTFILES_OS="Mac"   ;;
    *)      DOTFILES_OS="Linux" ;;
esac
export DOTFILES_OS
unset _raw_os

if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    DOTFILES_WSL="true"
else
    DOTFILES_WSL="false"
fi
export DOTFILES_WSL

if [[ "${DOTFILES_OS}" == "Linux" && -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    _distro_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")"
    # shellcheck disable=SC1091
    _distro_id_like="$(. /etc/os-release 2>/dev/null && echo "${ID_LIKE:-}")"
    case "${_distro_id}" in
        fedora|rhel|centos|rocky|almalinux) DOTFILES_DISTRO="rhel" ;;
        ubuntu|debian|linuxmint|pop)        DOTFILES_DISTRO="debian" ;;
        opensuse*|sles)                     DOTFILES_DISTRO="suse" ;;
        manjaro|arch|endeavouros|garuda) DOTFILES_DISTRO="arch" ;;
        *)
            case "${_distro_id_like}" in
                *rhel*|*fedora*|*centos*) DOTFILES_DISTRO="rhel"   ;;
                *debian*|*ubuntu*)        DOTFILES_DISTRO="debian" ;;
                *suse*)                   DOTFILES_DISTRO="suse"   ;;
                *arch*)                   DOTFILES_DISTRO="arch"    ;;
                *)                        DOTFILES_DISTRO="unknown" ;;
            esac
            ;;
    esac
    unset _distro_id _distro_id_like
else
    DOTFILES_DISTRO="unknown"
fi
export DOTFILES_DISTRO

# ── Shell detection ───────────────────────────────────────────────────────────
if [[ -n "${ZSH_VERSION}" ]]; then
    DOTFILES_SHELL="zsh"
elif [[ -n "${BASH_VERSION}" ]]; then
    DOTFILES_SHELL="bash"
else
    DOTFILES_SHELL="sh"
fi
export DOTFILES_SHELL

# ── Behaviour flags ───────────────────────────────────────────────────────────
# Override any of these in env/90-local.sh — that file is sourced last.
DOTFILES_SHOW_FUNCTIONS="${DOTFILES_SHOW_FUNCTIONS:-false}"

# ── Lazy-load helper ─────────────────────────────────────────────────────────
bash_lazy_load() {
    local stub_name="$1"
    local source_file="$2"
    # shellcheck disable=SC2140,SC2086
    eval "${stub_name}() {
        unset -f ${stub_name}
        source \"${source_file}\"
        ${stub_name} \"\$@\"
    }"
}

# ── Tier 1: env/ — sourced in numeric order, no subprocesses ─────────────────
for _env_file in "${SHELL_CONFIG_DIR}/env"/[0-9][0-9]-*.sh; do
    # shellcheck disable=SC1090
    [[ -f "${_env_file}" ]] && source "${_env_file}"
done
unset _env_file

# ── Tier 1: core/ — always sourced ───────────────────────────────────────────
for _core_file in \
    "${SHELL_CONFIG_DIR}/core/aliases.sh" \
    "${SHELL_CONFIG_DIR}/core/functions.sh" \
    "${SHELL_CONFIG_DIR}/core/ssh.sh"; do
    # shellcheck disable=SC1090
    [[ -f "${_core_file}" ]] && source "${_core_file}"
done
unset _core_file

# ── Tier 1: shell-specific core ───────────────────────────────────────────────
# zsh.sh and bash.sh contain constructs that are illegal in the other shell,
# so they are sourced conditionally here rather than in the core/ glob loop.
if [[ "${DOTFILES_SHELL}" == "zsh" ]]; then
    # shellcheck disable=SC1091
    [[ -f "${SHELL_CONFIG_DIR}/core/zsh.sh" ]] && source "${SHELL_CONFIG_DIR}/core/zsh.sh"
elif [[ "${DOTFILES_SHELL}" == "bash" ]]; then
    # shellcheck disable=SC1091
    [[ -f "${SHELL_CONFIG_DIR}/core/bash.sh" ]] && source "${SHELL_CONFIG_DIR}/core/bash.sh"
fi

# ── Tier 2: tools/ — guarded by command availability ─────────────────────────
_source_if_cmd() {
    local cmd="$1"
    local file="$2"
    # shellcheck disable=SC1090
    command -v "${cmd}" &>/dev/null && [[ -f "${file}" ]] && source "${file}"
}

_source_if_any_cmd() {
    local file="${SHELL_CONFIG_DIR}/tools/${1}"
    shift
    for _cmd in "$@"; do
        if command -v "${_cmd}" &>/dev/null; then
            # shellcheck disable=SC1090
            [[ -f "${file}" ]] && source "${file}"
            return
        fi
    done
}

_source_if_cmd  git        "${SHELL_CONFIG_DIR}/tools/git.sh"
_source_if_cmd  kubectl    "${SHELL_CONFIG_DIR}/tools/kubernetes.sh"
_source_if_any_cmd terraform.sh  terraform tofu
_source_if_cmd  ansible    "${SHELL_CONFIG_DIR}/tools/ansible.sh"
_source_if_any_cmd containers.sh docker podman
_source_if_cmd  aws        "${SHELL_CONFIG_DIR}/tools/aws.sh"
_source_if_cmd  az         "${SHELL_CONFIG_DIR}/tools/azure.sh"
_source_if_cmd  go         "${SHELL_CONFIG_DIR}/tools/go.sh"

_source_if_cmd     fzf         "${SHELL_CONFIG_DIR}/tools/fzf.sh"

# zsh plugins — sourced only in zsh; check for at least one plugin before loading
if [[ "${DOTFILES_SHELL}" == "zsh" ]] && {
    [[ -d "${HOME}/.zsh/zsh-autosuggestions" ]]              ||
    [[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] ||
    [[ -d "${HOME}/.oh-my-zsh/custom/plugins/zsh-autosuggestions" ]] ||
    [[ -d "${HOME}/.zsh/zsh-syntax-highlighting" ]]          ||
    [[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] ||
    [[ -d "${HOME}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" ]]
}; then
    # shellcheck disable=SC1091
    [[ -f "${SHELL_CONFIG_DIR}/tools/zsh-plugins.sh" ]] && source "${SHELL_CONFIG_DIR}/tools/zsh-plugins.sh"
fi

# ── Tier 2: platform/ ─────────────────────────────────────────────────────────
case "${DOTFILES_OS}" in
    Linux) _platform_file="${SHELL_CONFIG_DIR}/platform/linux.sh" ;;
    Mac)   _platform_file="${SHELL_CONFIG_DIR}/platform/macos.sh" ;;
    *)     _platform_file="" ;;
esac
# shellcheck disable=SC1090
[[ -n "${_platform_file}" && -f "${_platform_file}" ]] && source "${_platform_file}"
unset _platform_file

if [[ "${DOTFILES_WSL}" == "true" ]]; then
    _wsl_file="${SHELL_CONFIG_DIR}/platform/wsl.sh"
    # shellcheck disable=SC1090
    [[ -f "${_wsl_file}" ]] && source "${_wsl_file}"
    unset _wsl_file
fi

# ── Tier 2: distro/ ───────────────────────────────────────────────────────────
_distro_file="${SHELL_CONFIG_DIR}/distro/${DOTFILES_DISTRO}.sh"
# shellcheck disable=SC1090
[[ -f "${_distro_file}" ]] && source "${_distro_file}"
unset _distro_file

# ── Completions ───────────────────────────────────────────────────────────────
# shellcheck disable=SC1091
command -v gh      &>/dev/null && [[ -f "${SHELL_CONFIG_DIR}/completions/gh.sh" ]]         && source "${SHELL_CONFIG_DIR}/completions/gh.sh"
# shellcheck disable=SC1091
command -v kubectl &>/dev/null && [[ -f "${SHELL_CONFIG_DIR}/completions/kubernetes.sh" ]] && source "${SHELL_CONFIG_DIR}/completions/kubernetes.sh"
# shellcheck disable=SC1091
{ command -v terraform &>/dev/null || command -v tofu &>/dev/null; } && [[ -f "${SHELL_CONFIG_DIR}/completions/terraform.sh" ]] && source "${SHELL_CONFIG_DIR}/completions/terraform.sh"

# ── Tier 3: lazy stubs — auto-discovered from lazy/*.sh ──────────────────────
# Any public function (no leading _) defined in a lazy/ file gets a stub
# automatically. To add a new lazy-loaded function: add it to the relevant
# lazy/ file and prefix private helpers with _. No changes needed here.
_register_lazy_stubs() {
    local source_file="$1"
    local fn
    while IFS= read -r fn; do
        [[ -n "${fn}" ]] && bash_lazy_load "${fn}" "${source_file}"
    done < <(grep -E '^[a-zA-Z][a-zA-Z0-9_-]+\s*\(\)' "${source_file}" 2>/dev/null \
             | sed 's/[[:space:]]*().*//')
}

for _lazy_file in "${SHELL_CONFIG_DIR}/lazy"/*.sh; do
    [[ -f "${_lazy_file}" ]] && _register_lazy_stubs "${_lazy_file}"
done
unset _lazy_file
unset -f _register_lazy_stubs

# Prompt engine — mutually exclusive; omp wins if both are present.
# OMZ guard also requires zsh since it only makes sense there.
if command -v oh-my-posh &>/dev/null; then
    # shellcheck disable=SC1091
    [[ -f "${SHELL_CONFIG_DIR}/tools/omp.sh" ]] && source "${SHELL_CONFIG_DIR}/tools/omp.sh"
elif [[ -d "${HOME}/.oh-my-zsh" ]] && [[ -n "${ZSH_VERSION}" ]]; then
    # shellcheck disable=SC1091
    [[ -f "${SHELL_CONFIG_DIR}/tools/omz.sh" ]] && source "${SHELL_CONFIG_DIR}/tools/omz.sh"
elif [[ -n "${ZSH_VERSION}" ]] && [[ -n "${_DOTFILES_DISTRO_PROMPT_FILE:-}" ]] && [[ -f "${_DOTFILES_DISTRO_PROMPT_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${_DOTFILES_DISTRO_PROMPT_FILE}"
    export DOTFILES_PROMPT_ENGINE="distro-native"
    log_debug "loader: using distro-native zsh prompt"
else
    log_warn "No prompt engine found (oh-my-posh or oh-my-zsh). Using system/default prompt."
    if [[ -n "${BASH_VERSION:-}" ]]; then
        # We own the prompt in this branch — don't defer to whatever /etc/bash.bashrc
        # set. Ubuntu ships a plain PS1 there; the colour upgrade normally happens in
        # the user ~/.bashrc we've replaced. Replicate that logic here.
        if [[ -x /usr/bin/tput ]] && tput setaf 1 &>/dev/null; then
            PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
        else
            PS1='\u@\h:\w\$ '
        fi
        # Preserve xterm/rxvt window title, same as Ubuntu default ~/.bashrc does
        case "${TERM}" in
            xterm*|rxvt*)
                PS1="\[\e]0;\u@\h: \w\a\]${PS1}"
                ;;
        esac
    fi
fi

unset _DOTFILES_DISTRO_PROMPT_FILE
unset -f _source_if_cmd _source_if_any_cmd

# ── Local overrides (always last) ─────────────────────────────────────────────
_local_env="${SHELL_CONFIG_DIR}/env/90-local.sh"
# shellcheck disable=SC1090
[[ -f "${_local_env}" ]] && source "${_local_env}"
unset _local_env

# ── Migration pending warning ─────────────────────────────────────────────────
_migration_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/dotfiles/migration"
if [[ -d "${_migration_dir}" ]]; then
    while IFS= read -r _bak; do
        log_warn "Migration backup: ${_bak}"
        log_warn "  Review it and add anything you want to keep to ${SHELL_CONFIG_DIR}/env/90-local.sh"
    done < <(find "${_migration_dir}" -maxdepth 1 -name "*.pre-dotfiles.bak" -type f 2>/dev/null)
fi
unset _migration_dir _bak

# ── PATH deduplication ────────────────────────────────────────────────────────
# Run after all tiers so every tool that extended PATH is already done.
# dedupe-path is defined in core/functions.sh and is always available.
dedupe-path 2>/dev/null || true

# ── Interactive startup ───────────────────────────────────────────────────────
# Only runs in interactive shells — skipped in scripts, cron, SSH non-interactive.
# Set DOTFILES_SHOW_FUNCTIONS=true in env/90-local.sh to enable.
if [[ $- == *i* ]] && [[ "${DOTFILES_SHOW_FUNCTIONS}" == "true" ]] && command -v get-my-functions &>/dev/null; then
    get-my-functions
fi
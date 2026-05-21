#!/usr/bin/env bash
# install.sh — dotfiles bootstrap entry point
#
# Bootstraps the dotfiles system on a new machine. This script assumes it is
# run from within the already-cloned dotfiles repository (the repo is public
# and manually cloned before running this script).
#
# On first run:
#   1. Checks and optionally installs prerequisites (git, python3, ansible-core)
#   2. Generates ansible/host_vars/localhost.yml interactively
#   3. Generates per-repo SSH deploy keys for the sync service and companion repos
#   4. Runs ansible-playbook to deploy configuration
#
# On subsequent runs:
#   - host_vars/localhost.yml is never overwritten if it exists
#   - SSH keys are never overwritten if they already exist
#   - Use --check for a dry run before applying changes
#
# Usage: ./install.sh [OPTIONS]
#
#   --profile <workstation|server|minimal>  Skip profile prompt
#   --machine-name <name>                   Skip hostname prompt
#   --playbook <site|server>                Playbook to run (default: site)
#   --check                                 Ansible dry-run (--check --diff)
#   --skip-ssh                              Skip SSH deploy key generation
#   --no-prereqs                            Skip prerequisite check/install
#   -h, --help                              Show this help

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

# ── Argument defaults ─────────────────────────────────────────────────────────
ARG_PROFILE=""
ARG_MACHINE_NAME=""
ARG_PLAYBOOK="site"
ARG_CHECK="false"
ARG_SKIP_SSH="false"
ARG_NO_PREREQS="false"

# Populated during execution (by generate_host_vars or read from existing file)
PROFILE=""
MACHINE_NAME=""
GIT_PERSONAL_EMAIL=""
GIT_WORK_EMAIL=""
NVIM_REPO_URL=""
AI_REPO_URL=""

# ── Colour output ─────────────────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput &>/dev/null; then
    _RED=$(tput setaf 1)
    _GREEN=$(tput setaf 2)
    _YELLOW=$(tput setaf 3)
    _BLUE=$(tput setaf 4)
    _BOLD=$(tput bold)
    _RESET=$(tput sgr0)
else
    _RED="" _GREEN="" _YELLOW="" _BLUE="" _BOLD="" _RESET=""
fi

info()   { echo "${_GREEN}[INFO]${_RESET}  $*"; }
warn()   { echo "${_YELLOW}[WARN]${_RESET}  $*"; }
error()  { echo "${_RED}[ERROR]${_RESET} $*" >&2; }
header() { echo; echo "${_BOLD}${_BLUE}── $* ${_RESET}"; echo; }
die()    { error "$*"; exit 1; }

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat << EOF
dotfiles install.sh v${VERSION}

Usage: $(basename "$0") [OPTIONS]

OPTIONS
  --profile <workstation|server|minimal>
      Skip the profile selection prompt and use the given value.

  --machine-name <name>
      Skip the machine name prompt and use the given value.

  --playbook <site|server>
      Ansible playbook to run. Defaults to 'site'.
      Use 'server' in combination with --profile server for server deployments.

  --check
      Pass --check --diff to ansible-playbook. Previews changes without
      applying them. Useful for validating before a first apply.

  --skip-ssh
      Skip SSH deploy key generation entirely. Repo URLs in host_vars are
      used as-is. Useful when your personal SSH key already has access to
      all required repositories.

  --no-prereqs
      Skip the prerequisite check and installation step. Use when you know
      git, python3 >= 3.9, and ansible-core >= 2.14 are already present.

  -h, --help
      Show this help.

PROFILES
  workstation   Full setup: common, shell, git, ssh, nvim, ai-tools, sync
  server        Common, shell, git, ssh, sync
  minimal       Common and shell only

  Note: nvim-config and ai-config repo URLs are not prompted for 'server' or
  'minimal' profiles because those roles do not run under those profiles.
  This is intentional — see ansible/roles/shell/README.md.

SSH DEPLOY KEYS
  When SSH key generation is not skipped, install.sh creates one ed25519
  deploy key per private repository:

    ~/.ssh/dotfiles_main    For the dotfiles sync service (read-only pull)
    ~/.ssh/dotfiles_nvim    For nvim-config (if URL provided)
    ~/.ssh/dotfiles_ai      For ai-config (if URL provided)

  SSH host aliases are written to ~/.ssh/config.d/10-dotfiles.conf.
  Use these aliases in your host_vars repo URLs, e.g.:
    git@github-dotfiles-nvim:user/nvim-config.git

  Each key needs to be added to its repository as a read-only deploy key
  (repo Settings → Deploy keys → Add deploy key → allow write access: NO).

EXAMPLES
  ./install.sh                                    Interactive first run
  ./install.sh --check                            Dry run — preview changes
  ./install.sh --profile workstation              Skip profile prompt
  ./install.sh --profile server --playbook server Server deployment
  ./install.sh --no-prereqs --skip-ssh            Re-run Ansible only
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                [[ -z "${2:-}" ]] && die "--profile requires an argument (workstation|server|minimal)"
                case "$2" in
                    workstation|server|minimal) ARG_PROFILE="$2" ;;
                    *) die "Invalid profile '${2}'. Valid values: workstation, server, minimal" ;;
                esac
                shift 2
                ;;
            --machine-name)
                [[ -z "${2:-}" ]] && die "--machine-name requires an argument"
                ARG_MACHINE_NAME="$2"
                shift 2
                ;;
            --playbook)
                [[ -z "${2:-}" ]] && die "--playbook requires an argument (site|server)"
                case "$2" in
                    site|server) ARG_PLAYBOOK="$2" ;;
                    *) die "Invalid playbook '${2}'. Valid values: site, server" ;;
                esac
                shift 2
                ;;
            --check)      ARG_CHECK="true"; shift ;;
            --skip-ssh)   ARG_SKIP_SSH="true"; shift ;;
            --no-prereqs) ARG_NO_PREREQS="true"; shift ;;
            -h|--help)    usage; exit 0 ;;
            *) die "Unknown option: $1 — use --help for usage" ;;
        esac
    done
}

# ── Repo structure sanity check ───────────────────────────────────────────────
check_repo_structure() {
    [[ -d "${REPO_ROOT}/ansible" ]] \
        || die "ansible/ directory not found. Run install.sh from the root of the dotfiles repository."
    [[ -d "${REPO_ROOT}/shell" ]] \
        || die "shell/ directory not found. Run install.sh from the root of the dotfiles repository."
    [[ -f "${REPO_ROOT}/ansible/site.yml" ]] \
        || die "ansible/site.yml not found. Repository may be incomplete."
}

# ── Version comparison ────────────────────────────────────────────────────────
# Returns 0 (true) if version $1 is >= version $2
version_ge() {
    [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

# ── Phase 1: Prerequisites ────────────────────────────────────────────────────
detect_package_manager() {
    if   command -v dnf     &>/dev/null; then echo "dnf"
    elif command -v apt-get &>/dev/null; then echo "apt"
    elif command -v brew    &>/dev/null; then echo "brew"
    elif command -v zypper  &>/dev/null; then echo "zypper"
    elif command -v pacman  &>/dev/null; then echo "pacman"
    else echo "unknown"
    fi
}

install_prereqs() {
    local pm="$1"
    shift
    local missing=("$@")

    info "Installing missing prerequisites via ${pm}..."

    case "${pm}" in
        dnf)
            local pkgs=()
            for dep in "${missing[@]}"; do
                case "${dep}" in
                    git)                      pkgs+=(git) ;;
                    python3|python3-upgrade)  pkgs+=(python3) ;;
                    ansible|ansible-upgrade)  pkgs+=(ansible-core) ;;
                esac
            done
            [[ ${#pkgs[@]} -gt 0 ]] && sudo dnf install -y "${pkgs[@]}"
            ;;
        apt)
            sudo apt-get update -qq
            local pkgs=()
            for dep in "${missing[@]}"; do
                case "${dep}" in
                    git)                      pkgs+=(git) ;;
                    python3|python3-upgrade)  pkgs+=(python3 python3-pip) ;;
                    ansible|ansible-upgrade)  pkgs+=(ansible-core) ;;
                esac
            done
            [[ ${#pkgs[@]} -gt 0 ]] && sudo apt-get install -y "${pkgs[@]}"
            # ansible-core may not be in the default apt repos on older Ubuntu.
            # Fall back to pip if the apt install didn't provide ansible-playbook.
            if ! command -v ansible-playbook &>/dev/null; then
                warn "ansible-core not available via apt — installing via pip..."
                python3 -m pip install --user ansible-core
                # Ensure ~/.local/bin is on PATH for this session
                export PATH="${HOME}/.local/bin:${PATH}"
            fi
            ;;
        brew)
            for dep in "${missing[@]}"; do
                case "${dep}" in
                    git)                      brew install git ;;
                    python3|python3-upgrade)  brew install python3 ;;
                    ansible|ansible-upgrade)  brew install ansible ;;
                esac
            done
            ;;
        zypper)
            local pkgs=()
            for dep in "${missing[@]}"; do
                case "${dep}" in
                    git)                      pkgs+=(git) ;;
                    python3|python3-upgrade)  pkgs+=(python3) ;;
                    ansible|ansible-upgrade)  pkgs+=(ansible) ;;
                esac
            done
            [[ ${#pkgs[@]} -gt 0 ]] && sudo zypper install -y "${pkgs[@]}"
            ;;
        *)
            die "Cannot auto-install prerequisites — package manager '${pm}' not recognised. Install manually: git, python3 >= 3.9, ansible-core >= 2.14"
            ;;
    esac

    info "Prerequisites installed."
}

check_prereqs() {
    header "Prerequisites"

    local missing=()

    # git
    if ! command -v git &>/dev/null; then
        warn "git: not found"
        missing+=(git)
    else
        info "git: $(git --version | head -1)"
    fi

    # python3 >= 3.9
    if ! command -v python3 &>/dev/null; then
        warn "python3: not found"
        missing+=(python3)
    else
        local py_ver
        py_ver=$(python3 -c "import sys; print('{}.{}'.format(sys.version_info.major, sys.version_info.minor))" 2>/dev/null || echo "0.0")
        if version_ge "${py_ver}" "3.9"; then
            info "python3: ${py_ver}"
        else
            warn "python3 ${py_ver} found but >= 3.9 is required"
            missing+=(python3-upgrade)
        fi
    fi

    # ansible-core >= 2.14
    if ! command -v ansible-playbook &>/dev/null; then
        warn "ansible-core: not found"
        missing+=(ansible)
    else
        local ans_ver
        ans_ver=$(ansible --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "0.0")
        if version_ge "${ans_ver}" "2.14"; then
            info "ansible-core: ${ans_ver}"
        else
            warn "ansible-core ${ans_ver} found but >= 2.14 is required"
            missing+=(ansible-upgrade)
        fi
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        info "All prerequisites satisfied."
        return 0
    fi

    local pm
    pm=$(detect_package_manager)
    info "Package manager: ${pm}"

    install_prereqs "${pm}" "${missing[@]}"
}

# ── Phase 2: host_vars generation ────────────────────────────────────────────
# Reads existing host_vars if present (populates URL variables for SSH phase).
# Otherwise, prompts interactively and writes the file.
#
# Profile note: nvim_config_repo_url and ai_config_repo_url are only prompted
# for the 'workstation' profile. Server and minimal profiles do not run the
# nvim or ai-tools roles, so collecting these values would be misleading.
# This design choice is documented here and in the shell role README.

_read_yaml_scalar() {
    # Reads a bare scalar value from a simple YAML file.
    # Usage: _read_yaml_scalar <key> <file>
    local key="$1"
    local file="$2"
    grep "^${key}:" "${file}" 2>/dev/null \
        | sed "s/^${key}: *//" \
        | tr -d '"' \
        | tr -d "'" \
        | tr -d '[:space:]' \
        || true
}

generate_host_vars() {
    local host_vars_file="${REPO_ROOT}/ansible/host_vars/localhost.yml"

    if [[ -f "${host_vars_file}" ]]; then
        info "host_vars/localhost.yml already exists — skipping. Delete it to regenerate."
        # Read URLs from the existing file so the SSH phase can use them.
        NVIM_REPO_URL=$(_read_yaml_scalar "nvim_config_repo_url" "${host_vars_file}")
        AI_REPO_URL=$(_read_yaml_scalar  "ai_config_repo_url"   "${host_vars_file}")
        PROFILE=$(_read_yaml_scalar "dotfiles_profile" "${host_vars_file}")
        return 0
    fi

    header "Machine Configuration"
    info "Creating ansible/host_vars/localhost.yml"
    info "This file is gitignored and will never be overwritten by Ansible."
    echo

    # ── Profile ───────────────────────────────────────────────────────────────
    PROFILE="${ARG_PROFILE}"
    if [[ -z "${PROFILE}" ]]; then
        echo "Select a profile:"
        echo "  1) workstation  Full setup — shell, git, ssh, nvim, ai-tools, sync"
        echo "  2) server       Common, shell, git, ssh, sync"
        echo "  3) minimal      Common and shell only"
        echo
        local choice
        read -r -p "Profile [1]: " choice || true
        case "${choice:-1}" in
            1|workstation) PROFILE="workstation" ;;
            2|server)      PROFILE="server" ;;
            3|minimal)     PROFILE="minimal" ;;
            *)             PROFILE="workstation" ;;
        esac
    fi
    info "Profile: ${PROFILE}"
    echo

    # ── Machine name ──────────────────────────────────────────────────────────
    MACHINE_NAME="${ARG_MACHINE_NAME}"
    if [[ -z "${MACHINE_NAME}" ]]; then
        local default_hostname
        default_hostname="$(hostname -s 2>/dev/null || hostname)"
        read -r -p "Machine name [${default_hostname}]: " MACHINE_NAME || true
        MACHINE_NAME="${MACHINE_NAME:-${default_hostname}}"
    fi
    info "Machine name: ${MACHINE_NAME}"

    # ── Git emails ────────────────────────────────────────────────────────────
    while [[ -z "${GIT_PERSONAL_EMAIL}" ]]; do
        read -r -p "Personal git email: " GIT_PERSONAL_EMAIL || true
    done
    read -r -p "Work git email (leave blank if not applicable): " GIT_WORK_EMAIL || true

    # ── Companion repo URLs ───────────────────────────────────────────────────
    # Only prompted for workstation profile. Server and minimal profiles do not
    # run the nvim or ai-tools Ansible roles, so these URLs would go unused.
    if [[ "${PROFILE}" == "workstation" ]]; then
        echo
        info "Companion repo SSH URLs (leave blank to skip cloning):"
        read -r -p "  nvim-config repo: " NVIM_REPO_URL || true
        read -r -p "  ai-config repo:   " AI_REPO_URL   || true
    else
        NVIM_REPO_URL=""
        AI_REPO_URL=""
        info "Skipping nvim/ai-config repo URLs — not applicable for '${PROFILE}' profile."
    fi

    # ── Write file ────────────────────────────────────────────────────────────
    mkdir -p "$(dirname "${host_vars_file}")"
    cat > "${host_vars_file}" << EOF
# Generated by install.sh on $(date '+%Y-%m-%d')
# Gitignored — do not commit this file.
# Delete this file and re-run install.sh to regenerate interactively.
# Ansible will never overwrite values in this file on subsequent runs.

dotfiles_profile: ${PROFILE}
machine_name: "${MACHINE_NAME}"
git_personal_email: "${GIT_PERSONAL_EMAIL}"
git_work_email: "${GIT_WORK_EMAIL}"
nvim_config_repo_url: "${NVIM_REPO_URL}"
ai_config_repo_url: "${AI_REPO_URL}"
EOF

    info "Created ${host_vars_file}"
}

# ── Phase 3: SSH deploy keys ──────────────────────────────────────────────────
generate_deploy_key() {
    local key_name="$1"
    local comment="$2"
    local key_path="${HOME}/.ssh/${key_name}"

    if [[ -f "${key_path}" ]]; then
        info "Deploy key '${key_name}' already exists — skipping generation."
        return 0
    fi

    ssh-keygen -t ed25519 -f "${key_path}" -N "" -C "${comment}" -q
    info "Generated: ${key_path}"
}

_write_ssh_host_entry() {
    local alias="$1"
    local key_name="$2"
    local conf_file="$3"

    cat >> "${conf_file}" << EOF

Host ${alias}
    HostName github.com
    User git
    IdentityFile ${HOME}/.ssh/${key_name}
    IdentitiesOnly yes
EOF
}

ensure_ssh_config_include() {
    local ssh_config="${HOME}/.ssh/config"
    local include_line="Include ~/.ssh/config.d/*.conf"

    touch "${ssh_config}"
    chmod 600 "${ssh_config}"

    if grep -qF "${include_line}" "${ssh_config}" 2>/dev/null; then
        return 0
    fi

    # Prepend — Include must appear before any Host/Match blocks to be effective
    local tmp
    tmp=$(mktemp)
    {
        echo "${include_line}"
        echo ""
        cat "${ssh_config}"
    } > "${tmp}"
    mv "${tmp}" "${ssh_config}"
    chmod 600 "${ssh_config}"
    info "Added Include directive to ~/.ssh/config"
}

setup_ssh_keys() {
    header "SSH Deploy Keys"

    info "Generating per-repo SSH deploy keys."
    info "Each key grants read-only access to one repository."
    echo

    mkdir -p "${HOME}/.ssh/config.d"
    chmod 700 "${HOME}/.ssh" "${HOME}/.ssh/config.d"

    local conf_file="${HOME}/.ssh/config.d/10-dotfiles.conf"

    # install.sh owns this file. The ssh Ansible role (Phase 2, step 4)
    # will later manage the broader config.d structure.
    cat > "${conf_file}" << 'SSHEOF'
# dotfiles deploy keys — generated by install.sh
# One Host alias per repository. IdentitiesOnly yes prevents SSH from
# falling back to other loaded keys, ensuring the right key is always used.
#
# SSH alias format: github-dotfiles-<repo>
# Use these aliases as the hostname in your repo SSH clone URLs, e.g.:
#   git@github-dotfiles-nvim:user/nvim-config.git
SSHEOF
    chmod 600 "${conf_file}"

    # dotfiles_main — always generated; used by the sync service to pull
    # updates to the dotfiles repo itself. The initial clone uses your
    # personal key; this key is for unattended sync only.
    generate_deploy_key "dotfiles_main" "dotfiles-sync@$(hostname -s 2>/dev/null || hostname)"
    _write_ssh_host_entry "github-dotfiles-main" "dotfiles_main" "${conf_file}"

    # dotfiles_nvim — only if a nvim-config URL was provided
    if [[ -n "${NVIM_REPO_URL}" ]]; then
        generate_deploy_key "dotfiles_nvim" "dotfiles-nvim@$(hostname -s 2>/dev/null || hostname)"
        _write_ssh_host_entry "github-dotfiles-nvim" "dotfiles_nvim" "${conf_file}"
    fi

    # dotfiles_ai — only if an ai-config URL was provided
    if [[ -n "${AI_REPO_URL}" ]]; then
        generate_deploy_key "dotfiles_ai" "dotfiles-ai@$(hostname -s 2>/dev/null || hostname)"
        _write_ssh_host_entry "github-dotfiles-ai" "dotfiles_ai" "${conf_file}"
    fi

    ensure_ssh_config_include

    # ── Display public keys for GitHub ────────────────────────────────────────
    echo
    echo "${_BOLD}${_YELLOW}ACTION REQUIRED — Add the following keys to GitHub before continuing${_RESET}"
    echo
    echo "For each key: go to the repository → Settings → Deploy keys → Add deploy key"
    echo "Allow write access: NO (read-only is sufficient for sync)"
    echo

    # Build an ordered list of keys to display
    local -a display_keys=(
        "dotfiles_main:dotfiles repo (sync service)"
    )
    [[ -n "${NVIM_REPO_URL}" ]] && display_keys+=("dotfiles_nvim:nvim-config repo")
    [[ -n "${AI_REPO_URL}"   ]] && display_keys+=("dotfiles_ai:ai-config repo")

    for entry in "${display_keys[@]}"; do
        local key_name="${entry%%:*}"
        local label="${entry##*:}"
        local pub_file="${HOME}/.ssh/${key_name}.pub"
        if [[ -f "${pub_file}" ]]; then
            echo "${_BOLD}${label}${_RESET}"
            cat "${pub_file}"
            echo
        fi
    done

    # ── SSH alias reminder ────────────────────────────────────────────────────
    if [[ -n "${NVIM_REPO_URL}" ]] || [[ -n "${AI_REPO_URL}" ]]; then
        echo "${_BOLD}SSH alias URLs for host_vars/localhost.yml:${_RESET}"
        [[ -n "${NVIM_REPO_URL}" ]] && echo "  nvim_config_repo_url: \"git@github-dotfiles-nvim:${NVIM_REPO_URL##*:}\""
        [[ -n "${AI_REPO_URL}"   ]] && echo "  ai_config_repo_url:   \"git@github-dotfiles-ai:${AI_REPO_URL##*:}\""
        echo
        info "Update ansible/host_vars/localhost.yml with the alias URLs above."
        info "The alias form ensures the correct deploy key is used for each repo."
        echo
    fi

    read -r -p "Press Enter once all deploy keys have been added to GitHub..." || true
}

# ── Phase 4: Ansible ──────────────────────────────────────────────────────────
run_ansible() {
    header "Ansible"

    local playbook_dir="${REPO_ROOT}/ansible"
    local playbook="${ARG_PLAYBOOK}.yml"

    [[ -f "${playbook_dir}/${playbook}" ]] \
        || die "Playbook not found: ${playbook_dir}/${playbook}"

    local ansible_cmd=(ansible-playbook "${playbook}")
    [[ "${ARG_CHECK}" == "true" ]] && ansible_cmd+=(--check --diff)

    info "Running: ${ansible_cmd[*]}"

    # Run in a subshell so cd does not affect the parent process.
    # ansible.cfg uses relative paths resolved from its own location,
    # so we must cd to the ansible/ directory.
    (
        cd "${playbook_dir}"
        "${ansible_cmd[@]}"
    )
}

# ── Phase 5: Post-run summary ─────────────────────────────────────────────────
post_run() {
    header "Complete"

    if [[ "${ARG_CHECK}" == "true" ]]; then
        info "Dry run complete — no changes were applied."
        info "Remove --check and re-run to apply."
        return 0
    fi

    info "dotfiles deployed successfully."
    echo
    echo "  Activate in your current shell:"
    echo "    source ~/.bashrc    # bash"
    echo "    source ~/.zshrc     # zsh"
    echo "  Or simply open a new terminal."

    if [[ -n "${NVIM_REPO_URL}" ]] || [[ -n "${AI_REPO_URL}" ]]; then
        echo
        echo "  Next step — update host_vars with SSH alias URLs, then re-run:"
        echo "    ./install.sh --no-prereqs --skip-ssh"
        echo "  This triggers the nvim/ai-tools roles to clone their repos."
    fi

    echo
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    echo
    echo "${_BOLD}dotfiles install.sh v${VERSION}${_RESET}"

    check_repo_structure

    # Phase 1 — Prerequisites
    if [[ "${ARG_NO_PREREQS}" == "false" ]]; then
        check_prereqs
    else
        info "Skipping prerequisite checks (--no-prereqs)."
    fi

    # Phase 2 — host_vars (before SSH so URLs are available)
    generate_host_vars

    # Phase 3 — SSH deploy keys
    if [[ "${ARG_SKIP_SSH}" == "false" ]]; then
        setup_ssh_keys
    else
        info "Skipping SSH key generation (--skip-ssh)."
    fi

    # Phase 4 — Ansible
    run_ansible

    # Phase 5 — Summary
    post_run
}

main "$@"

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
#   3. Generates per-repo SSH deploy keys for private companion repos (nvim-config, ai-config)
#   4. Runs ansible-playbook to deploy configuration
#
# On subsequent runs:
#   - host_vars/localhost.yml is never overwritten if it exists
#   - SSH keys are never overwritten if they already exist
#   - Use --check for a dry run before applying changes
#
# Usage: ./install.sh [OPTIONS]
#
#   --ask-become-pass, -K                   Prompt for sudo password before running Ansible.
#   --profile <workstation|server|minimal>  Skip profile prompt
#   --machine-name <name>                   Skip hostname prompt
#   --playbook <site|server>                Playbook to run (default: site)
#   --projects-base <path>                  Skip projects base prompt (set by bootstrap.sh)
#   --skip-roles <role[,role]>              Skip named roles (passed as --skip-tags to Ansible)
#   --only-roles <role[,role]>              Run only named roles (common always included)
#   --check                                 Ansible dry-run (--check --diff)
#   --skip-ssh                              Skip SSH deploy key generation
#   --no-prereqs                            Skip prerequisite check/install
#   -h, --help                              Show this help

set -euo pipefail

VERSION="1.0.8"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

# ── Argument defaults ─────────────────────────────────────────────────────────
ARG_PROFILE=""
ARG_MACHINE_NAME=""
ARG_PLAYBOOK="site"
ARG_CHECK="false"
ARG_SKIP_SSH="false"
ARG_NO_PREREQS="false"
ARG_BECOME_PASS="false"
ARG_PROJECTS_BASE=""
ARG_SKIP_ROLES=""
ARG_ONLY_ROLES=""

# Populated during execution (by generate_host_vars or read from existing file)
PROFILE=""
MACHINE_NAME=""
PROJECTS_BASE=""
GIT_NAME=""
GIT_DEFAULT_EMAIL=""
GIT_DEFAULT_SIGNING_KEY=""
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

info()   { echo "${_GREEN}[INFO]${_RESET}  $*" >&2; }
warn()   { echo "${_YELLOW}[WARN]${_RESET}  $*" >&2; }
error()  { echo "${_RED}[ERROR]${_RESET} $*" >&2; }
header() { { echo; echo "${_BOLD}${_BLUE}── $* ${_RESET}"; echo; } >&2; }
die()    { error "$*"; exit 1; }

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat << EOF
dotfiles install.sh v${VERSION}

Usage: $(basename "$0") [OPTIONS]

OPTIONS
  --ask-become-pass, -K
      Prompt for sudo password before running Ansible. Required when any role
      needs to install system packages (e.g. neovim on a first run). Not needed
      on re-runs once packages are already installed.

  --profile <workstation|server|minimal>
      Skip the profile selection prompt and use the given value.

  --machine-name <name>
      Skip the machine name prompt and use the given value.

  --playbook <site|server>
      Ansible playbook to run. Defaults to 'site'.
      Use 'server' in combination with --profile server for server deployments.

  --projects-base <path>
      Skip the projects base directory prompt. Passed automatically by
      bootstrap.sh. Tilde expansion is handled (~/Projects is valid).

  --skip-roles <role[,role,...]>
      Skip one or more named roles. Passed as --skip-tags to ansible-playbook.
      Also suppresses related prompts (e.g. --skip-roles ai-tools skips the
      ai-config repo URL prompt and disables the role in host_vars).
      'common' cannot be skipped and is silently removed if included.

  --only-roles <role[,role,...]>
      Run only the named roles. 'common' is always prepended.
      Also suppresses prompts for roles not in the list.

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
  The dotfiles repo is public — no deploy key is needed for it. The sync
  service pulls via HTTPS.

  Deploy keys are only generated for private companion repos:

    ~/.ssh/dotfiles_nvim    For nvim-config (if URL provided)
    ~/.ssh/dotfiles_ai      For ai-config (if URL provided)

  SSH host aliases are written to ~/.ssh/config.d/10-dotfiles.conf.
  Use these aliases in your host_vars repo URLs, e.g.:
    git@github-dotfiles-nvim:user/nvim-config.git

  Each key needs to be added to its repository as a read-only deploy key
  (repo Settings → Deploy keys → Add deploy key → allow write access: NO).

  If neither nvim-config nor ai-config URLs are provided, the SSH phase is
  skipped entirely. --skip-ssh is still available to bypass it explicitly.

EXAMPLES
  ./install.sh                                    Interactive first run
  ./install.sh --check                            Dry run — preview changes
  ./install.sh --profile workstation              Skip profile prompt
  ./install.sh --profile server --playbook server Server deployment
  ./install.sh --no-prereqs --skip-ssh            Re-run Ansible only
  ./install.sh --skip-roles ai-tools              Skip ai-tools role and prompts
  ./install.sh --only-roles shell,git             Run common + shell + git only
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ask-become-pass|-K)
                ARG_BECOME_PASS="true"
                shift
                ;;
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
            --projects-base)
                [[ -z "${2:-}" ]] && die "--projects-base requires an argument"
                ARG_PROJECTS_BASE="${2/#\~/${HOME}}"
                shift 2
                ;;
            --skip-roles)
                [[ -z "${2:-}" ]] && die "--skip-roles requires a comma-separated list of role names"
                ARG_SKIP_ROLES="$2"
                shift 2
                ;;
            --only-roles)
                [[ -z "${2:-}" ]] && die "--only-roles requires a comma-separated list of role names"
                ARG_ONLY_ROLES="$2"
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

# ── Role suppression check ────────────────────────────────────────────────────
# Returns 0 (true) if the given role should be excluded from this run, based
# on --skip-roles or --only-roles CLI flags.
#
# Used by generate_host_vars to suppress prompts for roles that won't run,
# and to set dotfiles_<role>_enabled: false in host_vars when a role is
# explicitly skipped on a first run.
_role_is_suppressed() {
    local role="$1"
    # Explicitly skipped via --skip-roles
    if [[ -n "${ARG_SKIP_ROLES}" ]]; then
        if echo "${ARG_SKIP_ROLES}" | tr ',' '\n' | grep -qx "${role}"; then
            return 0
        fi
    fi
    # --only-roles in effect and this role isn't listed
    if [[ -n "${ARG_ONLY_ROLES}" ]]; then
        if ! echo "${ARG_ONLY_ROLES}" | tr ',' '\n' | grep -qx "${role}"; then
            return 0
        fi
    fi
    return 1
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
                    git)                     pkgs+=(git) ;;
                    python3|python3-upgrade) pkgs+=(python3) ;;
                    ansible|ansible-upgrade) pkgs+=(ansible-core) ;;
                esac
            done
            [[ ${#pkgs[@]} -gt 0 ]] && sudo dnf install -y "${pkgs[@]}"
            ;;
        apt)
            sudo apt-get update -qq
            local pkgs=()
            for dep in "${missing[@]}"; do
                case "${dep}" in
                    git)                     pkgs+=(git) ;;
                    python3|python3-upgrade) pkgs+=(python3 python3-pip) ;;
                    ansible|ansible-upgrade) pkgs+=(ansible-core) ;;
                esac
            done
            [[ ${#pkgs[@]} -gt 0 ]] && sudo apt-get install -y "${pkgs[@]}"
            # ansible-core may not be in the default apt repos on older Ubuntu.
            # Fall back to pip if the apt install didn't provide ansible-playbook.
            if ! command -v ansible-playbook &>/dev/null; then
                info "ansible-playbook not found after apt install — trying pip3..."
                pip3 install --user ansible-core
            fi
            ;;
        brew)
            for dep in "${missing[@]}"; do
                case "${dep}" in
                    git)                     brew install git ;;
                    python3|python3-upgrade) brew install python3 ;;
                    ansible|ansible-upgrade) brew install ansible ;;
                esac
            done
            ;;
        zypper)
            local pkgs=()
            for dep in "${missing[@]}"; do
                case "${dep}" in
                    git)                     pkgs+=(git) ;;
                    python3|python3-upgrade) pkgs+=(python3) ;;
                    ansible|ansible-upgrade) pkgs+=(ansible-core) ;;
                esac
            done
            [[ ${#pkgs[@]} -gt 0 ]] && sudo zypper install -y "${pkgs[@]}"
            ;;
        *)
            die "Cannot install prerequisites: unknown package manager. Install git, python3 >= 3.9, and ansible-core >= 2.14 manually, then re-run with --no-prereqs."
            ;;
    esac
}

check_prereqs() {
    header "Prerequisites"

    local missing=()

    # git
    if ! command -v git &>/dev/null; then
        warn "git: not found"
        missing+=(git)
    else
        info "git: $(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    fi

    # python3
    if ! command -v python3 &>/dev/null; then
        warn "python3: not found"
        missing+=(python3)
    else
        local py_ver
        py_ver=$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "0.0")
        if version_ge "${py_ver}" "3.9"; then
            info "python3: ${py_ver}"
        else
            warn "python3 ${py_ver} found but >= 3.9 is required"
            missing+=(python3-upgrade)
        fi
    fi

    # ansible-core
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
# Prompt suppression: --skip-roles and --only-roles are consulted via
# _role_is_suppressed(). Suppressed roles skip their companion repo URL
# prompts and their enable-flag prompts, and are written as disabled in the
# generated host_vars file.
#
# Profile note: nvim_config_repo_url and ai_config_repo_url are only prompted
# for the 'workstation' profile. Server and minimal profiles do not run the
# nvim or ai-tools roles, so collecting these values would be misleading.

_read_yaml_scalar() {
    # Reads a bare scalar value from a simple YAML file (no yq dependency).
    # Usage: _read_yaml_scalar <key> <file>
    local key="$1" file="$2"
    grep "^${key}:" "${file}" 2>/dev/null \
        | sed "s/^${key}: *//" \
        | tr -d '"' \
        | tr -d "'" \
        | tr -d '[:space:]' \
        || true
}

# ── Backfill a companion repo URL into an existing host_vars file ─────────────
# Called when host_vars already exists but a role is being explicitly targeted
# via --only-roles and its URL is currently empty.
#
# Args:
#   $1  role name          (e.g. "nvim")
#   $2  url_key            (e.g. "nvim_config_repo_url")
#   $3  enabled_key        (e.g. "dotfiles_nvim_enabled")
#   $4  prompt label       (e.g. "nvim-config repo SSH URL")
#   $5  host_vars_file     path to the YAML file
#
# Side effects:
#   - Prompts the user if the conditions are met
#   - Patches $url_key and $enabled_key in the file via sed
#   - Updates the NVIM_REPO_URL / AI_REPO_URL global as appropriate
_backfill_role_url() {
    local role="$1" url_key="$2" enabled_key="$3" label="$4" file="$5"
    local current_url

    # Only act when this role is explicitly being targeted and not suppressed
    ! _role_is_suppressed "${role}" || return 0
    [[ -n "${ARG_ONLY_ROLES}" ]] || return 0
    echo "${ARG_ONLY_ROLES}" | tr ',' '\n' | grep -qx "${role}" || return 0

    current_url=$(_read_yaml_scalar "${url_key}" "${file}")
    [[ -z "${current_url}" ]] || return 0   # Already set — nothing to do

    header "Backfilling ${role} configuration"
    warn "${role} was skipped on the original run — its repo URL is empty in host_vars."
    info "Provide the URL now to enable it, or press Enter to leave it disabled."
    echo

    local new_url=""
    read -r -p "  ${label} (leave blank to skip): " new_url || true

    if [[ -z "${new_url}" ]]; then
        info "No URL provided — ${role} will remain disabled."
        return 0
    fi

    # Patch the URL key in the file
    sed -i "s|^${url_key}:.*|${url_key}: \"${new_url}\"|" "${file}"
    # Flip the enabled flag to true
    sed -i "s|^${enabled_key}:.*|${enabled_key}: true|" "${file}"

    info "Updated ${url_key} in host_vars."

    # Update the global variable for the SSH phase
    case "${role}" in
        nvim)     NVIM_REPO_URL="${new_url}" ;;
        ai-tools) AI_REPO_URL="${new_url}"   ;;
    esac
}

generate_host_vars() {
    local host_vars_file="${REPO_ROOT}/ansible/host_vars/localhost.yml"

    if [[ -f "${host_vars_file}" ]]; then
        info "host_vars/localhost.yml already exists — skipping. Delete it to regenerate."
        # Read back the values the SSH phase and Ansible run need.
        NVIM_REPO_URL=$(_read_yaml_scalar "nvim_config_repo_url" "${host_vars_file}")
        AI_REPO_URL=$(_read_yaml_scalar   "ai_config_repo_url"   "${host_vars_file}")
        PROFILE=$(_read_yaml_scalar       "dotfiles_profile"     "${host_vars_file}")
        # Honour CLI suppression — don't hand suppressed role URLs to the SSH phase.
        _role_is_suppressed "nvim"     && NVIM_REPO_URL=""
        _role_is_suppressed "ai-tools" && AI_REPO_URL=""

        # ── Backfill empty URLs for roles being explicitly re-run ─────────────
        # If --only-roles targets a role whose URL was left empty on the first
        # run (e.g. the user answered N then, but now wants to add the role),
        # prompt for just those values and patch them into the existing file.
        # This avoids forcing the user to delete host_vars and start over.
        _backfill_role_url "nvim"     "nvim_config_repo_url" "dotfiles_nvim_enabled" \
            "nvim-config repo SSH URL" "${host_vars_file}"
        _backfill_role_url "ai-tools" "ai_config_repo_url"   "dotfiles_ai_tools_enabled" \
            "ai-config repo SSH URL"  "${host_vars_file}"

        return 0
    fi

    header "Machine Configuration"
    info "Creating ansible/host_vars/localhost.yml"
    info "This file is gitignored and will never be committed or overwritten by Ansible."
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
            2|server)      PROFILE="server"      ;;
            3|minimal)     PROFILE="minimal"     ;;
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
    echo

    # ── Projects base ─────────────────────────────────────────────────────────
    PROJECTS_BASE="${ARG_PROJECTS_BASE}"
    if [[ -z "${PROJECTS_BASE}" ]]; then
        local default_projects="${HOME}/Projects"
        read -r -p "Projects base directory [${default_projects}]: " PROJECTS_BASE || true
        PROJECTS_BASE="${PROJECTS_BASE:-${default_projects}}"
        PROJECTS_BASE="${PROJECTS_BASE/#\~/${HOME}}"
    fi
    info "Projects base: ${PROJECTS_BASE}"

    # ── Git identity ──────────────────────────────────────────────────────────
    echo
    info "Git global identity (used when no project-specific profile matches):"
    read -r -p "  Your full name: " GIT_NAME || true
    while [[ -z "${GIT_DEFAULT_EMAIL}" ]]; do
        read -r -p "  Default email:  " GIT_DEFAULT_EMAIL || true
    done
    read -r -p "  Default GPG signing key fingerprint (optional, Enter to skip): " GIT_DEFAULT_SIGNING_KEY || true
    echo

    # ── Git projects ──────────────────────────────────────────────────────────
    local git_projects_yaml=""
    if [[ "${PROFILE}" == "workstation" ]]; then
        info "Git projects — context/provider pairs (e.g. Personal/GitHub, Acme/AzureDevOps)."
        echo "Press Enter at the context prompt to finish. Add more later with: git-add-project"
        echo

        while true; do
            local ctx="" prov="" email="" key=""
            read -r -p "  Context (or Enter to finish): " ctx || true
            [[ -z "${ctx}" ]] && break

            read -r -p "  Provider for ${ctx} (GitHub/GitLab/Bitbucket/AzureDevOps/other): " prov || true
            [[ -z "${prov}" ]] && { warn "Provider cannot be empty — skipping."; continue; }

            while [[ -z "${email}" ]]; do
                read -r -p "  Email for ${ctx}/${prov}: " email || true
            done

            read -r -p "  GPG signing key for ${ctx}/${prov} (optional, Enter to skip): " key || true

            git_projects_yaml+="  - context: \"${ctx}\"\n"
            git_projects_yaml+="    provider: \"${prov}\"\n"
            git_projects_yaml+="    email: \"${email}\"\n"
            [[ -n "${key}" ]] && git_projects_yaml+="    signing_key: \"${key}\"\n"

            info "Added ${ctx}/${prov}"
            echo
        done
    fi

    # ── Companion repo URLs and role enable flags ─────────────────────────────
    # Declared here at function scope so the write block below can always
    # reference them, regardless of which branch of the if/else is taken.
    local nvim_enabled="true"
    local ai_enabled="true"

    if [[ "${PROFILE}" == "workstation" ]]; then
        echo
        info "Optional roles — answer N to disable, or provide a repo URL to enable:"
        echo

        # nvim ─────────────────────────────────────────────────────────────────
        if _role_is_suppressed "nvim"; then
            nvim_enabled="false"
            NVIM_REPO_URL=""
            info "  nvim role: disabled (suppressed by CLI flags)"
        else
            local nvim_prompt_answer
            read -r -p "  Enable nvim role? [Y/n]: " nvim_prompt_answer || true
            if [[ "${nvim_prompt_answer,,}" == "n" ]]; then
                nvim_enabled="false"
                NVIM_REPO_URL=""
            else
                nvim_enabled="true"
                read -r -p "  nvim-config repo SSH URL (leave blank to skip cloning): " NVIM_REPO_URL || true
            fi
        fi

        echo

        # ai-tools ─────────────────────────────────────────────────────────────
        if _role_is_suppressed "ai-tools"; then
            ai_enabled="false"
            AI_REPO_URL=""
            info "  ai-tools role: disabled (suppressed by CLI flags)"
        else
            local ai_prompt_answer
            read -r -p "  Enable ai-tools role? [Y/n]: " ai_prompt_answer || true
            if [[ "${ai_prompt_answer,,}" == "n" ]]; then
                ai_enabled="false"
                AI_REPO_URL=""
            else
                ai_enabled="true"
                read -r -p "  ai-config repo SSH URL (leave blank to skip cloning):   " AI_REPO_URL || true
            fi
        fi
    else
        NVIM_REPO_URL=""
        AI_REPO_URL=""
        nvim_enabled="false"
        ai_enabled="false"
        info "Skipping nvim/ai-config repo URLs — not applicable for '${PROFILE}' profile."
    fi

    # ── Write file ────────────────────────────────────────────────────────────
    mkdir -p "$(dirname "${host_vars_file}")"

    {
        cat << EOF
# Generated by install.sh on $(date '+%Y-%m-%d')
# Gitignored — do not commit this file.
# Delete this file and re-run install.sh to regenerate interactively.
# Ansible will never overwrite values in this file on subsequent runs.

dotfiles_profile: ${PROFILE}
machine_name: "${MACHINE_NAME}"

# ── Companion repos ────────────────────────────────────────────────────────
nvim_config_repo_url: "${NVIM_REPO_URL}"
ai_config_repo_url:   "${AI_REPO_URL}"

# ── Role feature flags ─────────────────────────────────────────────────────
# common is always required and cannot be disabled.
dotfiles_nvim_enabled:     ${nvim_enabled}
dotfiles_ai_tools_enabled: ${ai_enabled}
dotfiles_sync_enabled:     true

# ── Git global identity ────────────────────────────────────────────────────
projects_base: ${PROJECTS_BASE}
git_name: "${GIT_NAME}"
git_default_email: "${GIT_DEFAULT_EMAIL}"
EOF

        # Signing key is optional — only write if provided
        if [[ -n "${GIT_DEFAULT_SIGNING_KEY}" ]]; then
            echo "git_default_signing_key: \"${GIT_DEFAULT_SIGNING_KEY}\""
        fi

        # Projects list — empty list if none were gathered
        echo ""
        echo "# ── Git projects ─────────────────────────────────────────────────────────"
        if [[ -n "${git_projects_yaml}" ]]; then
            echo "git_projects:"
            printf '%b' "${git_projects_yaml}"
        else
            echo "git_projects: []"
            echo "# Add projects later with: git-add-project <context> <provider> <email>"
        fi

    } > "${host_vars_file}"

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
    ControlMaster no
    ControlPersist no
    ControlPath none
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
    # dotfiles is public — no deploy key needed for the sync service (HTTPS).
    # This phase only runs when at least one private companion repo URL was provided.
    if [[ -z "${NVIM_REPO_URL}" ]] && [[ -z "${AI_REPO_URL}" ]]; then
        info "No companion repo URLs provided — skipping SSH key generation."
        return 0
    fi

    header "SSH Deploy Keys"

    mkdir -p "${HOME}/.ssh/config.d"
    chmod 700 "${HOME}/.ssh" "${HOME}/.ssh/config.d"

    local conf_file="${HOME}/.ssh/config.d/10-dotfiles.conf"

    # Only create/reset the file if it doesn't already exist. install.sh owns
    # this file; the ssh Ansible role (Phase 2, step 4) will later manage the
    # broader config.d structure.
    if [[ ! -f "${conf_file}" ]]; then
        cat > "${conf_file}" << 'SSHEOF'
# dotfiles companion repo deploy keys — generated by install.sh
# One Host alias per private repository. IdentitiesOnly yes prevents SSH from
# falling back to other loaded keys, ensuring the right key is always used.
#
# SSH alias format: github-dotfiles-<repo>
# Use these aliases as the hostname in your repo SSH clone URLs, e.g.:
#   git@github-dotfiles-nvim:user/nvim-config.git
#
# Note: the dotfiles repo itself is public and uses HTTPS — no entry here.
SSHEOF
        chmod 600 "${conf_file}"
    fi

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

    local -a display_keys=()
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
    echo "${_BOLD}SSH alias URLs for host_vars/localhost.yml:${_RESET}"
    [[ -n "${NVIM_REPO_URL}" ]] && echo "  nvim_config_repo_url: \"git@github-dotfiles-nvim:${NVIM_REPO_URL##*:}\""
    [[ -n "${AI_REPO_URL}"   ]] && echo "  ai_config_repo_url:   \"git@github-dotfiles-ai:${AI_REPO_URL##*:}\""
    echo
    info "Update ansible/host_vars/localhost.yml with the alias URLs above."
    info "The alias form ensures the correct deploy key is used for each repo."
    echo

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
    [[ "${ARG_CHECK}"       == "true" ]] && ansible_cmd+=(--check --diff)
    [[ "${ARG_BECOME_PASS}" == "true" ]] && ansible_cmd+=(--ask-become-pass)

    # --only-roles: always include common, then the requested roles.
    # Deduplication handles the case where the caller explicitly includes common.
    if [[ -n "${ARG_ONLY_ROLES}" ]]; then
        local only_tags
        only_tags="common,${ARG_ONLY_ROLES}"
        only_tags=$(echo "${only_tags}" | tr ',' '\n' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//')
        ansible_cmd+=(--tags "${only_tags}")
        info "Role filter (--only-roles): ${only_tags}"
    fi

    # --skip-roles: prevent skipping common — it is always required.
    if [[ -n "${ARG_SKIP_ROLES}" ]]; then
        local skip_tags
        skip_tags=$(echo "${ARG_SKIP_ROLES}" | tr ',' '\n' | grep -v '^common$' | tr '\n' ',' | sed 's/,$//')
        if [[ "${ARG_SKIP_ROLES}" != "${skip_tags}" ]]; then
            warn "'common' cannot be skipped — it is always required. Removed from --skip-roles."
        fi
        if [[ -n "${skip_tags}" ]]; then
            ansible_cmd+=(--skip-tags "${skip_tags}")
            info "Skipping roles: ${skip_tags}"
        fi
    fi

    info "Running: ${ansible_cmd[*]}"

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
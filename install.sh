#!/usr/bin/env bash
# install.sh — dotfiles bootstrap entry point
#
# Bootstraps the dotfiles system on a new machine. This script assumes it is
# run from within the already-cloned dotfiles repository (the repo is public
# and manually cloned before running this script).
#
# On first run:
#   1. Checks and optionally installs prerequisites (git, python3, ansible-core)
#   2. Generates ansible/host_vars/localhost.yml interactively, including any
#      number of external add-on repos (synced/deployed by sync-external)
#   3. Generates per-repo SSH deploy keys for repos registered as private
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

VERSION="2.0.0"
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

# ── Become / sudo state ───────────────────────────────────────────────────────
# Tracks whether a temporary sudoers drop-in was written so cleanup_become()
# can remove it on exit, even if Ansible fails or the user hits Ctrl-C.
_SUDOERS_DROPIN="/etc/sudoers.d/99-dotfiles-install"
_SUDOERS_WRITTEN="false"

# Populated during execution (by generate_host_vars or read from existing file)
PROFILE=""
MACHINE_NAME=""
PROJECTS_BASE=""
GIT_NAME=""
GIT_DEFAULT_EMAIL=""
GIT_DEFAULT_SIGNING_KEY=""

# Populated by generate_host_vars() during the external add-on repo
# collection loop; consumed by setup_ssh_keys() to know which repos need a
# deploy key + SSH alias. Parallel arrays, indexed together — bash 3.2 has
# no associative arrays.
EXTERNAL_REPO_NAMES=()
EXTERNAL_REPO_URLS=()
EXTERNAL_REPO_CLONE_DIRS=()
EXTERNAL_REPO_PRIVATE=()

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
  workstation   Full setup: common, shell, git, ssh, tmux, vim, sync-external, sync
  server        Common, shell, git, ssh, sync-external, sync
  minimal       Common and shell only

  Note: external add-on repos are not prompted for the 'minimal' profile
  because the sync-external role does not run under it.

SSH DEPLOY KEYS
  The dotfiles repo is public — no deploy key is needed for it. The sync
  service pulls via HTTPS.

  Deploy keys are only generated for external add-on repos registered as
  private during the interactive prompt:

    ~/.ssh/dotfiles-<name>    One key per private repo (any git host)

  SSH host aliases are written to ~/.ssh/config.d/10-dotfiles.conf, one
  'Host dotfiles-<name>' block per private repo, with HostName set to the
  repo's actual host (GitHub, GitLab, self-hosted, etc.) extracted from its
  repo_url. The sync-external Ansible role rewrites each private repo's URL
  to its alias form automatically — you never need to hand-edit host_vars
  with the alias URL.

  Each key needs to be added to its repository as a read-only deploy key
  (repo Settings → Deploy keys → Add deploy key → allow write access: NO).

  If no private repos are registered, the SSH phase is skipped entirely.
  --skip-ssh is still available to bypass it explicitly.

EXAMPLES
  ./install.sh                                    Interactive first run
  ./install.sh --check                            Dry run — preview changes
  ./install.sh --profile workstation              Skip profile prompt
  ./install.sh --profile server --playbook server Server deployment
  ./install.sh --no-prereqs --skip-ssh            Re-run Ansible only
  ./install.sh --skip-roles sync-external         Skip sync-external role
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
                while [[ $# -gt 0 && "${1}" != --* && "${1}" != -* ]]; do
                    ARG_SKIP_ROLES="${ARG_SKIP_ROLES},${1}"
                    shift
                done
                ;;
            --only-roles)
                [[ -z "${2:-}" ]] && die "--only-roles requires a comma-separated list of role names"
                ARG_ONLY_ROLES="$2"
                shift 2
                while [[ $# -gt 0 && "${1}" != --* && "${1}" != -* ]]; do
                    ARG_ONLY_ROLES="${ARG_ONLY_ROLES},${1}"
                    shift
                done
                ;;
            --check)      ARG_CHECK="true"; shift ;;
            --skip-ssh)   ARG_SKIP_SSH="true"; shift ;;
            --no-prereqs) ARG_NO_PREREQS="true"; shift ;;
            -h|--help)    usage; exit 0 ;;
            *) die "Unknown option: $1 — use --help for usage" ;;
        esac
    done
}

# ── Hostname detection ────────────────────────────────────────────────────────
# Not every minimal image ships the standalone `hostname` binary (Fedora
# minimal, some WSL base images) even though hostnamectl/systemd is present.
# Try hostnamectl first since it's the most consistently available, then
# hostname, then uname -n as a last resort. Each command is guarded with
# `command -v` and `|| true` so a missing binary never trips `set -e` —
# the original bug here was the final command in a `||` chain failing
# and killing the script before the user was ever prompted.
_default_hostname() {
    local name=""

    if command -v hostnamectl &>/dev/null; then
        name="$(hostnamectl --static 2>/dev/null)" || name=""
    fi

    if [[ -z "${name}" ]] && command -v hostname &>/dev/null; then
        name="$(hostname -s 2>/dev/null)" || name="$(hostname 2>/dev/null)" || name=""
    fi

    if [[ -z "${name}" ]] && command -v uname &>/dev/null; then
        name="$(uname -n 2>/dev/null)" || name=""
    fi

    printf '%s' "${name}"
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
        pacman)
            local pkgs=()
            for dep in "${missing[@]}"; do
                case "${dep}" in
                    git)                     pkgs+=(git) ;;
                    python3|python3-upgrade) pkgs+=(python3) ;;
                    ansible|ansible-upgrade) pkgs+=(ansible) ;;
                esac
            done
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                sudo pacman -Sy --noconfirm "${pkgs[@]}"
            fi
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
# Reads existing host_vars if present (populates the values the SSH and
# Ansible phases need). Otherwise, prompts interactively and writes the file.
#
# The external add-on repo collection loop (and the rest of this interactive
# flow) only runs on first-time generation, same as the git_projects loop
# below — add more repos later by editing external_synced_repos directly in
# host_vars/localhost.yml (see docs/external-sync.md#adding-a-repo).

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

_read_external_repos_from_host_vars() {
    # Emits "<name>|<private>|<repo_url>" for each entry under
    # external_synced_repos in an existing host_vars file, in the same shape
    # install.sh itself writes (see generate_host_vars' "Write file" section
    # below). Used so setup_ssh_keys() can still generate deploy keys (and
    # derive the correct git host — see _extract_git_host) for repos that
    # were added by hand-editing host_vars after the interactive loop already
    # ran once (see docs/external-sync.md#adding-a-repo-to-an-already-provisioned-machine).
    local file="$1"
    awk '
        function clean(s) {
            sub(/[[:space:]]+#.*$/, "", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            gsub(/^"|"$/, "", s)
            gsub(/^'"'"'|'"'"'$/, "", s)
            return s
        }
        /^external_synced_repos:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[A-Za-z]/ { in_block = 0 }
        in_block && /^  - name:/ {
            if (name != "") print name "|" priv "|" url
            line = $0
            sub(/^  - name: */, "", line)
            name = clean(line)
            priv = "false"
            url = ""
            next
        }
        in_block && /^    repo_url:/ {
            line = $0
            sub(/^    repo_url: */, "", line)
            url = clean(line)
        }
        in_block && /^    private:/ {
            line = $0
            sub(/^    private: */, "", line)
            priv = clean(line)
        }
        END { if (name != "") print name "|" priv "|" url }
    ' "${file}"
}

_extract_git_host() {
    # Derives the real git host from a repo_url in any of the forms
    # install.sh/sync-external accept: https://host/path, git@host:path, or
    # ssh://git@host/path. Falls back to empty on no match — callers decide
    # the fallback (e.g. warn and default to github.com).
    local url="$1" host=""
    if [[ "${url}" =~ ^https://([^/]+)/ ]]; then
        host="${BASH_REMATCH[1]}"
    elif [[ "${url}" =~ ^ssh://git@([^/]+)/ ]]; then
        host="${BASH_REMATCH[1]}"
    elif [[ "${url}" =~ ^git@([^:]+): ]]; then
        host="${BASH_REMATCH[1]}"
    fi
    # A "host" that is itself a dotfiles-<name> alias means repo_url was
    # already in rewritten alias form (e.g. hand-copied from a rendered
    # sync.conf) — the real host isn't recoverable from it, so treat as
    # unresolved rather than writing a self-referential HostName.
    [[ "${host}" =~ ^dotfiles- ]] && host=""
    printf '%s' "${host}"
}

generate_host_vars() {
    local host_vars_file="${REPO_ROOT}/ansible/host_vars/localhost.yml"

    if [[ -f "${host_vars_file}" ]]; then
        info "host_vars/localhost.yml already exists — skipping. Delete it to regenerate."
        # Read back the values the Ansible run needs. External repos are a
        # YAML list, not a bare scalar, so PROFILE/MACHINE_NAME use the
        # simple scalar reader — the sync-external role reads the list
        # directly. EXTERNAL_REPO_NAMES/PRIVATE/URLS are re-derived from the
        # list here too, purely so setup_ssh_keys() (below) can still find
        # repos that were registered by hand-editing this file rather than
        # through the interactive loop.
        PROFILE=$(_read_yaml_scalar       "dotfiles_profile"     "${host_vars_file}")
        MACHINE_NAME=$(_read_yaml_scalar  "machine_name"         "${host_vars_file}")

        local repo_name repo_private repo_url
        while IFS='|' read -r repo_name repo_private repo_url; do
            [[ -z "${repo_name}" ]] && continue
            EXTERNAL_REPO_NAMES+=("${repo_name}")
            EXTERNAL_REPO_PRIVATE+=("${repo_private:-false}")
            EXTERNAL_REPO_URLS+=("${repo_url}")
        done < <(_read_external_repos_from_host_vars "${host_vars_file}")

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
        echo "  1) workstation  Full setup — shell, git, ssh, tmux, vim, sync-external, sync"
        echo "  2) server       Common, shell, git, ssh, sync-external, sync"
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
        default_hostname="$(_default_hostname)"

        if [[ -n "${default_hostname}" ]]; then
            read -r -p "Machine name [${default_hostname}]: " MACHINE_NAME || true
            MACHINE_NAME="${MACHINE_NAME:-${default_hostname}}"
        else
            warn "Could not auto-detect a hostname (hostnamectl, hostname, and uname all unavailable)."
            while [[ -z "${MACHINE_NAME}" ]]; do
                read -r -p "Machine name (required): " MACHINE_NAME || true
            done
        fi
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

    # ── External add-on repos ─────────────────────────────────────────────────
    # Any number of repos, each synced/deployed by the sync-external engine
    # per its own .dotfiles-sync.yml (see docs/sync-manifest-spec.md). Only
    # offered for profiles that actually run the sync-external role.
    local external_repos_yaml=""

    if [[ "${PROFILE}" == "workstation" || "${PROFILE}" == "server" ]]; then
        if _role_is_suppressed "sync-external"; then
            info "sync-external role: disabled (suppressed by CLI flags) — skipping add-on repo prompts."
        else
            echo
            info "External add-on repos — synced and deployed by the sync-external engine"
            info "(e.g. nvim-config, ai-config). Add more later by editing"
            info "external_synced_repos in host_vars/localhost.yml — see docs/external-sync.md."
            echo

            local add_more_answer=""
            read -r -p "  Add an external add-on repo? [y/N]: " add_more_answer < /dev/tty || true

            while [[ "${add_more_answer}" == "y" || "${add_more_answer}" == "Y" ]]; do
                local repo_name="" repo_url="" repo_clone_dir="" repo_private_answer="" repo_private="false"
                local dup_found="false" i

                while [[ -z "${repo_name}" ]]; do
                    read -r -p "    Repo name (lowercase letters, digits, hyphens): " repo_name < /dev/tty || true
                    if [[ -n "${repo_name}" ]] && ! [[ "${repo_name}" =~ ^[a-z0-9-]+$ ]]; then
                        warn "    Invalid name '${repo_name}' — use lowercase letters, digits, and hyphens only."
                        repo_name=""
                    fi
                done

                for ((i = 0; i < ${#EXTERNAL_REPO_NAMES[@]}; i++)); do
                    if [[ "${EXTERNAL_REPO_NAMES[i]}" == "${repo_name}" ]]; then
                        dup_found="true"
                        break
                    fi
                done
                if [[ "${dup_found}" == "true" ]]; then
                    warn "  '${repo_name}' is already registered — skipping duplicate."
                else
                    while [[ -z "${repo_url}" ]]; do
                        read -r -p "    Repo URL for ${repo_name}: " repo_url < /dev/tty || true
                    done

                    # shellcheck disable=SC2088 # intentional: written verbatim into
                    # host_vars as clone_dir, expanded later by the sync-external
                    # role's regex_replace('^~', ...) — not by this shell.
                    local default_clone_dir="~/.local/share/${repo_name}"
                    read -r -p "    Clone directory for ${repo_name} [${default_clone_dir}]: " repo_clone_dir < /dev/tty || true
                    repo_clone_dir="${repo_clone_dir:-${default_clone_dir}}"

                    read -r -p "    Is ${repo_name} private? [y/N]: " repo_private_answer < /dev/tty || true
                    if [[ "${repo_private_answer}" == "y" || "${repo_private_answer}" == "Y" ]]; then
                        repo_private="true"
                    fi

                    EXTERNAL_REPO_NAMES+=("${repo_name}")
                    EXTERNAL_REPO_URLS+=("${repo_url}")
                    EXTERNAL_REPO_CLONE_DIRS+=("${repo_clone_dir}")
                    EXTERNAL_REPO_PRIVATE+=("${repo_private}")

                    external_repos_yaml+="  - name: \"${repo_name}\"\n"
                    external_repos_yaml+="    repo_url: \"${repo_url}\"\n"
                    external_repos_yaml+="    clone_dir: \"${repo_clone_dir}\"\n"
                    external_repos_yaml+="    private: ${repo_private}\n"

                    info "  Registered ${repo_name} ($( [[ "${repo_private}" == "true" ]] && echo private || echo public ))"
                fi

                echo
                add_more_answer=""
                read -r -p "  Add another external add-on repo? [y/N]: " add_more_answer < /dev/tty || true
            done
        fi
    else
        info "Skipping external add-on repo prompts — not applicable for '${PROFILE}' profile."
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

# ── Role feature flags ─────────────────────────────────────────────────────
# common is always required and cannot be disabled.
dotfiles_sync_enabled: true

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

        # External add-on repos — empty list if none were registered
        echo ""
        echo "# ── External add-on repos ────────────────────────────────────────────────"
        if [[ -n "${external_repos_yaml}" ]]; then
            echo "external_synced_repos:"
            printf '%b' "${external_repos_yaml}"
        else
            echo "external_synced_repos: []"
            echo "# Add repos later by editing this list — see docs/external-sync.md#adding-a-repo"
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
    local host="$4"

    cat >> "${conf_file}" << EOF

Host ${alias}
    HostName ${host}
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
    # This phase only runs when at least one repo is registered as private,
    # whether from this run's interactive collection loop or (on a re-run)
    # parsed back out of an existing host_vars file — see generate_host_vars().
    local private_count=0 i
    for ((i = 0; i < ${#EXTERNAL_REPO_NAMES[@]}; i++)); do
        [[ "${EXTERNAL_REPO_PRIVATE[i]}" == "true" ]] && private_count=$((private_count + 1))
    done

    if [[ "${private_count}" -eq 0 ]]; then
        info "No private add-on repos registered — skipping SSH key generation."
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
# dotfiles external add-on repo deploy keys — generated by install.sh
# One Host alias per private repository. IdentitiesOnly yes prevents SSH from
# falling back to other loaded keys, ensuring the right key is always used.
#
# SSH alias format: dotfiles-<name> (works for any git host — GitHub,
# GitLab, self-hosted, etc.; HostName is set per-alias to the repo's actual
# host, extracted from its repo_url).
# The sync-external Ansible role rewrites each private repo's URL to this
# alias form automatically — you never need to hand-edit host_vars for it.
#
# Note: the dotfiles repo itself is public and uses HTTPS — no entry here.
SSHEOF
        chmod 600 "${conf_file}"
    fi

    local -a display_names=()

    for ((i = 0; i < ${#EXTERNAL_REPO_NAMES[@]}; i++)); do
        [[ "${EXTERNAL_REPO_PRIVATE[i]}" == "true" ]] || continue

        local repo_name="${EXTERNAL_REPO_NAMES[i]}"
        local key_name="dotfiles-${repo_name}"
        local alias="dotfiles-${repo_name}"

        local host
        host=$(_extract_git_host "${EXTERNAL_REPO_URLS[i]}")
        if [[ -z "${host}" ]]; then
            die "Could not determine the git host for private repo '${repo_name}' from repo_url '${EXTERNAL_REPO_URLS[i]}'. Set repo_url to a normal https://<host>/..., git@<host>:..., or ssh://git@<host>/... form in host_vars (not an already-rewritten dotfiles-<name> alias, which doesn't encode the real host), then re-run. Alternatively, add the Host dotfiles-${repo_name} block to ${conf_file} by hand and re-run with --skip-ssh."
        fi

        generate_deploy_key "${key_name}" "${key_name}@${MACHINE_NAME}"

        # Idempotent — skip if this alias's Host block is already present so
        # re-running install.sh never duplicates it.
        if grep -qx "Host ${alias}" "${conf_file}" 2>/dev/null; then
            info "SSH alias '${alias}' already present in ${conf_file} — skipping."
        else
            _write_ssh_host_entry "${alias}" "${key_name}" "${conf_file}" "${host}"
        fi

        display_names+=("${repo_name}")
    done

    ensure_ssh_config_include

    # ── Display public keys ─────────────────────────────────────────────────
    echo
    echo "${_BOLD}${_YELLOW}ACTION REQUIRED — Add the following keys to each repository before continuing${_RESET}"
    echo
    echo "For each key: go to the repository → Settings → Deploy keys → Add deploy key"
    echo "Allow write access: NO (read-only is sufficient for sync)"
    echo

    for repo_name in "${display_names[@]}"; do
        local pub_file="${HOME}/.ssh/dotfiles-${repo_name}.pub"
        if [[ -f "${pub_file}" ]]; then
            echo "${_BOLD}${repo_name}${_RESET}"
            cat "${pub_file}"
            echo
        fi
    done

    info "The sync-external role rewrites each repo's URL to its alias form"
    info "automatically at Ansible run time — no further host_vars edits needed."
    echo

    read -r -p "Press Enter once all deploy keys have been added to their repositories..." < /dev/tty || true
}

# ── Phase 3b: Sudo / become setup ────────────────────────────────────────────
# Validates sudo access once interactively, then on Linux writes a scoped
# NOPASSWD drop-in so Ansible's become pipe isn't blocked by use_pty.
# The drop-in explicitly disables use_pty for this user so that cleanup_become
# can remove it non-interactively via sudo -n — Fedora and Manjaro both enable
# use_pty by default which would otherwise block passwordless non-TTY sudo.
setup_become() {
    [[ "${ARG_BECOME_PASS}" == "true" ]] || return 0

    info "Validating sudo access..."
    if ! sudo -v; then
        die "sudo authentication failed — check your password and try again."
    fi

    if [[ "$(uname -s)" == "Linux" ]]; then
        info "Writing temporary sudoers drop-in for Ansible run..."
        printf 'Defaults:%s !use_pty\n%s ALL=(ALL) NOPASSWD: ALL\n' \
            "${USER}" "${USER}" \
            | sudo tee "${_SUDOERS_DROPIN}" > /dev/null
        sudo chmod 0440 "${_SUDOERS_DROPIN}"

        if ! sudo visudo -c -f "${_SUDOERS_DROPIN}" &>/dev/null; then
            sudo rm -f "${_SUDOERS_DROPIN}"
            die "sudoers drop-in failed validation — aborting."
        fi

        _SUDOERS_WRITTEN="true"
        info "Temporary NOPASSWD drop-in written — will be removed after Ansible completes."
    fi
    # macOS: no drop-in needed; --ask-become-pass is passed directly to
    # ansible-playbook in run_ansible() instead.
}

cleanup_become() {
    # sudoers.d/ is mode 0750 root:root on Manjaro and Fedora — unprivileged
    # test -f cannot traverse the directory and returns false even when the
    # file exists. All checks against this path must go via sudo.
    if ! sudo -n test -f "${_SUDOERS_DROPIN}" 2>/dev/null; then
        return 0
    fi

    if sudo -n rm -f "${_SUDOERS_DROPIN}" 2>/dev/null; then
        info "Temporary sudoers drop-in removed."
        return 0
    fi

    echo >&2
    error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    error "  SECURITY WARNING: sudoers drop-in was NOT removed"
    error ""
    error "  ${_SUDOERS_DROPIN} grants passwordless sudo to ${USER}."
    error "  Remove it manually before doing anything else:"
    error ""
    error "    sudo rm ${_SUDOERS_DROPIN}"
    error ""
    error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo >&2
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

    # On Linux, setup_become() has already handled sudo via a NOPASSWD drop-in,
    # so --ask-become-pass must NOT be passed — it would trigger a second prompt
    # that Ansible cannot satisfy (use_pty incompatibility on Ubuntu 22.04+).
    # On macOS, use_pty is not an issue so the flag is passed through directly.
    if [[ "${ARG_BECOME_PASS}" == "true" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
        ansible_cmd+=(--ask-become-pass)
    fi

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

    if [[ ${#EXTERNAL_REPO_NAMES[@]} -gt 0 ]]; then
        echo
        echo "  Registered add-on repos were cloned/adopted and deployed by sync-external."
        echo "  Check status any time with:"
        echo "    external-sync"
        echo "    cat ~/.local/share/external-sync/<name>/last-sync"
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

   # Phase 3b — Sudo setup
    trap cleanup_become INT TERM ERR   # abnormal exits only, NOT EXIT
    setup_become

    # Phase 4 — Ansible
    run_ansible

    # Phase 5 — Cleanup (explicit on happy path)
    cleanup_become

    # Phase 6 — Summary
    post_run

    trap - INT TERM ERR   # disarm — cleanup already done
}

main "$@"
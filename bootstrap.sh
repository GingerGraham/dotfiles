#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/you/dotfiles.git"
DEFAULT_PROJECTS_BASE="${HOME}/Projects"
CLONE_SUBPATH="Personal/GitHub/dotfiles"

# ── Parse bootstrap's own args, collect the rest for pass-through ─────────────

projects_base=""
passthrough_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --projects-base)
            [[ -z "${2:-}" ]] && { echo "ERROR: --projects-base requires an argument"; exit 1; }
            projects_base="${2/#\~/${HOME}}"
            shift 2
            ;;
        *)
            passthrough_args+=("$1")
            shift
            ;;
    esac
done

# ── Determine clone target ────────────────────────────────────────────────────

if [[ -z "${projects_base}" ]]; then
    read -rp "Projects base directory [${DEFAULT_PROJECTS_BASE}]: " projects_base
    projects_base="${projects_base:-${DEFAULT_PROJECTS_BASE}}"
    projects_base="${projects_base/#\~/${HOME}}"
fi

clone_target="${projects_base}/${CLONE_SUBPATH}"

# ── Prereq check ──────────────────────────────────────────────────────────────

if ! command -v git &>/dev/null; then
    echo "ERROR: git is required but not installed. Install it and re-run."
    exit 1
fi

# ── Clone ─────────────────────────────────────────────────────────────────────

if [[ -d "${clone_target}/.git" ]]; then
    echo "Repo already exists at ${clone_target} — skipping clone."
else
    echo "Cloning dotfiles to ${clone_target}..."
    mkdir -p "${clone_target}"
    git clone "${REPO_URL}" "${clone_target}"
fi

# ── Hand off — pass bootstrap's projects-base plus all other args through ─────

exec "${clone_target}/install.sh" \
    --projects-base "${projects_base}" \
    "${passthrough_args[@]}"
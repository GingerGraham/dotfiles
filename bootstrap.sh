#!/usr/bin/env bash
set -euo pipefail

VERSION="2.0.0"

# Forking this repo? Update these three (and dotfiles_release_repo_url in
# ansible/group_vars/all.yml) to point at your own fork.
REPO_OWNER="GingerGraham"
REPO_NAME="dotfiles"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
DEFAULT_BRANCH="main"

DEFAULT_PROJECTS_BASE="${HOME}/Projects"
CLONE_SUBPATH="Personal/GitHub/dotfiles"

RELEASE_BASE="${HOME}/.local/share/dotfiles"
KEEP_RELEASES=5

# ── Print bootstrap script version ────────────────────────────────────────────
echo "Bootstrap script version ${VERSION}"

# ── Parse bootstrap's own args, collect the rest for pass-through ─────────────

dev_mode="false"
projects_base=""
passthrough_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev)
            dev_mode="true"
            shift
            ;;
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

# ── --dev: clone with .git into projects_base ─────────────────────────────────
# The pre-existing workflow, unchanged — what Graham uses on gw-fw13-02.

if [[ "${dev_mode}" == "true" ]]; then
    if [[ -z "${projects_base}" ]]; then
        read -rp "Projects base directory [${DEFAULT_PROJECTS_BASE}]: " raw_input || true
        # Strip control characters that leak in when running via bash <(curl ...)
        # e.g. Delete key sends ^[[3~ which corrupts the path if not sanitised
        projects_base=$(printf '%s' "${raw_input}" | tr -cd '[:print:]' | xargs)
        projects_base="${projects_base:-${DEFAULT_PROJECTS_BASE}}"
        projects_base="${projects_base/#\~/${HOME}}"
    fi

    # Validate — must resolve to a path under $HOME
    if [[ "${projects_base}" != "${HOME}"/* ]]; then
        echo "WARNING: projects base '${projects_base}' is not under \$HOME — using default ${DEFAULT_PROJECTS_BASE}" >&2
        projects_base="${DEFAULT_PROJECTS_BASE}"
    fi

    clone_target="${projects_base}/${CLONE_SUBPATH}"

    if ! command -v git &>/dev/null; then
        echo "ERROR: git is required for --dev but not installed. Install it and re-run."
        exit 1
    fi

    if [[ -d "${clone_target}/.git" ]]; then
        echo "Repo already exists at ${clone_target} — pulling latest changes..."
        git -C "${clone_target}" pull --ff-only \
            || echo "WARNING: git pull failed (local changes or network issue) — proceeding with existing state." >&2
    else
        echo "Cloning dotfiles to ${clone_target}..."
        mkdir -p "${clone_target}"
        git clone "${REPO_URL}" "${clone_target}"
    fi

    exec "${clone_target}/install.sh" \
        --projects-base "${projects_base}" \
        "${passthrough_args[@]}"
fi

# ── Default: fetch a release tarball, no .git anywhere ────────────────────────
# Flip is atomic (symlink swap) so a re-run of this one-liner is always safe,
# even mid-way through a previous run. See docs/sync.md#install-modes.

for cmd in curl tar; do
    if ! command -v "${cmd}" &>/dev/null; then
        echo "ERROR: ${cmd} is required but not installed. Install it and re-run."
        exit 1
    fi
done

mkdir -p "${RELEASE_BASE}/releases"

tmp_tar=$(mktemp)
tmp_extract=$(mktemp -d)
trap 'rm -f "${tmp_tar}"; rm -rf "${tmp_extract}"' EXIT

# Resolve the branch to a commit sha via the GitHub API first. GitHub's
# codeload tarball for a branch ref always extracts to a constant
# <repo>-<branch>/ directory regardless of which commit is at the tip, so
# there is no sha to read back out of the archive itself — this is the only
# way to get a "what am I running" release id.
echo "Resolving ${REPO_OWNER}/${REPO_NAME}@${DEFAULT_BRANCH}..."
# head -1, not grep -m1: the API response is a single (compact) line, so
# -m1 would still let -o print every match on it — including the nested
# commit.tree.sha further along — instead of just the first ("sha" is the
# top-level key, appearing first).
sha=$(curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/${DEFAULT_BRANCH}" \
    | grep -o '"sha":[^,]*' \
    | head -1 \
    | grep -oE '[0-9a-f]{40}')
if [[ -z "${sha}" ]]; then
    echo "ERROR: could not resolve ${DEFAULT_BRANCH} to a commit via the GitHub API"
    exit 1
fi
shortsha="${sha:0:7}"

echo "Fetching ${REPO_OWNER}/${REPO_NAME}@${shortsha}..."
if ! curl -fsSL "https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${DEFAULT_BRANCH}" -o "${tmp_tar}"; then
    echo "ERROR: could not fetch https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${DEFAULT_BRANCH}"
    exit 1
fi

tar -xzf "${tmp_tar}" -C "${tmp_extract}"
rm -f "${tmp_tar}"

extracted_dir=$(find "${tmp_extract}" -mindepth 1 -maxdepth 1 -type d | head -1)
if [[ -z "${extracted_dir}" ]]; then
    echo "ERROR: release tarball extraction produced no directory"
    exit 1
fi

timestamp=$(date -u +"%Y-%m-%dT%H%M%SZ")
release_dir="${RELEASE_BASE}/releases/${timestamp}-${shortsha}"

mv "${extracted_dir}" "${release_dir}"
rm -rf "${tmp_extract}"
trap - EXIT

# Atomic flip: symlink into place under a temp name, then rename over the
# real one — 'current' always points at either the old or the new release,
# never a half-written one.
ln -sfn "${release_dir}" "${RELEASE_BASE}/current.tmp"
mv -T "${RELEASE_BASE}/current.tmp" "${RELEASE_BASE}/current"

echo "Installed release ${shortsha} to ${release_dir}"

# Prune releases beyond keep-N, oldest first.
while IFS= read -r old; do
    [[ -n "${old}" ]] && rm -rf "${old}"
done < <(find "${RELEASE_BASE}/releases" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$((KEEP_RELEASES + 1)))

# --projects-base has nothing to do with where dotfiles itself lives in this
# mode, but install.sh still wants it for the caller's own project tree — so
# forward it through if given, rather than silently dropping it.
if [[ -n "${projects_base}" ]]; then
    passthrough_args+=(--projects-base "${projects_base}")
fi

exec "${RELEASE_BASE}/current/install.sh" "${passthrough_args[@]}"

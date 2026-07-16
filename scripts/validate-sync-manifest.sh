#!/usr/bin/env bash
# scripts/validate-sync-manifest.sh
# ─────────────────────────────────────────────────────────────────────────────
# Developer-time validator for .dotfiles-sync.yml against
# docs/sync-manifest-spec.md, the authoritative contract — if this script
# ever disagrees with that file, the spec wins (see its own header note and
# ansible/roles/sync-external/tasks/repo.yml's header, which cites this
# script back). Meant to be run by hand, or wired into an add-on repo's own
# CI, before pushing a manifest — it checks the same src/dest/command[0]
# resolution rules Ansible enforces at provisioning time, without needing
# Ansible or a live machine.
#
# This is the one place in the dotfiles repo where yq is an acceptable
# dependency: it's a developer-time tool, never invoked on the timer path
# (scripts/external-sync.sh never parses YAML — see the spec's "Purpose").
# Requires mikefarah/yq v4; detection mirrors
# shell/config/tools/git.sh's _git_require_yq(), including the
# python3-yq-shadowing-on-Ubuntu trap — that binary reports itself as `yq`
# too, but is a completely different (jq-wrapper) tool with no compatible
# CLI surface.
#
# Usage: validate-sync-manifest.sh [path]   (default: ./.dotfiles-sync.yml)
# Exit status: 0 if the manifest is valid, non-zero otherwise.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ERRORS=0
WARNINGS=0

err()  { echo "[ERROR] $*" >&2; ERRORS=$((ERRORS + 1)); }
warn() { echo "[WARN]  $*" >&2; WARNINGS=$((WARNINGS + 1)); }
info() { echo "[INFO]  $*"; }

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [path]

Validates a .dotfiles-sync.yml manifest against the rules in
docs/sync-manifest-spec.md — the same src/dest/command[0] resolution rules
the sync-external Ansible role enforces at provisioning time, checked here
without needing Ansible or a live machine.

  path   Path to the manifest to validate (default: ./.dotfiles-sync.yml)

Checks (fail the manifest):
  - the file parses as YAML
  - version is present and equal to 1
  - every deploy[] entry has src and dest
  - src is a safe relative path (no leading /, no .. segment)
  - dest (and dest_macos) starts with ~/, contains no .. segment, and does
    not target the dest denylist (see the spec's "dest validation")
  - mode, when given, is copy or link
  - platforms, when given, only contains linux/macos
  - hooks.post_deploy.command, when hooks.post_deploy is declared, is a
    non-empty list (not a string) whose [0] is a safe relative path that
    exists in the repo
  - hooks.post_deploy.run_on, when given, is changed/always/initial
  - hooks.post_deploy.timeout, when given, is a positive integer

Warns (does not fail the manifest):
  - a deploy[] src that does not exist in the repo
  - a manifest declaring hooks (reminder: allow_hooks: true is required per
    machine, in host_vars — see docs/external-sync.md#enabling-hooks)
  - both deploy and hooks absent (clone-only is valid, but worth confirming
    it was deliberate)

Requires mikefarah/yq v4: https://github.com/mikefarah/yq#install
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

MANIFEST="${1:-./.dotfiles-sync.yml}"

require_yq() {
    if ! command -v yq &>/dev/null; then
        err "yq is required for manifest validation."
        err "Install: https://github.com/mikefarah/yq#install"
        exit 1
    fi
    if ! yq --version 2>&1 | grep -qE 'mikefarah|version v4|yq \(https://github.com/mikefarah'; then
        err "Wrong yq detected — mikefarah/yq v4 is required."
        err "Found: $(yq --version 2>&1)"
        err "Install: https://github.com/mikefarah/yq#install"
        err "On Ubuntu/Debian, python3-yq may be shadowing the correct binary — check 'which -a yq'."
        exit 1
    fi
}

require_yq

if [[ ! -f "${MANIFEST}" ]]; then
    err "Manifest not found: ${MANIFEST}"
    exit 1
fi

if ! yq eval '.' "${MANIFEST}" > /dev/null 2>&1; then
    err "Manifest does not parse as YAML: ${MANIFEST}"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${MANIFEST}")" && pwd)"

# ── Path-safety helpers ───────────────────────────────────────────────────────
# Mirrors ansible/roles/sync-external/tasks/repo.yml's src/command[0]
# assertion: non-empty, no leading /, no .. segment. Runs against the raw
# manifest value, same as the Ansible-side check — this script has no
# concept of an absolute clone_dir, it only checks the manifest's own shape.

_is_safe_relative_path() {
    local p="$1"
    [[ -z "${p}" || "${p}" == "null" ]] && return 1
    [[ "${p}" == /* ]] && return 1
    local seg
    local IFS='/'
    for seg in ${p}; do
        [[ "${seg}" == ".." ]] && return 1
    done
    return 0
}

# dest denylist, relative to ~ — same set as
# ansible/roles/sync-external/defaults/main.yml's
# sync_external_dest_denylist_dirs/_files, with the leading ~ stripped since
# this script has no single real machine's $HOME to resolve against; it only
# checks that dest is anchored at ~ and doesn't fall under one of these.
_DEST_DENYLIST_DIRS_REL=(
    ".ssh/" ".gnupg/" ".config/shell/" ".config/git/" ".config/dotfiles/"
    ".config/external-sync/" ".config/systemd/user/" "Library/LaunchAgents/"
)
_DEST_DENYLIST_FILES_REL=(
    ".bashrc" ".zshrc" ".profile" ".gitconfig"
)

_is_safe_dest() {
    local d="$1"
    [[ -z "${d}" || "${d}" == "null" ]] && return 1
    # shellcheck disable=SC2088 # intentional: checking the raw manifest
    # string for a literal leading "~/", not asking the shell to expand it.
    [[ "${d}" != "~/"* ]] && return 1

    local rel="${d#\~/}"
    [[ -z "${rel}" ]] && return 1

    local seg
    local IFS='/'
    for seg in ${rel}; do
        [[ "${seg}" == ".." ]] && return 1
    done

    local entry
    for entry in "${_DEST_DENYLIST_DIRS_REL[@]}"; do
        [[ "${rel}" == "${entry}"* ]] && return 1
    done
    for entry in "${_DEST_DENYLIST_FILES_REL[@]}"; do
        [[ "${rel}" == "${entry}" ]] && return 1
    done
    return 0
}

# ── version ──────────────────────────────────────────────────────────────────

_version=$(yq eval '.version' "${MANIFEST}")
if [[ -z "${_version}" || "${_version}" == "null" ]]; then
    err "version is required (docs/sync-manifest-spec.md §Field reference)."
elif [[ "${_version}" != "1" ]]; then
    err "version must be 1 — found '${_version}' (docs/sync-manifest-spec.md §Schema version 1)."
fi

# ── deploy[] ─────────────────────────────────────────────────────────────────

_has_deploy=$(yq eval '.deploy != null' "${MANIFEST}")
_deploy_count=0
if [[ "${_has_deploy}" == "true" ]]; then
    _deploy_count=$(yq eval '.deploy | length' "${MANIFEST}")
fi

if [[ "${_deploy_count}" -gt 0 ]]; then
    _i=0
    while [[ "${_i}" -lt "${_deploy_count}" ]]; do
        _src=$(yq eval ".deploy[${_i}].src" "${MANIFEST}")
        _dest=$(yq eval ".deploy[${_i}].dest" "${MANIFEST}")
        _dest_macos=$(yq eval ".deploy[${_i}].dest_macos" "${MANIFEST}")
        _mode=$(yq eval ".deploy[${_i}].mode" "${MANIFEST}")
        _label="deploy[${_i}] (src: ${_src})"

        if [[ -z "${_src}" || "${_src}" == "null" ]]; then
            err "${_label}: src is required (docs/sync-manifest-spec.md §Field reference)."
        elif ! _is_safe_relative_path "${_src}"; then
            err "${_label}: src '${_src}' must be a path relative to the repo root, without '..' segments or a leading '/' (docs/sync-manifest-spec.md §Deploy semantics)."
        elif [[ ! -e "${REPO_ROOT}/${_src}" ]]; then
            warn "${_label}: src '${_src}' does not exist in the repo (checked ${REPO_ROOT}/${_src})."
        fi

        if [[ -z "${_dest}" || "${_dest}" == "null" ]]; then
            err "${_label}: dest is required (docs/sync-manifest-spec.md §Field reference)."
        elif ! _is_safe_dest "${_dest}"; then
            err "${_label}: dest '${_dest}' must start with ~/, contain no '..' segments, and must not target the dest denylist (docs/sync-manifest-spec.md §dest validation)."
        fi

        if [[ -n "${_dest_macos}" && "${_dest_macos}" != "null" ]] && ! _is_safe_dest "${_dest_macos}"; then
            err "${_label}: dest_macos '${_dest_macos}' must start with ~/, contain no '..' segments, and must not target the dest denylist (docs/sync-manifest-spec.md §dest validation)."
        fi

        if [[ -n "${_mode}" && "${_mode}" != "null" && "${_mode}" != "copy" && "${_mode}" != "link" ]]; then
            err "${_label}: mode must be 'copy' or 'link' — found '${_mode}'."
        fi

        _platforms_count=$(yq eval ".deploy[${_i}].platforms // [] | length" "${MANIFEST}")
        if [[ "${_platforms_count}" -gt 0 ]]; then
            _p=0
            while [[ "${_p}" -lt "${_platforms_count}" ]]; do
                _platform=$(yq eval ".deploy[${_i}].platforms[${_p}]" "${MANIFEST}")
                if [[ "${_platform}" != "linux" && "${_platform}" != "macos" ]]; then
                    err "${_label}: platforms[${_p}] must be 'linux' or 'macos' — found '${_platform}'."
                fi
                _p=$((_p + 1))
            done
        fi

        _i=$((_i + 1))
    done
fi

# ── hooks.post_deploy ──────────────────────────────────────────────────────────

_hook_declared=$(yq eval '.hooks.post_deploy != null' "${MANIFEST}")

if [[ "${_hook_declared}" == "true" ]]; then
    warn "manifest declares a post_deploy hook — remember allow_hooks: true is required per machine, in host_vars (docs/external-sync.md#enabling-hooks)."

    _command_type=$(yq eval '.hooks.post_deploy.command | type' "${MANIFEST}")
    if [[ "${_command_type}" == "!!str" ]]; then
        err "hooks.post_deploy.command must be a list (argv form), not a string — found a string. A string would be silently word-split (docs/sync-manifest-spec.md §Hook manifest schema)."
    elif [[ "${_command_type}" != "!!seq" ]]; then
        err "hooks.post_deploy.command is required and must be a non-empty list (docs/sync-manifest-spec.md §Hook manifest schema)."
    else
        _command_len=$(yq eval '.hooks.post_deploy.command | length' "${MANIFEST}")
        if [[ "${_command_len}" -eq 0 ]]; then
            err "hooks.post_deploy.command must be a non-empty list."
        else
            _command0=$(yq eval '.hooks.post_deploy.command[0]' "${MANIFEST}")
            if ! _is_safe_relative_path "${_command0}"; then
                err "hooks.post_deploy.command[0] '${_command0}' must be a path relative to the repo root, without '..' segments or a leading '/' (docs/sync-manifest-spec.md §Hook manifest schema)."
            elif [[ ! -e "${REPO_ROOT}/${_command0}" ]]; then
                err "hooks.post_deploy.command[0] '${_command0}' does not exist in the repo (checked ${REPO_ROOT}/${_command0})."
            fi
        fi
    fi

    _run_on=$(yq eval '.hooks.post_deploy.run_on' "${MANIFEST}")
    if [[ -n "${_run_on}" && "${_run_on}" != "null" ]]; then
        case "${_run_on}" in
            changed|always|initial) ;;
            *) err "hooks.post_deploy.run_on must be changed, always, or initial — found '${_run_on}'." ;;
        esac
    fi

    _timeout=$(yq eval '.hooks.post_deploy.timeout' "${MANIFEST}")
    if [[ -n "${_timeout}" && "${_timeout}" != "null" ]]; then
        if ! [[ "${_timeout}" =~ ^[0-9]+$ ]] || [[ "${_timeout}" -eq 0 ]]; then
            err "hooks.post_deploy.timeout must be a positive integer — found '${_timeout}'."
        fi
    fi
fi

if [[ "${_deploy_count}" -eq 0 && "${_hook_declared}" != "true" ]]; then
    warn "manifest has no deploy entries and no hooks — this is a valid clone-only manifest, but confirm that was deliberate (docs/sync-manifest-spec.md §1. Clone-only)."
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo
if [[ "${ERRORS}" -eq 0 ]]; then
    info "${MANIFEST}: valid (${WARNINGS} warning(s))."
    exit 0
else
    err "${MANIFEST}: ${ERRORS} error(s), ${WARNINGS} warning(s)."
    exit 1
fi

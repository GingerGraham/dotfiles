#!/usr/bin/env bash
# tests/check-updater-coverage.sh
#
# Keeps update-tools in sync with the installer set. Two checks:
#   1. Every public install-* function in lazy/installers.sh is referenced
#      somewhere in lazy/maintenance.sh (registry row or fallback updater),
#      unless explicitly allow-listed.
#   2. Every updater/installer function named in the registry actually exists
#      as a defined function somewhere under shell/config (catches typos like
#      `helm-install` for `install-helm`).
#
# Run with bash (not sh): bash tests/check-updater-coverage.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installers="${repo_root}/shell/config/lazy/installers.sh"
maintenance="${repo_root}/shell/config/lazy/maintenance.sh"
config_dir="${repo_root}/shell/config"

# install-* functions that intentionally aren't part of routine update-tools.
# Keep short and justified.
allowlist=(
    install-edit-version      # pinned-version variant of install-edit
    install-noteshub-version  # pinned-version variant of install-noteshub
)

is_allowlisted() { local f="$1" a; for a in "${allowlist[@]}"; do [[ "${a}" == "${f}" ]] && return 0; done; return 1; }

# ---- Check 1: every installer is wired into the updater -----------------------
installers_found=()
while IFS= read -r fn; do installers_found+=("${fn}"); done < <(
    grep -Eo '^install-[a-zA-Z0-9_-]+[[:space:]]*\(\)' "${installers}" \
        | sed -E 's/[[:space:]]*\(\).*//' | sort -u
)

missing=()
for fn in "${installers_found[@]}"; do
    is_allowlisted "${fn}" && continue
    grep -qF -- "${fn}" "${maintenance}" || missing+=("${fn}")
done

# ---- Check 2: every registry function name is actually defined ---------------
defined_fns=()
while IFS= read -r fn; do defined_fns+=("${fn}"); done < <(
    grep -rhoE '^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*\(\)' "${config_dir}" \
        | sed -E 's/[[:space:]]*\(\).*//' | sort -u
)
is_defined() { local f="$1" g; for g in "${defined_fns[@]}"; do [[ "${g}" == "${f}" ]] && return 0; done; return 1; }

undefined=()
while IFS='|' read -r name detect updater installer label; do
    [[ -z "${name}" ]] && continue
    for f in "${updater}" "${installer}"; do
        is_defined "${f}" || undefined+=("${name} -> ${f}")
    done
done < <(grep -E '^[a-zA-Z0-9_-]+\|' "${maintenance}")

# ---- Report ------------------------------------------------------------------
rc=0
if (( ${#missing[@]} )); then
    rc=1
    echo "FAIL: install-* functions not wired into update-tools (add a registry row in"
    echo "      lazy/maintenance.sh, or allow-list them in this test with a reason):"
    printf '  - %s\n' "${missing[@]}"
fi
if (( ${#undefined[@]} )); then
    rc=1
    echo "FAIL: registry references functions that are not defined under shell/config"
    echo "      (typo, or the function was renamed/removed):"
    printf '  - %s\n' "${undefined[@]}"
fi
if (( rc == 0 )); then
    echo "OK: ${#installers_found[@]} installers checked, all covered; registry functions all defined."
fi
exit "${rc}"

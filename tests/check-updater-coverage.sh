#!/usr/bin/env bash
# tests/check-updater-coverage.sh
#
# Keeps update-tools in sync with the installer set. Three checks:
#   1. Every public install-* function in any lazy/installers*.sh file is
#      referenced somewhere in lazy/maintenance.sh (registry row or fallback
#      updater), unless explicitly allow-listed.
#   2. Every public install-* function in any lazy/optional/installers*.sh file
#      is referenced in _optional_tools_registry() in maintenance.sh, unless
#      explicitly allow-listed.
#   3. Every updater/installer function named in either registry actually exists
#      as a defined function somewhere under shell/config (catches typos like
#      `helm-install` for `install-helm`).
#
# Run with bash (not sh): bash tests/check-updater-coverage.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
maintenance="${repo_root}/shell/config/lazy/maintenance.sh"
config_dir="${repo_root}/shell/config"

# Installer files: any lazy/installers*.sh. Adding a new group file
# (e.g. installers-ai.sh) is picked up automatically — no edit needed here.
shopt -s nullglob
installer_files=( "${repo_root}/shell/config/lazy/installers"*.sh )
shopt -u nullglob
if (( ${#installer_files[@]} == 0 )); then
    echo "FAIL: no installer files found under shell/config/lazy/installers*.sh"
    exit 1
fi

# install-* functions that intentionally aren't part of routine update-tools.
# Keep short and justified.
allowlist=(
    install-edit-version      # pinned-version variant of install-edit
    install-gemini-cli        # alias for install-antigravity; Google deprecated Gemini CLI
    install-zsh               # package-manager install, no-op if zsh present; OS owns updates
    install-zsh-default-shell # one-time chsh action, not a versioned tool
    install-zsh-plugins       # one-time plugin clone/install; re-clone semantics, not update-in-place
)

is_allowlisted() { local f="$1" a; for a in "${allowlist[@]}"; do [[ "${a}" == "${f}" ]] && return 0; done; return 1; }

# ---- Check 1: every installer is wired into the updater -----------------------
installers_found=()
while IFS= read -r fn; do installers_found+=("${fn}"); done < <(
    grep -Eho '^install-[a-zA-Z0-9_-]+[[:space:]]*\(\)' "${installer_files[@]}" \
        | sed -E 's/[[:space:]]*\(\).*//' | sort -u
)

missing=()
for fn in "${installers_found[@]}"; do
    is_allowlisted "${fn}" && continue
    grep -qF -- "${fn}" "${maintenance}" || missing+=("${fn}")
done

# Optional installer files: any lazy/optional/installers*.sh.
shopt -s nullglob
optional_installer_files=( "${repo_root}/shell/config/lazy/optional/installers"*.sh )
shopt -u nullglob

# Optional allowlist — pinned-version variants and one-time actions from optional/.
optional_allowlist=(
    install-noteshub-version  # pinned-version variant; specific-version flow not yet implemented
    install-opendeck-version  # pinned-version variant; specific-version flow not yet implemented
)
is_optional_allowlisted() { local f="$1" a; for a in "${optional_allowlist[@]}"; do [[ "${a}" == "${f}" ]] && return 0; done; return 1; }

# ---- Check 2: every optional installer is wired into _optional_tools_registry ----
optional_missing=()
if (( ${#optional_installer_files[@]} > 0 )); then
    optional_installers_found=()
    while IFS= read -r fn; do optional_installers_found+=("${fn}"); done < <(
        grep -Eho '^install-[a-zA-Z0-9_-]+[[:space:]]*\(\)' "${optional_installer_files[@]}" \
            | sed -E 's/[[:space:]]*\(\).*//' | sort -u
    )
    for fn in "${optional_installers_found[@]}"; do
        is_optional_allowlisted "${fn}" && continue
        grep -qF -- "${fn}" "${maintenance}" || optional_missing+=("${fn}")
    done
fi

# ---- Check 3: every registry function name is actually defined ---------------
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
if (( ${#optional_missing[@]} )); then
    rc=1
    echo "FAIL: optional install-* functions not wired into _optional_tools_registry() in"
    echo "      lazy/maintenance.sh (add a registry row, or add to optional_allowlist above):"
    printf '  - %s\n' "${optional_missing[@]}"
fi
if (( ${#undefined[@]} )); then
    rc=1
    echo "FAIL: registry references functions that are not defined under shell/config"
    echo "      (typo, or the function was renamed/removed):"
    printf '  - %s\n' "${undefined[@]}"
fi
if (( rc == 0 )); then
    core_count="${#installers_found[@]}"
    opt_count="${#optional_installer_files[@]}"
    echo "OK: ${core_count} core installers and ${opt_count:+${#optional_installers_found[@]}}${opt_count:-0} optional installers checked, all covered; registry functions all defined."
fi
exit "${rc}"

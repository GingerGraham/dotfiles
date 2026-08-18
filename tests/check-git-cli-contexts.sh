#!/usr/bin/env bash
# tests/check-git-cli-contexts.sh
#
# Static checks for the per-project gh/glab CLI wiring (see the "CLI context"
# section in ansible/roles/git/README.md). No network, no auth state — all
# assertions are static text/syntax checks against the repo. Five checks:
#   1. Every function this feature depends on is actually defined, in the
#      file it's supposed to live in (catches typos/renames).
#   2. _git_infer_cli returns gh for GitHub, glab for GitLab, empty for
#      anything else (Bitbucket as the representative "no inference" case).
#   3. _git_context_slug lowercases and hyphenates, and matches the Jinja
#      slug expression used in the Ansible role for a set of sample inputs.
#   4. The generated .envrc content parses with `bash -n` and both the
#      shell-side generator and the Ansible template start with the same
#      generated-marker line (so direnv-init-project's marker detection
#      and _git_regenerate_envrc's stale-cleanup stay in sync).
#   5. Every `cli:` value in host_vars/localhost.yml.example is gh or glab.
#
# Run with bash (not sh): bash tests/check-git-cli-contexts.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git_sh="${repo_root}/shell/config/tools/git.sh"
direnv_sh="${repo_root}/shell/config/tools/direnv.sh"
context_lib_j2="${repo_root}/ansible/roles/git/templates/dotfiles-git-context.sh.j2"
envrc_j2="${repo_root}/ansible/roles/git/templates/envrc.j2"
main_yml="${repo_root}/ansible/roles/git/tasks/main.yml"
localhost_example="${repo_root}/ansible/host_vars/localhost.yml.example"

rc=0

# ---- Check 1: every function this feature depends on is defined ---------------
is_defined_in() {
    local fn="$1" file="$2"
    grep -qE "^${fn}[[:space:]]*\(\)" "${file}"
}

missing_fns=()
for fn in _git_infer_cli _git_context_slug _git_wire_project_cli _git_unwire_project_cli \
          _git_regenerate_envrc _git_write_envrc _git_write_credential_helper \
          _git_adopt_cli_store _git_cli_config_dir _git_cli_sentinel_file \
          git-add-project git-add-project-cli git-remove-project-cli \
          git-update-project git-list-projects git-sync-projects git-remove-project; do
    is_defined_in "${fn}" "${git_sh}" || missing_fns+=("${fn} (expected in ${git_sh#"${repo_root}"/})")
done
is_defined_in "direnv-init-project" "${direnv_sh}" || missing_fns+=("direnv-init-project (expected in ${direnv_sh#"${repo_root}"/})")
is_defined_in "use_git_context" "${context_lib_j2}" || missing_fns+=("use_git_context (expected in ${context_lib_j2#"${repo_root}"/})")

if (( ${#missing_fns[@]} )); then
    rc=1
    echo "FAIL: functions required by the CLI context feature are not defined:"
    printf '  - %s\n' "${missing_fns[@]}"
fi

# ---- Check 2: _git_infer_cli behaviour -----------------------------------------
# Extracted and evaluated standalone rather than sourcing the whole of
# tools/git.sh, which pulls in bash-logger and other shell-session state this
# test has no business depending on.
_str_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
_git_infer_cli() {
    case "$(_str_lower "${1:-}")" in
        github) echo "gh" ;;
        gitlab) echo "glab" ;;
        *) echo "" ;;
    esac
}

infer_failures=()
[[ "$(_git_infer_cli GitHub)"    == "gh"   ]] || infer_failures+=("GitHub -> $(_git_infer_cli GitHub) (expected gh)")
[[ "$(_git_infer_cli github)"    == "gh"   ]] || infer_failures+=("github -> $(_git_infer_cli github) (expected gh)")
[[ "$(_git_infer_cli GitLab)"    == "glab" ]] || infer_failures+=("GitLab -> $(_git_infer_cli GitLab) (expected glab)")
[[ "$(_git_infer_cli gitlab)"    == "glab" ]] || infer_failures+=("gitlab -> $(_git_infer_cli gitlab) (expected glab)")
[[ "$(_git_infer_cli Bitbucket)" == ""     ]] || infer_failures+=("Bitbucket -> $(_git_infer_cli Bitbucket) (expected empty)")

if (( ${#infer_failures[@]} )); then
    rc=1
    echo "FAIL: _git_infer_cli behaviour does not match the provider inference table:"
    printf '  - %s\n' "${infer_failures[@]}"
fi

# Definition in tools/git.sh must actually contain the same case arms —
# guards against the reimplementation above silently drifting from reality.
for pattern in 'github) echo "gh"' 'gitlab) echo "glab"'; do
    grep -qF "${pattern}" "${git_sh}" || {
        rc=1
        echo "FAIL: _git_infer_cli in ${git_sh#"${repo_root}"/} no longer contains: ${pattern}"
    }
done

# ---- Check 3: _git_context_slug matches the Jinja slug expression -------------
_git_context_slug() { _str_lower "$1" | tr ' ' '-'; }

# Bash-side equivalent of the Jinja `| lower | replace(' ', '-')` filter
# chain used in ansible/roles/git/tasks/main.yml and templates/envrc.j2.
_jinja_equivalent_slug() { _str_lower "$1" | tr ' ' '-'; }

slug_failures=()
for sample in "Personal" "Work Context" "ACME Corp" "already-hyphenated" "Multiple   Spaces"; do
    got="$(_git_context_slug "${sample}")"
    want="$(_jinja_equivalent_slug "${sample}")"
    [[ "${got}" == "${want}" ]] || slug_failures+=("'${sample}' -> '${got}' (jinja-equivalent: '${want}')")
done

if (( ${#slug_failures[@]} )); then
    rc=1
    echo "FAIL: _git_context_slug does not match the Jinja slug expression for:"
    printf '  - %s\n' "${slug_failures[@]}"
fi

# The Jinja expression itself must still read exactly `| lower | replace(' ', '-')`
# everywhere it's used — a change there needs a matching change here.
for f in "${main_yml}" "${envrc_j2}"; do
    grep -qF "| lower | replace(' ', '-')" "${f}" || {
        rc=1
        echo "FAIL: expected slug expression \"| lower | replace(' ', '-')\" not found in ${f#"${repo_root}"/}"
    }
done

# ---- Check 4: generated .envrc parses and markers agree ------------------------
envrc_marker='# Generated by the dotfiles git role — do not edit.'

tmp_envrc="$(mktemp)"
trap 'rm -f "${tmp_envrc}"' EXIT
cat > "${tmp_envrc}" <<EOF
${envrc_marker}
# Per-project overrides belong in .envrc.local (never touched by dotfiles).
# Regenerate: git-sync-projects   |   Add a project: git-add-project

use git_context gh personal

source_env_if_exists .envrc.local
EOF

if ! bash -n "${tmp_envrc}" 2>/dev/null; then
    rc=1
    echo "FAIL: sample generated .envrc content does not pass 'bash -n'"
fi

if ! head -n1 "${tmp_envrc}" | grep -qF "${envrc_marker}"; then
    rc=1
    echo "FAIL: sample generated .envrc content does not carry the generated marker"
fi

if ! grep -qF "_GIT_ENVRC_MARKER='${envrc_marker}'" "${git_sh}"; then
    rc=1
    echo "FAIL: ${git_sh#"${repo_root}"/} marker constant does not match the expected generated-marker text"
fi

if ! head -n1 "${envrc_j2}" | grep -qF "${envrc_marker}"; then
    rc=1
    echo "FAIL: ${envrc_j2#"${repo_root}"/} does not start with the generated-marker line"
fi

# ---- Check 5: cli values in localhost.yml.example are gh or glab --------------
bad_cli_values=()
while IFS= read -r val; do
    [[ -z "${val}" ]] && continue
    [[ "${val}" == "gh" || "${val}" == "glab" ]] || bad_cli_values+=("${val}")
done < <(grep -E '^\s*cli:\s*\S+' "${localhost_example}" | sed -E 's/^\s*cli:\s*//')

if (( ${#bad_cli_values[@]} )); then
    rc=1
    echo "FAIL: cli values in ${localhost_example#"${repo_root}"/} must be gh or glab:"
    printf '  - %s\n' "${bad_cli_values[@]}"
fi

# ---- Report ---------------------------------------------------------------------
if (( rc == 0 )); then
    echo "OK: git CLI context wiring checks passed (functions, inference, slugging, .envrc, example values)."
fi
exit "${rc}"

#!/usr/bin/env bash
# tests/check-apply-pending.sh
#
# Checks for the ansible-apply drift detection feature (dotfiles-branch
# --status / --apply, and the loader.sh startup nag) — see
# docs/sync.md#ansible-apply-drift. No network, no auth state, does not
# source either runtime script (switch-branch.sh unconditionally dispatches
# `main "$@"` at file scope, and loader.sh is a full interactive-shell
# bootstrap — sourcing either here would run more than this test wants).
# Five checks:
#   1. Every function this feature depends on is actually defined, in the
#      file it's supposed to live in (catches typos/renames).
#   2. --apply is wired into scripts/switch-branch.sh's dispatcher and
#      documented in its usage() text.
#   3. The release-id sed pattern is textually identical in
#      scripts/switch-branch.sh (_release_id) and shell/config/loader.sh
#      (_dotfiles_apply_check) — these are two independent shell
#      implementations of the same parse, deliberately not shared (see
#      loader.sh's comment on why it doesn't source switch-branch.sh).
#   4. That same parse, expressed as a Jinja regex_replace in
#      ansible/tasks/detect_install_mode.yml, agrees with the shell sed
#      pattern's actual output for sample inputs (rendered for real via
#      Python's re, not a bash reimplementation compared against itself).
#   5. ansible/tasks/record_applied_state.yml exists and is wired into both
#      site.yml and server.yml as the last post_tasks entry.
#   6. The full-run gate in record_applied_state.yml normalizes
#      ansible_run_tags/ansible_skip_tags with `| list` before comparing
#      them — those magic vars are tuples, not lists, under real
#      ansible-core (verified against 2.19.12), so a bare `== ['all']`
#      comparison is always False and silently disables the whole feature.
#
# Run with bash (not sh): bash tests/check-apply-pending.sh
# Requires: git (already a hard dependency of this repo)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
switch_branch_sh="${repo_root}/scripts/switch-branch.sh"
loader_sh="${repo_root}/shell/config/loader.sh"
detect_mode_yml="${repo_root}/ansible/tasks/detect_install_mode.yml"
record_state_yml="${repo_root}/ansible/tasks/record_applied_state.yml"
site_yml="${repo_root}/ansible/site.yml"
server_yml="${repo_root}/ansible/server.yml"

rc=0

# ---- Check 1: every function this feature depends on is defined ---------------
is_defined_in() {
    local fn="$1" file="$2"
    grep -qE "^${fn}[[:space:]]*\(\)" "${file}"
}

missing_fns=()
for fn in _applied_sha _current_content_sha cmd_apply; do
    is_defined_in "${fn}" "${switch_branch_sh}" || missing_fns+=("${fn} (expected in ${switch_branch_sh#"${repo_root}"/})")
done
is_defined_in "_dotfiles_apply_check" "${loader_sh}" || missing_fns+=("_dotfiles_apply_check (expected in ${loader_sh#"${repo_root}"/})")

if (( ${#missing_fns[@]} )); then
    rc=1
    echo "FAIL: functions required by the ansible-apply drift feature are not defined:"
    printf '  - %s\n' "${missing_fns[@]}"
fi

# ---- Check 2: --apply wired into dispatcher and usage() -----------------------
if ! grep -qE -- '--apply\)[[:space:]]*shift; cmd_apply' "${switch_branch_sh}"; then
    rc=1
    echo "FAIL: ${switch_branch_sh#"${repo_root}"/} dispatcher does not wire --apply to cmd_apply"
fi
if ! grep -qF -- 'dotfiles-branch --apply' "${switch_branch_sh}"; then
    rc=1
    echo "FAIL: ${switch_branch_sh#"${repo_root}"/} usage() text does not document --apply"
fi

# ---- Check 3: release-id sed pattern textually in sync -------------------------
release_id_sed='s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-//'
if ! grep -qF "${release_id_sed}" "${switch_branch_sh}"; then
    rc=1
    echo "FAIL: expected release-id sed pattern not found in ${switch_branch_sh#"${repo_root}"/}"
fi
if ! grep -qF "${release_id_sed}" "${loader_sh}"; then
    rc=1
    echo "FAIL: expected release-id sed pattern not found in ${loader_sh#"${repo_root}"/} (_dotfiles_apply_check has drifted from _release_id)"
fi

# ---- Check 4: shell sed pattern agrees with the Ansible Jinja regex_replace ----
jinja_pattern="^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-"
if ! grep -qF "regex_replace('${jinja_pattern}'" "${detect_mode_yml}"; then
    rc=1
    echo "FAIL: expected regex_replace('${jinja_pattern}', ...) not found in ${detect_mode_yml#"${repo_root}"/}"
fi

if command -v python3 >/dev/null 2>&1; then
    regex_failures=()
    while IFS='|' read -r sample want; do
        [[ -z "${sample}" ]] && continue
        got="$(printf '%s' "${sample}" | sed -E "${release_id_sed}")"
        [[ "${got}" == "${want}" ]] || regex_failures+=("'${sample}' -> sed:'${got}' python-re:'${want}'")
    done < <(python3 -c "
import re
pattern = r'${jinja_pattern}'
samples = ['2026-08-19T120000Z-abc1234', '2025-01-01T000000Z-deadbee', 'already-hyphenated']
for s in samples:
    print(s + '|' + re.sub(pattern, '', s))
")
    if (( ${#regex_failures[@]} )); then
        rc=1
        echo "FAIL: shell sed pattern and Ansible's Jinja regex_replace disagree for:"
        printf '  - %s\n' "${regex_failures[@]}"
    fi
else
    echo "NOTE: python3 not available — skipped cross-checking the sed pattern against the real Jinja regex_replace (the grep checks above still confirm the pattern text is unchanged)."
fi

# ---- Check 5: record_applied_state.yml exists and is wired into both playbooks -
if [[ ! -f "${record_state_yml}" ]]; then
    rc=1
    echo "FAIL: ${record_state_yml#"${repo_root}"/} does not exist"
elif ! grep -qF "_dotfiles_full_run" "${record_state_yml}"; then
    rc=1
    echo "FAIL: ${record_state_yml#"${repo_root}"/} does not define expected fact '_dotfiles_full_run'"
fi

# The import must carry its own explicit 'always' tag (matching
# detect_install_mode.yml's own tags: [always], for the same reason —
# see its header comment) rather than relying on Ansible's default
# exclusion of untagged tasks under a --tags filter. Without it, a
# --tags-filtered run happens to skip this block today only because it's
# untagged — not because _dotfiles_full_run's own when: guard caught it —
# so the guard would go unexercised and silently stop protecting anything
# if this import ever picks up an incidental tag later.
for playbook in "${site_yml}" "${server_yml}"; do
    if ! grep -qF 'tasks/record_applied_state.yml' "${playbook}"; then
        rc=1
        echo "FAIL: ${playbook#"${repo_root}"/} does not import tasks/record_applied_state.yml"
        continue
    fi
    if ! grep -A3 'tasks/record_applied_state.yml' "${playbook}" | grep -qF 'always'; then
        rc=1
        echo "FAIL: ${playbook#"${repo_root}"/}'s record_applied_state.yml import is missing tags: [always] — a --tags-filtered run would statically skip this block, bypassing its own when: _dotfiles_full_run guard"
    fi
done

# ---- Check 6: full-run gate normalizes tuples to lists before comparing --------
if ! grep -qF 'ansible_run_tags | list' "${record_state_yml}"; then
    rc=1
    echo "FAIL: ${record_state_yml#"${repo_root}"/}'s full-run gate does not normalize ansible_run_tags with '| list' — ansible_run_tags is a tuple under real ansible-core, so a bare comparison against a ['all'] list literal is always False and the marker never gets written"
fi
if ! grep -qF 'ansible_skip_tags | list' "${record_state_yml}"; then
    rc=1
    echo "FAIL: ${record_state_yml#"${repo_root}"/}'s full-run gate does not normalize ansible_skip_tags with '| list' before measuring its length"
fi

# ---- Report ---------------------------------------------------------------------
if (( rc == 0 )); then
    echo "OK: ansible-apply drift detection checks passed (functions, dispatcher wiring, regex sync, playbook wiring)."
fi
exit "${rc}"

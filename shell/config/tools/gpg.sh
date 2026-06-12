#!/usr/bin/env bash
# GPG key management — aliases and functions for day-to-day GPG operations.
# Sourced when gpg is present (guarded below).
# Heavy operations (key generation, export, rotation) live in lazy/gpg-management.sh.
#
# Public functions in this file:
#   gpg-list              List all keys with fingerprints (brief overview)
#   gpg-list-secret       List secret keys with fingerprints
#   gpg-list-signing-keys List signing-capable subkeys formatted for git-add-project
#   gpg-show              Show full detail for a specific key by fingerprint or email
#   gpg-verify            Verify a file signature
#   gpg-agent-restart     Restart the GPG agent
#   gpg-agent-forget      Forget cached passphrases
#   gpg-card-status       Show smartcard / YubiKey status (if sc-tool present)
#   gpg-github-keys       List GPG keys registered on the authenticated GitHub account

command -v gpg &>/dev/null || return 0

# ── Listing functions ─────────────────────────────────────────────────────────

# gpg-list
# List all keys (public keyring) with fingerprints and expiry.
gpg-list() {
    log_info "Public keys:"
    gpg --list-keys --keyid-format long "$@"
}

# gpg-list-secret
# List all secret keys with fingerprints.
gpg-list-secret() {
    log_info "Secret keys:"
    gpg --list-secret-keys --keyid-format long "$@"
}

# ── Aliases ───────────────────────────────────────────────────────────────────

alias gpg-ls="gpg-list"
alias gpg-ls-secret="gpg-list-secret"

# gpg-list-signing-keys
# List signing-capable (sub)keys in a format suitable for use with git-add-project.
# Outputs the long key ID and associated UIDs for easy copy-paste.
#
# Uses --with-colons output for reliable cross-platform parsing (GnuPG 2.x, macOS, Linux).
#
# Usage:
#   gpg-list-signing-keys
#   gpg-list-signing-keys <email>    # filter to keys matching an email
#
# Output format:
#   [S]  Key ID: ABCDEF1234567890  (expires: 2026-06-01)
#        UID:    Graham Watts <graham@example.com>
#   → Pass the Key ID to git-add-project as the signing_key argument.
gpg-list-signing-keys() {
    local filter="${1:-}"
    local found=0
    local uids=()

    echo
    echo "GPG signing keys available for use with git-add-project:"
    echo "─────────────────────────────────────────────────────────"

    # --with-colons fields (colon-delimited):
    #   field 1:  record type (sec/ssb/uid/fpr/pub/sub)
    #   field 5:  long key ID (8-byte hex, for sec/ssb/pub/sub records)
    #   field 7:  expiry timestamp (unix epoch, empty if none)
    #   field 10: UID string (for uid records); fingerprint (for fpr records)
    #   field 12: key capabilities: e=encrypt s=sign a=auth c=certify
    #             uppercase = primary key has that capability

    while IFS=: read -r type _ _ _ keyid _ expiry _ _ uid _ caps _; do
        case "${type}" in
            sec|pub)
                # Start of a new key block — reset UID accumulator
                uids=()
                ;;
            uid)
                [[ -n "${uid}" ]] && uids+=("${uid}")
                ;;
            ssb|sub)
                # Only process signing-capable subkeys
                [[ "${caps}" != *s* ]] && continue

                # Apply email filter against collected UIDs
                local matched_uids=()
                local u
                for u in "${uids[@]}"; do
                    if [[ -z "${filter}" ]] || echo "${u}" | grep -qi "${filter}"; then
                        matched_uids+=("${u}")
                    fi
                done
                [[ ${#matched_uids[@]} -eq 0 ]] && continue

                # Format expiry — portable across GNU date (Linux) and BSD date (macOS)
                local exp_str="no expiry"
                if [[ -n "${expiry}" && "${expiry}" != "0" ]]; then
                    local exp_formatted
                    exp_formatted="$(date -d "@${expiry}" '+%Y-%m-%d' 2>/dev/null \
                        || date -r "${expiry}" '+%Y-%m-%d' 2>/dev/null \
                        || echo "${expiry}")"
                    exp_str="expires: ${exp_formatted}"
                fi

                echo
                printf "  [S]  Key ID: %s  (%s)\n" "${keyid}" "${exp_str}"
                for u in "${matched_uids[@]}"; do
                    printf "       UID:    %s\n" "${u}"
                done
                found=$((found + 1))
                ;;
        esac
    done < <(gpg --list-secret-keys --with-colons 2>/dev/null)

    if [[ ${found} -eq 0 ]]; then
        echo "  No signing keys found${filter:+ matching \'${filter}\'}."
        echo
        echo "  To create a new key set, run: gpg-create-key"
    else
        echo
        echo "  → Pass the Key ID above to git-add-project:"
        echo "    git-add-project <context> <provider> <email> <Key ID>"
    fi
    echo
}

# gpg-github-keys
# List GPG keys currently registered on the authenticated GitHub account.
# Requires: gh CLI, authenticated via 'gh auth login'.
#
# Usage:
#   gpg-github-keys
gpg-github-keys() {
    if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) is not installed"
        log_error "Install it with: sudo dnf install gh   # Fedora"
        log_error "                 sudo apt install gh   # Debian/Ubuntu"
        return 1
    fi

    if ! gh auth status &>/dev/null 2>&1; then
        log_error "GitHub CLI is not authenticated"
        log_error "Run: gh auth login"
        return 1
    fi

    log_info "GPG keys registered on GitHub:"
    echo
    gh gpg-key list
}

# ── Signing-key resolution for git-add-project / git-update-project ──────────
#
# _gpg_collect_signing_keys
# Print one line per signing-capable ([S]) subkey in the local secret
# keyring, as "<long-key-id><TAB><label>". Label is the first UID on the
# key, with a "(+N more)" suffix if there are additional UIDs, plus an
# expiry annotation.
#
# Used by gpg-push-github and gpg-push-gitlab so both present and validate
# against exactly the same set of keys — the long key ID of the signing
# subkey itself, matching the output of gpg-list-signing-keys.
#
# (Relocated here from lazy/gpg-management.sh — tools/gpg.sh is eager-loaded
# whenever gpg is present, so this is reachable from git.sh as well.)
_gpg_collect_signing_keys() {
    local type keyid expiry uid caps
    local -a uids=()

    while IFS=: read -r type _ _ _ keyid _ expiry _ _ uid _ caps _; do
        case "${type}" in
            sec|pub)
                uids=()
                ;;
            uid)
                [[ -n "${uid}" ]] && uids+=("${uid}")
                ;;
            ssb|sub)
                [[ "${caps}" != *s* ]] && continue
                [[ ${#uids[@]} -eq 0 ]] && continue

                local exp_str="no expiry"
                if [[ -n "${expiry}" && "${expiry}" != "0" ]]; then
                    local exp_formatted
                    exp_formatted="$(date -d "@${expiry}" '+%Y-%m-%d' 2>/dev/null \
                        || date -r "${expiry}" '+%Y-%m-%d' 2>/dev/null \
                        || echo "${expiry}")"
                    exp_str="expires: ${exp_formatted}"
                fi

                local first_uid label
                first_uid="$(_array_get uids 1)"
                label="${first_uid}  [${exp_str}]"
                [[ ${#uids[@]} -gt 1 ]] && label="${first_uid} (+$((${#uids[@]} - 1)) more)  [${exp_str}]"

                printf '%s\t%s\n' "${keyid}" "${label}"
                ;;
        esac
    done < <(gpg --list-secret-keys --with-colons 2>/dev/null)
}

# _gpg_master_for_key <key-id>
# Given a key ID/fingerprint (master OR subkey, long-keyid or full fpr,
# case-insensitive, optional "0x" prefix already stripped by caller),
# print the long key ID of the master [sec] key it belongs to.
# Prints nothing and returns non-zero if not found locally.
_gpg_master_for_key() {
    local target="$1"
    gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: -v target="${target}" '
        $1=="sec" {
            cur_master=$5
            if (tolower(cur_master)==target) { print cur_master; exit }
        }
        $1=="ssb" {
            cur_sub=$5
            if (tolower(cur_sub)==target) { print cur_master; exit }
        }
        $1=="fpr" {
            fp=tolower($10)
            short=substr(fp, length(fp)-15)
            if (fp==target || short==target) { print cur_master; exit }
        }
    '
}

# _gpg_signing_subkeys_for_master <master-long-keyid>
# Print "<keyid><TAB><fingerprint><TAB><expiry-label>" for each [S]-capable
# subkey belonging to the given master key. Empty output means the master
# has no signing-capable subkey.
_gpg_signing_subkeys_for_master() {
    local target="$1"
    local cur_master="" pending_id="" pending_exp=""
    local type keyid expiry fpr caps

    while IFS=: read -r type _ _ _ keyid _ expiry _ _ fpr _ caps _; do
        case "${type}" in
            sec)
                cur_master="${keyid}"
                pending_id=""
                ;;
            ssb)
                pending_id=""
                if [[ "${cur_master}" == "${target}" && "${caps}" == *s* ]]; then
                    pending_id="${keyid}"
                    pending_exp="${expiry}"
                fi
                ;;
            fpr)
                if [[ -n "${pending_id}" ]]; then
                    local exp_str="no expiry"
                    if [[ -n "${pending_exp}" && "${pending_exp}" != "0" ]]; then
                        exp_str="expires: $(date -d "@${pending_exp}" '+%Y-%m-%d' 2>/dev/null \
                            || date -r "${pending_exp}" '+%Y-%m-%d' 2>/dev/null \
                            || echo "${pending_exp}")"
                    fi
                    printf '%s\t%s\t%s\n' "${pending_id}" "${fpr}" "${exp_str}"
                    pending_id=""
                fi
                ;;
        esac
    done < <(gpg --list-secret-keys --with-colons 2>/dev/null)
}

# _gpg_resolve_signing_key <key-id>
#
# Validates a key ID intended for git's user.signingkey and corrects the
# common mistake of supplying a master/primary key ID (or its fingerprint)
# instead of its signing-capable [S] subkey.
#
# stdout: the key ID to actually use — ONLY this, so this function is safe
#         to call as: key="$(_gpg_resolve_signing_key "${input}")"
# stderr: all log_info/log_warn/log_error diagnostics
#
# Return codes:
#   0  resolved (possibly unchanged) — stdout has the key to use
#   1  the supplied key has no signing-capable subkey — caller should abort
#
# Cases:
#   - <key-id> already matches an [S] subkey of its master (by keyid or
#     fingerprint)         → returned unchanged
#   - <key-id> is the master, or a non-signing subkey:
#       - exactly one [S] subkey on that master  → warns and switches to it
#       - more than one [S] subkey on that master → interactive selection
#       - no [S] subkey on that master            → error, returns 1
#   - <key-id> not found in the local secret keyring → warns and returns
#     it unchanged (it may live on a smartcard or another machine)
_gpg_resolve_signing_key() {
    local input="${1:-}"
    [[ -z "${input}" ]] && return 0

    local target
    target="$(_str_lower "${input#0x}")"

    local master
    master="$(_gpg_master_for_key "${target}")"

    if [[ -z "${master}" ]]; then
        log_warn "Key '${input}' was not found in the local secret keyring" >&2
        log_warn "Proceeding with it as supplied — verify it is correct" >&2
        log_warn "Run gpg-list-signing-keys to see available signing subkeys" >&2
        printf '%s\n' "${input}"
        return 0
    fi

    local signing
    signing="$(_gpg_signing_subkeys_for_master "${master}")"

    if [[ -z "${signing}" ]]; then
        log_error "Key '${input}' has no signing-capable [S] subkey" >&2
        log_error "Create one with: gpg-add-subkey ${master}" >&2
        return 1
    fi

    # Already a valid [S] subkey of this master (matched by keyid or fpr)?
    local kid fpr label
    while IFS=$'\t' read -r kid fpr label; do
        if [[ "$(_str_lower "${kid}")" == "${target}" || "$(_str_lower "${fpr}")" == "${target}" ]]; then
            printf '%s\n' "${input}"
            return 0
        fi
    done <<< "${signing}"

    local count
    count="$(printf '%s\n' "${signing}" | wc -l | tr -d ' ')"

    log_warn "Key '${input}' is a master/primary key (or non-signing subkey), not a signing subkey" >&2

    if [[ "${count}" -eq 1 ]]; then
        local resolved
        resolved="$(printf '%s\n' "${signing}" | cut -f1)"
        log_warn "Switching to its signing subkey: ${resolved}" >&2
        printf '%s\n' "${resolved}"
        return 0
    fi

    log_warn "It has multiple signing subkeys — choose one:" >&2
    echo >&2

    local -a menu_ids=()
    local i=1
    while IFS=$'\t' read -r kid fpr label; do
        printf "  %2d)  Key ID: %s  (%s)\n" "${i}" "${kid}" "${label}" >&2
        menu_ids+=("${kid}")
        i=$(( i + 1 ))
    done <<< "${signing}"
    echo >&2

    local choice
    while true; do
        _read_prompt "  Select signing key (1-${#menu_ids[@]}): " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#menu_ids[@]} )); then
            printf '%s\n' "$(_array_get menu_ids "${choice}")"
            return 0
        fi
        log_warn "Invalid selection — enter a number between 1 and ${#menu_ids[@]}" >&2
    done
}

# gpg-gitlab-keys
# List GPG keys currently registered on the authenticated GitLab account.
# Requires: glab CLI, authenticated via 'glab auth login'.
gpg-gitlab-keys() {
    if ! command -v glab &>/dev/null; then
        log_error "GitLab CLI (glab) is not installed"
        log_error "Install it with: install-glab"
        return 1
    fi

    if ! glab auth status &>/dev/null 2>&1; then
        log_error "GitLab CLI is not authenticated"
        log_error "Run: glab auth login"
        return 1
    fi

    log_info "GPG keys registered on GitLab:"
    echo
    glab gpg-key list
}

# gpg-show
# Show full details for a key identified by fingerprint, key ID, or email.
#
# Usage:
#   gpg-show graham@example.com
#   gpg-show ABCDEF1234567890
gpg-show() {
    if [[ -z "${1:-}" ]]; then
        log_error "Usage: gpg-show <fingerprint|keyid|email>"
        return 1
    fi
    echo
    log_info "Key details for: ${1}"
    echo "── Public key ───────────────────────────────────────────────────"
    gpg --list-keys --keyid-format long --with-subkey-fingerprints "${1}"
    echo "── Secret key ───────────────────────────────────────────────────"
    gpg --list-secret-keys --keyid-format long --with-subkey-fingerprints "${1}" 2>/dev/null \
        || log_warn "No secret key found for ${1}"
    echo
}

# ── Verification ──────────────────────────────────────────────────────────────

# gpg-verify
# Verify a detached signature.
#
# Usage:
#   gpg-verify <file>            # looks for <file>.sig or <file>.asc
#   gpg-verify <file> <sigfile>  # explicit signature file
gpg-verify() {
    local file="${1:-}"
    local sigfile="${2:-}"

    if [[ -z "${file}" ]]; then
        log_error "Usage: gpg-verify <file> [sigfile]"
        return 1
    fi
    [[ ! -f "${file}" ]] && { log_error "File not found: ${file}"; return 1; }

    if [[ -z "${sigfile}" ]]; then
        if   [[ -f "${file}.sig" ]]; then sigfile="${file}.sig"
        elif [[ -f "${file}.asc" ]]; then sigfile="${file}.asc"
        else
            log_error "No signature file found. Looked for ${file}.sig and ${file}.asc"
            log_error "Specify explicitly: gpg-verify <file> <sigfile>"
            return 1
        fi
    fi
    [[ ! -f "${sigfile}" ]] && { log_error "Signature file not found: ${sigfile}"; return 1; }

    gpg --verify "${sigfile}" "${file}"
}

# ── Agent management ──────────────────────────────────────────────────────────

# gpg-agent-restart
# Kills and restarts the GPG agent. Useful after changing pinentry or config.
gpg-agent-restart() {
    log_info "Restarting GPG agent..."
    gpgconf --kill gpg-agent
    gpg-agent --daemon --quiet 2>/dev/null || true
    log_info "GPG agent restarted"
    # Re-export the socket path in case it changed
    export GPG_TTY
    GPG_TTY="$(tty)"
}

# gpg-agent-forget
# Forgets all cached passphrases without restarting the agent.
gpg-agent-forget() {
    log_info "Clearing GPG agent passphrase cache..."
    echo RELOADAGENT | gpg-connect-agent &>/dev/null \
        || gpgconf --reload gpg-agent
    log_info "Passphrase cache cleared"
}

# gpg-card-status
# Show connected smartcard or YubiKey GPG status.
gpg-card-status() {
    if command -v gpg &>/dev/null; then
        gpg --card-status
    else
        log_error "gpg not found"
        return 1
    fi
}

# ── GPG_TTY export (required for pinentry-curses on non-X11 terminals) ────────
# This runs at source time so the variable is always set correctly for this session.
export GPG_TTY
GPG_TTY="$(tty 2>/dev/null || echo '')"

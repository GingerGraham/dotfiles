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

command -v gpg &>/dev/null || return 0

# ── Aliases ───────────────────────────────────────────────────────────────────

alias gpg-list="gpg-list"               # see function below — alias for discoverability
alias gpg-ls="gpg-list"
alias gpg-ls-secret="gpg-list-secret"

# ── Listing functions ─────────────────────────────────────────────────────────

# gpg-list
# List all keys (public keyring) with fingerprints and expiry.
gpg-list() {
    log_info "Public keys:"
    gpg --list-keys --keyid-format long --with-fingerprint "$@"
}

# gpg-list-secret
# List all secret keys with fingerprints.
gpg-list-secret() {
    log_info "Secret keys:"
    gpg --list-secret-keys --keyid-format long --with-fingerprint "$@"
}

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
    gpg --list-keys --keyid-format long --with-fingerprint --with-subkey-fingerprints "${1}"
    echo "── Secret key ───────────────────────────────────────────────────"
    gpg --list-secret-keys --keyid-format long --with-fingerprint --with-subkey-fingerprints "${1}" 2>/dev/null \
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

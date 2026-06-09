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
# Usage:
#   gpg-list-signing-keys
#   gpg-list-signing-keys <email>    # filter to keys matching an email
#
# Output format:
#   [S]  Key ID: ABCDEF1234567890  (expires: 2026-06-01)
#        UID:    Graham Watkins <graham@example.com>
#   → Pass the Key ID to git-add-project as the signing_key argument.
gpg-list-signing-keys() {
    local filter="${1:-}"
    local found=0

    echo
    echo "GPG signing keys available for use with git-add-project:"
    echo "─────────────────────────────────────────────────────────"

    while IFS= read -r line; do
        # pub/sub records: pub = primary key, sub = subkey
        # capability flags: S=sign, E=encrypt, C=certify, A=auth
        if [[ "${line}" =~ ^(pub|sub)[[:space:]] ]]; then
            local caps="" key_id="" expiry=""
            # Extract capability flags (field after key size/type, bracketed)
            caps="$(echo "${line}" | grep -oP '\[.*?\]' | tr -d '[]')"
            # Only proceed if this key has signing capability
            [[ "${caps}" != *S* ]] && continue
            # Extract the long key ID (16 hex chars after the /)
            key_id="$(echo "${line}" | grep -oP '[0-9A-F]{16}')"
            [[ -z "${key_id}" ]] && continue
            # Extract expiry if present
            expiry="$(echo "${line}" | grep -oP 'expires: [0-9-]+')"
            [[ -n "${expiry}" ]] && expiry=" (${expiry})" || expiry=" (no expiry)"
            # Collect UIDs for this key block
            local uids=()
            while IFS= read -r uid_line; do
                [[ "${uid_line}" =~ ^uid ]] || break
                local uid_val
                uid_val="$(echo "${uid_line}" | sed 's/^uid[[:space:]]*//' | sed 's/^[[:space:]]*//')"
                # Apply email filter if given
                if [[ -z "${filter}" ]] || echo "${uid_val}" | grep -qi "${filter}"; then
                    uids+=("${uid_val}")
                fi
            done < <(gpg --list-secret-keys --keyid-format long --with-fingerprint 2>/dev/null \
                | grep -A 20 "${key_id}" | grep '^uid')

            [[ ${#uids[@]} -eq 0 && -n "${filter}" ]] && continue

            echo
            printf "  [S]  Key ID: %s%s\n" "${key_id}" "${expiry}"
            for uid in "${uids[@]}"; do
                printf "       UID:    %s\n" "${uid}"
            done
            found=$((found + 1))
        fi
    done < <(gpg --list-secret-keys --keyid-format long --with-fingerprint 2>/dev/null)

    if [[ ${found} -eq 0 ]]; then
        echo "  No signing keys found${filter:+ matching '${filter}'}."
        echo
        echo "  To create a new key set, run: gpg-create-key"
        echo "  (from lazy/gpg-management.sh — available without sourcing anything)"
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

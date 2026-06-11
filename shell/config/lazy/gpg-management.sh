#!/usr/bin/env bash
# Lazy-loaded GPG key management — generation, subkey operations, export, import, rotation.
# This file is sourced via stub in loader.sh on first call to any function here.
#
# Best-practice key structure created by gpg-create-key:
#
#   Master key  [C]    — Certify only. Never used for day-to-day operations.
#     └─ Subkey [S]    — Sign: git commits, tags, files
#     └─ Subkey [E]    — Encrypt: files, secrets
#     └─ Subkey [A]    — Authenticate: SSH, API (optional)
#
# The master key's private material should be exported and stored offline
# (Bitwarden, encrypted USB, etc.) and then removed from the local keyring
# so only subkeys remain. Subkeys can be rotated without creating a new
# identity. If the master key is needed again (new subkey, expiry extension,
# certifying another key), import it from Bitwarden, perform the operation,
# then remove it again.
#
# Public functions:
#   gpg-create-key        Interactive wizard: master [C] + subkeys [S][E][A]
#   gpg-add-uid           Add an email address / identity to an existing key
#   gpg-add-subkey        Add a new subkey to an existing master key
#   gpg-extend-expiry     Extend expiry on a key or subkey
#   gpg-remove-master     Remove master secret key material from local keyring
#   gpg-revoke            Generate or apply a revocation certificate
#   gpg-export            Export public + secret keys to files
#   gpg-export-master     Export master key secret material only (for offline backup)
#   gpg-export-subkeys    Export subkeys-only secret material (for daily-use keyring)
#   gpg-export-bitwarden  Export keys and store them as Bitwarden secure notes
#   gpg-import            Import a key from a file
#   gpg-import-bitwarden  Pull a key from a Bitwarden secure note and import it
#   gpg-rotate-subkey     Expire current subkey and generate a replacement
#   gpg-trust             Set owner trust level on a key
#   gpg-push-github       Push a signing key to the authenticated GitHub account

# ── Portability helpers ───────────────────────────────────────────────────────

# _read_prompt <prompt_string> <variable_name>
# Portable prompt + read for bash and zsh.
# zsh's read builtin does not support -p for a prompt string (that flag means
# "read from coprocess"). Use printf to /dev/tty so the prompt always reaches
# the terminal regardless of stdin/stderr redirection.
# _read_prompt() {
#     local _rp_prompt="$1"
#     local _rp_var="$2"
#     local _rp_value
#     printf '%s' "${_rp_prompt}" >/dev/tty
#     IFS= read -r _rp_value </dev/tty
#     eval "${_rp_var}=\${_rp_value}"
# }

# # _read_prompt_silent <prompt_string> <variable_name>
# # Silent prompt + read (no echo) for bash and zsh.
# # The explicit printf '\n' after read is required because the suppressed
# # Enter keypress produces no newline on screen.
# _read_prompt_silent() {
#     local _rp_prompt="$1"
#     local _rp_var="$2"
#     local _rp_value
#     printf '%s' "${_rp_prompt}" >/dev/tty
#     IFS= read -rs _rp_value </dev/tty
#     printf '\n' >/dev/tty
#     eval "${_rp_var}=\${_rp_value}"
# }

# # _str_lower <string>
# # Portable lowercase — bash ${var,,} is not supported in zsh.
# _str_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# # _array_get <array_name> <1-based-index>
# # Portable 1-based array access for bash and zsh.
# _array_get() {
#     local _ag_arr="$1" _ag_idx="$2"
#     if [[ -n "${ZSH_VERSION}" ]]; then
#         eval "printf '%s' \"\${${_ag_arr}[${_ag_idx}]}\""
#     else
#         eval "printf '%s' \"\${${_ag_arr}[$((${_ag_idx} - 1))]}\""
#     fi
# }

# ── Internal helpers ──────────────────────────────────────────────────────────

_gpg_require_key() {
    local key_id="${1:-}"
    if [[ -z "${key_id}" ]]; then
        log_error "A key fingerprint or long key ID is required"
        return 1
    fi
    if ! gpg --list-secret-keys "${key_id}" &>/dev/null; then
        log_error "No secret key found for: ${key_id}"
        log_error "Run gpg-list-secret to see available keys"
        return 1
    fi
}

_gpg_require_bw() {
    if ! command -v bw &>/dev/null; then
        log_error "Bitwarden CLI (bw) is not installed"
        log_error "Install it with: install-bw-cli"
        return 1
    fi
}

_gpg_bw_logged_in() {
    if [[ -z "${BW_SESSION:-}" ]]; then
        log_error "BW_SESSION is not set"
        log_error "Run: export BW_SESSION=\$(bw unlock --raw)"
        return 1
    fi

    local bw_status
    bw_status="$(bw status 2>/dev/null | grep -oP '(?<="status":")[^"]+')"

    if [[ "${bw_status}" != "unlocked" ]]; then
        log_error "Bitwarden vault is not unlocked (status: ${bw_status:-unknown})"
        log_error "Run: export BW_SESSION=\$(bw unlock --raw)"
        return 1
    fi
}

# Prompt for a key ID using a numbered selection list.
# Lists master secret keys with fingerprint, UIDs, and expiry.
# Writes display output to stderr; returns the fingerprint via stdout.
_gpg_prompt_key_id() {
    local prompt_label="${1:-Key ID or fingerprint}"
    echo >&2
    log_info "Available secret keys:" >&2
    gpg --list-secret-keys --keyid-format long --with-fingerprint 2>/dev/null \
        | sed '/Key fingerprint/{s/[[:space:]]//g; s/Keyfingerprint=/ Key fingerprint = /}' >&2
    echo >&2
    local key_id
    _read_prompt "  ${prompt_label}: " key_id
    echo "${key_id}"
}

# Convert a key ID/fingerprint to the full 40-char fingerprint.
_gpg_fingerprint() {
    gpg --list-keys --with-colons "${1}" 2>/dev/null \
        | awk -F: '/^fpr/{print $10; exit}'
}

# ── Key creation ──────────────────────────────────────────────────────────────

# gpg-create-key
# Interactive wizard to create a master [C] key + [S][E] subkeys.
# Optionally adds an [A] authentication subkey.
#
# Master key gets a long or no expiry — it is stored offline.
# Subkeys get a shorter expiry for day-to-day use.
#
# After running:
#   1. Generate a revocation certificate immediately
#   2. Export and back up to Bitwarden
#   3. Remove master secret key from local keyring with gpg-remove-master
#
# Usage:
#   gpg-create-key
gpg-create-key() {
    echo
    echo "═══════════════════════════════════════════════════════════"
    echo "  GPG Key Creation Wizard"
    echo "  Creates: master [C] + sign [S] + encrypt [E] subkeys"
    echo "═══════════════════════════════════════════════════════════"
    echo
    echo "  Best practice key structure:"
    echo "    Master key  [C]  — certify only, store offline after creation"
    echo "    Subkey      [S]  — sign commits, tags, files"
    echo "    Subkey      [E]  — encrypt files and secrets"
    echo "    Subkey      [A]  — authenticate (SSH, optional)"
    echo

    # Collect identity
    local name email comment auth_subkey
    _read_prompt "  Full name:  " name
    [[ -z "${name}" ]] && { log_error "Name is required"; return 1; }

    _read_prompt "  Email:      " email
    [[ -z "${email}" ]] && { log_error "Email is required"; return 1; }

    _read_prompt "  Comment (optional, e.g. 'personal' or 'work'): " comment

    # Collect expiry — master and subkeys separately
    echo
    echo "  Master key expiry."
    echo "  The master [C] key is used only to certify subkeys and is stored"
    echo "  offline after creation. A very long expiry or no expiry is fine here."
    _read_prompt "  Master key expiry (e.g. 10y, 0 for no expiry) [0]: " master_expiry_input
    master_expiry_input="${master_expiry_input:-0}"
    local master_expiry="${master_expiry_input}"

    echo
    echo "  Subkey expiry. Subkeys are used daily — a shorter expiry limits"
    echo "  exposure if a subkey is compromised. You can always extend."
    _read_prompt "  Subkey expiry in years [2]: " subkey_expiry_years
    subkey_expiry_years="${subkey_expiry_years:-2}"
    local subkey_expiry="${subkey_expiry_years}y"

    echo
    _read_prompt "  Add authentication [A] subkey for SSH? [y/N]: " auth_subkey

    # Build the UID string
    local uid="${name}"
    [[ -n "${comment}" ]] && uid="${uid} (${comment})"
    uid="${uid} <${email}>"

    echo
    log_info "Creating master key [C] for: ${uid}"
    log_info "Master expiry: ${master_expiry} | Subkey expiry: ${subkey_expiry}"
    echo
    echo "  You will be prompted to set a passphrase. Use a strong, unique"
    echo "  passphrase — this protects your master key."
    echo

    local param_file
    param_file="$(mktemp /tmp/gpg-keygen-XXXXXX)"
    chmod 600 "${param_file}"

    cat > "${param_file}" <<EOF
%echo Generating master key (Certify only)
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: cert
Name-Real: ${name}
$([ -n "${comment}" ] && echo "Name-Comment: ${comment}")
Name-Email: ${email}
Expire-Date: ${master_expiry}
%ask-passphrase
%commit
%echo Master key done
EOF

    gpg --full-generate-key --expert --batch "${param_file}"
    local gen_rc=$?
    rm -f "${param_file}"

    if [[ ${gen_rc} -ne 0 ]]; then
        log_error "Master key generation failed (exit ${gen_rc})"
        return 1
    fi

    # Find the fingerprint of the key we just created
    local fp
    fp="$(gpg --list-keys --with-colons "${email}" 2>/dev/null \
        | awk -F: '/^fpr/{print $10; exit}')"

    if [[ -z "${fp}" ]]; then
        log_error "Could not locate new key for ${email}. Check 'gpg-list'."
        return 1
    fi

    log_info "Master key created: ${fp}"
    echo
    log_info "Adding sign [S] subkey..."
    gpg --batch --yes --quick-add-key "${fp}" ed25519 sign "${subkey_expiry}"

    log_info "Adding encrypt [E] subkey..."
    gpg --batch --yes --quick-add-key "${fp}" cv25519 encr "${subkey_expiry}"

    if [[ "$(_str_lower "${auth_subkey}")" == "y" ]]; then
        log_info "Adding authenticate [A] subkey..."
        gpg --batch --yes --quick-add-key "${fp}" ed25519 auth "${subkey_expiry}"
    fi

    echo
    log_info "Key creation complete. Summary:"
    gpg --list-secret-keys --keyid-format long "${fp}"

    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Key created: ${fp}"
    echo
    echo "  Complete these steps before using the key:"
    echo
    echo "  1. Add any additional email addresses (GitHub noreply, work alias, etc.):"
    echo "       gpg-add-uid ${fp}"
    echo "     Then re-export to Bitwarden after adding UIDs."
    echo
    echo "  2. Generate a revocation certificate:"
    echo "       gpg-revoke ${fp}"
    echo
    echo "  3. Export and back up to Bitwarden (includes revocation cert):"
    echo "       gpg-export-bitwarden ${fp}"
    echo "     or export to file:"
    echo "       gpg-export-master ${fp}"
    echo
    echo "  4. Remove master secret key from this machine:"
    echo "       gpg-remove-master ${fp}"
    echo
    echo "  5. Wire up git signing:"
    echo "       gpg-list-signing-keys ${email}"
    echo "       git-add-project <context> <provider> ${email} <signing-subkey-id>"
    echo "═══════════════════════════════════════════════════════════════════"
}

# ── UID management ────────────────────────────────────────────────────────────

# gpg-add-uid
# Add an email address / identity to an existing key.
# Useful for: GitHub noreply addresses, work aliases, alternate emails.
#
# Usage:
#   gpg-add-uid
#   gpg-add-uid <fingerprint>
gpg-add-uid() {
    local fp="${1:-}"

    echo
    echo "═══════════════════════════════════════════════════════════"
    echo "  Add UID to GPG Key"
    echo "  Adds an email address / identity to an existing key."
    echo "  Useful for: GitHub noreply, work aliases, alternate emails."
    echo "═══════════════════════════════════════════════════════════"

    if [[ -z "${fp}" ]]; then
        local -a fps=()
        local -a labels=()
        local i=1
        echo
        log_info "Available keys:"
        echo

        # Parse --with-colons: only collect sec (master) records, not ssb/subkeys
        local cur_fp="" cur_uid=""
        while IFS=: read -r type _ _ _ _ _ _ _ _ uid _ _; do
            case "${type}" in
                sec)
                    cur_fp=""
                    cur_uid=""
                    ;;
                fpr)
                    # First fpr after sec is the master key fingerprint
                    if [[ -z "${cur_fp}" ]]; then
                        cur_fp="${uid}"   # fpr field 10 is the fingerprint
                    fi
                    ;;
                uid)
                    if [[ -z "${cur_uid}" && -n "${cur_fp}" ]]; then
                        cur_uid="${uid}"
                        fps+=("${cur_fp}")
                        labels+=("${cur_uid}")
                        printf "  %d.  %s\n      Fingerprint: %s\n\n" \
                            "${i}" "${cur_uid}" "${cur_fp}"
                        (( i++ ))
                    fi
                    ;;
            esac
        done < <(gpg --list-secret-keys --with-colons 2>/dev/null)

        if [[ ${#fps[@]} -eq 0 ]]; then
            log_error "No secret keys found. Run gpg-create-key to create one."
            return 1
        fi

        local selection
        _read_prompt "  Select key number [1]: " selection
        selection="${selection:-1}"
        if ! [[ "${selection}" =~ ^[0-9]+$ ]] || \
        [[ "${selection}" -lt 1 || "${selection}" -gt ${#fps[@]} ]]; then
            log_error "Invalid selection"
            return 1
        fi
        fp="$(_array_get fps "${selection}")"
    fi

    _gpg_require_key "${fp}" || return 1

    log_info "Selected: $(gpg --list-keys --with-colons "${fp}" 2>/dev/null \
        | awk -F: '/^uid/{print $10; exit}')"

    echo
    log_info "Current UIDs on this key:"
    gpg --list-keys --with-colons "${fp}" 2>/dev/null \
        | awk -F: '/^uid/{print "  • " $10}'

    echo
    echo "  Enter details for the new UID."
    echo "  For a GitHub noreply address, leave name blank to reuse the"
    echo "  existing name and enter: <id>+username@users.noreply.github.com"
    echo

    # Name — blank reuses existing primary UID name
    local existing_name
    existing_name="$(gpg --list-keys --with-colons "${fp}" 2>/dev/null \
        | awk -F: '/^uid/{print $10; exit}' \
        | sed 's/ (.*//' | sed 's/ <.*//')"

    local new_name
    _read_prompt "  Full name (blank to reuse existing name): " new_name
    if [[ -z "${new_name}" ]]; then
        new_name="${existing_name}"
        log_info "Using existing name: ${new_name}"
    fi

    local new_email
    _read_prompt "  Email: " new_email
    [[ -z "${new_email}" ]] && { log_error "Email is required"; return 1; }

    local new_comment
    _read_prompt "  Comment (optional, e.g. 'github' or 'work'): " new_comment

    # Build UID string
    local new_uid="${new_name}"
    [[ -n "${new_comment}" ]] && new_uid="${new_uid} (${new_comment})"
    new_uid="${new_uid} <${new_email}>"

    echo
    log_info "New UID:  ${new_uid}"
    log_info "On key:   ${fp}"
    local confirm
    _read_prompt "  Confirm? [Y/n]: " confirm
    [[ "$(_str_lower "${confirm}")" == "n" ]] && { log_info "Cancelled"; return 0; }

    gpg --batch --yes --quick-add-uid "${fp}" "${new_uid}"
    local add_rc=$?
    if [[ ${add_rc} -ne 0 ]]; then
        log_error "Failed to add UID (exit ${add_rc})"
        return 1
    fi

    log_info "UID added successfully."

    # Re-apply ultimate ownertrust — GPG marks newly-added UIDs [unknown]
    # until ownertrust is re-asserted on the key.
    if echo "${fp}:6:" | gpg --import-ownertrust 2>/dev/null && \
            gpg --check-trustdb 2>/dev/null; then
        :
    else
        log_warn "Could not set ownertrust automatically; run: gpg-trust ${fp}"
    fi

    echo
    echo "  Your existing primary UID is unchanged."
    echo "  For a GitHub noreply address, leaving your real email as primary"
    echo "  is usually correct — GitHub verifies against any UID on the key."
    echo

    # Offer to change primary UID
    local make_primary
    _read_prompt "  Set '${new_uid}' as the primary UID? [y/N]: " make_primary
    if [[ "$(_str_lower "${make_primary}")" == "y" ]]; then
        gpg --batch --yes --quick-set-primary-uid "${fp}" "${new_uid}"
        log_info "Primary UID updated."
    fi

    echo
    log_info "Updated key:"
    gpg --list-secret-keys --keyid-format long "${fp}"

    echo
    echo "  Re-export to keep your Bitwarden backup current:"
    echo "    gpg-export-bitwarden ${fp}"
}

# ── Master key removal ────────────────────────────────────────────────────────

# gpg-remove-master
# Remove master secret key material from the local keyring.
# Subkeys remain — they are sufficient for signing, encryption, and SSH.
#
# After removal the key shows as 'sec#' (stub only) in gpg --list-secret-keys.
# To restore the master key: gpg-import-bitwarden or gpg-import <backup-file>
#
# When you need the master key again (adding subkeys, extending expiry,
# certifying another key), import it, do the work, then remove it again.
#
# Usage:
#   gpg-remove-master <fingerprint>
#   gpg-remove-master                   # interactive key selection
gpg-remove-master() {
    local fp="${1:-}"

    echo
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Remove Master Secret Key"
    echo "  Removes the master [C] key's private material from this machine."
    echo "  Subkeys remain intact for day-to-day use."
    echo "═══════════════════════════════════════════════════════════════════"

    if [[ -z "${fp}" ]]; then
        fp="$(_gpg_prompt_key_id "Master key fingerprint")"
    fi
    _gpg_require_key "${fp}" || return 1

    # Check whether master secret is actually present (not already sec#)
    local sec_line
    sec_line="$(gpg --list-secret-keys --with-colons "${fp}" 2>/dev/null \
        | awk -F: '/^sec/{print $2; exit}')"

    if [[ "${sec_line}" == "#" ]]; then
        log_warn "Master secret key is already absent from local keyring (sec#)"
        log_warn "Nothing to remove. Key in Bitwarden/offline backup is authoritative."
        return 0
    fi

    echo
    log_info "Key to remove master secret from:"
    gpg --list-secret-keys --keyid-format long "${fp}"

    echo
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │  BEFORE YOU CONTINUE                                        │"
    echo "  │                                                             │"
    echo "  │  Ensure you have a backup of the master key:               │"
    echo "  │    • Bitwarden (recommended): gpg-export-bitwarden ${fp: -16}  │"
    echo "  │    • File backup:             gpg-export-master ${fp: -16}     │"
    echo "  │                                                             │"
    echo "  │  Without a backup you cannot add subkeys, extend expiry,   │"
    echo "  │  or certify other keys. Recovery will not be possible.     │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo
    local backed_up
    _read_prompt "  Have you backed up the master key? [y/N]: " backed_up
    if [[ "$(_str_lower "${backed_up}")" != "y" ]]; then
        echo
        log_warn "Aborting. Back up the key first:"
        echo "    gpg-export-bitwarden ${fp}"
        echo "  or:"
        echo "    gpg-export-master ${fp}"
        return 1
    fi

    echo
    echo "  This will remove the master [C] key secret material from:"
    echo "    ${GNUPGHOME:-~/.gnupg}"
    echo
    echo "  Type 'yes' to confirm (anything else cancels):"
    local confirm
    _read_prompt "  > " confirm
    if [[ "${confirm}" != "yes" ]]; then
        log_info "Cancelled — master key not removed"
        return 0
    fi

    # The '!' suffix targets only the primary key, leaving subkeys intact.
    # GnuPG 2.1+ retains a sec# stub so the public key and subkeys remain usable.
    log_info "Removing master secret key material..."
    gpg --batch --yes --delete-secret-keys "${fp}!"
    local del_rc=$?

    if [[ ${del_rc} -ne 0 ]]; then
        log_error "Deletion failed (exit ${del_rc})"
        log_error "You can retry manually:"
        log_error "  gpg --delete-secret-keys ${fp}!"
        return 1
    fi

    echo
    log_info "Master secret key removed. Updated key:"
    gpg --list-secret-keys --keyid-format long "${fp}"
    echo
    log_info "The 'sec#' marker confirms the master secret is no longer stored locally."
    echo
    echo "  To restore the master key when needed:"
    echo "    export BW_SESSION=\$(bw unlock --raw)"
    echo "    gpg-import-bitwarden"
    echo "  or:"
    echo "    gpg-import <path-to-backup.asc>"
    echo
    echo "  After completing any master-key operations, remove it again:"
    echo "    gpg-remove-master ${fp}"
}

# ── Subkey management ─────────────────────────────────────────────────────────

# gpg-add-subkey
# Add a new subkey to an existing master key.
#
# Usage:
#   gpg-add-subkey <fingerprint> <type> <expiry>
#   gpg-add-subkey                               # interactive prompts
#
# Types: sign | encr | auth
# Expiry: e.g. 1y, 2y, 0 (no expiry)
gpg-add-subkey() {
    local fp="${1:-}" type="${2:-}" expiry="${3:-}"

    if [[ -z "${fp}" ]]; then
        fp="$(_gpg_prompt_key_id "Master key fingerprint")"
    fi
    _gpg_require_key "${fp}" || return 1

    # Warn if master secret is absent — adding subkeys requires it
    local sec_line
    sec_line="$(gpg --list-secret-keys --with-colons "${fp}" 2>/dev/null \
        | awk -F: '/^sec/{print $2; exit}')"
    if [[ "${sec_line}" == "#" ]]; then
        log_error "Master secret key is not present locally (sec#)"
        log_error "Import it first, then re-run this command:"
        log_error "  gpg-import-bitwarden   or   gpg-import <backup.asc>"
        return 1
    fi

    if [[ -z "${type}" ]]; then
        echo "  Subkey type:"
        echo "    sign  — signing (git commits, tags, files)"
        echo "    encr  — encryption"
        echo "    auth  — authentication (SSH)"
        _read_prompt "  Type [sign]: " type
        type="${type:-sign}"
    fi

    case "${type}" in
        sign) local algo="ed25519" ;;
        encr) local algo="cv25519" ;;
        auth) local algo="ed25519" ;;
        *) log_error "Unknown type '${type}'. Use: sign | encr | auth"; return 1 ;;
    esac

    if [[ -z "${expiry}" ]]; then
        _read_prompt "  Expiry (e.g. 2y, 1y, 0 for none) [2y]: " expiry
        expiry="${expiry:-2y}"
    fi

    log_info "Adding ${type} subkey (${algo}) to ${fp}, expiry: ${expiry}"
    gpg --batch --yes --quick-add-key "${fp}" "${algo}" "${type}" "${expiry}"

    echo
    log_info "Updated key:"
    gpg --list-secret-keys --keyid-format long "${fp}"
    echo
    echo "  Re-export to keep your Bitwarden backup current:"
    echo "    gpg-export-bitwarden ${fp}"
    echo
    echo "  When done, remove the master secret key again:"
    echo "    gpg-remove-master ${fp}"
}

# gpg-extend-expiry
# Extend the expiry on a key and all its subkeys.
#
# Usage:
#   gpg-extend-expiry <fingerprint> <new-expiry>   e.g. 2y, 1y
#   gpg-extend-expiry                              # interactive
gpg-extend-expiry() {
    local fp="${1:-}" expiry="${2:-}"

    if [[ -z "${fp}" ]]; then
        fp="$(_gpg_prompt_key_id "Key fingerprint to extend")"
    fi
    _gpg_require_key "${fp}" || return 1

    # Warn if master secret is absent — extending expiry requires it
    local sec_line
    sec_line="$(gpg --list-secret-keys --with-colons "${fp}" 2>/dev/null \
        | awk -F: '/^sec/{print $2; exit}')"
    if [[ "${sec_line}" == "#" ]]; then
        log_error "Master secret key is not present locally (sec#)"
        log_error "Import it first, then re-run this command:"
        log_error "  gpg-import-bitwarden   or   gpg-import <backup.asc>"
        return 1
    fi

    if [[ -z "${expiry}" ]]; then
        _read_prompt "  New expiry (e.g. 2y, 1y): " expiry
        [[ -z "${expiry}" ]] && { log_error "Expiry is required"; return 1; }
    fi

    log_info "Extending expiry for ${fp} and all subkeys to ${expiry}..."
    # quick-set-expire with '*' extends all subkeys; without it extends the primary
    gpg --batch --yes --quick-set-expire "${fp}" "${expiry}" '*'
    gpg --batch --yes --quick-set-expire "${fp}" "${expiry}"

    echo
    log_info "Updated key:"
    gpg --list-secret-keys --keyid-format long "${fp}"
    echo
    echo "  Re-export to keep your Bitwarden backup current:"
    echo "    gpg-export-bitwarden ${fp}"
    echo
    echo "  When done, remove the master secret key again:"
    echo "    gpg-remove-master ${fp}"
}

# gpg-rotate-subkey
# Mark a specific subkey as expired and generate a replacement.
# Useful for annual rotation without replacing your identity.
#
# Usage:
#   gpg-rotate-subkey <master-fp> <subkey-fp> <type> <new-expiry>
#   gpg-rotate-subkey                                              # interactive
gpg-rotate-subkey() {
    local master_fp="${1:-}" subkey_fp="${2:-}" type="${3:-}" expiry="${4:-2y}"

    if [[ -z "${master_fp}" ]]; then
        master_fp="$(_gpg_prompt_key_id "Master key fingerprint")"
    fi
    _gpg_require_key "${master_fp}" || return 1

    # Warn if master secret is absent
    local sec_line
    sec_line="$(gpg --list-secret-keys --with-colons "${master_fp}" 2>/dev/null \
        | awk -F: '/^sec/{print $2; exit}')"
    if [[ "${sec_line}" == "#" ]]; then
        log_error "Master secret key is not present locally (sec#)"
        log_error "Import it first, then re-run this command:"
        log_error "  gpg-import-bitwarden   or   gpg-import <backup.asc>"
        return 1
    fi

    if [[ -z "${subkey_fp}" ]]; then
        echo
        log_info "Subkeys for ${master_fp}:"
        gpg --list-secret-keys --with-colons "${master_fp}" 2>/dev/null \
            | awk -F: '/^fpr/ && NR>1 {print "  " $10}'
        echo
        _read_prompt "  Subkey fingerprint to retire: " subkey_fp
    fi

    if [[ -z "${type}" ]]; then
        echo "  Replacement subkey type (sign | encr | auth):"
        _read_prompt "  Type [sign]: " type
        type="${type:-sign}"
    fi

    case "${type}" in
        sign) local algo="ed25519" ;;
        encr) local algo="cv25519" ;;
        auth) local algo="ed25519" ;;
        *) log_error "Unknown type '${type}'"; return 1 ;;
    esac

    log_info "Setting subkey ${subkey_fp} to expire now..."
    gpg --batch --yes --quick-set-expire "${master_fp}" seconds=1 "${subkey_fp}"

    log_info "Generating replacement ${type} subkey..."
    gpg --batch --yes --quick-add-key "${master_fp}" "${algo}" "${type}" "${expiry}"

    echo
    log_info "Rotation complete. Updated key:"
    gpg --list-secret-keys --keyid-format long "${master_fp}"
    echo
    echo "  Re-export to keep your Bitwarden backup current:"
    echo "    gpg-export-bitwarden ${master_fp}"
    echo
    echo "  When done, remove the master secret key again:"
    echo "    gpg-remove-master ${master_fp}"
}

# ── Revocation ────────────────────────────────────────────────────────────────

# gpg-revoke
# Generate a revocation certificate, or apply an existing one.
#
# Usage:
#   gpg-revoke <fingerprint>           # generate certificate
#   gpg-revoke <fingerprint> --apply   # generate and apply immediately
gpg-revoke() {
    local fp="${1:-}" apply="${2:-}"

    if [[ -z "${fp}" ]]; then
        fp="$(_gpg_prompt_key_id "Key fingerprint to revoke")"
    fi
    _gpg_require_key "${fp}" || return 1

    local rev_dir="${GNUPGHOME:-${HOME}/.gnupg}/revocations"
    mkdir -p "${rev_dir}"
    chmod 700 "${rev_dir}"
    local rev_file="${rev_dir}/${fp}-revocation.asc"

    log_info "Generating revocation certificate for ${fp}..."
    gpg --output "${rev_file}" --gen-revoke "${fp}"
    local gen_rc=$?

    if [[ ${gen_rc} -ne 0 ]]; then
        log_error "Failed to generate revocation certificate"
        return 1
    fi

    chmod 600 "${rev_file}"
    log_info "Revocation certificate saved: ${rev_file}"

    if [[ "${apply}" == "--apply" ]]; then
        echo
        log_warn "Applying the revocation certificate will immediately revoke this key."
        log_warn "This cannot be undone. Type 'yes' to confirm:"
        local confirm
        _read_prompt "  > " confirm
        if [[ "${confirm}" == "yes" ]]; then
            gpg --import "${rev_file}"
            log_info "Key revoked. Upload to keyserver to propagate:"
            log_info "  gpg --keyserver keys.openpgp.org --send-keys ${fp}"
        else
            log_info "Revocation not applied — certificate saved for future use"
        fi
    fi
}

# ── Export functions ──────────────────────────────────────────────────────────

# gpg-export
# Export both public and secret key material to armoured ASCII files.
# Secret key includes all subkeys and the master key.
#
# Usage:
#   gpg-export <fingerprint> [output-dir]
gpg-export() {
    local fp="${1:-}" output_dir="${2:-${HOME}}"

    if [[ -z "${fp}" ]]; then
        fp="$(_gpg_prompt_key_id "Key fingerprint to export")"
    fi
    _gpg_require_key "${fp}" || return 1

    mkdir -p "${output_dir}"
    local pub_file="${output_dir}/gpg-${fp}-public.asc"
    local sec_file="${output_dir}/gpg-${fp}-secret.asc"
    local rev_dir="${GNUPGHOME:-${HOME}/.gnupg}/revocations"
    local rev_file="${rev_dir}/${fp}-revocation.asc"

    log_info "Exporting public key to ${pub_file}..."
    gpg --armor --export "${fp}" > "${pub_file}"

    log_info "Exporting secret key to ${sec_file}..."
    gpg --armor --export-secret-keys "${fp}" > "${sec_file}"
    chmod 600 "${sec_file}"

    echo
    log_info "Exported:"
    echo "  Public:  ${pub_file}"
    echo "  Secret:  ${sec_file}"
    [[ -f "${rev_file}" ]] && echo "  Revoke:  ${rev_file}"
    echo
    echo "  The secret key file is armoured and passphrase-protected."
    echo "  Treat it as you would an SSH private key."
}

# gpg-export-master
# Export ONLY the master key secret material — no subkeys.
# Use this when you want to move the master offline and keep only subkeys
# on the daily-use machine.
#
# Usage:
#   gpg-export-master <fingerprint> [output-dir]
gpg-export-master() {
    local fp="${1:-}" output_dir="${2:-${HOME}}"

    if [[ -z "${fp}" ]]; then
        fp="$(_gpg_prompt_key_id "Master key fingerprint")"
    fi
    _gpg_require_key "${fp}" || return 1

    mkdir -p "${output_dir}"
    local out_file="${output_dir}/gpg-${fp}-master-only.asc"

    log_info "Exporting master key only (no subkeys) to ${out_file}..."
    gpg --armor --export-secret-keys --export-options export-minimal "${fp}" \
        > "${out_file}"
    chmod 600 "${out_file}"

    log_info "Master key exported to: ${out_file}"
    echo
    echo "  This contains your master [C] key material only."
    echo "  Store it offline (Bitwarden, encrypted USB, etc.)."
    echo
    echo "  When ready to take the master offline:"
    echo "    gpg-remove-master ${fp}"
}

# gpg-export-subkeys
# Export subkeys only (no master key secret material).
# Import this on a machine that should not hold the master key.
#
# Usage:
#   gpg-export-subkeys <fingerprint> [output-dir]
gpg-export-subkeys() {
    local fp="${1:-}" output_dir="${2:-${HOME}}"

    if [[ -z "${fp}" ]]; then
        fp="$(_gpg_prompt_key_id "Master key fingerprint")"
    fi
    _gpg_require_key "${fp}" || return 1

    mkdir -p "${output_dir}"
    local out_file="${output_dir}/gpg-${fp}-subkeys-only.asc"

    log_info "Exporting subkeys only (master key material excluded) to ${out_file}..."
    gpg --armor --export-secret-subkeys "${fp}" > "${out_file}"
    chmod 600 "${out_file}"

    log_info "Subkeys exported to: ${out_file}"
    echo
    echo "  This export contains only subkey material."
    echo "  The master [C] key is NOT included — it remains on this machine."
    echo "  Import with: gpg-import ${out_file}"
}

# gpg-export-bitwarden
# Export public key, secret key, and revocation certificate as Bitwarden
# secure notes. Passphrase is stored as a separate Bitwarden Login item so it
# benefits from breach monitoring and masked password history.
#
# Note naming convention:
#   <type> — [<qualifier>] <uid> (<fingerprint>)
#
# The qualifier defaults to the short hostname (hostname -s) so backups from
# different machines are distinct and never clobber each other on upsert.
# Use --name to override the qualifier when the hostname is not meaningful.
#
# Requires: bw CLI, BW_SESSION set (run: export BW_SESSION=$(bw unlock --raw))
#
# Usage:
#   gpg-export-bitwarden <fingerprint>
#   gpg-export-bitwarden <fingerprint> --name "work-laptop"
#   gpg-export-bitwarden <fingerprint> --master-only
#   gpg-export-bitwarden <fingerprint> --name "work-laptop" --master-only
gpg-export-bitwarden() {
    local fp="${1:-}" custom_qualifier="" master_only=""

    shift || true
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --name)        custom_qualifier="${2:-}"; shift 2 ;;
            --master-only) master_only="--master-only";  shift ;;
            *)             shift ;;
        esac
    done

    if [[ -z "${fp}" ]]; then
        fp="$(_gpg_prompt_key_id "Key fingerprint to back up")"
    fi
    _gpg_require_key "${fp}" || return 1
    _gpg_require_bw          || return 1
    _gpg_bw_logged_in        || return 1

    # Qualifier: --name wins, otherwise short hostname
    local qualifier="${custom_qualifier:-$(hostname -s)}"

    # UID from key — always included regardless of qualifier
    local uid
    uid="$(gpg --list-keys --with-colons "${fp}" 2>/dev/null \
        | awk -F: '/^uid/{print $10; exit}')"
    local uid_part="${uid:-${fp}}"

    # Shared label used in all note names
    local note_label="[${qualifier}] ${uid_part} (${fp})"

    # ── Passphrase capture ────────────────────────────────────────────────────
    # Prompt before any GPG operations so the user can bail cleanly if they
    # haven't copied the passphrase from Bitwarden yet. Empty input skips
    # Login item creation with a reminder to add it manually.
    echo
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │  PASSPHRASE CAPTURE                                             │"
    echo "  │                                                                 │"
    echo "  │  The passphrase will be stored as a Bitwarden Login item with   │"
    echo "  │  breach monitoring. Copy it from Bitwarden before continuing.   │"
    echo "  │                                                                 │"
    echo "  │  Press Enter with no input to skip (add manually later).        │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo
    local passphrase=""
    _read_prompt_silent "  Passphrase (Enter to skip): " passphrase

    local store_passphrase=false
    if [[ -n "${passphrase}" ]]; then
        local passphrase_confirm=""
        _read_prompt_silent "  Confirm passphrase: " passphrase_confirm
        if [[ "${passphrase}" != "${passphrase_confirm}" ]]; then
            log_error "Passphrases do not match — skipping passphrase storage"
            log_warn  "Re-run or add the passphrase manually in Bitwarden"
            passphrase=""
        else
            store_passphrase=true
            log_info "Passphrase confirmed — will store as Login item after key export"
        fi
    else
        log_warn "No passphrase entered — skipping Login item creation"
        log_warn "Add manually in Bitwarden: GPG Key Passphrase — ${note_label}"
    fi
    echo

    log_info "Exporting keys to Bitwarden for: ${note_label}"
    echo

    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/gpg-bw-XXXXXX)"
    chmod 700 "${tmp_dir}"

    local pub_file="${tmp_dir}/public.asc"
    local sec_file="${tmp_dir}/secret.asc"
    local sub_file="${tmp_dir}/subkeys.asc"
    local rev_dir="${GNUPGHOME:-${HOME}/.gnupg}/revocations"
    local rev_file="${rev_dir}/${fp}-revocation.asc"

    gpg --armor --export "${fp}" > "${pub_file}"
    gpg --armor --export-secret-keys "${fp}" > "${sec_file}"
    chmod 600 "${sec_file}"

    if [[ "${master_only}" != "--master-only" ]]; then
        gpg --armor --export-secret-subkeys "${fp}" > "${sub_file}"
        chmod 600 "${sub_file}"
    fi

    # Ensure revocation cert exists
    if [[ ! -f "${rev_file}" ]]; then
        log_warn "No revocation certificate found — generating one now..."
        mkdir -p "${rev_dir}"
        chmod 700 "${rev_dir}"
        gpg --output "${rev_file}" --gen-revoke "${fp}" || true
        chmod 600 "${rev_file}" 2>/dev/null || true
    fi

    # _bw_upsert_note <note_name> <body_file>
    # Creates or updates a Bitwarden secure note. Body is read from a file to
    # avoid argv size limits and shell escaping issues with armoured key material.
    _bw_upsert_note() {
        local note_name="${1}" note_body_file="${2}"

        local existing_id
        existing_id="$(bw list items --search "${note_name}" 2>/dev/null \
            | python3 -c "
import json, sys
items = json.load(sys.stdin)
match = [i for i in items if i.get('name') == sys.argv[1]]
print(match[0]['id'] if match else '')
" "${note_name}" 2>/dev/null || true)"

        local note_json_file="${tmp_dir}/item_$(date +%s%N).json"
        python3 - "${note_name}" "${note_body_file}" "${note_json_file}" <<'PYEOF'
import json, sys

note_name  = sys.argv[1]
body_path  = sys.argv[2]
out_path   = sys.argv[3]

with open(body_path, 'r') as f:
    body = f.read()

item = {
    "organizationId": None,
    "folderId":       None,
    "type":           2,
    "name":           note_name,
    "notes":          body,
    "favorite":       False,
    "secureNote":     {"type": 0},
    "fields":         []
}

with open(out_path, 'w') as f:
    json.dump(item, f)
PYEOF

        if [[ ! -f "${note_json_file}" ]]; then
            log_error "Failed to build Bitwarden item JSON for: ${note_name}"
            return 1
        fi

        local encoded
        encoded="$(bw encode < "${note_json_file}")"

        if [[ -n "${existing_id}" ]]; then
            log_info "Updating existing Bitwarden note: ${note_name}"
            bw edit item "${existing_id}" "${encoded}" >/dev/null
        else
            log_info "Creating Bitwarden note: ${note_name}"
            bw create item "${encoded}" >/dev/null
        fi
    }

    # _bw_upsert_login <item_name> <username> <password>
    # Creates or updates a Bitwarden Login item. Password field is masked in
    # the vault UI and eligible for breach monitoring.
    _bw_upsert_login() {
        local item_name="${1}" username="${2}" password="${3}"

        local existing_id
        existing_id="$(bw list items --search "${item_name}" 2>/dev/null \
            | python3 -c "
import json, sys
items = json.load(sys.stdin)
match = [i for i in items if i.get('name') == sys.argv[1]]
print(match[0]['id'] if match else '')
" "${item_name}" 2>/dev/null || true)"

        local login_json_file="${tmp_dir}/login_$(date +%s%N).json"
        python3 - "${item_name}" "${username}" "${password}" "${login_json_file}" <<'PYEOF'
import json, sys

item_name  = sys.argv[1]
username   = sys.argv[2]
password   = sys.argv[3]
out_path   = sys.argv[4]

item = {
    "organizationId": None,
    "folderId":       None,
    "type":           1,
    "name":           item_name,
    "notes":          None,
    "favorite":       False,
    "login": {
        "username": username,
        "password": password,
        "uris":     []
    },
    "fields": []
}

with open(out_path, 'w') as f:
    json.dump(item, f)
PYEOF

        if [[ ! -f "${login_json_file}" ]]; then
            log_error "Failed to build Bitwarden Login item JSON for: ${item_name}"
            return 1
        fi

        local encoded
        encoded="$(bw encode < "${login_json_file}")"

        if [[ -n "${existing_id}" ]]; then
            log_info "Updating existing Bitwarden Login item: ${item_name}"
            bw edit item "${existing_id}" "${encoded}" >/dev/null
        else
            log_info "Creating Bitwarden Login item: ${item_name}"
            bw create item "${encoded}" >/dev/null
        fi
    }

    _bw_upsert_note "GPG Public Key — ${note_label}"    "${pub_file}"
    _bw_upsert_note "GPG Secret Key — ${note_label}"    "${sec_file}"

    if [[ -f "${sub_file}" ]]; then
        _bw_upsert_note "GPG Subkeys Only — ${note_label}" "${sub_file}"
    fi

    if [[ -f "${rev_file}" ]]; then
        _bw_upsert_note "GPG Revocation Certificate — ${note_label}" "${rev_file}"
    else
        log_warn "No revocation certificate to store — generate one with: gpg-revoke ${fp}"
    fi

    if [[ "${store_passphrase}" == "true" ]]; then
        _bw_upsert_login \
            "GPG Key Passphrase — ${note_label}" \
            "${fp}" \
            "${passphrase}"
        # Clear from memory immediately after use
        passphrase=""
        passphrase_confirm=""
    fi

    rm -rf "${tmp_dir}"

    echo
    log_info "Bitwarden backup complete for ${fp}"
    echo "  Stored notes:"
    echo "    • GPG Public Key — ${note_label}"
    echo "    • GPG Secret Key — ${note_label}"
    [[ "${master_only}" != "--master-only" ]] && \
        echo "    • GPG Subkeys Only — ${note_label}"
    [[ -f "${rev_file}" ]] && \
        echo "    • GPG Revocation Certificate — ${note_label}"
    [[ "${store_passphrase}" == "true" ]] && \
        echo "    • GPG Key Passphrase — ${note_label}  (Login item)"
    echo
    log_info "Sync to ensure notes are persisted: bw sync"
    echo
    echo "  When ready to take the master key offline:"
    echo "    gpg-remove-master ${fp}"
}

# ── Import functions ──────────────────────────────────────────────────────────

# gpg-import
# Import a key from an armoured ASCII file.
#
# Usage:
#   gpg-import <file.asc>
gpg-import() {
    local file="${1:-}"
    if [[ -z "${file}" ]]; then
        _read_prompt "  Path to key file (.asc): " file
    fi
    [[ ! -f "${file}" ]] && { log_error "File not found: ${file}"; return 1; }

    log_info "Importing key from: ${file}"
    gpg --import "${file}"

    echo
    log_info "Imported. Current secret keys:"
    gpg --list-secret-keys --keyid-format long
}

# gpg-import-bitwarden
# Pull a secret key from a Bitwarden secure note and import it into the keyring.
#
# Usage:
#   gpg-import-bitwarden                       # interactive search
#   gpg-import-bitwarden "GPG Secret Key — …"  # by exact note name
gpg-import-bitwarden() {
    local note_name="${1:-}"
    _gpg_require_bw   || return 1
    _gpg_bw_logged_in || return 1

    if [[ -z "${note_name}" ]]; then
        echo
        log_info "Searching Bitwarden for GPG key notes..."
        bw list items --search "GPG" 2>/dev/null \
            | python3 -c "
import json,sys
items=json.load(sys.stdin)
gpg_items=[i for i in items if 'GPG' in i.get('name','')]
for i,item in enumerate(gpg_items):
    print(f'  {i+1}. {item[\"name\"]}')
"
        echo
        _read_prompt "  Note name (or partial match): " note_name
    fi

    log_info "Fetching note: ${note_name}"
    local note_content
    note_content="$(bw list items --search "${note_name}" 2>/dev/null \
        | python3 -c "
import json,sys
items=json.load(sys.stdin)
match=[i for i in items if sys.argv[1] in i.get('name','')]
if match:
    print(match[0].get('notes',''))
" "${note_name}")"

    if [[ -z "${note_content}" ]]; then
        log_error "No matching note found or note is empty"
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp /tmp/gpg-import-XXXXXX.asc)"
    chmod 600 "${tmp_file}"
    echo "${note_content}" > "${tmp_file}"

    log_info "Importing key..."
    gpg --import "${tmp_file}"
    local rc=$?
    rm -f "${tmp_file}"

    [[ ${rc} -eq 0 ]] && log_info "Import complete" || log_error "Import failed"
    return ${rc}
}

# ── Trust ─────────────────────────────────────────────────────────────────────

# gpg-trust
# Set the owner trust level on a key.
# You almost always want 'ultimate' for your own keys.
#
# Trust levels: 1=unknown 2=none 3=marginal 4=full 5=ultimate
#
# Usage:
#   gpg-trust <fingerprint> [level]    level: unknown|none|marginal|full|ultimate
gpg-trust() {
    local fp="${1:-}" level="${2:-ultimate}"

    if [[ -z "${fp}" ]]; then
        fp="$(_gpg_prompt_key_id "Key fingerprint to set trust on")"
    fi

    # Resolve to full 40-char fingerprint — --import-ownertrust silently
    # ignores short key IDs (exits 0 but writes nothing)
    local full_fp
    full_fp="$(gpg --list-keys --with-colons "${fp}" 2>/dev/null \
        | awk -F: '/^fpr/{print $10; exit}')"
    if [[ -z "${full_fp}" ]]; then
        log_error "Could not resolve fingerprint for: ${fp}"
        return 1
    fi

    local trust_val
    case "${level}" in
        unknown)   trust_val=2 ;;
        none)      trust_val=3 ;;
        marginal)  trust_val=4 ;;
        full)      trust_val=5 ;;
        ultimate)  trust_val=6 ;;
        [1-6])     trust_val="${level}" ;;
        *) log_error "Unknown trust level '${level}'. Use: unknown|none|marginal|full|ultimate"; return 1 ;;
    esac

    log_info "Setting trust level ${level} (${trust_val}) on ${full_fp}..."
    echo "${full_fp}:${trust_val}:" | gpg --import-ownertrust 2>/dev/null
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
        log_error "Failed to set ownertrust (exit ${rc})"
        return 1
    fi
    gpg --check-trustdb 2>/dev/null
    log_info "Trust level set"

    echo
    log_info "Updated key:"
    gpg --list-secret-keys --keyid-format long "${full_fp}"
}

# ── GitHub integration ────────────────────────────────────────────────────────

# gpg-push-github
# Push a GPG public key to the authenticated GitHub account.
#
# Presents the list of local signing-capable keys, prompts for selection,
# verifies gh CLI authentication, then uploads the public key.
# Handles duplicate detection — GitHub rejects keys already present.
#
# Usage:
#   gpg-push-github              # interactive key selection
#   gpg-push-github <key-id>     # skip selection prompt
gpg-push-github() {
    local selected_keyid="${1:-}"

    # ── Preflight: gh CLI present and authenticated ───────────────────────────
    if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) is not installed"
        log_error "Install it with: sudo dnf install gh   # Fedora"
        log_error "                 sudo apt install gh   # Debian/Ubuntu"
        log_error "Then authenticate: gh auth login"
        return 1
    fi

    local gh_user
    if ! gh_user="$(gh api user --jq '.login' 2>/dev/null)"; then
        log_error "GitHub CLI is not authenticated (or the API call failed)"
        log_error "Run: gh auth login"
        log_error "     gh auth status   # to verify scope"
        return 1
    fi
    log_info "Authenticated to GitHub as: ${gh_user}"

    # ── Collect available signing keys into an array ──────────────────────────
    # Parallel arrays: key IDs and their display labels
    local key_ids=()
    local key_labels=()
    local uids=()

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

                # Build a label from all UIDs on this key
                local label="${uids[0]}"
                [[ ${#uids[@]} -gt 1 ]] && label+=" (+$((${#uids[@]} - 1)) more)"
                label+="  [${exp_str}]"

                key_ids+=("${keyid}")
                key_labels+=("${label}")
                ;;
        esac
    done < <(gpg --list-secret-keys --with-colons 2>/dev/null)

    if [[ ${#key_ids[@]} -eq 0 ]]; then
        log_error "No signing-capable keys found in local keyring"
        log_error "Create one with: gpg-create-key"
        return 1
    fi

    # ── Key selection ─────────────────────────────────────────────────────────
    if [[ -n "${selected_keyid}" ]]; then
        # Validate the supplied key ID is in our list
        local found=0
        local k
        for k in "${key_ids[@]}"; do
            [[ "${k}" == "${selected_keyid}" ]] && { found=1; break; }
        done
        if [[ ${found} -eq 0 ]]; then
            log_error "Key ID '${selected_keyid}' not found among local signing keys"
            log_error "Run gpg-list-signing-keys to see available keys"
            return 1
        fi
    else
        echo
        echo "═══════════════════════════════════════════════════════════════════"
        echo "  Push GPG Signing Key to GitHub"
        echo "  GitHub account: ${gh_user}"
        echo "═══════════════════════════════════════════════════════════════════"
        echo
        echo "  Available signing keys:"
        echo
        local i
        for i in "${!key_ids[@]}"; do
            printf "  %2d)  Key ID: %s\n" "$((i + 1))" "${key_ids[${i}]}"
            printf "       UID:    %s\n" "${key_labels[${i}]}"
            echo
        done

        local choice
        while true; do
            _read_prompt "  Select key (1-${#key_ids[@]}, or q to quit): " choice
            [[ "${choice}" == "q" || "${choice}" == "Q" ]] && {
                log_info "Aborted"
                return 0
            }
            if [[ "${choice}" =~ ^[0-9]+$ ]] \
                && (( choice >= 1 && choice <= ${#key_ids[@]} )); then
                selected_keyid="${key_ids[$((choice - 1))]}"
                break
            fi
            log_warn "Invalid selection — enter a number between 1 and ${#key_ids[@]}"
        done
    fi

    log_info "Selected key: ${selected_keyid}"

    # ── Key title (label shown on GitHub) ─────────────────────────────────────
    local default_title
    default_title="$(hostname -s 2>/dev/null || hostname)"
    local key_title
    echo
    _read_prompt "  Key title for GitHub [${default_title}]: " key_title
    key_title="${key_title:-${default_title}}"
    log_info "Key will be uploaded as: ${key_title}"

    # ── Export public key to temp file ────────────────────────────────────────
    local tmp_file
    tmp_file="$(mktemp /tmp/gpg-github-XXXXXX.asc)"
    chmod 600 "${tmp_file}"

    if ! gpg --armor --export "${selected_keyid}" > "${tmp_file}" 2>/dev/null \
            || [[ ! -s "${tmp_file}" ]]; then
        log_error "Failed to export public key for ${selected_keyid}"
        rm -f "${tmp_file}"
        return 1
    fi

    # ── Upload via gh CLI ─────────────────────────────────────────────────────
    log_info "Uploading GPG key to GitHub..."
    if gh gpg-key add "${tmp_file}" --title "${key_title}" 2>/dev/null; then
        log_info "GPG key uploaded successfully"
        log_info "View at: https://github.com/settings/keys"
    else
        local gh_exit=$?
        # Exit 1 from gh gpg-key add usually means duplicate key
        log_warn "gh gpg-key add exited ${gh_exit} — key may already be registered"
        log_warn "Check: https://github.com/settings/keys"
    fi

    rm -f "${tmp_file}"
}
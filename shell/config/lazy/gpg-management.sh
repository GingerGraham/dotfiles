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
# (Bitwarden, encrypted USB, etc.) and then optionally removed from the
# local keyring so only subkeys remain. Subkeys can be rotated without
# creating a new identity.
#
# Public functions:
#   gpg-create-key        Interactive wizard: master [C] + subkeys [S][E][A]
#   gpg-add-subkey        Add a new subkey to an existing master key
#   gpg-extend-expiry     Extend expiry on a key or subkey
#   gpg-revoke            Generate or apply a revocation certificate
#   gpg-export            Export public + secret keys to files
#   gpg-export-master     Export master key secret material only (for offline backup)
#   gpg-export-subkeys    Export subkeys-only secret material (for daily-use keyring)
#   gpg-export-bitwarden  Export keys and store them as Bitwarden secure notes
#   gpg-import            Import a key from a file
#   gpg-import-bitwarden  Pull a key from a Bitwarden secure note and import it
#   gpg-rotate-subkey     Expire current subkey and generate a replacement
#   gpg-trust             Set owner trust level on a key
#   gpg-add-uid           Add a new UID (email address / identity) to an existing key

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
    local status
    # grep -P (PCRE) is not available on macOS without Homebrew — use grep -o + sed
    status="$(bw status 2>/dev/null \
        | grep -o '"status":"[^"]*"' \
        | sed 's/"status":"//;s/"//')"
    if [[ "${status}" != "unlocked" ]]; then
        log_error "Bitwarden vault is not unlocked (status: ${status:-unknown})"
        log_error "Run: export BW_SESSION=\$(bw unlock --raw)"
        return 1
    fi
}

# Prompt for a key ID, offering a list of available secret keys first.
_gpg_prompt_key_id() {
    local prompt_label="${1:-Key ID or fingerprint}"
    echo
    log_info "Available secret keys:"
    gpg --list-secret-keys --keyid-format long --with-fingerprint 2>/dev/null \
        | grep -E '(^sec|^uid)' | sed 's/^/  /'
    echo
    local key_id
    read -r -p "  ${prompt_label}: " key_id
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
# The master key is generated with --expert so capabilities can be set
# precisely. All three subkeys use separate key material.
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
    local name email comment expiry_years auth_subkey
    read -r -p "  Full name:  " name
    [[ -z "${name}" ]] && { log_error "Name is required"; return 1; }

    read -r -p "  Email:      " email
    [[ -z "${email}" ]] && { log_error "Email is required"; return 1; }

    read -r -p "  Comment (optional, e.g. 'personal' or 'work'): " comment

    echo
    echo "  Key expiry (years). Subkeys will use the same expiry."
    echo "  Recommended: 2 years — short enough to limit exposure,"
    echo "  long enough not to be annoying. You can always extend."
    read -r -p "  Expiry in years [2]: " expiry_years
    expiry_years="${expiry_years:-2}"
    local expiry="${expiry_years}y"

    echo
    read -r -p "  Add authentication [A] subkey for SSH? [y/N]: " auth_subkey

    # Build the UID string
    local uid="${name}"
    [[ -n "${comment}" ]] && uid="${uid} (${comment})"
    uid="${uid} <${email}>"

    echo
    log_info "Creating master key [C] for: ${uid}"
    log_info "Expiry: ${expiry}"
    echo
    echo "  You will be prompted to set a passphrase. Use a strong, unique"
    echo "  passphrase — this protects your master key."
    echo

    # Generate master key (certify only) using batch mode where possible,
    # then add subkeys interactively via --edit-key.
    # We use a parameter file for the master key so the UID and expiry are set
    # consistently, then drop into --edit-key for the subkeys.

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
Expire-Date: ${expiry}
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

    # Add [S] subkey: ed25519
    gpg --batch --yes --quick-add-key "${fp}" ed25519 sign "${expiry}"

    log_info "Adding encrypt [E] subkey..."
    # Add [E] subkey: cv25519 (ECDH — the encrypt equivalent of ed25519)
    gpg --batch --yes --quick-add-key "${fp}" cv25519 encr "${expiry}"

    if [[ "${auth_subkey,,}" == "y" ]]; then
        log_info "Adding authenticate [A] subkey..."
        gpg --batch --yes --quick-add-key "${fp}" ed25519 auth "${expiry}"
    fi

    echo
    log_info "Key creation complete. Summary:"
    gpg --list-secret-keys --keyid-format long --with-fingerprint "${fp}"

    echo
    echo "═══════════════════════════════════════════════════════════"
    echo "  Recommended next steps:"
    echo
    echo "  1. Generate a revocation certificate (do this now):"
    echo "       gpg-revoke ${fp}"
    echo
    echo "  2. Export and back up your master key:"
    echo "       gpg-export-bitwarden ${fp}    # store in Bitwarden"
    echo "     or:"
    echo "       gpg-export-master ${fp}       # export to encrypted file"
    echo
    echo "  3. Use the signing subkey ID with git:"
    echo "       gpg-list-signing-keys ${email}"
    echo "       git-add-project <context> <provider> ${email} <signing-subkey-id>"
    echo "═══════════════════════════════════════════════════════════"
    echo
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

    if [[ -z "${type}" ]]; then
        echo "  Subkey type:"
        echo "    sign  — signing (git commits, tags, files)"
        echo "    encr  — encryption"
        echo "    auth  — authentication (SSH)"
        read -r -p "  Type [sign]: " type
        type="${type:-sign}"
    fi

    case "${type}" in
        sign) local algo="ed25519" ;;
        encr) local algo="cv25519" ;;
        auth) local algo="ed25519" ;;
        *) log_error "Unknown type '${type}'. Use: sign | encr | auth"; return 1 ;;
    esac

    if [[ -z "${expiry}" ]]; then
        read -r -p "  Expiry (e.g. 2y, 1y, 0 for none) [2y]: " expiry
        expiry="${expiry:-2y}"
    fi

    log_info "Adding ${type} subkey (${algo}) to ${fp}, expiry: ${expiry}"
    gpg --batch --yes --quick-add-key "${fp}" "${algo}" "${type}" "${expiry}"

    echo
    log_info "Updated key:"
    gpg --list-secret-keys --keyid-format long --with-fingerprint "${fp}"
}

# gpg-add-uid
# Add an additional UID (name + email) to an existing key.
# Useful for adding a GitHub noreply address, a work alias, or any alternate
# email to a key without creating a new key.
#
# GitHub signature verification accepts any UID on the key, so adding your
# <id>+username@users.noreply.github.com means both your real email and the
# noreply address will verify correctly.
#
# Usage:
#   gpg-add-uid <fingerprint>    # prompts for UID details
#   gpg-add-uid                  # prompts for key selection first
#
# After adding a UID, re-export to keep your Bitwarden backup current:
#   gpg-export-bitwarden <fingerprint>
gpg-add-uid() {
    local fp="${1:-}"

    # ── Key selection ────────────────────────────────────────────────────────
    if [[ -z "${fp}" ]]; then
        echo
        echo "═══════════════════════════════════════════════════════════"
        echo "  Add UID to GPG Key"
        echo "  Adds an email address / identity to an existing key."
        echo "  Useful for: GitHub noreply, work aliases, alternate emails."
        echo "═══════════════════════════════════════════════════════════"
        echo
        log_info "Available keys:"
        echo

        # Build numbered list from --with-colons output.
        # Bash 3.2 compat (macOS): no associative arrays, index via parallel arrays.
        local fps=() labels=()
        local _cur_fp="" _cur_uid_seen=0

        while IFS=: read -r type _ _ _ _ _ _ _ _ field10 _; do
            case "${type}" in
                sec)
                    _cur_fp=""
                    _cur_uid_seen=0
                    ;;
                fpr)
                    # First fpr record after sec is the master key fingerprint
                    [[ -z "${_cur_fp}" ]] && _cur_fp="${field10}"
                    ;;
                uid)
                    # Capture only the first UID per key for the label
                    if [[ "${_cur_uid_seen}" -eq 0 && -n "${field10}" && -n "${_cur_fp}" ]]; then
                        _cur_uid_seen=1
                        fps+=("${_cur_fp}")
                        labels+=("${field10}")
                        local _idx=${#fps[@]}
                        printf "  %d.  %s\n      Fingerprint: %s\n\n" \
                            "${_idx}" "${field10}" "${_cur_fp}"
                    fi
                    ;;
            esac
        done < <(gpg --list-secret-keys --with-colons 2>/dev/null)

        if [[ ${#fps[@]} -eq 0 ]]; then
            log_error "No secret keys found. Run gpg-create-key first."
            return 1
        fi

        local choice
        read -r -p "  Select key number [1]: " choice
        choice="${choice:-1}"

        if ! echo "${choice}" | grep -qE '^[0-9]+$' || \
           [[ "${choice}" -lt 1 ]] || \
           [[ "${choice}" -gt ${#fps[@]} ]]; then
            log_error "Invalid selection: ${choice}"
            return 1
        fi

        # Bash 3.2 compat: retrieve by walking the array with a counter
        local _i=0
        local _selected_label=""
        for _f in "${fps[@]}"; do
            _i=$((_i + 1))
            if [[ "${_i}" -eq "${choice}" ]]; then
                fp="${_f}"
                break
            fi
        done
        _i=0
        for _l in "${labels[@]}"; do
            _i=$((_i + 1))
            if [[ "${_i}" -eq "${choice}" ]]; then
                _selected_label="${_l}"
                break
            fi
        done

        echo
        log_info "Selected: ${_selected_label}"
    fi

    _gpg_require_key "${fp}" || return 1

    # ── Show existing UIDs ───────────────────────────────────────────────────
    echo
    log_info "Current UIDs on this key:"
    local existing_uids=()
    local _uid_field
    while IFS=: read -r type _ _ _ _ _ _ _ _ _uid_field _; do
        if [[ "${type}" == "uid" && -n "${_uid_field}" ]]; then
            existing_uids+=("${_uid_field}")
            printf "  • %s\n" "${_uid_field}"
        fi
    done < <(gpg --list-secret-keys --with-colons "${fp}" 2>/dev/null)

    # ── Collect new UID details ──────────────────────────────────────────────
    echo
    echo "  Enter details for the new UID."
    echo "  For a GitHub noreply address, leave name blank to reuse the"
    echo "  existing name and enter: <id>+username@users.noreply.github.com"
    echo

    local new_name new_email new_comment
    read -r -p "  Full name (blank to reuse existing name): " new_name

    # Fall back to name component of first existing UID
    if [[ -z "${new_name}" ]] && [[ ${#existing_uids[@]} -gt 0 ]]; then
        # UID format: "Name (Comment) <email>" — strip everything from ( or < onwards
        new_name="${existing_uids[0]%%(*}"
        new_name="${new_name%%<*}"
        # Trim trailing whitespace portably
        new_name="$(echo "${new_name}" | sed 's/[[:space:]]*$//')"
        log_info "Using existing name: ${new_name}"
    fi
    [[ -z "${new_name}" ]] && { log_error "Name is required"; return 1; }

    read -r -p "  Email: " new_email
    [[ -z "${new_email}" ]] && { log_error "Email is required"; return 1; }

    # Warn if this email is already present on the key
    local _u
    for _u in "${existing_uids[@]}"; do
        if echo "${_u}" | grep -qi "${new_email}"; then
            log_warn "A UID matching '${new_email}' already exists: ${_u}"
            local _confirm
            read -r -p "  Add it anyway? [y/N]: " _confirm
            [[ "${_confirm}" != "y" && "${_confirm}" != "Y" ]] && return 0
            break
        fi
    done

    read -r -p "  Comment (optional, e.g. 'github' or 'work'): " new_comment

    # ── Build and confirm the new UID string ─────────────────────────────────
    local new_uid="${new_name}"
    [[ -n "${new_comment}" ]] && new_uid="${new_uid} (${new_comment})"
    new_uid="${new_uid} <${new_email}>"

    echo
    log_info "New UID:  ${new_uid}"
    log_info "On key:   ${fp}"
    local _confirm
    read -r -p "  Confirm? [Y/n]: " _confirm
    [[ "${_confirm}" == "n" || "${_confirm}" == "N" ]] && return 0

    # ── Add the UID ──────────────────────────────────────────────────────────
    # --quick-add-uid requires GnuPG >= 2.1.13 — present on all current
    # Fedora, Ubuntu 18.04+, Debian 10+, Arch, macOS (Homebrew gnupg).
    gpg --batch --yes --quick-add-uid "${fp}" "${new_uid}"
    local _rc=$?

    if [[ ${_rc} -ne 0 ]]; then
        log_error "Failed to add UID (gpg exit ${_rc})"
        return 1
    fi

    log_info "UID added successfully."

    # ── Optionally set as primary ────────────────────────────────────────────
    echo
    echo "  Your existing primary UID is unchanged."
    echo "  For a GitHub noreply address, leaving your real email as primary"
    echo "  is usually correct — GitHub verifies against any UID on the key."
    echo
    local _set_primary
    read -r -p "  Set '${new_uid}' as the primary UID? [y/N]: " _set_primary

    if [[ "${_set_primary}" == "y" || "${_set_primary}" == "Y" ]]; then
        # --quick-set-primary-uid requires GnuPG >= 2.2.17
        if gpg --batch --yes --quick-set-primary-uid "${fp}" "${new_uid}" 2>/dev/null; then
            log_info "Primary UID updated."
        else
            log_warn "--quick-set-primary-uid not supported on this GPG version."
            log_warn "Set it manually:"
            log_warn "  gpg --edit-key ${fp}"
            log_warn "  At the gpg> prompt: uid <N>  then: primary  then: save"
        fi
    fi

    # ── Summary ──────────────────────────────────────────────────────────────
    echo
    log_info "Updated key:"
    gpg --list-secret-keys --keyid-format long --with-fingerprint "${fp}"
    echo
    echo "  Re-export to keep your Bitwarden backup current:"
    echo "    gpg-export-bitwarden ${fp}"
    echo
}

# gpg-extend-expiry
# Extend the expiry on a key or its subkeys.
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

    if [[ -z "${expiry}" ]]; then
        read -r -p "  New expiry (e.g. 2y, 1y): " expiry
        [[ -z "${expiry}" ]] && { log_error "Expiry is required"; return 1; }
    fi

    log_info "Extending expiry for all subkeys of ${fp} to ${expiry}..."
    # quick-set-expire with no subkey fingerprint extends the primary key;
    # with '*' it extends all subkeys.
    gpg --batch --yes --quick-set-expire "${fp}" "${expiry}" '*'
    gpg --batch --yes --quick-set-expire "${fp}" "${expiry}"

    echo
    log_info "Updated key:"
    gpg --list-secret-keys --keyid-format long --with-fingerprint "${fp}"
    echo
    log_info "Remember to re-export and update your Bitwarden backup:"
    log_info "  gpg-export-bitwarden ${fp}"
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

    if [[ -z "${subkey_fp}" ]]; then
        echo
        log_info "Subkeys for ${master_fp}:"
        gpg --list-secret-keys --with-colons "${master_fp}" 2>/dev/null \
            | awk -F: '/^fpr/ && NR>1 {print "  " $10}'
        echo
        read -r -p "  Subkey fingerprint to retire: " subkey_fp
    fi

    if [[ -z "${type}" ]]; then
        echo "  Replacement subkey type (sign | encr | auth):"
        read -r -p "  Type [sign]: " type
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
    gpg --list-secret-keys --keyid-format long --with-fingerprint "${master_fp}"
    echo
    log_info "Update your Bitwarden backup with the new subkey material:"
    log_info "  gpg-export-bitwarden ${master_fp}"
}

# ── Revocation ────────────────────────────────────────────────────────────────

# gpg-revoke
# Generate a revocation certificate and optionally apply it.
# Store the certificate alongside your key backup — it's your kill switch.
#
# Usage:
#   gpg-revoke <fingerprint>    # generate certificate only
#   gpg-revoke <fingerprint> --apply  # generate and immediately revoke
gpg-revoke() {
    local fp="${1:-}" apply="${2:-}"

    if [[ -z "${fp}" ]]; then
        fp="$(_gpg_prompt_key_id "Key fingerprint to revoke")"
    fi
    _gpg_require_key "${fp}" || return 1

    local revoke_dir="${GNUPGHOME:-${HOME}/.gnupg}/revocations"
    mkdir -p "${revoke_dir}"
    chmod 700 "${revoke_dir}"
    local revoke_file="${revoke_dir}/${fp}-revocation.asc"

    log_info "Generating revocation certificate for ${fp}..."
    gpg --output "${revoke_file}" --gen-revoke "${fp}"

    if [[ $? -ne 0 ]]; then
        log_error "Revocation certificate generation failed"
        return 1
    fi

    chmod 600 "${revoke_file}"
    log_info "Revocation certificate saved to: ${revoke_file}"
    echo
    echo "  Store this certificate safely — applying it will permanently"
    echo "  revoke the key on any keyserver it has been uploaded to."
    echo

    if [[ "${apply}" == "--apply" ]]; then
        echo
        read -r -p "  Confirm: immediately revoke key ${fp}? [yes/N]: " confirm
        if [[ "${confirm}" == "yes" ]]; then
            gpg --import "${revoke_file}"
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
    echo "  Store it offline (Bitwarden, encrypted USB, etc.) and"
    echo "  consider running gpg-export-subkeys to get a subkeys-only"
    echo "  export for your day-to-day keyring."
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
# secure notes. Each is stored as a separate note for easy retrieval.
#
# Requires: bw CLI, BW_SESSION set (run: export BW_SESSION=$(bw unlock --raw))
#
# Usage:
#   gpg-export-bitwarden <fingerprint>
#   gpg-export-bitwarden <fingerprint> --master-only   # skip subkey export
gpg-export-bitwarden() {
    local fp="${1:-}" master_only="${2:-}"

    if [[ -z "${fp}" ]]; then
        fp="$(_gpg_prompt_key_id "Key fingerprint to back up")"
    fi
    _gpg_require_key "${fp}" || return 1
    _gpg_require_bw   || return 1
    _gpg_bw_logged_in || return 1

    # Gather key UIDs for naming the notes
    local uid
    uid="$(gpg --list-keys --with-colons "${fp}" 2>/dev/null \
        | awk -F: '/^uid/{print $10; exit}')"
    local label="${uid:-${fp}}"

    log_info "Exporting keys to Bitwarden for: ${label}"
    echo

    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/gpg-bw-XXXXXX)"
    chmod 700 "${tmp_dir}"

    local pub_file="${tmp_dir}/public.asc"
    local sec_file="${tmp_dir}/secret.asc"
    local sub_file="${tmp_dir}/subkeys.asc"
    local rev_dir="${GNUPGHOME:-${HOME}/.gnupg}/revocations"
    local rev_file="${rev_dir}/${fp}-revocation.asc"

    # Export all key material to temp files
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

    # Helper: create or update a Bitwarden secure note
    _bw_upsert_note() {
        local note_name="${1}" note_body="${2}"
        local existing_id
        existing_id="$(bw list items --search "${note_name}" 2>/dev/null \
            | python3 -c "
import json,sys
items=json.load(sys.stdin)
match=[i for i in items if i.get('name')=='${note_name}']
print(match[0]['id'] if match else '')
" 2>/dev/null || true)"

        local note_json
        note_json="$(bw get template item 2>/dev/null \
            | python3 -c "
import json,sys
t=json.load(sys.stdin)
t['type']=2
t['name']='${note_name}'
t['notes']=sys.argv[1]
t['secureNote']={'type':0}
print(json.dumps(t))
" "${note_body}" 2>/dev/null)"

        if [[ -z "${note_json}" ]]; then
            log_error "Failed to build Bitwarden item JSON"
            return 1
        fi

        local encoded
        encoded="$(echo "${note_json}" | bw encode)"

        if [[ -n "${existing_id}" ]]; then
            log_info "Updating existing Bitwarden note: ${note_name}"
            bw edit item "${existing_id}" "${encoded}" >/dev/null
        else
            log_info "Creating Bitwarden note: ${note_name}"
            bw create item "${encoded}" >/dev/null
        fi
    }

    # Store public key
    _bw_upsert_note "GPG Public Key — ${label} (${fp})" "$(cat "${pub_file}")"

    # Store full secret key (master + subkeys)
    _bw_upsert_note "GPG Secret Key — ${label} (${fp})" "$(cat "${sec_file}")"

    # Store subkeys-only export if we have it
    if [[ -f "${sub_file}" ]]; then
        _bw_upsert_note "GPG Subkeys Only — ${label} (${fp})" "$(cat "${sub_file}")"
    fi

    # Store revocation certificate
    if [[ -f "${rev_file}" ]]; then
        _bw_upsert_note "GPG Revocation Certificate — ${label} (${fp})" "$(cat "${rev_file}")"
    else
        log_warn "No revocation certificate to store — generate one with: gpg-revoke ${fp}"
    fi

    # Clean up
    rm -rf "${tmp_dir}"

    echo
    log_info "Bitwarden backup complete for ${fp}"
    echo "  Stored notes:"
    echo "    • GPG Public Key — ${label} (${fp})"
    echo "    • GPG Secret Key — ${label} (${fp})"
    [[ -f "${sub_file}" ]] && echo "    • GPG Subkeys Only — ${label} (${fp})"
    [[ -f "${rev_file}" ]] && echo "    • GPG Revocation Certificate — ${label} (${fp})"
    echo
    log_info "Sync to ensure notes are persisted: bw sync"
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
        read -r -p "  Path to key file (.asc): " file
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
" 2>/dev/null
        echo
        read -r -p "  Note name (or partial match): " note_name
    fi

    log_info "Fetching note: ${note_name}"
    local note_content
    note_content="$(bw list items --search "${note_name}" 2>/dev/null \
        | python3 -c "
import json,sys
items=json.load(sys.stdin)
match=[i for i in items if '${note_name}' in i.get('name','')]
if match:
    print(match[0].get('notes',''))
" 2>/dev/null)"

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

    local trust_val
    case "${level}" in
        unknown)   trust_val=1 ;;
        none)      trust_val=2 ;;
        marginal)  trust_val=3 ;;
        full)      trust_val=4 ;;
        ultimate)  trust_val=5 ;;
        [1-5])     trust_val="${level}" ;;
        *) log_error "Unknown trust level '${level}'. Use: unknown|none|marginal|full|ultimate"; return 1 ;;
    esac

    log_info "Setting trust level ${level} (${trust_val}) on ${fp}..."
    echo "${fp}:${trust_val}:" | gpg --import-ownertrust
    log_info "Trust level set"
}

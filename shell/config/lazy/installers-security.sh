#!/usr/bin/env bash
# lazy/installers-security.sh
# shellcheck disable=SC1091
source "${SHELL_CONFIG_DIR:-$HOME/.config/shell}/lazy/installers-common.sh"


# ── cosign install (Sigstore signing) ────────────────────────────────────────
# Needed for full signature verification of tenv and of the tofu/terraform
# binaries tenv downloads. Bootstrapped from the official release binary
# (verifying cosign with cosign is circular); package managers can replace it.
install-cosign() {
    log_info "Installing or updating cosign..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    if [[ "${DOTFILES_OS}" == "Mac" ]]; then
        command -v brew &>/dev/null || { log_error "brew is required on macOS"; return 1; }
        if brew list cosign &>/dev/null; then brew upgrade cosign; else brew install cosign; fi
        return $?
    fi

    local arch
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_error "cosign: unsupported architecture $(uname -m)"; return 1 ;;
    esac

    local url="https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-${arch}"
    mkdir -p "${HOME}/.local/bin"
    log_info "cosign: downloading ${url##*/} ..."
    _download_file_robust "${url}" "${HOME}/.local/bin/cosign" \
        || { log_error "cosign: download failed"; return 1; }
    chmod +x "${HOME}/.local/bin/cosign"
    if command -v cosign &>/dev/null; then
        log_info "cosign installed: $(cosign version 2>/dev/null | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    else
        log_error "cosign: not on PATH after install (is ~/.local/bin on PATH?)"; return 1
    fi
}


# ── Trivy install ─────────────────────────────────────────────────────────────
_trivy-repo-rpm() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    [[ -f /etc/yum.repos.d/trivy.repo ]] && { log_info "Trivy repo already configured"; return 0; }
    cat <<'EOF' | ${elevation_cmd} tee /etc/yum.repos.d/trivy.repo
[trivy]
name=Trivy
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://aquasecurity.github.io/trivy-repo/rpm/public.key
EOF
    if command -v dnf &>/dev/null; then
        ${elevation_cmd} dnf check-update --refresh -y
    else
        ${elevation_cmd} yum check-update -y
    fi
}


_trivy-repo-deb() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    [[ -f /etc/apt/sources.list.d/trivy.list ]] && { log_info "Trivy repo already configured"; return 0; }
    ${elevation_cmd} apt-get install -y wget gnupg
    wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
        | gpg --dearmor | ${elevation_cmd} tee /usr/share/keyrings/trivy.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
        | ${elevation_cmd} tee /etc/apt/sources.list.d/trivy.list
    ${elevation_cmd} apt-get update
}


_trivy-install-linux() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    local ver
    ver="$(curl -s https://api.github.com/repos/aquasecurity/trivy/releases/latest \
        | grep '"tag_name":' | sed -E 's/.+"v([^"]+)".+/\1/')"
    [[ -z "${ver}" ]] && { log_error "Could not determine Trivy version"; return 1; }

    if command -v trivy &>/dev/null; then
        local current
        current="$(trivy version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        [[ "${current}" == "${ver}" ]] && { log_info "Trivy ${ver} already installed"; return 0; }
    fi

    if command -v dnf &>/dev/null; then
        _trivy-repo-rpm && ${elevation_cmd} dnf install -y trivy
    elif command -v yum &>/dev/null; then
        _trivy-repo-rpm && ${elevation_cmd} yum install -y trivy
    elif command -v apt-get &>/dev/null; then
        _trivy-repo-deb && ${elevation_cmd} apt-get install -y trivy
    else
        log_error "No supported package manager for Trivy install"; return 1
    fi
}


_trivy-install-mac() {
    command -v brew &>/dev/null || { log_error "brew required on macOS"; return 1; }
    if command -v trivy &>/dev/null; then
        brew upgrade trivy
    else
        brew install trivy
    fi
}


install-trivy() {
    case "${DOTFILES_OS}" in
        Linux) _trivy-install-linux ;;
        Mac)   _trivy-install-mac ;;
        *)     log_error "Unsupported OS for trivy"; return 1 ;;
    esac
}


# ── Bitwarden install ─────────────────────────────────────────────────────────
install-bitwarden() {
    log_info "Installing or updating Bitwarden..."
    [[ -z "${PACKAGE_MANAGER}" ]] && { detect-package-manager || return 1; }

    local elevation_cmd="" temp_dir
    if [[ "${PACKAGE_MANAGER}" != "brew" ]]; then
        sudo-test || { log_error "Administrator privileges required"; return 1; }
        elevation_cmd="$(get-elevation-command)" || return 1
    fi
    temp_dir="$(mktemp -d)"

    case "${PACKAGE_MANAGER}" in
        apt)
            local deb_url="https://bitwarden.com/download/?app=desktop&platform=linux&variant=deb"
            _download_file_robust "${deb_url}" "${temp_dir}/bitwarden.deb" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} dpkg -i "${temp_dir}/bitwarden.deb" || true
            ${elevation_cmd} apt-get install -f -y
            ;;
        dnf|yum)
            local rpm_url="https://bitwarden.com/download/?app=desktop&platform=linux&variant=rpm"
            _download_file_robust "${rpm_url}" "${temp_dir}/bitwarden.rpm" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} "${PACKAGE_MANAGER}" install -y "${temp_dir}/bitwarden.rpm"
            ;;
        zypper)
            local rpm_url="https://bitwarden.com/download/?app=desktop&platform=linux&variant=rpm"
            _download_file_robust "${rpm_url}" "${temp_dir}/bitwarden.rpm" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} zypper install -y "${temp_dir}/bitwarden.rpm"
            ;;
        pacman)
            if command -v yay &>/dev/null; then
                yay -S --noconfirm bitwarden-bin
            else
                mkdir -p "${HOME}/Applications"
                local ai_url="https://bitwarden.com/download/?app=desktop&platform=linux&variant=appimage"
                _download_file_robust "${ai_url}" "${HOME}/Applications/Bitwarden.AppImage" || { rm -rf "${temp_dir}"; return 1; }
                chmod +x "${HOME}/Applications/Bitwarden.AppImage"
            fi
            ;;
        brew)
            brew install --cask bitwarden
            ;;
        *)
            if command -v flatpak &>/dev/null; then
                flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
                flatpak install -y flathub com.bitwarden.desktop
            else
                log_error "No supported install method found"; rm -rf "${temp_dir}"; return 1
            fi
            ;;
    esac

    rm -rf "${temp_dir}"
    log_info "Bitwarden installation complete"
}


# ── Bitwarden CLI (bw) install ────────────────────────────────────────────────
# This is the headless CLI tool, separate from the Bitwarden desktop app.
# Used by gpg-export-bitwarden and gpg-import-bitwarden.
#
# After installing, authenticate with:
#   bw login
#   export BW_SESSION=$(bw unlock --raw)
# ── Internal helper: ensure npm is available, preferring nvm ─────────────────

install-bw-cli() {
    log_info "Installing or updating Bitwarden CLI (bw)..."

    case "${DOTFILES_OS}" in
        Mac)
            if command -v brew &>/dev/null; then
                brew install bitwarden-cli
            else
                log_error "Homebrew required on macOS for Bitwarden CLI"
                return 1
            fi
            ;;
        Linux)
            if _ensure_npm; then
                _npm_global_install "@bitwarden/cli" || { log_error "Bitwarden CLI npm install failed"; return 1; }
            else
                # npm unavailable and could not be installed — pre-built binary
                log_info "npm unavailable — downloading pre-built binary from GitHub..."
                local arch bw_arch
                arch="$(uname -m)"
                case "${arch}" in
                    x86_64)  bw_arch="linux-x64"   ;;
                    aarch64) bw_arch="linux-arm64" ;;
                    *) log_error "Unsupported architecture: ${arch}"; return 1 ;;
                esac

                local version
                version="$(curl -s https://api.github.com/repos/bitwarden/clients/releases \
                    | grep '"tag_name"' | grep '"cli-' | head -1 \
                    | sed -E 's/.*"cli-v([0-9.]+)".*/\1/')"
                [[ -z "${version}" ]] && { log_error "Could not determine bw CLI version"; return 1; }

                local tmp_dir; tmp_dir="$(mktemp -d)"
                local zip_url="https://github.com/bitwarden/clients/releases/download/cli-v${version}/bw-${bw_arch}-${version}.zip"
                _download_file_robust "${zip_url}" "${tmp_dir}/bw.zip" || { rm -rf "${tmp_dir}"; return 1; }
                unzip -q "${tmp_dir}/bw.zip" -d "${tmp_dir}"
                mkdir -p "${HOME}/.local/bin"
                install -m 755 "${tmp_dir}/bw" "${HOME}/.local/bin/bw"
                rm -rf "${tmp_dir}"
                log_info "bw CLI installed to ~/.local/bin/bw"
            fi
            ;;
        *)
            log_error "Unsupported OS for Bitwarden CLI install"
            return 1
            ;;
    esac

    if command -v bw &>/dev/null; then
        log_info "Bitwarden CLI installed: $(bw --version)"
        echo
        echo "  To authenticate:"
        echo "    bw login"
        echo "    export BW_SESSION=\$(bw unlock --raw)"
        echo
        echo "  To use with GPG exports:"
        echo "    gpg-export-bitwarden <fingerprint>"
    else
        log_warn "bw not found in PATH after install. You may need to restart your shell."
        log_warn "Expected location: ${HOME}/.local/bin/bw"
    fi
}


# ── 1Password desktop app install ────────────────────────────────────────────
# Official vendor repos per distro — package manager handles updates.
# GPG key: 3FEF9748469ADBE15DA7CA80AC2D62742012EA22

_1password-install-debian() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    # Add GPG key
    ${elevation_cmd} mkdir -p /usr/share/keyrings
    curl -sS https://downloads.1password.com/linux/keys/1password.asc \
        | ${elevation_cmd} gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg

    # Add apt repo
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
        | ${elevation_cmd} tee /etc/apt/sources.list.d/1password.list > /dev/null

    # Add debsig-verify policy
    ${elevation_cmd} mkdir -p /etc/debsig/policies/AC2D62742012EA22/
    curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol \
        | ${elevation_cmd} tee /etc/debsig/policies/AC2D62742012EA22/1password.pol > /dev/null
    ${elevation_cmd} mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
    curl -sS https://downloads.1password.com/linux/keys/1password.asc \
        | ${elevation_cmd} gpg --dearmor \
            --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg

    ${elevation_cmd} apt-get update
    ${elevation_cmd} apt-get install -y 1password
}


_1password-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1

    # Import GPG key
    ${elevation_cmd} rpm --import https://downloads.1password.com/linux/keys/1password.asc

    # Add yum/dnf repo
    ${elevation_cmd} sh -c 'echo -e "[1password]\nname=1Password Stable Channel\nbaseurl=https://downloads.1password.com/linux/rpm/stable/\$basearch\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=\"https://downloads.1password.com/linux/keys/1password.asc\"" > /etc/yum.repos.d/1password.repo'

    if command -v dnf &>/dev/null; then
        ${elevation_cmd} dnf install -y 1password
    else
        ${elevation_cmd} yum install -y 1password
    fi
}


_1password-install-suse() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1

    ${elevation_cmd} rpm --import https://downloads.1password.com/linux/keys/1password.asc
    if ! zypper lr 2>/dev/null | grep -qi '1password'; then
        ${elevation_cmd} zypper addrepo https://downloads.1password.com/linux/rpm/stable/x86_64 1password
    else
        log_info "1Password zypper repo already present"
    fi
    ${elevation_cmd} zypper --gpg-auto-import-keys refresh
    ${elevation_cmd} zypper install -y 1password
}


_1password-install-arch() {
    # AUR package maintained by community
    if command -v yay &>/dev/null; then
        # Import signing key first
        gpg --receive-keys 3FEF9748469ADBE15DA7CA80AC2D62742012EA22 2>/dev/null || true
        yay -S --noconfirm 1password
    else
        log_info "yay not found — cloning 1password AUR package manually..."
        gpg --receive-keys 3FEF9748469ADBE15DA7CA80AC2D62742012EA22 2>/dev/null || true
        local tmp_dir; tmp_dir="$(mktemp -d)"
        git clone https://aur.archlinux.org/1password.git "${tmp_dir}/1password" \
            || { log_error "Failed to clone AUR package"; rm -rf "${tmp_dir}"; return 1; }
        ( cd "${tmp_dir}/1password" && makepkg -si --noconfirm )
        rm -rf "${tmp_dir}"
    fi
}


_1password-install-mac() {
    command -v brew &>/dev/null || { log_error "Homebrew required on macOS"; return 1; }
    if command -v 1password &>/dev/null; then
        brew upgrade --cask 1password
    else
        brew install --cask 1password
    fi
}


install-1password() {
    log_info "Installing or updating 1Password desktop app..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    case "${DOTFILES_OS}" in
        Mac)
            _1password-install-mac
            ;;
        Linux)
            case "${DOTFILES_DISTRO}" in
                rhel)   _1password-install-rhel   ;;
                debian) _1password-install-debian ;;
                suse)   _1password-install-suse   ;;
                arch)   _1password-install-arch   ;;
                *)
                    # Flatpak fallback for unknown distros
                    if command -v flatpak &>/dev/null; then
                        log_info "Unknown distro — installing via Flatpak..."
                        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
                        flatpak install -y flathub com.onepassword.OnePassword
                        log_warn "Flatpak install: SSH agent and system auth integration are not available."
                    else
                        log_error "Unknown distro and flatpak not available — cannot install 1Password"
                        return 1
                    fi
                    ;;
            esac
            ;;
        *)
            log_error "Unsupported OS for 1Password install"; return 1
            ;;
    esac

    if command -v 1password &>/dev/null; then
        log_info "1Password installed: $(1password --version 2>/dev/null | head -1)"
    else
        log_info "1Password installation complete. Launch from your application menu."
    fi
    echo
    echo "  To enable CLI integration, open 1Password → Settings → Developer"
    echo "  and enable 'Integrate with 1Password CLI'."
}


# ── 1Password CLI (op) install ────────────────────────────────────────────────
# Official vendor repos per distro, matching the desktop app repo setup.
# The 'op' binary needs the onepassword-cli group + setgid for biometric unlock
# via the 1Password desktop app integration.
#
# After installing, enable the desktop app integration:
#   1Password → Settings → Developer → Integrate with 1Password CLI
# Then authenticate:
#   op signin
#   op vault list

_op-install-debian() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    ${elevation_cmd} mkdir -p /usr/share/keyrings
    curl -sS https://downloads.1password.com/linux/keys/1password.asc \
        | ${elevation_cmd} gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
        | ${elevation_cmd} tee /etc/apt/sources.list.d/1password.list > /dev/null

    ${elevation_cmd} apt-get update
    ${elevation_cmd} apt-get install -y 1password-cli
}


_op-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1

    # Repo may already exist from install-1password; rpm --import is idempotent
    ${elevation_cmd} rpm --import https://downloads.1password.com/linux/keys/1password.asc

    if [[ ! -f /etc/yum.repos.d/1password.repo ]]; then
        ${elevation_cmd} sh -c 'echo -e "[1password]\nname=1Password Stable Channel\nbaseurl=https://downloads.1password.com/linux/rpm/stable/\$basearch\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=\"https://downloads.1password.com/linux/keys/1password.asc\"" > /etc/yum.repos.d/1password.repo'
    fi

    if command -v dnf &>/dev/null; then
        ${elevation_cmd} dnf install -y 1password-cli
    else
        ${elevation_cmd} yum install -y 1password-cli
    fi
}


_op-install-suse() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1

    ${elevation_cmd} rpm --import https://downloads.1password.com/linux/keys/1password.asc
    if ! zypper lr 2>/dev/null | grep -qi '1password'; then
        ${elevation_cmd} zypper addrepo https://downloads.1password.com/linux/rpm/stable/x86_64 1password
    fi
    ${elevation_cmd} zypper --gpg-auto-import-keys refresh
    ${elevation_cmd} zypper install -y 1password-cli
}


_op-install-mac() {
    command -v brew &>/dev/null || { log_error "Homebrew required on macOS"; return 1; }
    if command -v op &>/dev/null; then
        brew upgrade --cask 1password-cli
    else
        brew install --cask 1password-cli
    fi
}


# Root-free binary fallback — installs to ~/.local/bin.
# Note: without the onepassword-cli group + setgid the desktop app biometric
# integration won't work, but the CLI itself is fully functional.
_op-install-binary() {
    log_info "Installing op binary to ~/.local/bin (no root required)..."
    command -v unzip &>/dev/null || { log_error "unzip is required"; return 1; }

    local arch op_arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64)        op_arch="amd64" ;;
        aarch64|arm64) op_arch="arm64" ;;
        i386|i686)     op_arch="386"   ;;
        armv7l)        op_arch="arm"   ;;
        *) log_error "Unsupported architecture: ${arch}"; return 1 ;;
    esac

    local version
    version="$(curl -s https://app-updates.agilebits.com/product_history/CLI2 \
        | grep -oP '(?<=<li class="[^"]*"><span class="version">)[^<]+' \
        | head -1)"
    # Fallback: use the stable direct-download URL which always points at latest
    local zip_url="https://cache.agilebits.com/dist/1P/op2/pkg/v${version}/op_linux_${op_arch}_v${version}.zip"
    if [[ -z "${version}" ]]; then
        log_warn "Could not determine op version — using latest stable download URL"
        zip_url="https://downloads.1password.com/linux/tar/stable/x86_64/1password-latest.tar.gz"
        log_error "Binary fallback requires version detection — install via package manager instead"
        return 1
    fi

    local tmp_dir; tmp_dir="$(mktemp -d)"
    _download_file_robust "${zip_url}" "${tmp_dir}/op.zip" || { rm -rf "${tmp_dir}"; return 1; }
    unzip -q "${tmp_dir}/op.zip" -d "${tmp_dir}"

    mkdir -p "${HOME}/.local/bin"
    install -m 755 "${tmp_dir}/op" "${HOME}/.local/bin/op"
    rm -rf "${tmp_dir}"

    log_info "op installed to ~/.local/bin/op"
    log_warn "Installed without onepassword-cli group — biometric unlock via desktop app will not work."
    log_warn "For full integration, re-install via package manager: install-op-cli"
    [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]] \
        && log_warn "${HOME}/.local/bin is not on PATH — add it in env/90-local.sh"
}


install-op-cli() {
    log_info "Installing or updating 1Password CLI (op)..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    case "${DOTFILES_OS}" in
        Mac)
            _op-install-mac
            ;;
        Linux)
            local ok=1
            case "${DOTFILES_DISTRO}" in
                rhel)   _op-install-rhel   && ok=0 ;;
                debian) _op-install-debian && ok=0 ;;
                suse)   _op-install-suse   && ok=0 ;;
                *)
                    log_warn "No vendor repo for distro '${DOTFILES_DISTRO}' — using binary install"
                    _op-install-binary && ok=0
                    ;;
            esac
            [[ "${ok}" -ne 0 ]] && { log_error "1Password CLI install failed"; return 1; }
            ;;
        *)
            log_error "Unsupported OS for op CLI install"; return 1
            ;;
    esac

    if command -v op &>/dev/null; then
        log_info "1Password CLI installed: $(op --version 2>/dev/null | head -1)"
        echo
        echo "  Enable desktop app integration first:"
        echo "    1Password → Settings → Developer → Integrate with 1Password CLI"
        echo
        echo "  Then authenticate:"
        echo "    op signin"
        echo "    op vault list"
    else
        log_warn "op not found in PATH after install. Restart your shell or check ~/.local/bin."
    fi
}


#!/usr/bin/env bash
# lazy/installers-system.sh — system-level package infrastructure (snapd, flatpak)
# shellcheck disable=SC1091
source "${SHELL_CONFIG_DIR:-$HOME/.config/shell}/lazy/installers-common.sh"


# ── snapd install ─────────────────────────────────────────────────────────────
install-snapd() {
    log_info "Installing or configuring snapd..."
    [[ "${DOTFILES_OS}" != "Linux" ]] && { log_error "snapd is Linux-only"; return 1; }

    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    local snap_present=false
    command -v snap &>/dev/null && snap_present=true

    # ── Package install ───────────────────────────────────────────────────────
    if [[ "${snap_present}" == "false" ]]; then
        case "${DOTFILES_DISTRO}" in
            rhel)
                if command -v dnf &>/dev/null; then
                    ${elevation_cmd} dnf install -y epel-release 2>/dev/null || true
                    ${elevation_cmd} dnf install -y snapd
                elif command -v yum &>/dev/null; then
                    ${elevation_cmd} yum install -y epel-release 2>/dev/null || true
                    ${elevation_cmd} yum install -y snapd
                else
                    log_error "snapd: neither dnf nor yum found"; return 1
                fi
                ;;
            debian)
                ${elevation_cmd} apt-get update
                ${elevation_cmd} apt-get install -y snapd
                ;;
            suse)
                # Tumbleweed and Leap use different repo URLs; Tumbleweed also
                # needs snapd.apparmor enabled.
                local os_name opensuse_repo_url
                os_name="$(. /etc/os-release 2>/dev/null && echo "${NAME:-}")"

                if echo "${os_name}" | grep -qi 'tumbleweed'; then
                    opensuse_repo_url="https://download.opensuse.org/repositories/system:/snappy/openSUSE_Tumbleweed/"
                else
                    # Leap (and any other SUSE variant) — version-specific URL
                    local opensuse_ver
                    opensuse_ver="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-15.6}")"
                    opensuse_repo_url="https://download.opensuse.org/repositories/system:/snappy/openSUSE_Leap_${opensuse_ver}/"
                fi

                if ! zypper lr 2>/dev/null | grep -qi 'snappy'; then
                    ${elevation_cmd} zypper addrepo --refresh "${opensuse_repo_url}" snappy
                    ${elevation_cmd} zypper --gpg-auto-import-keys refresh snappy
                else
                    log_info "snapd: snappy repo already present"
                fi
                ${elevation_cmd} zypper install -y snapd
                ;;
            arch)
                if command -v yay &>/dev/null; then
                    yay -S --noconfirm snapd
                else
                    log_info "snapd: yay not found — cloning snapd from AUR..."
                    local tmp_dir; tmp_dir="$(mktemp -d)"
                    git clone https://aur.archlinux.org/snapd.git "${tmp_dir}/snapd" \
                        || { log_error "Failed to clone snapd AUR package"; rm -rf "${tmp_dir}"; return 1; }
                    ( cd "${tmp_dir}/snapd" && makepkg -si --noconfirm )
                    rm -rf "${tmp_dir}"
                fi
                ;;
            *)
                log_error "snapd: unsupported distro (${DOTFILES_DISTRO})"; return 1
                ;;
        esac
        command -v snap &>/dev/null && snap_present=true
    else
        log_info "snapd: snap binary already present — skipping package install"
    fi

    [[ "${snap_present}" == "false" ]] \
        && { log_error "snapd: snap not on PATH after install"; return 1; }

    # ── systemd socket ────────────────────────────────────────────────────────
    if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null; then
        if ! systemctl is-enabled snapd.socket &>/dev/null; then
            log_info "snapd: enabling snapd.socket..."
            ${elevation_cmd} systemctl enable --now snapd.socket
        else
            log_info "snapd: snapd.socket already enabled"
        fi

        # Tumbleweed requires snapd.apparmor in addition to snapd.socket
        local os_name
        os_name="$(. /etc/os-release 2>/dev/null && echo "${NAME:-}")"
        if echo "${os_name}" | grep -qi 'tumbleweed'; then
            if ! systemctl is-enabled snapd.apparmor &>/dev/null; then
                log_info "snapd: enabling snapd.apparmor (Tumbleweed)..."
                ${elevation_cmd} systemctl enable --now snapd.apparmor
            else
                log_info "snapd: snapd.apparmor already enabled"
            fi
        fi
    else
        log_warn "snapd: systemd not active — start snapd.socket manually when available"
    fi

    # ── Classic confinement symlink ───────────────────────────────────────────
    if [[ ! -e /snap ]]; then
        log_info "snapd: creating /snap symlink for classic confinement..."
        ${elevation_cmd} ln -s /var/lib/snapd/snap /snap
    else
        log_info "snapd: /snap already exists"
    fi

    log_info "snapd ready: $(snap version 2>/dev/null | grep snapd | awk '{print $2}')"
    log_info "You may need to log out and back in for PATH changes to take effect."
}


# ── flatpak install ───────────────────────────────────────────────────────────
install-flatpak() {
    log_info "Installing flatpak and configuring Flathub..."
    [[ "${DOTFILES_OS}" != "Linux" ]] && { log_error "flatpak is Linux-only"; return 1; }

    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1

    # ── Package install (skip if flatpak already present) ─────────────────────
    if ! command -v flatpak &>/dev/null; then
        case "${DOTFILES_DISTRO}" in
            rhel)
                if command -v dnf &>/dev/null; then
                    ${elevation_cmd} dnf install -y flatpak
                else
                    ${elevation_cmd} yum install -y flatpak
                fi
                ;;
            debian)
                ${elevation_cmd} apt-get update
                ${elevation_cmd} apt-get install -y flatpak
                ${elevation_cmd} apt-get install -y gnome-software-plugin-flatpak 2>/dev/null || true
                ;;
            suse)
                ${elevation_cmd} zypper install -y flatpak
                ;;
            arch)
                ${elevation_cmd} pacman -S --noconfirm flatpak
                ;;
            *)
                log_error "flatpak: unsupported distro (${DOTFILES_DISTRO})"; return 1
                ;;
        esac
    else
        log_info "flatpak: already installed ($(flatpak --version))"
    fi

    command -v flatpak &>/dev/null \
        || { log_error "flatpak not on PATH after install"; return 1; }

    # ── Flathub remote (only add if not already configured) ───────────────────
    # Try user-level first (no elevation for subsequent flatpak install calls).
    # Fall back to system-level for environments where user remotes aren't
    # recognised by the desktop software centre.
    local flathub_url="https://dl.flathub.org/repo/flathub.flatpakrepo"

    if flatpak remote-list --user 2>/dev/null | grep -q 'flathub' \
        || flatpak remote-list --system 2>/dev/null | grep -q 'flathub'; then
        log_info "flatpak: Flathub remote already configured"
    else
        log_info "flatpak: adding Flathub remote (user scope)..."
        if ! flatpak remote-add --user --if-not-exists flathub "${flathub_url}" 2>/dev/null; then
            log_warn "flatpak: user-scope remote add failed — trying system scope..."
            ${elevation_cmd} flatpak remote-add --if-not-exists flathub "${flathub_url}"
        fi
    fi

    log_info "flatpak $(flatpak --version) ready with Flathub configured."
    log_info "A session restart may be required before installing apps."
}

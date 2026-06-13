#!/usr/bin/env bash
# lazy/installers-prompt.sh
# shellcheck disable=SC1091
source "${SHELL_CONFIG_DIR:-$HOME/.config/shell}/lazy/installers-common.sh"


# ── Oh-My-Posh install ────────────────────────────────────────────────────────

_omp-install-linux() {
    if command -v oh-my-posh &>/dev/null; then
        if oh-my-posh update; then
            log_info "oh-my-posh updated successfully"
            return 0
        else
            log_error "oh-my-posh update failed. Check your installation or try updating manually."
            return 1
        fi
    fi

    if command -v curl &>/dev/null; then
        curl -s https://ohmyposh.dev/install.sh | bash
    elif command -v wget &>/dev/null; then
        wget -qO- https://ohmyposh.dev/install.sh | bash
    else
        log_error "curl or wget required to install oh-my-posh"
        return 1
    fi
}


_omp-install-macos() {
    if command -v oh-my-posh &>/dev/null && command -v brew &>/dev/null; then
        if brew update && brew upgrade oh-my-posh; then
            log_info "oh-my-posh updated successfully via Homebrew"
            return 0
        elif oh-my-posh update; then
            log_info "oh-my-posh updated successfully via built-in updater"
            return 0
        else
            log_error "oh-my-posh update failed. Check your installation or try updating manually."
            return 1
        fi
    fi

    if command -v brew &>/dev/null; then
        brew install jandedobbeleer/oh-my-posh/oh-my-posh
    else
        _omp-install-linux
    fi
}


install-oh-my-posh() {
    case "${DOTFILES_OS}" in
        Linux) _omp-install-linux ;;
        Mac)   _omp-install-macos ;;
        *)     log_error "Unsupported OS for oh-my-posh install"; return 1 ;;
    esac
}


# ── starship install/update ─────────────────────────────────────────────────

_starship-install-linux() {
    local install_dir="${HOME}/.local/bin"
    mkdir -p "${install_dir}"
    # The official script overwrites the binary in place, so this call
    # serves as both the initial install and subsequent updates.
    if curl -sS https://starship.rs/install.sh | sh -s -- -y -b "${install_dir}"; then
        log_info "starship installed/updated in ${install_dir}"
    else
        log_error "starship install/update failed. Check your installation or try updating manually."
        return 1
    fi
}


_starship-install-macos() {
    if command -v starship &>/dev/null; then
        brew upgrade starship
    else
        brew install starship
    fi
}


install-starship() {
    case "${DOTFILES_OS}" in
        Linux) _starship-install-linux ;;
        Mac)   _starship-install-macos ;;
        *)     log_error "Unsupported OS for starship install"; return 1 ;;
    esac
}


# ── oh-my-zsh install ─────────────────────────────────────────────────────────

install-oh-my-zsh() {
    if command -v omz &>/dev/null; then
        if omz update; then
            log_info "oh-my-zsh updated successfully"
            return 0
        else
            log_error "oh-my-zsh update failed. Check your installation or try updating manually."
            return 1
        fi
    fi

    if command -v curl &>/dev/null; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    elif command -v wget &>/dev/null; then
        sh -c "$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)"
    elif command -v fetch &>/dev/null; then
        sh -c "$(fetch -o - https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    else
        log_error "curl or wget required to install oh-my-zsh"
        return 1
    fi
}


# ── zsh install ───────────────────────────────────────────────────────────────

_zsh-install-dnf() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    log_info "Installing zsh via dnf..."
    ${elevation_cmd} dnf install -y zsh
}


_zsh-install-apt() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    log_info "Installing zsh via apt..."
    ${elevation_cmd} apt-get update && ${elevation_cmd} apt-get install -y zsh
}


_zsh-install-zypper() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    log_info "Installing zsh via zypper..."
    ${elevation_cmd} zypper install -y zsh
}


_zsh-install-pacman() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    log_info "Installing zsh via pacman..."
    ${elevation_cmd} pacman -S --noconfirm zsh
}


_zsh-install-brew() {
    log_info "Installing zsh via brew..."
    brew install zsh
}


install-zsh() {
    if command -v zsh &>/dev/null; then
        log_info "zsh is already installed ($(zsh --version))"
        return 0
    fi

    case "${DOTFILES_DISTRO}" in
        rhel)   _zsh-install-dnf    ;;
        debian) _zsh-install-apt    ;;
        suse)   _zsh-install-zypper ;;
        arch)   _zsh-install-pacman ;;
        *)
            if [[ "${DOTFILES_OS}" == "Mac" ]]; then
                _zsh-install-brew
            else
                log_error "install-zsh: unsupported distro '${DOTFILES_DISTRO}' — install zsh manually"
                return 1
            fi
            ;;
    esac || return 1

    log_info "zsh installed. To set as your default shell, run: install-zsh-default-shell"
}


install-zsh-default-shell() {
    if ! command -v zsh &>/dev/null; then
        log_error "zsh is not installed — run install-zsh first"
        return 1
    fi

    local zsh_path; zsh_path="$(command -v zsh)"
    if [[ "${SHELL}" == "${zsh_path}" ]]; then
        log_info "zsh is already your default shell"
        return 0
    fi

    # Ensure zsh is in /etc/shells (required for chsh)
    if ! grep -qxF "${zsh_path}" /etc/shells 2>/dev/null; then
        log_info "Adding ${zsh_path} to /etc/shells..."
        local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
        echo "${zsh_path}" | ${elevation_cmd} tee -a /etc/shells >/dev/null
    fi

    log_info "Changing default shell to ${zsh_path}..."
    chsh -s "${zsh_path}"
    log_info "Default shell changed. Log out and back in (or start a new session) to apply."
}


# ── zsh plugin install ────────────────────────────────────────────────────────
# Installs zsh-autosuggestions and zsh-syntax-highlighting.
# Delivery method, in priority order:
#   1. Distro package manager    — system packages where available
#   2. Standalone git clone      — fallback to ~/.local/share/zsh/plugins/

_zsh-plugins-install-packages-dnf() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} dnf install -y zsh-autosuggestions zsh-syntax-highlighting
}


_zsh-plugins-install-packages-apt() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} apt-get update && \
        ${elevation_cmd} apt-get install -y zsh-autosuggestions zsh-syntax-highlighting
}


_zsh-plugins-install-packages-zypper() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} zypper install -y zsh-autosuggestions zsh-syntax-highlighting
}


_zsh-plugins-install-packages-pacman() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} pacman -S --noconfirm zsh-autosuggestions zsh-syntax-highlighting
}


_zsh-plugins-install-packages-brew() {
    brew install zsh-autosuggestions zsh-syntax-highlighting
}


_zsh-plugins-install-standalone() {
    local plugin_dir="${HOME}/.local/share/zsh/plugins"
    mkdir -p "${plugin_dir}"

    log_info "Installing zsh plugins to ${plugin_dir}..."

    if [[ ! -d "${plugin_dir}/zsh-autosuggestions" ]]; then
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
            "${plugin_dir}/zsh-autosuggestions" \
            && log_info "zsh-autosuggestions cloned" \
            || { log_error "Failed to clone zsh-autosuggestions"; return 1; }
    else
        log_info "zsh-autosuggestions already present"
    fi

    if [[ ! -d "${plugin_dir}/zsh-syntax-highlighting" ]]; then
        git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
            "${plugin_dir}/zsh-syntax-highlighting" \
            && log_info "zsh-syntax-highlighting cloned" \
            || { log_error "Failed to clone zsh-syntax-highlighting"; return 1; }
    else
        log_info "zsh-syntax-highlighting already present"
    fi

    log_info "Plugins installed. Reload your shell to activate."
}


install-zsh-plugins() {
    if [[ "${DOTFILES_SHELL}" != "zsh" ]]; then
        log_error "install-zsh-plugins: must be run from zsh"
        return 1
    fi

    if ! command -v zsh &>/dev/null; then
        log_error "install-zsh-plugins: zsh not found — run install-zsh first"
        return 1
    fi

    local _pkg_installed=false
    case "${DOTFILES_DISTRO}" in
        rhel)   _zsh-plugins-install-packages-dnf    && _pkg_installed=true ;;
        debian) _zsh-plugins-install-packages-apt    && _pkg_installed=true ;;
        suse)   _zsh-plugins-install-packages-zypper && _pkg_installed=true ;;
        arch)   _zsh-plugins-install-packages-pacman && _pkg_installed=true ;;
        *)
            if [[ "${DOTFILES_OS}" == "Mac" ]]; then
                _zsh-plugins-install-packages-brew && _pkg_installed=true
            fi
            ;;
    esac

    if [[ "${_pkg_installed}" == "true" ]]; then
        log_info "Plugins installed via package manager. Reload your shell to activate."
        return 0
    fi

    log_info "Package manager install unavailable — falling back to git clone..."
    _zsh-plugins-install-standalone
}


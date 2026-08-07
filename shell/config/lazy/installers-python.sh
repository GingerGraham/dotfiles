#!/usr/bin/env bash
# lazy/installers-python.sh
# A dedicated group file for Python tooling, anticipating more of it beyond
# uv — see docs/shell-config.md for the lazy/installers-*.sh split rationale.
# shellcheck disable=SC1091
source "${SHELL_CONFIG_DIR:-$HOME/.config/shell}/lazy/installers-common.sh"


# ── uv install ────────────────────────────────────────────────────────────────
#
# Astral's official standalone installer, run with UV_NO_MODIFY_PATH=1.
#
# UV_NO_MODIFY_PATH is load-bearing, not optional. By default the installer
# appends PATH exports to every shell profile it finds. Our ~/.bashrc /
# ~/.zshrc are managed symlinks into the dotfiles repo, so an unguarded run
# writes uncommitted changes into the working tree and blocks the
# external-sync timer — the exact failure we had to clean up after with
# _restore_managed_shell_files for nvm. Setting the variable prevents the
# problem rather than repairing it after the fact.
#
# UV_UNMANAGED_INSTALL is deliberately NOT used — it disables `uv self
# update`, which is the mechanism _update_uv (lazy/maintenance.sh) depends on
# to keep uv current.
#
# No UV_INSTALL_DIR override: the installer's default — the XDG "executable
# directory", ~/.local/bin on both Linux and macOS — is already on PATH via
# env/00-core.sh.

# _uv_packaged_version — non-empty if a package-manager-installed uv is
# present, via the package database (not `command -v`, which ~/.local/bin
# would shadow once the standalone binary exists).
_uv_packaged_version() {
    local packaged=""
    if [[ "${DOTFILES_OS}" == "Mac" ]]; then
        command -v brew &>/dev/null && brew list --versions uv &>/dev/null \
            && packaged="$(brew list --versions uv 2>/dev/null)"
    else
        case "${DOTFILES_DISTRO}" in
            rhel|suse)
                command -v rpm &>/dev/null && rpm -q uv &>/dev/null \
                    && packaged="$(rpm -q uv 2>/dev/null)"
                ;;
            debian)
                command -v dpkg &>/dev/null && dpkg -s uv &>/dev/null \
                    && packaged="$(dpkg -s uv 2>/dev/null | awk -F': ' '/^Version:/{print $2}')"
                ;;
            arch)
                command -v pacman &>/dev/null && pacman -Q uv &>/dev/null \
                    && packaged="$(pacman -Q uv 2>/dev/null)"
                ;;
        esac
    fi
    printf '%s' "${packaged}"
}

install-uv() {
    log_info "Installing or updating uv..."

    local rc
    if command -v curl &>/dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
        rc=$?
    elif command -v wget &>/dev/null; then
        wget -qO- https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
        rc=$?
    else
        log_error "curl or wget is required to install uv"
        return 1
    fi
    if [[ ${rc} -ne 0 ]]; then
        log_error "uv installer failed"
        return 1
    fi

    if command -v uv &>/dev/null; then
        log_info "uv installed: $(uv --version 2>/dev/null)"
    else
        log_warn "uv not found on PATH after install. Restart your shell or check ~/.local/bin."
    fi

    local packaged; packaged="$(_uv_packaged_version)"
    if [[ -n "${packaged}" ]]; then
        log_warn "A package-manager-installed uv was also found: ${packaged}"
        log_warn "The standalone binary in ~/.local/bin takes PATH precedence and is the one 'uv self update' manages."
    fi

    echo
    echo "  uv is a fast Python package and project manager. Common commands:"
    echo "    uv venv                # create a virtual environment"
    echo "    uv pip install <pkg>   # install a package"
    echo "    uvx <tool>             # run a tool without installing it"
}

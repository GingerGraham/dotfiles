#!/usr/bin/env bash
# lazy/installers-ai.sh
# shellcheck disable=SC1091
source "${SHELL_CONFIG_DIR:-$HOME/.config/shell}/lazy/installers-common.sh"


# ── GitHub Copilot CLI install ────────────────────────────────────────────────
# npm package @github/copilot — requires Node.js 22+.
install-copilot-cli() {
    log_info "Installing or updating GitHub Copilot CLI (@github/copilot)..."
    _ensure_npm || { log_error "npm is required for the Copilot CLI. Install Node first with: install-nvm"; return 1; }

    if ! _node_version_at_least 22; then
        log_warn "Copilot CLI requires Node.js 22+. Detected: $(node --version 2>/dev/null || echo none)."
        log_warn "Get a current Node with: install-nvm   (then re-run install-copilot-cli)"
        return 1
    fi

    _npm_global_install "@github/copilot" || { log_error "Copilot CLI install failed"; return 1; }

    if command -v copilot &>/dev/null; then
        log_info "Copilot CLI installed: $(copilot --version 2>/dev/null | head -1)"
        echo
        echo "  Launch and authenticate with your GitHub account:"
        echo "    copilot"
        echo "  Requires an active GitHub Copilot subscription."
    else
        log_warn "copilot not found in PATH after install. Restart your shell or check ~/.local/bin."
    fi
}


# ── Claude Code install ───────────────────────────────────────────────────────
# Native installer preferred (no Node dependency, self-updating); npm fallback.
_claude_post_install() {
    if command -v claude &>/dev/null; then
        log_info "Claude Code installed: $(claude --version 2>/dev/null | head -1)"
    else
        log_info "Claude Code installed to ~/.local/bin/claude"
        log_warn "Restart your shell or add ~/.local/bin to PATH if 'claude' is not found."
    fi
    echo
    echo "  Launch and authenticate (opens a browser on first run):"
    echo "    claude"
    echo "  Requires a Claude Pro/Max plan or an Anthropic Console (API) account."
}


install-claude-code() {
    log_info "Installing or updating Claude Code..."

    case "${DOTFILES_OS}" in
        Linux|Mac)
            if command -v curl &>/dev/null; then
                log_info "Using the native installer (no Node.js required, self-updating)..."
                if curl -fsSL https://claude.ai/install.sh | bash; then
                    if command -v claude &>/dev/null || [[ -x "${HOME}/.local/bin/claude" ]]; then
                        _claude_post_install
                        return 0
                    fi
                    log_warn "Native installer ran but 'claude' is not on PATH yet — trying npm..."
                else
                    log_warn "Native installer failed — falling back to npm..."
                fi
            fi
            ;;
        *)
            log_warn "Unrecognised OS — attempting npm install..."
            ;;
    esac

    _ensure_npm || { log_error "Native install failed and npm is unavailable. Install Node with: install-nvm"; return 1; }
    if ! _node_version_at_least 18; then
        log_warn "Claude Code (npm) requires Node.js 18+. Detected: $(node --version 2>/dev/null || echo none)."
        log_warn "Get a current Node with: install-nvm   (then re-run install-claude-code)"
        return 1
    fi
    _npm_global_install "@anthropic-ai/claude-code" || { log_error "Claude Code npm install failed"; return 1; }
    _claude_post_install
}


# ── Antigravity CLI install ───────────────────────────────────────────────────
# Google's successor to Gemini CLI. Native curl-to-bash installer places the
# binary (agy) in ~/.local/bin. Config lives in ~/.gemini/ (retained from the
# Gemini CLI path for backwards compatibility).
#
# The upstream installer appends `export PATH="~/.local/bin:$PATH"` to every
# shell profile it finds. Since our RC files are managed symlinks into the
# dotfiles repo, that append would land as an uncommitted diff and block the
# sync timer. _restore_managed_shell_files (core/functions.sh) resets them;
# ~/.local/bin is already in PATH via env/00-core.sh.

_agy_post_install() {
    if command -v agy &>/dev/null; then
        log_info "Antigravity CLI installed: $(agy --version 2>/dev/null | head -1)"
    else
        log_info "Antigravity CLI installed to ~/.local/bin/agy"
        log_warn "Restart your shell or ensure ~/.local/bin is on PATH if 'agy' is not found."
    fi
    echo
    echo "  Launch and authenticate (opens a browser on first run):"
    echo "    agy"
    echo "  Config and conversation history are stored in ~/.gemini/"
}

install-antigravity() {
    log_info "Installing or updating Antigravity CLI..."

    case "${DOTFILES_OS}" in
        Linux|Mac)
            if ! command -v curl &>/dev/null; then
                log_error "curl is required to install Antigravity CLI. Install it via your package manager."
                return 1
            fi
            log_info "Running the upstream Antigravity CLI installer..."
            if curl -fsSL https://antigravity.google/cli/install.sh | bash; then
                _restore_managed_shell_files
                _agy_post_install
                return 0
            else
                log_error "Antigravity CLI installer script failed."
                return 1
            fi
            ;;
        *)
            log_error "Antigravity CLI install is only supported on Linux and macOS."
            return 1
            ;;
    esac
}

# Google is deprecating Gemini CLI in favour of Antigravity CLI.
# install-gemini-cli is kept as a convenience alias so muscle memory still works.
alias install-gemini-cli="install-antigravity"

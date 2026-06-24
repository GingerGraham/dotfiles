#!/usr/bin/env bash
# lazy/installers-dev.sh
# shellcheck disable=SC1091
source "${SHELL_CONFIG_DIR:-$HOME/.config/shell}/lazy/installers-common.sh"

# _gh_release_asset_url <api_response_json> <extended_regex_pattern>
# Extracts the first browser_download_url whose filename matches <pattern>.
# Splits each browser_download_url onto its own line before filtering — a
# GitHub/GitLab API response is one unbroken line, so a plain grep+sed here
# would let a greedy regex match across every asset in the release rather
# than just the one wanted, silently returning the wrong file.
_gh_release_asset_url() {
    local api_response="$1" pattern="$2"
    printf '%s' "${api_response}" \
        | grep -Eo '"browser_download_url": *"[^"]+"' \
        | sed -E 's/.*"(https[^"]+)"/\1/' \
        | grep -E "${pattern}" \
        | head -1
}

# _node_version_at_least <major>
# True if the active node's major version is >= <major>.
_node_version_at_least() {
    local want="$1" have
    command -v node &>/dev/null || return 1
    have="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
    [[ -n "${have}" && "${have}" =~ ^[0-9]+$ && "${have}" -ge "${want}" ]]
}


# ── GitHub CLI install ────────────────────────────────────────────────────────

# DNF5 (Fedora 41+) and DNF4 use different config-manager syntax.
_gh_dnf_is_v5() {
    command -v dnf5 &>/dev/null && return 0
    dnf --version 2>/dev/null | head -1 | grep -qiE 'dnf5|^5\.'
}


_gh-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    [[ "${elevation_cmd}" == "run0" ]] && log_warn "run0 detected — multiple prompts expected"
    local repo_url="https://cli.github.com/packages/rpm/gh-cli.repo"

    if command -v dnf &>/dev/null; then
        if _gh_dnf_is_v5; then
            log_info "Configuring GitHub CLI repo (dnf5)..."
            ${elevation_cmd} dnf install -y dnf5-plugins
            ${elevation_cmd} dnf config-manager addrepo --from-repofile="${repo_url}" || true
        else
            log_info "Configuring GitHub CLI repo (dnf4)..."
            ${elevation_cmd} dnf install -y 'dnf-command(config-manager)'
            ${elevation_cmd} dnf config-manager --add-repo "${repo_url}"
        fi
        ${elevation_cmd} dnf install -y gh
    elif command -v yum &>/dev/null; then
        log_info "Configuring GitHub CLI repo (yum)..."
        command -v yum-config-manager &>/dev/null || ${elevation_cmd} yum install -y yum-utils
        ${elevation_cmd} yum-config-manager --add-repo "${repo_url}"
        ${elevation_cmd} yum install -y gh
    else
        log_error "Neither dnf nor yum found"; return 1
    fi
}


_gh-install-debian() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    if ! command -v wget &>/dev/null; then
        log_info "Installing wget (required to fetch the keyring)..."
        ${elevation_cmd} apt-get update && ${elevation_cmd} apt-get install -y wget
    fi
    local keyring="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
    ${elevation_cmd} mkdir -p -m 755 /etc/apt/keyrings
    local tmp; tmp="$(mktemp)"
    if ! wget -nv -O "${tmp}" https://cli.github.com/packages/githubcli-archive-keyring.gpg; then
        log_error "Failed to download GitHub CLI keyring"; rm -f "${tmp}"; return 1
    fi
    ${elevation_cmd} install -m 644 "${tmp}" "${keyring}"
    rm -f "${tmp}"
    ${elevation_cmd} mkdir -p -m 755 /etc/apt/sources.list.d
    echo "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://cli.github.com/packages stable main" \
        | ${elevation_cmd} tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    ${elevation_cmd} apt-get update
    ${elevation_cmd} apt-get install -y gh
}


_gh-install-suse() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    local repo_url="https://cli.github.com/packages/rpm/gh-cli.repo"
    if zypper lr 2>/dev/null | grep -qi 'gh-cli'; then
        log_info "GitHub CLI zypper repo already present"
    else
        ${elevation_cmd} zypper addrepo "${repo_url}"
    fi
    ${elevation_cmd} zypper --gpg-auto-import-keys ref
    ${elevation_cmd} zypper install -y gh
}


_gh-install-arch() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} pacman -S --noconfirm github-cli
}


_gh-install-mac() {
    command -v brew &>/dev/null || { log_error "Homebrew required on macOS"; return 1; }
    if command -v gh &>/dev/null; then brew upgrade gh; else brew install gh; fi
}


# Distro-independent fallback: latest release tarball → ~/.local/bin/gh
_gh-install-tarball() {
    log_info "Falling back to a distro-independent binary install from GitHub releases..."
    command -v tar &>/dev/null || { log_error "tar is required for the fallback install"; return 1; }

    local api_response ver ver_num
    api_response="$(curl -s https://api.github.com/repos/cli/cli/releases/latest)"
    ver="$(printf '%s' "${api_response}" | grep '"tag_name":' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | head -1)"
    [[ -z "${ver}" ]] && { log_error "Could not determine latest gh version (GitHub API rate limit?)"; return 1; }
    ver_num="${ver#v}"

    local machine os arch ext
    machine="$(uname -m)"; os="$(uname -s)"
    case "${machine}" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_error "Unsupported architecture: ${machine}"; return 1 ;;
    esac
    case "${os}" in
        Linux)  os="linux";  ext="tar.gz" ;;
        Darwin) os="macOS";  ext="zip"    ;;
        *) log_error "Unsupported OS: ${os}"; return 1 ;;
    esac

    local asset="gh_${ver_num}_${os}_${arch}.${ext}"
    local url="https://github.com/cli/cli/releases/download/${ver}/${asset}"
    local tmp_dir; tmp_dir="$(mktemp -d)"

    log_info "Downloading ${asset}..."
    _download_file_robust "${url}" "${tmp_dir}/${asset}" || { rm -rf "${tmp_dir}"; return 1; }

    if [[ "${ext}" == "zip" ]]; then
        command -v unzip &>/dev/null || { log_error "unzip is required"; rm -rf "${tmp_dir}"; return 1; }
        unzip -q "${tmp_dir}/${asset}" -d "${tmp_dir}"
    else
        tar -xzf "${tmp_dir}/${asset}" -C "${tmp_dir}"
    fi

    local bin; bin="$(find "${tmp_dir}" -type f -path '*/bin/gh' | head -1)"
    [[ -z "${bin}" ]] && bin="$(find "${tmp_dir}" -type f -name gh -perm -u+x | head -1)"
    if [[ -z "${bin}" ]]; then
        log_error "gh binary not found in archive"; rm -rf "${tmp_dir}"; return 1
    fi
    mkdir -p "${HOME}/.local/bin"
    install -m 755 "${bin}" "${HOME}/.local/bin/gh"
    rm -rf "${tmp_dir}"
    log_info "gh installed to ~/.local/bin/gh"
    [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]] \
        && log_warn "${HOME}/.local/bin is not on PATH — add it in env/90-local.sh"
}


install-gh() {
    log_info "Installing or updating GitHub CLI (gh)..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    case "${DOTFILES_OS}" in
        Mac)
            _gh-install-mac
            ;;
        Linux)
            local ok=1
            case "${DOTFILES_DISTRO}" in
                rhel)   _gh-install-rhel   && ok=0 ;;
                debian) _gh-install-debian && ok=0 ;;
                suse)   _gh-install-suse   && ok=0 ;;
                arch)   _gh-install-arch   && ok=0 ;;
                *)      log_warn "Unknown distro (${DOTFILES_DISTRO}) — using distro-independent install" ;;
            esac
            [[ "${ok}" -ne 0 ]] && { _gh-install-tarball || return 1; }
            ;;
        *)
            log_error "Unsupported OS for gh install"; return 1
            ;;
    esac

    if command -v gh &>/dev/null; then
        log_info "GitHub CLI installed: $(gh --version 2>/dev/null | head -1)"
        echo
        echo "  Authenticate with:"
        echo "    gh auth login"
    else
        log_warn "gh not found in PATH after install. Restart your shell or check ~/.local/bin."
    fi
}

# ── GitLab CLI install ────────────────────────────────────────────────────────
# Fedora/RHEL: official dnf/yum repo package 'glab'.
# Arch: official 'extra/glab' via pacman.
# Debian/Ubuntu, openSUSE: no vendor apt/zypper repo exists, but GitLab attaches
#   native .deb/.rpm packages to every release — download + install directly
#   (same pattern as install-noteshub/install-opendeck).
# macOS: Homebrew — GitLab's own docs call this the officially supported
#   method for Linux too, hence its place in the fallback chain below.
# Fallback (native path failed, or distro unrecognised): Homebrew/Linuxbrew if
#   present, else the distro-independent release tarball.
#
# Snap is deliberately NOT used. glab ships as a strict-confinement snap, and
# strict snaps' only $HOME access (the "home" interface) cannot read or create
# hidden directories at all — confirmed as intentional snapd behaviour
# (https://bugs.launchpad.net/snapd/+bug/1979060). glab's config lives at
# ~/.config/glab-cli, a hidden directory, so the snap can never write it.
# (glab does support GLAB_CONFIG_DIR to relocate config somewhere non-hidden
# if you ever want the snap anyway — not worth the extra moving part here.)

_glab-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    if command -v dnf &>/dev/null; then
        ${elevation_cmd} dnf install -y glab
    elif command -v yum &>/dev/null; then
        ${elevation_cmd} yum install -y glab
    else
        log_error "Neither dnf nor yum found"; return 1
    fi
}


_glab-install-arch() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} pacman -S --noconfirm glab
}


# Shared: latest glab tag and arch suffix, used by the debian/suse/tarball paths.
_glab-latest-tag() {
    curl -s "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases?order_by=released_at&sort=desc&per_page=1" \
        | grep -o '"tag_name": *"[^"]*"' \
        | head -1 \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

_glab-arch-suffix() {
    case "$(uname -m)" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) log_error "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac
}


# Direct .deb download from the GitLab release — no apt repo exists for glab.
_glab-install-debian() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    local ver ver_num arch asset url tmp_dir
    ver="$(_glab-latest-tag)"; [[ -z "${ver}" ]] && { log_error "Could not determine latest glab version"; return 1; }
    ver_num="${ver#v}"
    arch="$(_glab-arch-suffix)" || return 1

    asset="glab_${ver_num}_linux_${arch}.deb"
    url="https://gitlab.com/gitlab-org/cli/-/releases/${ver}/downloads/${asset}"
    tmp_dir="$(mktemp -d)"

    log_info "Downloading ${asset}..."
    _download_file_robust "${url}" "${tmp_dir}/${asset}" || { rm -rf "${tmp_dir}"; return 1; }
    ${elevation_cmd} dpkg -i "${tmp_dir}/${asset}" || ${elevation_cmd} apt-get install -f -y
    rm -rf "${tmp_dir}"
}


# Direct .rpm download from the GitLab release — no zypper repo exists for glab.
_glab-install-suse() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    local ver ver_num arch asset url tmp_dir
    ver="$(_glab-latest-tag)"; [[ -z "${ver}" ]] && { log_error "Could not determine latest glab version"; return 1; }
    ver_num="${ver#v}"
    arch="$(_glab-arch-suffix)" || return 1

    asset="glab_${ver_num}_linux_${arch}.rpm"
    url="https://gitlab.com/gitlab-org/cli/-/releases/${ver}/downloads/${asset}"
    tmp_dir="$(mktemp -d)"

    log_info "Downloading ${asset}..."
    _download_file_robust "${url}" "${tmp_dir}/${asset}" || { rm -rf "${tmp_dir}"; return 1; }
    ${elevation_cmd} zypper install -y "${tmp_dir}/${asset}"
    rm -rf "${tmp_dir}"
}


_glab-install-brew() {
    command -v brew &>/dev/null || { log_error "Homebrew not found"; return 1; }
    if command -v glab &>/dev/null; then brew upgrade glab; else brew install glab; fi
}


_glab-install-mac() {
    _glab-install-brew
}


# Distro-independent fallback: latest release tarball → ~/.local/bin/glab
_glab-install-tarball() {
    log_info "Falling back to distro-independent binary from GitLab releases..."
    command -v tar &>/dev/null || { log_error "tar is required for the fallback install"; return 1; }

    local ver ver_num arch asset url tmp_dir bin
    ver="$(_glab-latest-tag)"; [[ -z "${ver}" ]] && { log_error "Could not determine latest glab version (GitLab API unavailable?)"; return 1; }
    ver_num="${ver#v}"
    arch="$(_glab-arch-suffix)" || return 1

    # GitLab release assets use lowercase "linux" (glab_<ver>_linux_<arch>.tar.gz)
    # since the GitLab org took over the project — the old profclems/glab
    # releases used "Linux", which is what broke this before.
    asset="glab_${ver_num}_linux_${arch}.tar.gz"
    url="https://gitlab.com/gitlab-org/cli/-/releases/${ver}/downloads/${asset}"
    tmp_dir="$(mktemp -d)"

    log_info "Downloading ${asset}..."
    _download_file_robust "${url}" "${tmp_dir}/${asset}" || { rm -rf "${tmp_dir}"; return 1; }
    if ! tar -xzf "${tmp_dir}/${asset}" -C "${tmp_dir}"; then
        log_error "Archive did not extract — asset naming may have changed upstream again"
        rm -rf "${tmp_dir}"; return 1
    fi

    bin="$(find "${tmp_dir}" -type f -name glab -perm -u+x | head -1)"
    if [[ -z "${bin}" ]]; then
        log_error "glab binary not found in archive"; rm -rf "${tmp_dir}"; return 1
    fi
    mkdir -p "${HOME}/.local/bin"
    install -m 755 "${bin}" "${HOME}/.local/bin/glab"
    rm -rf "${tmp_dir}"
    log_info "glab installed to ~/.local/bin/glab"
    [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]] \
        && log_warn "${HOME}/.local/bin is not on PATH — add it in env/90-local.sh"
}


# Used if the matching native path above failed, or the distro is unrecognised:
# Homebrew/Linuxbrew if present, then the release tarball as the last resort.
_glab-install-fallback-chain() {
    if command -v brew &>/dev/null; then
        log_info "Homebrew detected — installing glab via brew..."
        _glab-install-brew && return 0
        log_warn "Homebrew install failed — trying the release tarball..."
    fi
    _glab-install-tarball
}


install-glab() {
    log_info "Installing or updating GitLab CLI (glab)..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    case "${DOTFILES_OS}" in
        Mac)
            _glab-install-mac
            ;;
        Linux)
            local ok=1
            case "${DOTFILES_DISTRO}" in
                rhel)   _glab-install-rhel   && ok=0 ;;
                arch)   _glab-install-arch   && ok=0 ;;
                debian) _glab-install-debian && ok=0 ;;
                suse)   _glab-install-suse   && ok=0 ;;
            esac
            if [[ "${ok}" -ne 0 ]]; then
                log_info "No working native package path for glab — trying brew/tarball..."
                _glab-install-fallback-chain || return 1
            fi
            ;;
        *)
            log_error "Unsupported OS for glab install"; return 1
            ;;
    esac

    if command -v glab &>/dev/null; then
        log_info "GitLab CLI installed: $(glab --version 2>/dev/null | head -1)"
        echo
        echo "  Authenticate with:"
        echo "    glab auth login"
    else
        log_warn "glab not found in PATH after install. Restart your shell or check ~/.local/bin."
    fi
}

# ── nvm (Node Version Manager) install ────────────────────────────────────────

_nvm_latest_version() {
    curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest 2>/dev/null \
        | grep '"tag_name":' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' \
        | head -1
}


# Detect a manually-installed system Node and, interactively, offer to remove it
# so nvm becomes the sole manager. No-op for nvm-managed or non-interactive cases.
_nvm_handle_system_node() {
    local node_path npm_path
    node_path="$(command -v node 2>/dev/null)"
    npm_path="$(command -v npm 2>/dev/null)"

    # Only act on a real on-disk binary (skip nvm stub *functions* and nvm paths).
    [[ "${node_path}" == */* && -x "${node_path}" ]] || return 0
    case "${node_path}" in
        *"/.nvm/"*) return 0 ;;
    esac

    log_warn "A manually-installed Node.js was found:"
    log_warn "  node: ${node_path}"
    [[ -n "${npm_path}" ]] && log_warn "  npm:  ${npm_path}"
    log_warn "nvm works best as the sole Node.js manager; a system Node on PATH can shadow"
    log_warn "nvm's versions in non-login contexts."

    if [[ ! -e /dev/tty ]]; then
        log_info "Non-interactive shell — leaving the system Node in place."
        return 0
    fi

    local reply
    _read_prompt "Remove the system Node.js/npm via the package manager and use nvm instead? [y/N]: " reply
    case "$(_str_lower "${reply}")" in
        y|yes) ;;
        *) log_info "Keeping the system Node.js. nvm will install alongside it."; return 0 ;;
    esac

    [[ -z "${PACKAGE_MANAGER}" ]] && { detect-package-manager || return 0; }
    local elevation_cmd
    elevation_cmd="$(get-elevation-command)" || { log_warn "No elevation available — cannot remove system Node."; return 0; }
    log_warn "Removing system nodejs/npm — this may also remove packages that depend on them."
    case "${PACKAGE_MANAGER}" in
        dnf)    ${elevation_cmd} dnf remove -y nodejs npm ;;
        yum)    ${elevation_cmd} yum remove -y nodejs npm ;;
        apt)    ${elevation_cmd} apt-get remove -y nodejs npm ;;
        zypper) ${elevation_cmd} zypper remove -y nodejs npm ;;
        pacman) ${elevation_cmd} pacman -Rs --noconfirm nodejs npm ;;
        brew)   brew uninstall node 2>/dev/null || true ;;
        *) log_warn "Unknown package manager — remove Node.js manually if desired." ;;
    esac
}


install-nvm() {
    log_info "Installing or updating nvm (Node Version Manager)..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }
    command -v git  &>/dev/null || log_warn "git not found — nvm self-update will be unavailable"

    export NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"
    mkdir -p "${NVM_DIR}" || { log_error "Failed to create ${NVM_DIR}"; return 1; }

    _nvm_handle_system_node

    # Version is embedded in the install URL and changes over time — detect it,
    # falling back to a pinned version if the API is unreachable / rate-limited.
    local nvm_ver
    nvm_ver="$(_nvm_latest_version)"
    if [[ -z "${nvm_ver}" ]]; then
        nvm_ver="v0.40.5"
        log_warn "Could not query the latest nvm version (GitHub API rate limit?) — using ${nvm_ver}"
    fi
    log_info "Target nvm version: ${nvm_ver}"

    local install_url="https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_ver}/install.sh"
    if ! curl -o- "${install_url}" | bash; then
        log_error "nvm install script failed"
        return 1
    fi

    # Load nvm now (replacing the lazy stubs from env/20-development.sh).
    if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
        unset -f nvm node npm npx yarn pnpm 2>/dev/null || true
        # shellcheck disable=SC1091
        source "${NVM_DIR}/nvm.sh"
    else
        log_error "nvm.sh not found at ${NVM_DIR} after install"
        return 1
    fi

    # Install current LTS if nothing is in use; set a default for new shells.
    local current
    current="$(nvm current 2>/dev/null)"
    if [[ -z "${current}" || "${current}" == "none" || "${current}" == "system" ]]; then
        log_info "No nvm-managed Node in use — installing latest LTS..."
        nvm install --lts || { log_error "nvm install --lts failed"; return 1; }
        nvm use --lts
        nvm alias default 'lts/*'
    else
        log_info "nvm already managing Node ${current} — keeping it as the active version"
        nvm alias default &>/dev/null || nvm alias default "${current}"
    fi

    log_info "nvm ready — node $(node --version 2>/dev/null), npm $(npm --version 2>/dev/null)"

    # The nvm installer appends PATH exports to every shell profile it finds.
    # Our RC files are managed symlinks into the dotfiles repo, so those appends
    # land as uncommitted diffs and block the sync timer. Reset them now;
    # ~/.local/bin and nvm's own PATH are already handled by env/00-core.sh
    # and env/20-development.sh respectively.
    _restore_managed_shell_files

    echo
    echo "  nvm is loaded in this shell and lazy-loads in new shells. Common commands:"
    echo "    nvm install --lts      # install the latest LTS"
    echo "    nvm install 20         # install a specific major"
    echo "    nvm use 20             # switch versions"
    echo "    nvm alias default 20   # set the default for new shells"
}


# ── Microsoft Edit install ────────────────────────────────────────────────────
#
# _edit_arch_stem <version_string>
#   Prints the platform-specific asset stem, e.g. "edit-2.0.0-x86_64-linux-gnu"
#   Returns 1 on unsupported platform so callers can bail early.
_edit_arch_stem() {
    local normalized_ver="$1"
    local machine; machine="$(uname -m)"
    local kernel;  kernel="$(uname -s)"

    local arch os_tag
    case "${machine}" in
        x86_64)         arch="x86_64"  ;;
        aarch64|arm64)  arch="aarch64" ;;
        *) log_error "Unsupported architecture: ${machine}"; return 1 ;;
    esac

    case "${kernel}" in
        Linux)  os_tag="linux-gnu"    ;;
        Darwin) os_tag="apple-darwin" ;;
        *) log_error "Unsupported OS: ${kernel}"; return 1 ;;
    esac

    printf 'edit-%s-%s-%s' "${normalized_ver}" "${arch}" "${os_tag}"
}


# _edit_asset_url <api_response> <stem>
_edit_asset_url() {
    local api_response="$1" stem="$2"
    _gh_release_asset_url "${api_response}" "${stem}"
}


# _edit_extract <archive> <dest_dir>
#   Extracts .tar.gz, .tar.zst, or .zip into dest_dir.
_edit_extract() {
    local archive="$1" dest="$2"
    case "${archive}" in
        *.tar.gz)  tar -xzf "${archive}" -C "${dest}" ;;
        *.tar.zst)
            if command -v zstd &>/dev/null; then
                tar -I zstd -xf "${archive}" -C "${dest}"
            else
                # tar on recent Linux/macOS handles zstd natively
                tar -xf "${archive}" -C "${dest}"
            fi
            ;;
        *.zip) unzip -q "${archive}" -d "${dest}" ;;
        *) log_error "Unrecognised archive format: $(basename "${archive}")"; return 1 ;;
    esac
}


# _edit_install_from_api_response <api_response> <display_version>
#   Shared implementation used by both install-edit and install-edit-version.
_edit_install_from_api_response() {
    local api_response="$1" display_ver="$2"
    local normalized_ver="${display_ver#v}"

    local stem
    stem="$(_edit_arch_stem "${normalized_ver}")" || return 1

    local download_url
    download_url="$(_edit_asset_url "${api_response}" "${stem}")"
    if [[ -z "${download_url}" ]]; then
        log_error "No release asset matching '${stem}' found for ${display_ver}"
        log_info "Assets available in this release:"
        printf '%s' "${api_response}" \
            | grep -Eo '"browser_download_url": *"[^"]+"' \
            | sed -E 's/.*"(https[^"]+)"/  \1/'
        return 1
    fi

    # Derive the archive filename from the URL so extraction uses the right handler
    local asset_name; asset_name="$(basename "${download_url}")"
    local tmp_dir;    tmp_dir="$(mktemp -d)"

    log_info "Downloading ${asset_name}..."
    if ! _download_file_robust "${download_url}" "${tmp_dir}/${asset_name}"; then
        rm -rf "${tmp_dir}"; return 1
    fi

    log_info "Extracting ${asset_name}..."
    if ! _edit_extract "${tmp_dir}/${asset_name}" "${tmp_dir}"; then
        log_error "Extraction failed for ${asset_name}"
        rm -rf "${tmp_dir}"; return 1
    fi

    local binary; binary="$(find "${tmp_dir}" -name "edit" -type f -executable | head -1)"
    if [[ -z "${binary}" ]]; then
        log_error "edit binary not found in archive — contents:"
        find "${tmp_dir}" -type f | sed 's/^/  /'
        rm -rf "${tmp_dir}"; return 1
    fi

    mkdir -p "${HOME}/.local/bin"
    cp "${binary}" "${HOME}/.local/bin/edit"
    chmod +x "${HOME}/.local/bin/edit"
    rm -rf "${tmp_dir}"
    log_info "Microsoft Edit ${normalized_ver} installed to ~/.local/bin/edit"
}


install-edit() {
    log_info "Installing or updating Microsoft Edit..."
    command -v curl   &>/dev/null || { log_error "curl is required";   return 1; }
    command -v tar    &>/dev/null || { log_error "tar is required"; return 1; }

    local api_response ver
    api_response="$(curl -s https://api.github.com/repos/microsoft/edit/releases/latest)"
    ver="$(printf '%s' "${api_response}" | grep '"tag_name":' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
    [[ -z "${ver}" ]] && { log_error "Could not determine latest edit version"; return 1; }

    log_info "Latest version: ${ver}"
    _edit_install_from_api_response "${api_response}" "${ver}"
}


install-edit-version() {
    local target_version="$1"
    [[ -z "${target_version}" ]] && { log_error "Usage: install-edit-version <version>  (e.g. v2.0.0)"; return 1; }

    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }
    command -v tar  &>/dev/null || { log_error "tar is required"; return 1; }

    log_info "Installing Microsoft Edit ${target_version}..."
    local api_response
    api_response="$(curl -s "https://api.github.com/repos/microsoft/edit/releases/tags/${target_version}")"
    printf '%s' "${api_response}" | grep -q '"message": *"Not Found"' \
        && { log_error "Version ${target_version} not found on GitHub"; return 1; }

    _edit_install_from_api_response "${api_response}" "${target_version}"
}


list-edit-releases() {
    curl -s https://api.github.com/repos/microsoft/edit/releases \
        | grep -o '"tag_name": *"[^"]*"' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' \
        | head -10
}


# ── OpenDeck install ──────────────────────────────────────────────────────────
install-opendeck() {
    log_info "Installing or updating OpenDeck..."
    [[ -z "${PACKAGE_MANAGER}" ]] && { detect-package-manager || return 1; }

    local api_response ver elevation_cmd="" temp_dir
    api_response="$(curl -s https://api.github.com/repos/nekename/OpenDeck/releases/latest)"
    ver="$(echo "${api_response}" | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
    [[ -z "${ver}" ]] && { log_error "Could not determine OpenDeck version"; return 1; }

    if [[ "${PACKAGE_MANAGER}" != "brew" ]]; then
        elevation_cmd="$(get-elevation-command)" || return 1
    fi
    temp_dir="$(mktemp -d)"

    case "${PACKAGE_MANAGER}" in
        apt)
            local url; url="$(_gh_release_asset_url "${api_response}" '\.deb$')"
            [[ -z "${url}" ]] && { log_error "No DEB asset found"; rm -rf "${temp_dir}"; return 1; }
            _download_file_robust "${url}" "${temp_dir}/opendeck.deb" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} dpkg -i "${temp_dir}/opendeck.deb" || ${elevation_cmd} apt-get install -f -y
            ;;
        dnf|yum|zypper)
            local url; url="$(_gh_release_asset_url "${api_response}" '\.rpm$')"
            [[ -z "${url}" ]] && { log_error "No RPM asset found"; rm -rf "${temp_dir}"; return 1; }
            _download_file_robust "${url}" "${temp_dir}/opendeck.rpm" || { rm -rf "${temp_dir}"; return 1; }
            if [[ "${PACKAGE_MANAGER}" == "zypper" ]]; then
                ${elevation_cmd} zypper install -y "${temp_dir}/opendeck.rpm"
            else
                ${elevation_cmd} "${PACKAGE_MANAGER}" install -y "${temp_dir}/opendeck.rpm"
            fi
            ;;
        *)
            log_error "No native package for ${PACKAGE_MANAGER}"; rm -rf "${temp_dir}"; return 1
            ;;
    esac

    rm -rf "${temp_dir}"
    log_info "OpenDeck installation complete"
}


install-opendeck-version() {
    local target="$1"
    [[ -z "${target}" ]] && { log_error "Usage: install-opendeck-version <version>"; return 1; }
    log_info "install-opendeck-version: use install-opendeck for latest; specific-version flow not yet implemented"
    return 1
}


list-opendeck-releases() {
    curl -s https://api.github.com/repos/nekename/OpenDeck/releases \
        | grep -o '"tag_name": *"[^"]*"' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' \
        | head -10
}


# ── NotesHub install ──────────────────────────────────────────────────────────
install-noteshub() {
    log_info "Installing or updating NotesHub..."
    [[ -z "${PACKAGE_MANAGER}" ]] && { detect-package-manager || return 1; }

    local api_response ver arch_suffix elevation_cmd="" temp_dir
    api_response="$(curl -s https://api.github.com/repos/NotesHubApp/noteshub-releases/releases/latest)"
    ver="$(echo "${api_response}" | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
    [[ -z "${ver}" ]] && { log_error "Could not determine NotesHub version"; return 1; }

    case "$(uname -m)" in
        x86_64)       arch_suffix="amd64" ;;
        aarch64|arm64) arch_suffix="arm64" ;;
        *) log_error "Unsupported arch: $(uname -m)"; return 1 ;;
    esac

    [[ "${PACKAGE_MANAGER}" != "brew" ]] && { elevation_cmd="$(get-elevation-command)" || return 1; }
    temp_dir="$(mktemp -d)"

    case "${PACKAGE_MANAGER}" in
        apt)
            local url; url="$(_gh_release_asset_url "${api_response}" "noteshub_.*_${arch_suffix}\.deb")"
            [[ -z "${url}" ]] && { log_error "No DEB asset"; rm -rf "${temp_dir}"; return 1; }
            _download_file_robust "${url}" "${temp_dir}/noteshub.deb" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} dpkg -i "${temp_dir}/noteshub.deb" || ${elevation_cmd} apt-get install -f -y
            ;;
        dnf|yum|zypper)
            [[ "${arch_suffix}" != "amd64" ]] && { log_error "RPM only for x86_64"; rm -rf "${temp_dir}"; return 1; }
            local url; url="$(_gh_release_asset_url "${api_response}" "NotesHub-.*\.x86_64\.rpm")"
            [[ -z "${url}" ]] && { log_error "No RPM asset"; rm -rf "${temp_dir}"; return 1; }
            _download_file_robust "${url}" "${temp_dir}/noteshub.rpm" || { rm -rf "${temp_dir}"; return 1; }
            if [[ "${PACKAGE_MANAGER}" == "zypper" ]]; then
                ${elevation_cmd} zypper install -y "${temp_dir}/noteshub.rpm"
            else
                ${elevation_cmd} "${PACKAGE_MANAGER}" install -y "${temp_dir}/noteshub.rpm"
            fi
            ;;
        *)
            log_error "No supported install method for ${PACKAGE_MANAGER}"; rm -rf "${temp_dir}"; return 1
            ;;
    esac

    rm -rf "${temp_dir}"
    log_info "NotesHub installation complete"
}


install-noteshub-version() {
    local target="$1"
    [[ -z "${target}" ]] && { log_error "Usage: install-noteshub-version <version>"; return 1; }
    log_info "install-noteshub-version: use install-noteshub for latest; specific-version flow not yet implemented"
    return 1
}


list-noteshub-releases() {
    curl -s https://api.github.com/repos/NotesHubApp/noteshub-releases/releases \
        | grep -o '"tag_name": *"[^"]*"' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' \
        | head -10
}

# ── direnv install ────────────────────────────────────────────────────────────

_direnv-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} dnf install -y direnv
}

_direnv-install-debian() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} apt-get update && ${elevation_cmd} apt-get install -y direnv
}

_direnv-install-suse() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} zypper install -y direnv
}

_direnv-install-arch() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} pacman -S --noconfirm direnv
}

_direnv-install-mac() {
    command -v brew &>/dev/null || { log_error "Homebrew required on macOS"; return 1; }
    if command -v direnv &>/dev/null; then brew upgrade direnv; else brew install direnv; fi
}

# Distro-independent fallback: official install script → ~/.local/bin
_direnv-install-script() {
    log_info "Falling back to the official direnv install script..."
    command -v curl &>/dev/null || { log_error "curl is required for the fallback install"; return 1; }
    mkdir -p "${HOME}/.local/bin"
    curl -sfL https://direnv.net/install.sh | bin_path="${HOME}/.local/bin" bash
    [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]] \
        && log_warn "${HOME}/.local/bin is not on PATH — add it in env/90-local.sh"
}


install-direnv() {
    log_info "Installing or updating direnv..."

    case "${DOTFILES_OS}" in
        Mac)
            _direnv-install-mac
            ;;
        Linux)
            local ok=1
            case "${DOTFILES_DISTRO}" in
                rhel)   _direnv-install-rhel   && ok=0 ;;
                debian) _direnv-install-debian && ok=0 ;;
                suse)   _direnv-install-suse   && ok=0 ;;
                arch)   _direnv-install-arch   && ok=0 ;;
                *)      log_warn "Unknown distro (${DOTFILES_DISTRO}) — using install script" ;;
            esac
            [[ "${ok}" -ne 0 ]] && { _direnv-install-script || return 1; }
            ;;
        *)
            log_error "Unsupported OS for direnv install"; return 1
            ;;
    esac

    if command -v direnv &>/dev/null; then
        log_info "direnv installed: $(direnv version 2>/dev/null)"

        # Attempt to install the shell hook into this session immediately
        local direnv_tool_file="${SHELL_CONFIG_DIR}/tools/direnv.sh"
        if [[ -f "${direnv_tool_file}" ]]; then
            # shellcheck disable=SC1090
            source "${direnv_tool_file}"
        fi

        echo
        log_warn "If 'direnv allow' or .envrc loading doesn't work in this shell,"
        log_warn "open a new terminal / log out and back in to fully activate direnv."
        echo
        echo "  Allow a project's .envrc with:"
        echo "    direnv allow"
    else
        log_warn "direnv not found in PATH after install. Restart your shell or check ~/.local/bin."
    fi
}

# ── fzf install ───────────────────────────────────────────────────────────────

_fzf-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    if command -v dnf &>/dev/null; then
        # fzf is in EPEL on RHEL 8, base repos on RHEL 9+ and Fedora
        ${elevation_cmd} dnf install -y fzf
    elif command -v yum &>/dev/null; then
        ${elevation_cmd} yum install -y epel-release 2>/dev/null || true
        ${elevation_cmd} yum install -y fzf
    else
        log_error "Neither dnf nor yum found"; return 1
    fi
}

_fzf-install-debian() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} apt-get update
    ${elevation_cmd} apt-get install -y fzf
}

_fzf-install-suse() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} zypper install -y fzf
}

_fzf-install-arch() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} pacman -S --noconfirm fzf
}

_fzf-install-mac() {
    command -v brew &>/dev/null || { log_error "brew is required on macOS"; return 1; }
    if command -v fzf &>/dev/null; then brew upgrade fzf; else brew install fzf; fi
}

# Binary fallback — latest GitHub release → ~/.local/bin
_fzf-install-binary() {
    log_info "fzf: falling back to binary install from GitHub releases..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }
    command -v tar  &>/dev/null || { log_error "tar is required";  return 1; }

    local api_response ver arch url asset tmp_dir
    api_response="$(curl -s https://api.github.com/repos/junegunn/fzf/releases/latest)"
    ver="$(printf '%s' "${api_response}" | grep '"tag_name":' \
        | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/' | head -1)"
    [[ -z "${ver}" ]] && { log_error "fzf: could not determine latest version"; return 1; }

    case "$(uname -m)" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_error "fzf: unsupported architecture $(uname -m)"; return 1 ;;
    esac

    asset="fzf-${ver}-linux_${arch}.tar.gz"
    url="$(_gh_release_asset_url "${api_response}" "fzf-${ver}-linux_${arch}\.tar\.gz")"
    [[ -z "${url}" ]] && { log_error "fzf: no matching asset for ${asset}"; return 1; }

    tmp_dir="$(mktemp -d)"
    _download_file_robust "${url}" "${tmp_dir}/${asset}" || { rm -rf "${tmp_dir}"; return 1; }
    tar -xzf "${tmp_dir}/${asset}" -C "${tmp_dir}"
    mkdir -p "${HOME}/.local/bin"
    install -m 755 "${tmp_dir}/fzf" "${HOME}/.local/bin/fzf"
    rm -rf "${tmp_dir}"
    log_info "fzf ${ver} installed to ~/.local/bin/fzf"
}

install-fzf() {
    log_info "Installing or updating fzf..."

    case "${DOTFILES_OS}" in
        Mac) _fzf-install-mac; return $? ;;
        Linux) ;;
        *) log_error "Unsupported OS for fzf install"; return 1 ;;
    esac

    local ok=1
    case "${DOTFILES_DISTRO}" in
        rhel)   _fzf-install-rhel   && ok=0 ;;
        debian) _fzf-install-debian && ok=0 ;;
        suse)   _fzf-install-suse   && ok=0 ;;
        arch)   _fzf-install-arch   && ok=0 ;;
        *)      log_warn "fzf: unknown distro (${DOTFILES_DISTRO}) — trying binary install" ;;
    esac
    [[ "${ok}" -ne 0 ]] && { _fzf-install-binary || return 1; }

    if command -v fzf &>/dev/null; then
        log_info "fzf installed: $(fzf --version)"
    else
        log_warn "fzf not on PATH after install — check ~/.local/bin is in PATH"
    fi
}


# ── jq install ────────────────────────────────────────────────────────────────
# jq is in default repos for all four distro families — package manager is
# always the right choice. Binary fallback retained for unknown distros only.

_jq-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    if command -v dnf &>/dev/null; then
        ${elevation_cmd} dnf install -y jq
    else
        ${elevation_cmd} yum install -y jq
    fi
}

_jq-install-debian() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} apt-get update
    ${elevation_cmd} apt-get install -y jq
}

_jq-install-suse() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} zypper install -y jq
}

_jq-install-arch() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} pacman -S --noconfirm jq
}

_jq-install-mac() {
    command -v brew &>/dev/null || { log_error "brew is required on macOS"; return 1; }
    if command -v jq &>/dev/null; then brew upgrade jq; else brew install jq; fi
}

_jq-install-binary() {
    log_info "jq: falling back to binary install from GitHub releases..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    local api_response ver arch url tmp_dir
    api_response="$(curl -s https://api.github.com/repos/jqlang/jq/releases/latest)"
    # jq tags are `jq-1.7.1`, not `v1.7.1`
    ver="$(printf '%s' "${api_response}" | grep '"tag_name":' \
        | sed -E 's/.*"tag_name": *"jq-([^"]+)".*/\1/' | head -1)"
    [[ -z "${ver}" ]] && { log_error "jq: could not determine latest version"; return 1; }

    case "$(uname -m)" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_error "jq: unsupported architecture $(uname -m)"; return 1 ;;
    esac

    # Asset naming changed in 1.7: jq-linux64 → jq-linux-amd64
    url="$(_gh_release_asset_url "${api_response}" "jq-linux-(${arch}|64)$")"
    [[ -z "${url}" ]] && { log_error "jq: no matching asset for linux/${arch}"; return 1; }

    tmp_dir="$(mktemp -d)"
    _download_file_robust "${url}" "${tmp_dir}/jq" || { rm -rf "${tmp_dir}"; return 1; }
    mkdir -p "${HOME}/.local/bin"
    install -m 755 "${tmp_dir}/jq" "${HOME}/.local/bin/jq"
    rm -rf "${tmp_dir}"
    log_info "jq ${ver} installed to ~/.local/bin/jq"
}

install-jq() {
    log_info "Installing or updating jq..."

    case "${DOTFILES_OS}" in
        Mac) _jq-install-mac; return $? ;;
        Linux) ;;
        *) log_error "Unsupported OS for jq install"; return 1 ;;
    esac

    local ok=1
    case "${DOTFILES_DISTRO}" in
        rhel)   _jq-install-rhel   && ok=0 ;;
        debian) _jq-install-debian && ok=0 ;;
        suse)   _jq-install-suse   && ok=0 ;;
        arch)   _jq-install-arch   && ok=0 ;;
        *)      log_warn "jq: unknown distro (${DOTFILES_DISTRO}) — trying binary install" ;;
    esac
    [[ "${ok}" -ne 0 ]] && { _jq-install-binary || return 1; }

    command -v jq &>/dev/null \
        && log_info "jq installed: $(jq --version 2>/dev/null)" \
        || log_warn "jq not on PATH after install — check ~/.local/bin is in PATH"
}


# ── yq install ────────────────────────────────────────────────────────────────
# mikefarah/yq package availability:
#   - Fedora: base repos (F38+)
#   - RHEL 9+: EPEL (enabled as a side-effect of install-snapd on rhel, but
#               not guaranteed here — attempt and fall through on failure)
#   - Ubuntu/Debian: apt ships yq 3.x (Python wrapper, wrong tool) — skip apt
#   - openSUSE: third-party OBS repo only — not worth adding a repo for
#   - Arch: AUR `yq` package
# Binary install is therefore the primary path for debian and suse.

_yq-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    if command -v dnf &>/dev/null; then
        # Fedora: yq is in base repos — try direct install first
        # RHEL/Rocky/Alma: yq is in EPEL 9+, so fall back to enabling epel-release
        if ! ${elevation_cmd} dnf install -y yq 2>/dev/null; then
            log_info "yq: not found in base repos, attempting via EPEL..."
            ${elevation_cmd} dnf install -y epel-release 2>/dev/null || true
            ${elevation_cmd} dnf install -y yq
        fi
    elif command -v yum &>/dev/null; then
        if ! ${elevation_cmd} yum install -y yq 2>/dev/null; then
            log_info "yq: not found in base repos, attempting via EPEL..."
            ${elevation_cmd} yum install -y epel-release 2>/dev/null || true
            ${elevation_cmd} yum install -y yq
        fi
    else
        log_error "yq: neither dnf nor yum found"; return 1
    fi
}

_yq-install-arch() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    # yq is in the Arch AUR; pacman -S works if the community/extra repo has it,
    # otherwise yay handles AUR resolution.
    if command -v yay &>/dev/null; then
        yay -S --noconfirm yq
    else
        ${elevation_cmd} pacman -S --noconfirm yq
    fi
}

_yq-install-mac() {
    command -v brew &>/dev/null || { log_error "brew is required on macOS"; return 1; }
    if command -v yq &>/dev/null; then brew upgrade yq; else brew install yq; fi
}

_yq-install-binary() {
    log_info "yq: installing binary from GitHub releases..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    local api_response ver arch url tmp_dir
    api_response="$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest)"
    ver="$(printf '%s' "${api_response}" | grep '"tag_name":' \
        | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/' | head -1)"
    [[ -z "${ver}" ]] && { log_error "yq: could not determine latest version"; return 1; }

    case "$(uname -m)" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_error "yq: unsupported architecture $(uname -m)"; return 1 ;;
    esac

    # yq releases a plain binary — no archive to extract
    url="$(_gh_release_asset_url "${api_response}" "yq_linux_${arch}$")"
    [[ -z "${url}" ]] \
        && url="https://github.com/mikefarah/yq/releases/download/v${ver}/yq_linux_${arch}"

    tmp_dir="$(mktemp -d)"
    _download_file_robust "${url}" "${tmp_dir}/yq" || { rm -rf "${tmp_dir}"; return 1; }
    mkdir -p "${HOME}/.local/bin"
    install -m 755 "${tmp_dir}/yq" "${HOME}/.local/bin/yq"
    rm -rf "${tmp_dir}"
    log_info "yq ${ver} installed to ~/.local/bin/yq"
}

install-yq() {
    log_info "Installing or updating yq..."

    case "${DOTFILES_OS}" in
        Mac) _yq-install-mac; return $? ;;
        Linux) ;;
        *) log_error "Unsupported OS for yq install"; return 1 ;;
    esac

    local ok=1
    case "${DOTFILES_DISTRO}" in
        rhel)   _yq-install-rhel && ok=0 ;;
        arch)   _yq-install-arch && ok=0 ;;
        # debian: apt ships yq 3.x (wrong tool) — go straight to binary
        # suse: only in third-party OBS repo — not worth a repo add, use binary
        debian|suse|*) log_info "yq: no suitable distro package — using binary install" ;;
    esac
    [[ "${ok}" -ne 0 ]] && { _yq-install-binary || return 1; }

    # Verify it's the mikefarah variant, not the Python yq 3.x wrapper
    if command -v yq &>/dev/null; then
        local installed_ver
        installed_ver="$(yq --version 2>/dev/null | head -1)"
        if printf '%s' "${installed_ver}" | grep -qiE '(https://github.com/mikefarah|mikefarah)'; then
            log_info "yq installed: ${installed_ver}"
        else
            log_warn "yq on PATH appears to be a different implementation: ${installed_ver}"
            log_warn "The mikefarah binary was installed to ~/.local/bin/yq — check PATH ordering."
        fi
    else
        log_warn "yq not on PATH after install — check ~/.local/bin is in PATH"
    fi
}

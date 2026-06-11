#!/usr/bin/env bash
# Lazy-loaded installer functions — heavy operations loaded on first call.
# This file is sourced via stub in loader.sh; all functions become available
# after the first call to any function defined here.

# ── Shared download helper ────────────────────────────────────────────────────
_download_file_robust() {
    local url="$1" output_file="$2"
    local max_retries=3 retry_count=0

    [[ -z "${url}" || -z "${output_file}" ]] && { log_error "_download_file_robust: URL and output required"; return 1; }

    while [[ ${retry_count} -lt ${max_retries} ]]; do
        retry_count=$((retry_count + 1))
        [[ ${retry_count} -gt 1 ]] && { log_info "Download attempt ${retry_count}/${max_retries}..."; sleep 2; }

        if curl -L -C - --connect-timeout 30 --max-time 1800 --retry 2 --retry-delay 1 -o "${output_file}" "${url}"; then
            return 0
        fi

        log_warn "Retrying with HTTP/1.1..."
        if curl --http1.1 -L -C - --connect-timeout 30 --max-time 1800 -o "${output_file}" "${url}"; then
            return 0
        fi

        if [[ -f "${output_file}" ]]; then
            local sz
            sz="$(stat -c%s "${output_file}" 2>/dev/null || echo 0)"
            [[ "${sz}" -lt 1024 ]] && rm -f "${output_file}"
        fi
    done

    log_error "All download attempts failed after ${max_retries} tries"
    return 1
}

# ── Shared npm helpers ────────────────────────────────────────────────────────

# _ensure_npm — ensure npm is usable, preferring nvm. Returns 0 if npm resolves.
# Priority: live npm → nvm stub → unsourced nvm (install LTS) → package manager.
_ensure_npm() {
    # Case 1: npm already resolves (nvm active, or system npm)
    if command -v npm &>/dev/null; then
        return 0
    fi

    # Case 2: nvm stub registered (function exists) but not yet activated
    if declare -f npm &>/dev/null || declare -f nvm &>/dev/null; then
        log_info "Activating nvm to access npm..."
        nvm --version &>/dev/null || true
        command -v npm &>/dev/null && return 0
    fi

    # Case 3: nvm installed but stubs not registered (e.g. non-interactive shell)
    local nvm_dir="${NVM_DIR:-${HOME}/.nvm}"
    if [[ -s "${nvm_dir}/nvm.sh" ]]; then
        log_info "Sourcing nvm..."
        # shellcheck disable=SC1091
        source "${nvm_dir}/nvm.sh"
        command -v npm &>/dev/null && return 0
        log_info "nvm active but no node version installed — installing LTS..."
        nvm install --lts
        nvm use --lts
        command -v npm &>/dev/null && return 0
    fi

    # Case 4: no nvm — install Node via the package manager
    log_info "nvm not found — attempting to install Node.js via package manager..."
    [[ -z "${PACKAGE_MANAGER}" ]] && { detect-package-manager || return 1; }
    local elevation_cmd
    elevation_cmd="$(get-elevation-command)" || return 1
    case "${PACKAGE_MANAGER}" in
        dnf)    ${elevation_cmd} dnf install -y nodejs npm ;;
        yum)    ${elevation_cmd} yum install -y nodejs npm ;;
        apt)    ${elevation_cmd} apt-get install -y nodejs npm ;;
        zypper) ${elevation_cmd} zypper install -y nodejs npm ;;
        pacman) ${elevation_cmd} pacman -S --noconfirm nodejs npm ;;
        brew)   brew install node ;;
        *) log_error "Cannot install Node.js: no supported package manager"; return 1 ;;
    esac
    command -v npm &>/dev/null && return 0
    return 1
}

# _npm_global_install <package>
# Installs/updates a global npm package. If npm's prefix is system-owned
# (/usr, /opt) the install is redirected to ~/.local so no root is required.
_npm_global_install() {
    local pkg="$1"
    [[ -z "${pkg}" ]] && { log_error "_npm_global_install: package name required"; return 1; }

    local npm_prefix install_prefix=""
    npm_prefix="$(npm config get prefix 2>/dev/null)"
    case "${npm_prefix}" in
        /usr/*|/opt/*|/usr|/opt)
            install_prefix="${HOME}/.local"
            log_info "System npm prefix (${npm_prefix}) — installing to ${install_prefix}"
            ;;
        *)
            log_info "npm prefix is user-writable (${npm_prefix})"
            ;;
    esac

    mkdir -p "${HOME}/.local/bin"
    if [[ -n "${install_prefix}" ]]; then
        npm install -g --prefix "${install_prefix}" "${pkg}" || return 1
        if [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
            log_warn "${HOME}/.local/bin is not on PATH — add it in env/90-local.sh"
        fi
    else
        npm install -g "${pkg}" || return 1
    fi
}

# _node_version_at_least <major>
# True if the active node's major version is >= <major>.
_node_version_at_least() {
    local want="$1" have
    command -v node &>/dev/null || return 1
    have="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
    [[ -n "${have}" && "${have}" =~ ^[0-9]+$ && "${have}" -ge "${want}" ]]
}

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

# ── Ansible install ───────────────────────────────────────────────────────────
_ansible-install-dnf() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    [[ "${elevation_cmd}" == "run0" ]] && log_warn "run0 detected — multiple prompts expected"
    command -v dnf &>/dev/null || { log_error "dnf not found"; return 1; }
    log_info "Installing Ansible via dnf..."
    ${elevation_cmd} dnf install -y ansible
}

_ansible-install-yum() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v yum &>/dev/null || { log_error "yum not found"; return 1; }
    ${elevation_cmd} yum install -y ansible
}

_ansible-install-zypper() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v zypper &>/dev/null || { log_error "zypper not found"; return 1; }
    ${elevation_cmd} zypper install -y ansible
}

_ansible-install-pacman() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v pacman &>/dev/null || { log_error "pacman not found"; return 1; }
    ${elevation_cmd} pacman -S --noconfirm ansible
}

_ansible-add-ppa() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v apt-add-repository &>/dev/null || { log_error "apt-add-repository not found"; return 1; }
    ${elevation_cmd} apt update
    dpkg -l | grep -q software-properties-common \
        || ${elevation_cmd} apt install -y software-properties-common
    ${elevation_cmd} apt-add-repository -y ppa:ansible/ansible
}

_ansible-install-python() {
    command -v pip3 &>/dev/null || { log_error "pip3 is required"; return 1; }
    local latest
    latest="$(curl -s https://pypi.org/pypi/ansible/json | grep -Eo '"version":"[0-9]+\.[0-9]+\.[0-9]+",' | sed -E 's/.+"([0-9]+\.[0-9]+\.[0-9]+)",/\1/' | head -1)"
    [[ -z "${latest}" ]] && { log_error "Could not determine latest Ansible version"; return 1; }
    log_info "Installing Ansible ${latest} via pip3..."
    pip3 install --upgrade ansible --disable-pip-version-check
}

install-ansible() {
    log_info "Installing Ansible..."
    [[ -z "${PACKAGE_MANAGER}" ]] && detect-package-manager
    case "${PACKAGE_MANAGER:-}" in
        dnf)    _ansible-install-dnf ;;
        yum)    _ansible-install-yum ;;
        zypper) _ansible-install-zypper ;;
        pacman) _ansible-install-pacman ;;
        apt)    _ansible-add-ppa && { local ec; ec="$(get-elevation-command)"; ${ec} apt install -y ansible; } ;;
        brew)   brew install ansible ;;
        *)      _ansible-install-python ;;
    esac
}

# ── Helm install ──────────────────────────────────────────────────────────────
_helm-install-linux() {
    local helm_version="$1"
    local helm_dir="${HOME}/.local/bin/k8s/helm-${helm_version}"
    mkdir -p "${helm_dir}"
    cd "${helm_dir}" || return 1
    command -v openssl &>/dev/null || { VERIFY_CHECKSUM=false; export VERIFY_CHECKSUM; }
    log_info "Installing helm ${helm_version}..."
    curl -fsSL "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3" -o get_helm.sh
    [[ -f get_helm.sh ]] || { log_error "Failed to download helm install script"; cd - || true; return 1; }
    chmod 700 get_helm.sh
    ./get_helm.sh
    unset VERIFY_CHECKSUM
    rm -f get_helm.sh
    cd - || true
    command -v helm &>/dev/null && log_info "Helm ${helm_version} installed"
}

_helm-install-mac() {
    command -v brew &>/dev/null || { log_error "brew is required on macOS"; return 1; }
    if command -v helm &>/dev/null; then
        brew upgrade helm
    else
        brew install helm
    fi
}

install-helm() {
    local helm_version
    helm_version="$(curl -s https://api.github.com/repos/helm/helm/releases/latest \
        | grep '"tag_name":' | sed -E 's/.+"v([^"]+)".+/\1/')"
    [[ -z "${helm_version}" ]] && { log_error "Could not determine helm version"; return 1; }

    if command -v helm &>/dev/null; then
        local current
        current="$(helm version --short | sed -r 's/v([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
        [[ "${current}" == "${helm_version}" ]] && { log_info "Helm ${helm_version} already installed"; return 0; }
    fi

    case "${DOTFILES_OS}" in
        Linux) _helm-install-linux "${helm_version}" ;;
        Mac)   _helm-install-mac ;;
        *)     log_error "Unsupported OS for helm install"; return 1 ;;
    esac
}

# ── Terraform install ─────────────────────────────────────────────────────────
_tf-install-linux() {
    local tf_version="${1:-$(get-latest-terraform-version)}"
    [[ -z "${tf_version}" ]] && { log_error "Could not determine Terraform version"; return 1; }

    if command -v terraform &>/dev/null; then
        local current
        current="$(terraform version | sed -r 's/Terraform v([0-9.]+)/\1/' | head -1)"
        [[ "${current}" == "${tf_version}" ]] && { log_info "Terraform ${tf_version} already installed"; return 0; }
    fi

    if command -v tfenv &>/dev/null; then
        git --git-dir="${HOME}/.tfenv/.git" pull && tfenv install "${tf_version}" && tfenv use "${tf_version}"
        return $?
    fi

    log_info "Installing tfenv..."
    git clone --depth=1 https://github.com/tfutils/tfenv.git "${HOME}/.tfenv" || { log_error "tfenv clone failed"; return 1; }
    [[ ":${PATH}:" != *":${HOME}/.tfenv/bin:"* ]] && PATH="${HOME}/.tfenv/bin:${PATH}"
    command -v tfenv &>/dev/null || { log_error "tfenv not found after install"; return 1; }
    tfenv install latest && tfenv use latest
}

_tf-install-mac() {
    local tf_version="${1:-$(get-latest-terraform-version)}"
    if command -v brew &>/dev/null; then
        if command -v tfenv &>/dev/null; then
            brew upgrade tfenv
        else
            brew install tfenv
        fi
    elif command -v git &>/dev/null; then
        git clone --depth=1 https://github.com/tfutils/tfenv.git "${HOME}/.tfenv"
        [[ ":${PATH}:" != *":${HOME}/.tfenv/bin:"* ]] && PATH="${HOME}/.tfenv/bin:${PATH}"
    else
        log_error "Neither brew nor git found"; return 1
    fi
    tfenv install latest && tfenv use latest
}

install-terraform() {
    local tf_version
    tf_version="$(get-latest-terraform-version)"
    [[ -z "${tf_version}" ]] && { log_error "Could not determine Terraform version"; return 1; }
    case "${DOTFILES_OS}" in
        Linux) _tf-install-linux "${tf_version}" && tflint-install && trivy-install ;;
        Mac)   _tf-install-mac "${tf_version}"   && tflint-install && trivy-install ;;
        *)     log_error "Unsupported OS"; return 1 ;;
    esac
}

# ── TFLint install ────────────────────────────────────────────────────────────
_tflint-install-linux() {
    local ver
    ver="$(curl -s https://api.github.com/repos/terraform-linters/tflint/releases/latest \
        | grep '"tag_name":' | sed -E 's/.+"v([^"]+)".+/\1/')"
    [[ -z "${ver}" ]] && { log_error "Could not determine TFLint version"; return 1; }

    if command -v tflint &>/dev/null; then
        local current
        current="$(tflint --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        [[ "${current}" == "${ver}" ]] && { log_info "TFLint ${ver} already installed"; return 0; }
    fi

    command -v unzip &>/dev/null || { log_error "unzip required for TFLint install"; return 1; }

    local install_path="${HOME}/.local/bin/tf-lint/tflint-${ver}"
    mkdir -p "${install_path}"
    TFLINT_INSTALL_PATH="${install_path}" \
        bash <(curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh)

    [[ -x "${install_path}/tflint" ]] || { log_error "TFLint install failed"; return 1; }

    local existing; existing="$(command -v tflint 2>/dev/null)"
    if [[ -n "${existing}" ]]; then
        if [[ -L "${existing}" ]]; then
            rm "${existing}"
        else
            mv "${existing}" "${existing}.old"
        fi
    fi
    ln -sf "${install_path}/tflint" "${HOME}/.local/bin/tflint"
    log_info "TFLint ${ver} installed"
}

_tflint-install-mac() {
    local ver
    ver="$(curl -s https://api.github.com/repos/terraform-linters/tflint/releases/latest \
        | grep '"tag_name":' | sed -E 's/.+"v([^"]+)".+/\1/')"
    [[ -z "${ver}" ]] && { log_error "Could not determine TFLint version"; return 1; }

    command -v brew &>/dev/null || { log_error "brew required on macOS"; return 1; }
    if command -v tflint &>/dev/null; then
        brew upgrade tflint
    else
        brew install tflint
    fi
}

install-tflint() {
    case "${DOTFILES_OS}" in
        Linux) _tflint-install-linux ;;
        Mac)   _tflint-install-mac ;;
        *)     log_error "Unsupported OS for tflint"; return 1 ;;
    esac
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
    echo
    echo "  nvm is loaded in this shell and lazy-loads in new shells. Common commands:"
    echo "    nvm install --lts      # install the latest LTS"
    echo "    nvm install 20         # install a specific major"
    echo "    nvm use 20             # switch versions"
    echo "    nvm alias default 20   # set the default for new shells"
}

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
#   Searches the GitHub API JSON for any download URL whose filename starts with
#   <stem> and ends with a known archive extension.  Prints the URL.
#   By matching on stem rather than full filename we survive extension changes.
_edit_asset_url() {
    local api_response="$1" stem="$2"
    local url
    # Match the stem followed by any extension (.tar.gz, .tar.zst, .zip, etc.)
    url="$(printf '%s' "${api_response}" \
        | grep "\"browser_download_url\":.*${stem}" \
        | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/' \
        | head -1)"
    printf '%s' "${url}"
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
            | grep '"browser_download_url":' \
            | sed -E 's/.*"browser_download_url": *"([^"]+)".*/  \1/'
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
        | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | head -10
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
            local url; url="$(echo "${api_response}" | grep '"browser_download_url":.*\.deb"' \
                | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')"
            [[ -z "${url}" ]] && { log_error "No DEB asset found"; rm -rf "${temp_dir}"; return 1; }
            _download_file_robust "${url}" "${temp_dir}/opendeck.deb" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} dpkg -i "${temp_dir}/opendeck.deb" || ${elevation_cmd} apt-get install -f -y
            ;;
        dnf|yum|zypper)
            local url; url="$(echo "${api_response}" | grep '"browser_download_url":.*\.rpm"' \
                | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')"
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
        | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | head -10
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
            local url; url="$(echo "${api_response}" | grep "\"browser_download_url\":.*noteshub_.*_${arch_suffix}\.deb\"" \
                | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')"
            [[ -z "${url}" ]] && { log_error "No DEB asset"; rm -rf "${temp_dir}"; return 1; }
            _download_file_robust "${url}" "${temp_dir}/noteshub.deb" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} dpkg -i "${temp_dir}/noteshub.deb" || ${elevation_cmd} apt-get install -f -y
            ;;
        dnf|yum|zypper)
            [[ "${arch_suffix}" != "amd64" ]] && { log_error "RPM only for x86_64"; rm -rf "${temp_dir}"; return 1; }
            local url; url="$(echo "${api_response}" | grep '"browser_download_url":.*NotesHub-.*\.x86_64\.rpm"' \
                | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')"
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
        | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | head -10
}

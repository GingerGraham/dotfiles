#!/usr/bin/env bash
# Lazy-loaded installer functions — heavy operations loaded on first call.
# This file is sourced via stub in loader.sh; all functions become available
# after the first call to any function defined here.

# ── Shared download helper ────────────────────────────────────────────────────
download_file_robust() {
    local url="$1" output_file="$2"
    local max_retries=3 retry_count=0

    [[ -z "${url}" || -z "${output_file}" ]] && { log_error "download_file_robust: URL and output required"; return 1; }

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

# ── Ansible install ───────────────────────────────────────────────────────────
ansible-install-dnf() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    [[ "${elevation_cmd}" == "run0" ]] && log_warn "run0 detected — multiple prompts expected"
    command -v dnf &>/dev/null || { log_error "dnf not found"; return 1; }
    log_info "Installing Ansible via dnf..."
    ${elevation_cmd} dnf install -y ansible
}

ansible-install-yum() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v yum &>/dev/null || { log_error "yum not found"; return 1; }
    ${elevation_cmd} yum install -y ansible
}

ansible-install-zypper() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v zypper &>/dev/null || { log_error "zypper not found"; return 1; }
    ${elevation_cmd} zypper install -y ansible
}

ansible-install-pacman() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v pacman &>/dev/null || { log_error "pacman not found"; return 1; }
    ${elevation_cmd} pacman -S --noconfirm ansible
}

ansible-add-ppa() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v apt-add-repository &>/dev/null || { log_error "apt-add-repository not found"; return 1; }
    ${elevation_cmd} apt update
    dpkg -l | grep -q software-properties-common \
        || ${elevation_cmd} apt install -y software-properties-common
    ${elevation_cmd} apt-add-repository -y ppa:ansible/ansible
}

ansible-install-python() {
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
        dnf)    ansible-install-dnf ;;
        yum)    ansible-install-yum ;;
        zypper) ansible-install-zypper ;;
        pacman) ansible-install-pacman ;;
        apt)    ansible-add-ppa && { local ec; ec="$(get-elevation-command)"; ${ec} apt install -y ansible; } ;;
        brew)   brew install ansible ;;
        *)      ansible-install-python ;;
    esac
}

# ── Helm install ──────────────────────────────────────────────────────────────
helm-install-linux() {
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

helm-install-mac() {
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
        Linux) helm-install-linux "${helm_version}" ;;
        Mac)   helm-install-mac ;;
        *)     log_error "Unsupported OS for helm install"; return 1 ;;
    esac
}

# ── Terraform install ─────────────────────────────────────────────────────────
tf-install-linux() {
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

tf-install-mac() {
    local tf_version="${1:-$(get-latest-terraform-version)}"
    if command -v brew &>/dev/null; then
        command -v tfenv &>/dev/null && brew upgrade tfenv || brew install tfenv
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
        Linux) tf-install-linux "${tf_version}" && tflint-install && trivy-install ;;
        Mac)   tf-install-mac "${tf_version}"   && tflint-install && trivy-install ;;
        *)     log_error "Unsupported OS"; return 1 ;;
    esac
}

# ── TFLint install ────────────────────────────────────────────────────────────
tflint-install-linux() {
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
        [[ -L "${existing}" ]] && rm "${existing}" || mv "${existing}" "${existing}.old"
    fi
    ln -sf "${install_path}/tflint" "${HOME}/.local/bin/tflint"
    log_info "TFLint ${ver} installed"
}

tflint-install-mac() {
    local ver
    ver="$(curl -s https://api.github.com/repos/terraform-linters/tflint/releases/latest \
        | grep '"tag_name":' | sed -E 's/.+"v([^"]+)".+/\1/')"
    [[ -z "${ver}" ]] && { log_error "Could not determine TFLint version"; return 1; }

    command -v brew &>/dev/null || { log_error "brew required on macOS"; return 1; }
    command -v tflint &>/dev/null && brew upgrade tflint || brew install tflint
}

install-tflint() {
    case "${DOTFILES_OS}" in
        Linux) tflint-install-linux ;;
        Mac)   tflint-install-mac ;;
        *)     log_error "Unsupported OS for tflint"; return 1 ;;
    esac
}

# ── Trivy install ─────────────────────────────────────────────────────────────
_trivy-repo-rpm() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    [[ -f /etc/yum.repos.d/trivy.repo ]] && { log_info "Trivy repo already configured"; return 0; }
    cat <<'EOF' | ${elevation_cmd} tee /etc/yum.repos.d/trivy.repo
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://aquasecurity.github.io/trivy-repo/rpm/public.key
EOF
    command -v dnf &>/dev/null && ${elevation_cmd} dnf check-update --refresh -y || \
        ${elevation_cmd} yum check-update -y
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

trivy-install-linux() {
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

trivy-install-mac() {
    command -v brew &>/dev/null || { log_error "brew required on macOS"; return 1; }
    command -v trivy &>/dev/null && brew upgrade trivy || brew install trivy
}

install-trivy() {
    case "${DOTFILES_OS}" in
        Linux) trivy-install-linux ;;
        Mac)   trivy-install-mac ;;
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
            download_file_robust "${deb_url}" "${temp_dir}/bitwarden.deb" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} dpkg -i "${temp_dir}/bitwarden.deb" || true
            ${elevation_cmd} apt-get install -f -y
            ;;
        dnf|yum)
            local rpm_url="https://bitwarden.com/download/?app=desktop&platform=linux&variant=rpm"
            download_file_robust "${rpm_url}" "${temp_dir}/bitwarden.rpm" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} "${PACKAGE_MANAGER}" install -y "${temp_dir}/bitwarden.rpm"
            ;;
        zypper)
            local rpm_url="https://bitwarden.com/download/?app=desktop&platform=linux&variant=rpm"
            download_file_robust "${rpm_url}" "${temp_dir}/bitwarden.rpm" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} zypper install -y "${temp_dir}/bitwarden.rpm"
            ;;
        pacman)
            if command -v yay &>/dev/null; then
                yay -S --noconfirm bitwarden-bin
            else
                mkdir -p "${HOME}/Applications"
                local ai_url="https://bitwarden.com/download/?app=desktop&platform=linux&variant=appimage"
                download_file_robust "${ai_url}" "${HOME}/Applications/Bitwarden.AppImage" || { rm -rf "${temp_dir}"; return 1; }
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
    if ! download_file_robust "${download_url}" "${tmp_dir}/${asset_name}"; then
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
            download_file_robust "${url}" "${temp_dir}/opendeck.deb" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} dpkg -i "${temp_dir}/opendeck.deb" || ${elevation_cmd} apt-get install -f -y
            ;;
        dnf|yum|zypper)
            local url; url="$(echo "${api_response}" | grep '"browser_download_url":.*\.rpm"' \
                | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')"
            [[ -z "${url}" ]] && { log_error "No RPM asset found"; rm -rf "${temp_dir}"; return 1; }
            download_file_robust "${url}" "${temp_dir}/opendeck.rpm" || { rm -rf "${temp_dir}"; return 1; }
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
            download_file_robust "${url}" "${temp_dir}/noteshub.deb" || { rm -rf "${temp_dir}"; return 1; }
            ${elevation_cmd} dpkg -i "${temp_dir}/noteshub.deb" || ${elevation_cmd} apt-get install -f -y
            ;;
        dnf|yum|zypper)
            [[ "${arch_suffix}" != "amd64" ]] && { log_error "RPM only for x86_64"; rm -rf "${temp_dir}"; return 1; }
            local url; url="$(echo "${api_response}" | grep '"browser_download_url":.*NotesHub-.*\.x86_64\.rpm"' \
                | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')"
            [[ -z "${url}" ]] && { log_error "No RPM asset"; rm -rf "${temp_dir}"; return 1; }
            download_file_robust "${url}" "${temp_dir}/noteshub.rpm" || { rm -rf "${temp_dir}"; return 1; }
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

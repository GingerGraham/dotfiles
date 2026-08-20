#!/usr/bin/env bash
# lazy/installers-iac.sh
# shellcheck disable=SC1091
source "${SHELL_CONFIG_DIR:-$HOME/.config/shell}/lazy/installers-common.sh"


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
        Linux) _tf-install-linux "${tf_version}" && install-tflint && install-trivy ;;
        Mac)   _tf-install-mac "${tf_version}"   && install-tflint && install-trivy ;;
        *)     log_error "Unsupported OS"; return 1 ;;
    esac
}


# ── tenv install (OpenTofu / Terraform version manager) ───────────────────────
# Upstream: https://github.com/tofuutils/tenv
# Release artifacts are cosign-signed. We verify the checksums file and the asset
# with cosign when it's present, then always confirm the SHA256. Without cosign
# we fall back to SHA256-only (set TENV_INSTALL_REQUIRE_COSIGN=true to make
# cosign mandatory).

_tenv_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) log_error "tenv: unsupported architecture $(uname -m)"; return 1 ;;
    esac
}


# Extract a browser_download_url whose filename matches an extended regex.
_tenv_asset_url() {
    local api_json="$1" pattern="$2"
    printf '%s' "${api_json}" \
        | grep -Eo '"browser_download_url": *"[^"]+"' \
        | sed -E 's/.*"(https[^"]+)"/\1/' \
        | grep -E "${pattern}" \
        | head -1
}


# cosign keyless verification of a blob against its detached sig + certificate.
_tenv_cosign_verify() {
    # $1 file  $2 sig  $3 pem  $4 tag
    cosign verify-blob \
        --certificate-identity "https://github.com/tofuutils/tenv/.github/workflows/release.yml@refs/tags/$4" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        --signature "$2" \
        --certificate "$3" \
        "$1"
}


# Download asset + checksums (+ sigs/pems) into $1, verify, and on success set
# _TENV_VERIFIED_ASSET to the verified asset path. Returns non-zero on any
# verification failure. (Path is returned via a variable, not stdout, so logger
# output can't contaminate it.)
_tenv_fetch_and_verify() {
    local tmp="$1" tag="$2" asset_pattern="$3" api_json="$4"
    _TENV_VERIFIED_ASSET=""

    local asset_url sig_url pem_url sums_url sums_sig_url sums_pem_url
    asset_url="$(_tenv_asset_url     "${api_json}" "${asset_pattern}\$")"
    sig_url="$(_tenv_asset_url       "${api_json}" "${asset_pattern}\.sig\$")"
    pem_url="$(_tenv_asset_url       "${api_json}" "${asset_pattern}\.pem\$")"
    sums_url="$(_tenv_asset_url      "${api_json}" "_checksums\.txt\$")"
    sums_sig_url="$(_tenv_asset_url  "${api_json}" "_checksums\.txt\.sig\$")"
    sums_pem_url="$(_tenv_asset_url  "${api_json}" "_checksums\.txt\.pem\$")"

    [[ -z "${asset_url}" ]] && { log_error "tenv: no asset matching /${asset_pattern}/ in ${tag}"; return 1; }
    [[ -z "${sums_url}"  ]] && { log_error "tenv: checksums file not found in ${tag}"; return 1; }

    local asset; asset="$(basename "${asset_url}")"
    log_info "tenv: downloading ${asset} ..."
    _download_file_robust "${asset_url}" "${tmp}/${asset}"                   || return 1
    _download_file_robust "${sums_url}"  "${tmp}/$(basename "${sums_url}")"  || return 1

    if command -v cosign &>/dev/null; then
        if [[ -n "${sig_url}" && -n "${pem_url}" && -n "${sums_sig_url}" && -n "${sums_pem_url}" ]]; then
            _download_file_robust "${sig_url}"      "${tmp}/$(basename "${sig_url}")"      || return 1
            _download_file_robust "${pem_url}"      "${tmp}/$(basename "${pem_url}")"      || return 1
            _download_file_robust "${sums_sig_url}" "${tmp}/$(basename "${sums_sig_url}")" || return 1
            _download_file_robust "${sums_pem_url}" "${tmp}/$(basename "${sums_pem_url}")" || return 1

            log_info "tenv: verifying checksums signature with cosign ..."
            ( cd "${tmp}" && _tenv_cosign_verify \
                "$(basename "${sums_url}")" "$(basename "${sums_sig_url}")" "$(basename "${sums_pem_url}")" "${tag}" ) \
                || { log_error "tenv: cosign verification of checksums failed"; return 1; }

            log_info "tenv: verifying ${asset} signature with cosign ..."
            ( cd "${tmp}" && _tenv_cosign_verify \
                "${asset}" "$(basename "${sig_url}")" "$(basename "${pem_url}")" "${tag}" ) \
                || { log_error "tenv: cosign verification of ${asset} failed"; return 1; }
        else
            log_warn "tenv: cosign present but signature assets missing for ${tag} — skipping cosign step"
        fi
    elif [[ "${TENV_INSTALL_REQUIRE_COSIGN:-false}" == "true" ]]; then
        log_error "tenv: cosign required (TENV_INSTALL_REQUIRE_COSIGN=true) but not installed. Run install-cosign."
        return 1
    else
        log_warn "tenv: cosign not installed — SHA256-only verification. Run install-cosign for signature checks."
    fi

    log_info "tenv: verifying SHA256 checksum ..."
    ( cd "${tmp}" && sha256sum -c "$(basename "${sums_url}")" --ignore-missing ) \
        || { log_error "tenv: SHA256 verification failed"; return 1; }

    _TENV_VERIFIED_ASSET="${tmp}/${asset}"
    return 0
}


_tenv-install-rpm() {
    local tag="$1" api_json="$2" arch; arch="$(_tenv_arch)" || return 1
    local tmp; tmp="$(mktemp -d)"
    _tenv_fetch_and_verify "${tmp}" "${tag}" "tenv_${tag}_${arch}\.rpm" "${api_json}" \
        || { rm -rf "${tmp}"; return 1; }
    local ec; ec="$(get-elevation-command)" || { rm -rf "${tmp}"; return 1; }
    log_info "tenv: installing $(basename "${_TENV_VERIFIED_ASSET}") ..."
    if command -v dnf &>/dev/null; then
        ${ec} dnf install -y "${_TENV_VERIFIED_ASSET}"
    elif command -v zypper &>/dev/null; then
        # rpm is already cosign-verified by us; zypper's own GPG check is moot here.
        ${ec} zypper --non-interactive install --allow-unsigned-rpm "${_TENV_VERIFIED_ASSET}"
    else
        ${ec} yum install -y "${_TENV_VERIFIED_ASSET}"
    fi
    local rc=$?; rm -rf "${tmp}"; return $rc
}


_tenv-install-deb() {
    local tag="$1" api_json="$2" arch; arch="$(_tenv_arch)" || return 1
    local tmp; tmp="$(mktemp -d)"
    _tenv_fetch_and_verify "${tmp}" "${tag}" "tenv_${tag}_${arch}\.deb" "${api_json}" \
        || { rm -rf "${tmp}"; return 1; }
    local ec; ec="$(get-elevation-command)" || { rm -rf "${tmp}"; return 1; }
    log_info "tenv: installing $(basename "${_TENV_VERIFIED_ASSET}") ..."
    ${ec} dpkg -i "${_TENV_VERIFIED_ASSET}" || ${ec} apt-get install -f -y
    local rc=$?; rm -rf "${tmp}"; return $rc
}


_tenv-install-arch() {
    local tag="$1" api_json="$2"
    local tmp; tmp="$(mktemp -d)"
    _tenv_fetch_and_verify "${tmp}" "${tag}" "tenv_${tag}_.*\.pkg\.tar\.zst" "${api_json}" \
        || { rm -rf "${tmp}"; return 1; }
    local ec; ec="$(get-elevation-command)" || { rm -rf "${tmp}"; return 1; }
    log_info "tenv: installing $(basename "${_TENV_VERIFIED_ASSET}") ..."
    ${ec} pacman -U --noconfirm "${_TENV_VERIFIED_ASSET}"
    local rc=$?; rm -rf "${tmp}"; return $rc
}


# Generic fallback: extract binaries to ~/.local/bin (root-free). Matches loosely
# on _Linux_*.tar.gz to stay robust to the goreleaser arch token (x86_64 vs amd64).
_tenv-install-tarball() {
    local tag="$1" api_json="$2"
    local tmp; tmp="$(mktemp -d)"
    _tenv_fetch_and_verify "${tmp}" "${tag}" "tenv_${tag}_Linux_.*\.tar\.gz" "${api_json}" \
        || { rm -rf "${tmp}"; return 1; }
    log_info "tenv: extracting to ~/.local/bin ..."
    mkdir -p "${HOME}/.local/bin"
    tar -xzf "${_TENV_VERIFIED_ASSET}" -C "${tmp}" \
        || { log_error "tenv: extraction failed"; rm -rf "${tmp}"; return 1; }
    local b
    for b in tenv tofu terraform tf tg tm at terragrunt terramate atmos; do
        [[ -f "${tmp}/${b}" ]] && { cp "${tmp}/${b}" "${HOME}/.local/bin/${b}"; chmod +x "${HOME}/.local/bin/${b}"; }
    done
    rm -rf "${tmp}"
    command -v tenv &>/dev/null || { log_error "tenv: not on PATH after install (is ~/.local/bin on PATH?)"; return 1; }
}


install-tenv() {
    log_info "Installing or updating tenv (OpenTofu / Terraform version manager)..."
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    if [[ "${DOTFILES_OS}" == "Mac" ]]; then
        command -v brew &>/dev/null || { log_error "brew is required on macOS"; return 1; }
        if brew list tenv &>/dev/null; then brew upgrade tenv; else brew install tenv; fi
        return $?
    fi

    local api_json tag
    api_json="$(curl -fsSL https://api.github.com/repos/tofuutils/tenv/releases/latest)" \
        || { log_error "tenv: could not query release API"; return 1; }
    tag="$(printf '%s' "${api_json}" | grep -E '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
    [[ -z "${tag}" ]] && { log_error "tenv: could not determine latest version"; return 1; }
    log_info "tenv: latest release is ${tag}"

    if command -v tenv &>/dev/null; then
        local current; current="$(tenv version 2>/dev/null | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if [[ "${current}" == "${tag}" ]]; then
            log_info "tenv ${tag} already installed"; return 0
        fi
        log_info "tenv: updating ${current:-unknown} → ${tag}"
    fi

    [[ -z "${PACKAGE_MANAGER}" ]] && detect-package-manager

    case "${PACKAGE_MANAGER}" in
        dnf|yum)  _tenv-install-rpm     "${tag}" "${api_json}" ;;
        zypper)   _tenv-install-rpm     "${tag}" "${api_json}" ;;
        apt)      _tenv-install-deb     "${tag}" "${api_json}" ;;
        pacman)   _tenv-install-arch    "${tag}" "${api_json}" ;;
        *)        _tenv-install-tarball "${tag}" "${api_json}" ;;
    esac
    local rc=$?

    if [[ $rc -eq 0 ]] && command -v tenv &>/dev/null; then
        log_info "tenv installed: $(tenv version 2>/dev/null | head -1)"
        log_info "TENV_AUTO_INSTALL is set in env/20-development.sh — tofu/terraform versions install on first use."
        command -v cosign &>/dev/null \
            || log_warn "cosign not present: tenv falls back to PGP/SHA for tofu & terraform checks. Run install-cosign for full cosign verification."
    fi
    return $rc
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


# ── AWS CLI install ───────────────────────────────────────────────────────────
# AWS ships the CLI v2 as a self-contained installer bundle rather than distro
# packages, so the same curl+unzip flow covers every Linux distro; only macOS
# differs (Homebrew).
_aws_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) log_error "AWS CLI: unsupported architecture $(uname -m)"; return 1 ;;
    esac
}


_aws-install-linux() {
    local arch; arch="$(_aws_arch)" || return 1
    command -v unzip &>/dev/null || { log_error "unzip is required for AWS CLI installation"; return 1; }

    local tmp_dir; tmp_dir="$(mktemp -d)"
    log_info "Downloading AWS CLI installer (${arch})..."
    _download_file_robust "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" "${tmp_dir}/awscliv2.zip" \
        || { rm -rf "${tmp_dir}"; return 1; }
    unzip -q "${tmp_dir}/awscliv2.zip" -d "${tmp_dir}" \
        || { log_error "AWS CLI: failed to extract installer"; rm -rf "${tmp_dir}"; return 1; }

    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || { rm -rf "${tmp_dir}"; return 1; }
    local rc=0
    if command -v aws &>/dev/null; then
        local aws_path; aws_path="$(command -v aws)"
        ${elevation_cmd} "${tmp_dir}/aws/install" --update --bin-dir "$(dirname "${aws_path}")" || rc=1
    else
        ${elevation_cmd} "${tmp_dir}/aws/install" || rc=1
    fi
    rm -rf "${tmp_dir}"
    return "${rc}"
}


_aws-install-mac() {
    command -v brew &>/dev/null || { log_error "Homebrew required on macOS"; return 1; }
    if command -v aws &>/dev/null; then brew upgrade awscli; else brew install awscli; fi
}


install-aws() {
    log_info "Installing or updating AWS CLI..."
    case "${DOTFILES_OS}" in
        Linux) _aws-install-linux ;;
        Mac)   _aws-install-mac ;;
        *)     log_error "Unsupported OS for AWS CLI install"; return 1 ;;
    esac
    local rc=$?

    if [[ ${rc} -eq 0 ]] && command -v aws &>/dev/null; then
        log_info "AWS CLI installed: $(aws --version 2>&1 | head -1)"
    elif [[ ${rc} -ne 0 ]]; then
        log_error "AWS CLI install failed"
    else
        log_warn "aws not found on PATH after install."
    fi
    return "${rc}"
}


# ── Azure CLI install ─────────────────────────────────────────────────────────
# Microsoft publishes a vendor repo for rhel/debian/suse (packages.microsoft.com);
# Arch has no official package, so it falls back to the community AUR package
# (same yay-or-manual-makepkg pattern as install-1password's arch helper); any
# other/unknown distro falls back further to pip, which works everywhere Python
# does. macOS uses Homebrew.
_azure-install-rhel() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} rpm --import https://packages.microsoft.com/keys/microsoft.asc

    if [[ ! -f /etc/yum.repos.d/azure-cli.repo ]]; then
        ${elevation_cmd} sh -c 'echo -e "[azure-cli]\nname=Azure CLI\nbaseurl=https://packages.microsoft.com/yumrepos/azure-cli\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/azure-cli.repo'
    fi

    if command -v dnf &>/dev/null; then
        ${elevation_cmd} dnf install -y azure-cli
    else
        ${elevation_cmd} yum install -y azure-cli
    fi
}


_azure-install-debian() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    ${elevation_cmd} apt-get update
    ${elevation_cmd} apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

    ${elevation_cmd} mkdir -p /etc/apt/keyrings
    curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
        | ${elevation_cmd} gpg --dearmor --output /etc/apt/keyrings/microsoft.gpg
    ${elevation_cmd} chmod go+r /etc/apt/keyrings/microsoft.gpg

    local az_dist
    az_dist="$(lsb_release -cs 2>/dev/null)"
    [[ -z "${az_dist}" ]] && az_dist="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
    [[ -z "${az_dist}" ]] && { log_error "azure-cli: could not determine distro codename"; return 1; }

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${az_dist} main" \
        | ${elevation_cmd} tee /etc/apt/sources.list.d/azure-cli.list > /dev/null

    ${elevation_cmd} apt-get update
    ${elevation_cmd} apt-get install -y azure-cli
}


_azure-install-suse() {
    local elevation_cmd; elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} rpm --import https://packages.microsoft.com/keys/microsoft.asc

    if ! zypper lr 2>/dev/null | grep -qi 'azure-cli'; then
        ${elevation_cmd} zypper addrepo --name 'Azure CLI' --check https://packages.microsoft.com/yumrepos/azure-cli azure-cli
    else
        log_info "azure-cli zypper repo already present"
    fi
    ${elevation_cmd} zypper --gpg-auto-import-keys refresh
    ${elevation_cmd} zypper install -y --from azure-cli azure-cli
}


_azure-install-arch() {
    # No official Arch package — community-maintained AUR package.
    if command -v yay &>/dev/null; then
        yay -S --noconfirm azure-cli
    else
        log_info "yay not found — cloning azure-cli AUR package manually..."
        local tmp_dir; tmp_dir="$(mktemp -d)"
        git clone https://aur.archlinux.org/azure-cli.git "${tmp_dir}/azure-cli" \
            || { log_error "Failed to clone azure-cli AUR package"; rm -rf "${tmp_dir}"; return 1; }
        ( cd "${tmp_dir}/azure-cli" && makepkg -si --noconfirm )
        rm -rf "${tmp_dir}"
    fi
}


_azure-install-pip() {
    local pip_cmd
    pip_cmd="$(command -v pip3 || command -v pip)"
    [[ -z "${pip_cmd}" ]] && { log_error "pip3 (or pip) is required to install Azure CLI without a supported distro repo"; return 1; }
    log_info "azure-cli: installing via ${pip_cmd} into the user site..."
    "${pip_cmd}" install --user --upgrade azure-cli
}


_azure-install-mac() {
    command -v brew &>/dev/null || { log_error "Homebrew required on macOS"; return 1; }
    if command -v az &>/dev/null; then brew upgrade azure-cli; else brew install azure-cli; fi
}


install-azure() {
    log_info "Installing or updating Azure CLI..."

    case "${DOTFILES_OS}" in
        Mac)
            _azure-install-mac
            ;;
        Linux)
            local ok=1
            case "${DOTFILES_DISTRO}" in
                rhel)   _azure-install-rhel   && ok=0 ;;
                debian) _azure-install-debian && ok=0 ;;
                suse)   _azure-install-suse   && ok=0 ;;
                arch)   _azure-install-arch   && ok=0 ;;
                *)      log_warn "Unknown distro (${DOTFILES_DISTRO}) — falling back to pip install" ;;
            esac
            [[ "${ok}" -ne 0 ]] && { _azure-install-pip || return 1; }
            ;;
        *)
            log_error "Unsupported OS for Azure CLI install"; return 1
            ;;
    esac

    if command -v az &>/dev/null; then
        log_info "Azure CLI installed: $(az version --query '"azure-cli"' -o tsv 2>/dev/null || az --version 2>/dev/null | head -1)"
        echo
        echo "  Authenticate with:"
        echo "    az login"
    else
        log_warn "az not found in PATH after install. Restart your shell or check ~/.local/bin."
    fi
}


# ── Google Cloud CLI (gcloud) install ─────────────────────────────────────────
# Google's official interactive installer is the same script on every distro
# and macOS (no vendor apt/dnf/zypper repo baked in by default), so there is
# no per-distro branching here — unlike aws/azure. Installs to
# ~/google-cloud-sdk and self-updates thereafter via `gcloud components update`.
#
# The upstream script offers, interactively, to append PATH/completion
# sourcing to shell rc files; --disable-prompts skips that entirely in a
# non-interactive run. _restore_managed_shell_files is still called
# afterward, belt-and-suspenders style (same as install-antigravity) — our rc
# files are managed symlinks and any injected lines would dirty the working
# tree and block the sync timer.
install-gcloud() {
    log_info "Installing or updating Google Cloud CLI (gcloud)..."

    if command -v gcloud &>/dev/null; then
        log_info "gcloud found — updating components..."
        gcloud components update --quiet
        return $?
    fi

    command -v curl &>/dev/null || { log_error "curl is required"; return 1; }

    curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts \
        || { log_error "Google Cloud CLI installer failed"; return 1; }
    _restore_managed_shell_files

    local sdk_bin="${HOME}/google-cloud-sdk/bin"
    [[ ":${PATH}:" != *":${sdk_bin}:"* ]] && PATH="${sdk_bin}:${PATH}"

    if command -v gcloud &>/dev/null; then
        log_info "Google Cloud CLI installed: $(gcloud --version 2>/dev/null | head -1)"
        echo
        echo "  ~/google-cloud-sdk/bin is not added to your managed shell rc files automatically."
        echo "  Add it to PATH yourself in ~/.config/dotfiles/local/90-local.sh, e.g.:"
        echo "    export PATH=\"\${HOME}/google-cloud-sdk/bin:\${PATH}\""
        echo
        echo "  Authenticate with:"
        echo "    gcloud init"
    else
        log_warn "gcloud not found on PATH after install. Check ~/google-cloud-sdk/bin."
    fi
}

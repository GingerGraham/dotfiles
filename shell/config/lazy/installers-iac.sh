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
        Linux) _tf-install-linux "${tf_version}" && tflint-install && trivy-install ;;
        Mac)   _tf-install-mac "${tf_version}"   && tflint-install && trivy-install ;;
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


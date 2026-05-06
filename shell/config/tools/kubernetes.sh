#!/usr/bin/env bash
# Kubernetes tool configuration — aliases and kubectl version management.
# Sourced only when kubectl is present (guarded in loader.sh).

# ── aliases ───────────────────────────────────────────────────────────────────
alias k="kubectl"
alias kube-version="kubectl version --client --short 2>/dev/null \
    || kubectl version --client | awk '/Client Version:/{print \$NF}' | sed 's/^v//'"

# ── functions ─────────────────────────────────────────────────────────────────
set-kubectl() {
    local KUBECTL_VERSION="" USE_LATEST=""

    while getopts ":hlsv:" opt; do
        case ${opt} in
            h) echo "Usage: set-kubectl [-v version|-l]"; return 0 ;;
            l|s) USE_LATEST=true ;;
            v)   KUBECTL_VERSION="${OPTARG}" ;;
            \?)  log_error "Invalid option: -${OPTARG}"; return 1 ;;
        esac
    done

    if [[ "${USE_LATEST}" == "true" ]]; then
        log_info "Fetching latest stable kubectl version..."
        KUBECTL_VERSION="$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)"
        KUBECTL_VERSION="${KUBECTL_VERSION#v}"
        log_info "Latest kubectl: ${KUBECTL_VERSION}"
    fi

    [[ -z "${KUBECTL_VERSION}" ]] && KUBECTL_VERSION="${1:-}"

    if [[ ! "${KUBECTL_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if [[ "${KUBECTL_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
            KUBECTL_VERSION="${KUBECTL_VERSION}.0"
        else
            log_error "Invalid kubectl version: '${KUBECTL_VERSION}'"
            return 1
        fi
    fi

    if command -v kubectl &>/dev/null; then
        local current
        current="$(kubectl version --client --short 2>/dev/null \
            || kubectl version --client | awk '/Client Version:/{print $NF}' | sed 's/^v//')"
        if [[ "${current}" == "${KUBECTL_VERSION}" ]]; then
            log_info "kubectl ${KUBECTL_VERSION} already active"; return 0
        fi
    fi

    local kubectl_dir="${HOME}/.local/bin/k8s/kubectl-${KUBECTL_VERSION}"
    mkdir -p "${kubectl_dir}"

    local kubectl_url
    case "${DOTFILES_OS}" in
        Mac)   kubectl_url="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/darwin/amd64/kubectl" ;;
        Linux) kubectl_url="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" ;;
        *)     log_error "Unsupported OS"; return 1 ;;
    esac

    if [[ ! -f "${kubectl_dir}/kubectl" ]]; then
        log_info "Downloading kubectl ${KUBECTL_VERSION}..."
        curl -sSL "${kubectl_url}" -o "${kubectl_dir}/kubectl"
        chmod +x "${kubectl_dir}/kubectl"
    fi

    if [[ ! -x "${kubectl_dir}/kubectl" ]]; then
        log_error "kubectl download failed"; return 1
    fi

    # Replace current symlink or binary
    local current_path
    current_path="$(command -v kubectl 2>/dev/null)"
    if [[ -n "${current_path}" ]]; then
        if [[ -L "${current_path}" ]]; then
            rm "${current_path}"
        else
            mv "${current_path}" "${current_path}.old"
        fi
    fi

    ln -s "${kubectl_dir}/kubectl" "${HOME}/.local/bin/kubectl"
    log_info "kubectl ${KUBECTL_VERSION} active"
}

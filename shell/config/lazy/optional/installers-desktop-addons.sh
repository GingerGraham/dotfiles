#!/usr/bin/env bash
# Not loaded at shell startup. Stubs are registered only when
# DOTFILES_OPTIONAL_INSTALLERS=true is set in env/90-local.sh.
# Functions here must also appear in _optional_tools_registry() in maintenance.sh.
# shellcheck disable=SC1091
source "${SHELL_CONFIG_DIR:-$HOME/.config/shell}/lazy/installers-common.sh"


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

#!/usr/bin/env bash
# AWS tool configuration.
# Sourced only when aws CLI is present (guarded in loader.sh).

# ── functions ─────────────────────────────────────────────────────────────────
aws-update() {
    log_info "Updating AWS CLI..."

    if [[ "${DOTFILES_OS}" == "Mac" ]] && command -v brew &>/dev/null; then
        brew upgrade awscli
        return $?
    fi

    # Linux: download and re-run the official installer
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    if ! curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${tmp_dir}/awscliv2.zip"; then
        log_error "Failed to download AWS CLI installer"
        rm -rf "${tmp_dir}"
        return 1
    fi

    if ! command -v unzip &>/dev/null; then
        log_error "unzip is required for AWS CLI installation"
        rm -rf "${tmp_dir}"
        return 1
    fi

    unzip -q "${tmp_dir}/awscliv2.zip" -d "${tmp_dir}"

    local elevation_cmd
    elevation_cmd="$(get-elevation-command)" || { rm -rf "${tmp_dir}"; return 1; }

    if command -v aws &>/dev/null; then
        local aws_path
        aws_path="$(command -v aws)"
        ${elevation_cmd} "${tmp_dir}/aws/install" --update --bin-dir "$(dirname "${aws_path}")" \
            || { log_error "AWS CLI update failed"; rm -rf "${tmp_dir}"; return 1; }
    else
        ${elevation_cmd} "${tmp_dir}/aws/install" \
            || { log_error "AWS CLI install failed"; rm -rf "${tmp_dir}"; return 1; }
    fi

    rm -rf "${tmp_dir}"
    log_info "AWS CLI updated to $(aws --version 2>&1 | head -1)"
}

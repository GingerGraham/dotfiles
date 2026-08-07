#!/usr/bin/env bash
# Go (golang) environment configuration.
# Sourced only when go is present (guarded in loader.sh).

# ── functions ─────────────────────────────────────────────────────────────────
if command -v go &>/dev/null; then
    # Populate GO_VERSION, stripping the leading "go" and any build/experiment
    # suffix Go appends after a hyphen or plus, e.g.:
    #   go1.26.5-X:nodwarf5  ->  1.26.5
    #   go1.22.0             ->  1.22.0
    _set-go-version() {
        local field
        field="$(go version 2>/dev/null | awk '{print $3}')"
        field="${field#go}"        # strip leading "go"
        field="${field%%[-+]*}"    # strip "-X:..." / "+build" style suffixes
        GO_VERSION="${field}"
        export GO_VERSION
    }

    get-go-version() {
        _set-go-version
        log_info "Go version: ${GO_VERSION}"
    }

    # Populate GO_VERSION on load — quiet, consistent with the log_debug-at-init
    # convention used elsewhere in tools/ (omp.sh, starship.sh, omz.sh).
    _set-go-version
    log_debug "Go version: ${GO_VERSION}"
fi

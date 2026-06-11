#!/usr/bin/env bash
# Go (golang) environment configuration.
# Sourced only when go is present (guarded in loader.sh).

# ── functions ─────────────────────────────────────────────────────────────────
get-go-version() {
    GO_VERSION="$(go version | awk '{print $3}' | tr -d 'go')"
    export GO_VERSION
    log_debug "Go version: ${GO_VERSION}"
}

# Populate GO_VERSION on load (fast — go version is a compiled binary)
get-go-version 2>/dev/null || true

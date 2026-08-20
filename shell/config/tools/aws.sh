#!/usr/bin/env bash
# AWS tool configuration.
# Sourced only when aws CLI is present (guarded in loader.sh).

# ── functions ─────────────────────────────────────────────────────────────────
# Thin wrapper — install-aws (lazy/installers-iac.sh) already handles both the
# fresh-install and update-in-place cases across every platform. Kept here as
# a short, memorable name for anyone reaching for "aws-update" out of habit.
aws-update() {
    install-aws
}

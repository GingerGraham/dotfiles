#!/usr/bin/env bash
# Security tool configuration — ClamAV and vulnerability scanners.
# Sourced when clamscan or trivy is present (guarded in loader.sh).

# ── ClamAV aliases ────────────────────────────────────────────────────────────
if command -v clamscan &>/dev/null; then
    alias av="sudo clamscan -r"
    alias clam="sudo clamscan -r"
    alias scan="sudo clamscan -r"
    alias clam-home="echo '[INFO] Scanning /home'; sudo nice -n 15 clamscan --bell -i -r /home"
    alias av-home="echo '[INFO] Scanning /home'; sudo nice -n 15 clamscan --bell -i -r /home"
    alias clam-update="sudo freshclam"
    alias av-update="sudo freshclam"
fi

# ── Sonar scanner alias ───────────────────────────────────────────────────────
if command -v sonar-scanner &>/dev/null; then
    alias sq="sonar-scanner -Dsonar.token=$(secret-tool lookup service sonarqube account scanner 2>/dev/null) -X"
fi

# ── netcat compatibility ──────────────────────────────────────────────────────
if command -v nc &>/dev/null; then
    alias netcat="nc"
    alias telnet="nc"
fi

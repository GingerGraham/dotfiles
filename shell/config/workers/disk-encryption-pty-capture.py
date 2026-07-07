#!/usr/bin/env python3
"""
Run a command inside a real pty — so interactive terminal behavior (echo
suppression for password prompts, etc.) works exactly as if run directly —
while logging everything the command outputs to a file.

This process is expected to already be running as root (invoked via `sudo
python3 ...` by the caller). It creates the logfile itself, with O_EXCL, so
there is never a point where a file created by one user is opened by
another — no DAC/mount-namespace/SELinux edge case to hit, and no chown-back
needed. The caller reads and removes the file afterwards via `sudo cat` /
`sudo shred`, since it remains root-owned for its whole lifecycle.

Deliberately invoked as a file, not piped into `python3 -` via stdin: doing
that would tie up fd 0 with the script source itself, leaving pty.spawn()'s
stdin-forwarding with nothing live to relay and no way to reach the child.

Called from shell/config/lazy/disk-encryption.sh.
"""
import os
import pty
import sys

if len(sys.argv) < 3:
    print("usage: disk-encryption-pty-capture.py <logfile> <command> [args...]", file=sys.stderr)
    sys.exit(2)

logfile = sys.argv[1]
argv = sys.argv[2:]

# O_EXCL: refuse to open a pre-existing file at this path — the caller only
# ever passes a freshly mktemp -u'd (name reserved, not created) path, so
# this should always be a fresh create. Mode 600 set at creation time rather
# than via a separate chmod, closing the brief window a chmod-after-create
# would otherwise leave.
fd = os.open(logfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)

with os.fdopen(fd, "ab") as fh:
    def _capture(fd_: int) -> bytes:
        data = os.read(fd_, 1024)
        if data:
            fh.write(data)
            fh.flush()
        return data

    pty.spawn(argv, _capture)
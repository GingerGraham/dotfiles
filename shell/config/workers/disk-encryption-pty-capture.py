#!/usr/bin/env python3
"""
Run a command inside a real pty — so interactive terminal behavior (echo
suppression for password prompts, etc.) works exactly as if run directly —
while logging everything the command outputs to a file.

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

with open(logfile, "ab") as fh:
    def _capture(fd):
        data = os.read(fd, 1024)
        if data:
            fh.write(data)
            fh.flush()
        return data

    pty.spawn(argv, _capture)

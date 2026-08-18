# User-defined config extensions

A machine-local drop-in directory for your own functions, aliases, and
installers — outside the dotfiles repo, with no repo involvement beyond
loading it.

## Table of Contents

- [User-defined config extensions](#user-defined-config-extensions)
  - [Table of Contents](#table-of-contents)
  - [What it's for](#what-its-for)
  - [Where it lives, and why it's outside the repo](#where-it-lives-and-why-its-outside-the-repo)
  - [Loading order and shadowing](#loading-order-and-shadowing)
  - [The bash -n gate and stamp caching](#the-bash--n-gate-and-stamp-caching)
  - [check-user-extensions](#check-user-extensions)
  - [The optional \_user\_tools\_registry contract](#the-optional-_user_tools_registry-contract)
  - [Environment variables](#environment-variables)

## What it's for

`90-local.sh` is the machine-local env override file — it's for
environment variables (PATH extensions, proxy settings, credentials), not for
functions, aliases, or installers. Overloading it with those would be the
wrong shape. `DOTFILES_USER_EXT_DIR` is a proper drop-in directory for that
instead: drop any number of `*.sh` files there and the loader sources them,
last, on every shell start.

There is no naming convention, no template, and no Ansible-managed content —
just a flat directory of files you write yourself.

## Where it lives, and why it's outside the repo

Default: `${XDG_CONFIG_HOME}/dotfiles/user` (typically `~/.config/dotfiles/user`).

This sits in the existing `~/.config/dotfiles/` namespace alongside
`migration/`. It is deliberately **outside** `SHELL_CONFIG_DIR`
(`~/.config/shell`), which is a symlink into the dotfiles repo working tree.
Anything placed under `~/.config/shell` would make `git status` on the repo
dirty and block the external-sync timer (see [external-sync.md](external-sync.md))
from pulling. Keeping user files in a genuinely separate, machine-local
directory avoids that entirely — Ansible creates the directory once and has
no further involvement (see `ansible/roles/shell/tasks/main.yml`, Section 6d).

## Loading order and shadowing

User extension files are sourced in `loader.sh`:

- **after** `90-local.sh` ("Local overrides, always last") — so user
  definitions shadow everything, including machine-local env overrides;
- **before** `dedupe-path` — so PATH entries added by a user file still get
  deduplicated.

Because user files load last, a function or alias you define with the same
name as a repo-defined one **replaces** it in your shell. This is the
intended semantic, not a bug — `check-user-extensions` reports these as
informational breadcrumbs, never as errors.

## The bash -n gate and stamp caching

Startup cost matters, so the loader doesn't blindly re-source every user file
on every shell start without checking it first — but it also doesn't want to
fork a `bash -n` subprocess per file on every single shell start once things
are stable.

The compromise: a single stamp file at
`${XDG_CACHE_HOME}/dotfiles/user-ext.stamp`, compared against each user file
with the `-nt` test operator (a shell builtin in both bash and zsh — no
`stat` subprocess, which would cost as much as the `bash -n` it's meant to
avoid, and whose flags differ between GNU and BSD anyway):

```bash
if [[ ! -f "${stamp}" ]] || [[ "${file}" -nt "${stamp}" ]]; then
    # file is new or has changed since the last successful check — run bash -n
fi
```

- A file that hasn't changed since the last successful check is sourced
  directly — zero subprocesses in the steady state.
- A file that's new or modified gets a `bash -n` syntax smoke-test before
  being sourced.
- If `bash -n` fails, the file is **skipped** (not sourced), a warning names
  the file, and the stamp is **withheld** — so that file (and only the
  re-check logic, not the other files) is re-evaluated, and the warning
  repeats, on every subsequent shell start until it's fixed.

`bash -n` runs even under zsh. It is a syntax smoke-test for "is this
obviously broken", not a bash/zsh compatibility gate — zsh has no equivalent
that's safe to run against arbitrary user-supplied files.

Shellcheck does **not** run at startup — it costs 100ms+ per file. It's only
run by `check-user-extensions`, on demand.

## check-user-extensions

A lazy-loaded command (only registered — and only visible in `get-functions`
— when `DOTFILES_USER_EXT_DIR` exists and contains at least one `*.sh` file):

```bash
check-user-extensions [--quiet]
```

Does a full, uncached pass over every file in the directory:

1. **Syntax** — `bash -n` on every file; pass/fail reported per file.
2. **Lint** — if `shellcheck` is installed, runs it per file and prints
   findings. A missing shellcheck is an informational line, never a warning —
   this step never fails the function.
3. **Collisions** — for every function and alias name defined across your
   user files, reports whether that name is also defined somewhere under
   `SHELL_CONFIG_DIR`. Informational only — see
   [Loading order and shadowing](#loading-order-and-shadowing).
4. **Stamp refresh** — if every file passes the syntax check, the startup
   stamp is refreshed too, so a clean manual run also short-circuits the next
   shell start's `bash -n` pass.

Exit status is non-zero **only** if at least one file fails the syntax check
(step 1). Lint findings and collisions never affect the exit code.

`--quiet` suppresses the per-file "OK" / lint / collision informational
lines; syntax failures are still printed (via `log_warn`) regardless.

## The optional `_user_tools_registry` contract

If one of your user files defines a function named `_user_tools_registry`,
`update-tools` picks its rows up automatically and folds them in alongside
the managed and optional tool registries, sorted together.

The contract is identical to `_managed_tools_registry` and
`_optional_tools_registry` in `lazy/maintenance.sh`: a function that emits
pipe-delimited rows on stdout, one per line —

```text
<name>|<detect>|<updater-fn>|<installer-cmd>|<label>
```

- `name` — the id shown in `update-tools --list` and matched against when you
  run `update-tools <name>`
- `detect` — `command -v` target, or `path:<file>` for a non-PATH install
- `updater-fn` — function to run to update the tool when present
- `installer-cmd` — command suggested when the tool is not present
- `label` — human-readable description

Worked example — a user file defining and using a personal tool:

```bash
# ~/.config/dotfiles/user/50-my-tools.sh

_update_my_cli() {
    my-cli self-update
}

install-my-cli() {
    curl -fsSL https://example.com/install-my-cli.sh | sh
}

_user_tools_registry() {
    cat <<'EOF'
my-cli|my-cli|_update_my_cli|install-my-cli|My personal CLI tool
EOF
}
```

After this file loads, `update-tools --list` shows `my-cli` alongside the
managed tools, and `update-tools` (with no args) updates it too.

The presence check is `command -v _user_tools_registry`, not `declare -F` —
user files are eagerly sourced at startup, so by the time the lazy-loaded
`maintenance.sh` runs, the function is already defined if it exists at all.

Note: `tests/check-updater-coverage.sh` is repo-scoped CI and has **no**
visibility into `_user_tools_registry` or the user extension directory — it
checks the repo's own installer/registry coverage only, and is deliberately
not extended to cover user machines.

## Environment variables

| Variable                    | Default                                | Notes                                                |
| ---------------------------- | --------------------------------------- | ----------------------------------------------------- |
| `DOTFILES_USER_EXT_DIR`      | `${XDG_CONFIG_HOME}/dotfiles/user`      | Flat directory, outside the repo. Override in `90-local.sh`. |
| `DOTFILES_USER_EXT_ENABLED`  | `true`                                  | Debug escape hatch only — set `false` in `90-local.sh` to disable entirely. |

See also [shell-config.md](shell-config.md) for where this fits in the
overall loading order, and [tool-management.md](tool-management.md) for how
`update-tools` works more broadly.

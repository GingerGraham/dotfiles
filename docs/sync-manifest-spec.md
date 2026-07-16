# `.dotfiles-sync.yml` — sync manifest spec

This is the authoritative contract for `.dotfiles-sync.yml`. If you are
authoring or updating one, everything you need is in this file — you should
not need to read the dotfiles repo's own Ansible role or sync script to use
this successfully.

If anything here ever disagrees with `ansible/roles/sync-external/tasks/repo.yml`
or `scripts/validate-sync-manifest.sh`, **this file wins** — both cite the
relevant section of this spec in their own validation error messages and in
a comment at their own head, precisely so a disagreement is a bug report
against one of them, not an ambiguity for you to resolve.

## Quick start

Drop this at the root of your add-on repo, adjust `src`/`dest`, commit it,
and you're done:

```yaml
# .dotfiles-sync.yml — schema version 1
version: 1
branch: main

deploy:
  - src: claude/
    dest: ~/.claude/
    mode: copy
    force: false
```

No `.dotfiles-sync.yml` at all is also valid — see [clone-only](#1-clone-only)
below. Run [`scripts/validate-sync-manifest.sh`](#validating-your-manifest)
against your manifest before committing it.

## Table of Contents

- [Purpose](#purpose)
- [Schema version 1](#schema-version-1)
  - [Field reference](#field-reference)
- [Archetypes](#archetypes)
  - [1. Clone-only](#1-clone-only)
  - [2. Copy, never-overwrite](#2-copy-never-overwrite)
  - [3. Symlink, auto-updating](#3-symlink-auto-updating)
  - [4. Clone-only with a post-deploy hook](#4-clone-only-with-a-post-deploy-hook)
- [Deploy semantics](#deploy-semantics)
  - [dest validation](#dest-validation)
- [Hook contract](#hook-contract)
  - [Manifest schema](#hook-manifest-schema)
  - [The `allow_hooks` gate](#the-allow_hooks-gate)
  - [`run_on` semantics](#run_on-semantics)
  - [Invocation](#invocation)
  - [Hook environment](#hook-environment)
  - [Distro detection for hook authors](#distro-detection-for-hook-authors)
  - [Hook obligations](#hook-obligations)
  - [Failure handling](#failure-handling)
  - [Reference hook skeleton](#reference-hook-skeleton)
- [What the engine guarantees / does not](#what-the-engine-guarantees--does-not)
- [How to make your repo compatible](#how-to-make-your-repo-compatible)
- [Validating your manifest](#validating-your-manifest)
- [See also](#see-also)

## Purpose

`.dotfiles-sync.yml` is a small declarative manifest that tells the
[dotfiles external-sync engine](external-sync.md) what to do with your
repository once it's been cloned onto a machine. It lives at the **root of
the add-on repo** — not in the `dotfiles` repo itself.

The dotfiles repo owns the *engine* (cloning, pulling, timers). Your repo
owns the *description of what to do with itself* — which files go where,
copied or symlinked, on which platforms, plus an optional post-deploy hook
for the rare case a declarative copy/link isn't enough. The dotfiles repo
never hardcodes your repo's internal layout; it only reads this file.

The manifest is read by Ansible (`roles/sync-external`), which parses the
YAML and renders it into flat `deploy.list` / `hooks.list` files that the
runtime sync script (`scripts/external-sync.sh`) consumes. **Bash never
parses YAML** — by the time your manifest reaches the sync script it has
already been flattened. This has one consequence worth understanding up
front — see [How to make your repo compatible](#how-to-make-your-repo-compatible).

## Schema version 1

```yaml
# .dotfiles-sync.yml — schema version 1
version: 1
branch: main            # optional; default tracking branch. host_vars/sync.conf value wins if set.

deploy:                 # optional. Omit entirely for clone-only repos.
  - src: claude/                 # required; path within the repo (file or dir), relative to repo root
    dest: ~/.claude/             # required; destination on Linux/WSL (and macOS unless dest_macos given)
    mode: copy                   # optional; copy (default) | link
    force: false                 # optional; copy mode only; overwrite existing? default false
    executable: false            # optional; chmod +x deployed files. default false
    dest_macos: "~/Library/..."  # optional; per-OS destination override for Darwin
    platforms: [linux, macos]    # optional; restrict deployment. default: all

hooks:                  # optional. Omit entirely for a repo with no hooks — see Hook contract.
  post_deploy:                   # the only event in schema v1
    command: ["install.sh", "--unattended"]   # required; argv list — see Hook contract
    run_on: changed               # optional; changed (default) | always | initial
    timeout: 300                  # optional; seconds, default 300
```

### Field reference

| Field | Required | Default | Meaning |
| --- | --- | --- | --- |
| `version` | yes | — | Manifest schema version. Only `1` exists today. |
| `branch` | no | `main` | Branch the engine tracks for this repo. A `GIT_BRANCH` already set at runtime in the repo's `sync.conf` (e.g. via manual edit) takes precedence over this value on subsequent runs — see [Deploy semantics](#deploy-semantics). |
| `deploy` | no | omitted = clone-only | List of deploy entries. Omit the key entirely for a clone-only repo. |
| `deploy[].src` | yes (per entry) | — | Path to a file or directory, relative to the repo root. No leading `/`, no `..` segments — see [Deploy semantics](#deploy-semantics). |
| `deploy[].dest` | yes (per entry) | — | Destination path. May use `~`; the engine expands it to an absolute path before writing `deploy.list`. Used on Linux/WSL and on macOS unless `dest_macos` is also given. Must resolve under `$HOME` — see [dest validation](#dest-validation). |
| `deploy[].mode` | no | `copy` | `copy` or `link`. See [Deploy semantics](#deploy-semantics). |
| `deploy[].force` | no | `false` | `copy` mode only. Whether to overwrite an existing destination file. |
| `deploy[].executable` | no | `false` | `chmod +x` each deployed file. |
| `deploy[].dest_macos` | no | — | Destination override used instead of `dest` when the engine is running on Darwin. Same validation rules as `dest`. |
| `deploy[].platforms` | no | all | List restricting which OSes this entry deploys on. Values: `linux`, `macos`. |
| `hooks` | no | absent | Omit entirely for a repo with no hooks. See [Hook contract](#hook-contract). |
| `hooks.post_deploy` | no | — | The only event in schema v1. Reserved as `hooks.<event>` so a future event can be added without a schema bump. |

## Archetypes

### 1. Clone-only

No `.dotfiles-sync.yml` at all, or one with no `deploy:` block. The engine
clones and keeps the repo pulled; the consuming tool reads the clone
directory directly. This is the right shape whenever your tool reads a fixed
config location — e.g. an editor that always reads `~/.config/<tool>` —
there is nothing to "deploy" elsewhere. See
[docs/external-sync.md's "Choosing a clone directory"](external-sync.md#choosing-a-clone-directory)
for how the *operator* registers a repo this way; nothing in this file
changes based on that choice.

```yaml
# .dotfiles-sync.yml — schema version 1
version: 1
branch: main
```

Or omit the file entirely — a repo with no manifest is treated identically.

### 2. Copy, never-overwrite

`mode: copy` with `force: false` (the default). Files are copied into place
once; if the destination file already exists — because the tool itself
wrote it (an auth token, session cache, machine-local state) — the engine
leaves it alone. This is the right shape for a repo that ships config
templates alongside credentials or state the tool itself manages, where you
never want a `git pull` to clobber what's live on disk.

```yaml
# .dotfiles-sync.yml — schema version 1
version: 1
branch: main

deploy:
  - src: claude/
    dest: ~/.claude/
    mode: copy
    force: false

  - src: copilot/
    dest: ~/.config/github-copilot/
    mode: copy
    force: false
```

### 3. Symlink, auto-updating

`mode: link`. The engine creates a symlink from `dest` to the file inside
the clone directory, so every `git pull` is reflected immediately with no
overwrite question to answer. Good fit for scripts deployed to
`~/.local/bin`.

```yaml
# .dotfiles-sync.yml — schema version 1
version: 1
branch: main

deploy:
  - src: bin/my-tool.sh
    dest: ~/.local/bin/my-tool
    mode: link
    executable: true
```

### 4. Clone-only with a post-deploy hook

Clone-only, plus a `hooks.post_deploy` that runs some setup step the
declarative `deploy:` block can't express — installing plugins, running a
build step, anything that isn't "put this file at that path." See
[Hook contract](#hook-contract) for the full rules; this is just the shape:

```yaml
# .dotfiles-sync.yml — schema version 1
version: 1
branch: main

# Clone-only — nothing to deploy elsewhere, the clone directory IS where the
# tool reads its config from.

hooks:
  post_deploy:
    command: ["hooks/post-deploy.sh"]
    run_on: changed
    timeout: 600
```

Hooks are an escape hatch, not the default. Most repos never need one — reach
for `deploy:` first, and only add a hook when the thing you need genuinely
can't be expressed as "copy/link this path to that path."

## Deploy semantics

- **Path resolution.** `src` is resolved relative to the repo's clone
  directory. `dest` (and `dest_macos`) may use `~`; the engine expands it to
  an absolute path when it writes `deploy.list` — the sync script never
  performs tilde expansion at runtime.
- **`copy` + `force: false`** (default): if the destination already exists,
  skip it — leave whatever is there untouched. If it doesn't exist, copy it.
- **`copy` + `force: true`**: always overwrite the destination with the
  repo's version.
- **`link`**: create a symlink at `dest` pointing at the file in the clone
  directory. `force` governs what happens when `dest` already exists and is
  *not* already the correct symlink — `force: true` replaces it, `force:
  false` leaves it alone.
- **Directories.** A directory `src` deploys recursively, preserving the
  relative structure under `dest`. The repo's own `.git/` directory is
  always excluded from a directory deploy, even for `src: .` (the whole
  repo) — you never need to account for it yourself.
- **Per-OS destination.** On Darwin, the engine uses `dest_macos` if the
  entry defines one, otherwise it falls back to `dest`. On Linux/WSL,
  `dest_macos` is ignored.
- **Per-OS filtering.** `platforms`, if given, restricts whether the entry
  deploys at all on the current OS. An entry with `platforms: [macos]` is
  skipped entirely (not just re-pointed) when running on Linux.
- **Branch precedence.** `branch` in the manifest sets the branch the engine
  clones on first contact. Once `sync.conf` exists for the repo, its
  `GIT_BRANCH` value is authoritative — this is the same field a user edits
  by hand to track a feature branch temporarily, and Ansible will not stomp
  on that choice on subsequent runs.

### `dest` validation

`src` only ever lets the engine *read* from within your clone — `dest` is
the *write* direction, so it's held to a stricter rule. Every `dest` (and
`dest_macos`, when given) must:

- be non-empty;
- resolve under `$HOME` after `~` expansion — anything that doesn't literally
  start with your home directory is rejected;
- contain no `..` path segments;
- not target a path this engine has no business writing into. Each of these
  is owned by a dotfiles role or is a live credential store, so a manifest
  targeting one is always a bug or an attack, never a legitimate use of this
  file:

  ```text
  ~/.ssh/                       ~/.bashrc
  ~/.gnupg/                     ~/.zshrc
  ~/.config/shell/               ~/.profile
  ~/.config/git/                 ~/.gitconfig
  ~/.config/dotfiles/
  ~/.config/external-sync/
  ~/.config/systemd/user/
  ~/Library/LaunchAgents/
  ```

A manifest that fails any of these rules fails the *Ansible run*, loudly,
naming the repo and the offending path — it does not silently deploy nothing
or deploy somewhere unexpected.

## Hook contract

Hooks are an **escape hatch**, not a replacement for the declarative
`deploy:` block — see [Archetype 4](#4-clone-only-with-a-post-deploy-hook).
Most repos never need one. Reach for `deploy:` first.

### Hook manifest schema

```yaml
hooks:
  post_deploy:
    command: ["install.sh", "--unattended"]   # required; argv list, command[0] validated like src
    run_on: changed                            # optional; changed (default) | always | initial
    timeout: 300                               # optional; seconds, default 300
```

| Field | Required | Default | Meaning |
| --- | --- | --- | --- |
| `hooks.post_deploy.command` | yes (if `post_deploy` is given) | — | **A list, not a string** — no shell word-splitting, no quoting ambiguity. A string here fails validation rather than being silently word-split. `command[0]` is a path relative to the clone root, validated identically to `deploy[].src` — non-empty, no leading `/`, no `..` segment. |
| `hooks.post_deploy.run_on` | no | `changed` | See [`run_on` semantics](#run_on-semantics). |
| `hooks.post_deploy.timeout` | no | `300` | Seconds. See [Invocation](#invocation). |

Unknown keys under `hooks.<event>` are ignored, not fatal — forward
compatibility for a future field appearing in a repo synced by an older
dotfiles checkout.

### The `allow_hooks` gate

A hook is gated **twice** before it ever runs, deliberately: the manifest
declares it (this file, authored by the add-on repo), and the machine's
`host_vars` must separately opt in with `allow_hooks: true` on that repo's
entry in `external_synced_repos` (default `false`). A hook is arbitrary code
from your repo, run unattended on a timer — the manifest alone is not
sufficient authorization to run it on someone else's machine.

If your manifest declares a hook and the machine hasn't set `allow_hooks:
true`, the Ansible run still succeeds — it prints a one-line reminder naming
the exact fix and simply doesn't wire the hook up. Adding a hook to your
manifest must never break provisioning on a machine that hasn't opted in.
See [docs/external-sync.md](external-sync.md#adding-a-repo) for how an
operator sets this.

### `run_on` semantics

| Value | Fires when |
| --- | --- |
| `initial` | This is the first successful hook run for this repo on this machine. |
| `changed` *(default)* | The git pull moved `HEAD`, **or** the deploy step actually placed/relinked at least one file, **or** the `initial` condition holds. |
| `always` | Every sync run that gets past the `DEV_MODE` and lock guards. |

A repo's very first sync always gets a chance to run its hook (via the
`initial` condition folded into `changed`'s definition), even if nothing
else about the run would otherwise count as "changed."

### Invocation

```text
cwd            = the repo's clone directory
command line   = timeout <timeout_s> bash <command[0]> <command[1..]>
stdout/stderr  → the repo's own sync log (same file external-sync's other
                 log lines go to)
```

The hook is invoked as `bash <script>`, never by executing the file
directly — the script's own executable bit is irrelevant, and does not need
to be set. This sidesteps a real class of bug: a hook script committed
without `+x` (a very easy mistake) is invoked identically to one committed
`+x`.

**Timeout portability.** GNU coreutils `timeout` is used when present
(Linux). macOS ships neither `timeout` nor `gtimeout` by default (`gtimeout`
only arrives via Homebrew coreutils) — when neither is found, the hook still
runs, just without an enforced timeout, and the engine logs one warning
saying so. Your `timeout` value is therefore a **should**, not a guarantee,
on a macOS machine without Homebrew coreutils installed — write your hook to
be safely interruptible/re-runnable regardless.

### Hook environment

Exported for the hook process only — nothing else in your shell environment
is guaranteed to be present (see [Hook obligations](#hook-obligations)):

| Variable | Value |
| --- | --- |
| `EXTERNAL_SYNC_NAME` | The repo's registered name, e.g. `nvim-config`. |
| `EXTERNAL_SYNC_CLONE_DIR` | Absolute path to the clone (same as the invocation `cwd`). |
| `EXTERNAL_SYNC_BRANCH` | The resolved `GIT_BRANCH` this sync used. |
| `EXTERNAL_SYNC_REASON` | `initial` \| `updated` \| `manual` \| `forced` — see below. |
| `EXTERNAL_SYNC_OS` | `linux` \| `macos`. |
| `EXTERNAL_SYNC_WSL` | `true` \| `false`. |
| `EXTERNAL_SYNC_LOG` | Absolute path to this repo's `logs/sync.log`. |
| `EXTERNAL_SYNC_MANIFEST_VERSION` | `1`. |

`REASON` is what lets one hook script serve both first-run and update
without needing its own sentinel file — it's computed independently of
`run_on` (which controls *whether* the hook fires; `REASON` tells you *why*
this particular firing is happening):

- `forced` — invoked via `external-sync <name> --force-hooks`.
- `manual` — invoked via `external-sync <name>` (a human ran it directly).
- `initial` — this is the first successful hook run for this repo (only
  possible on a timer-driven, all-repos sync).
- `updated` — everything else (a timer-driven sync where this isn't the
  first run).

There is deliberately **no `EXTERNAL_SYNC_DISTRO`**. The engine already
tracks OS (`linux`/`macos`) and WSL, both cheap, unambiguous, engine-level
facts — but Linux distro identity is a much larger taxonomy the engine has
no business dictating to a third-party repo. If your hook needs it, read
`/etc/os-release` yourself — see the next section.

### Distro detection for hook authors

**The engine does not tell you your distro; read `/etc/os-release`
yourself.** It's the systemd/freedesktop standard, present on every
supported Linux distro, absent on macOS — check `EXTERNAL_SYNC_OS` first and
skip this entirely if it's `macos`.

Three traps account for nearly every mistake here:

1. **Source it in a subshell.** `/etc/os-release` is shell-sourceable by
   design, but it sets `NAME`, `VERSION`, `ID`, `PRETTY_NAME` and more into
   whatever scope sources it. Sourcing it directly into your hook's own
   scope clobbers anything you have with those names.
2. **`ID` is exact; `ID_LIKE` is the family, is space-separated, and is
   frequently absent.** Fedora, Debian, and Arch all ship `ID` with **no**
   `ID_LIKE`. Ubuntu has `ID_LIKE=debian`; Manjaro has `ID_LIKE=arch`; Rocky
   has `ID_LIKE="rhel centos fedora"` — multi-valued, so match individual
   words, not the whole string. Check `ID` first, fall back to iterating
   `ID_LIKE` words, then treat it as unknown.
3. **Guard readability.** `[[ -r /etc/os-release ]]` — minimal containers
   occasionally lack it entirely.

```bash
#!/usr/bin/env bash
set -uo pipefail

if [[ "${EXTERNAL_SYNC_OS}" == "macos" ]]; then
    distro="macos"
elif [[ -r /etc/os-release ]]; then
    # Subshell so NAME/ID/ID_LIKE/etc. never touch this script's own scope.
    distro=$(
        . /etc/os-release
        case "${ID:-}" in
            fedora|debian|arch|ubuntu|manjaro|rocky) echo "${ID}" ;;
            *)
                for family in ${ID_LIKE:-}; do
                    case "${family}" in
                        debian|arch|rhel|fedora) echo "${family}"; break ;;
                    esac
                done
                ;;
        esac
    )
    distro="${distro:-unknown}"
else
    distro="unknown"
fi

echo "distro: ${distro}"
```

Dotfiles' own `shell/config/loader.sh` does the equivalent detection for the
interactive shell — hooks deliberately do not depend on it or anything else
from that loader. A hook runs in a bare `bash <script>` process, not a login
shell; see the next section.

### Hook obligations

A hook **must**:

- be idempotent — it fires on every content change, forever, not just once;
- be non-interactive — no TTY, no prompts, no `sudo`; it runs under a
  systemd user timer / launchd agent with nobody watching;
- exit `0` on success, non-zero on failure;
- own all of its own path logic — dotfiles has no opinion about what it
  does beyond invoking it;
- complete within its declared `timeout` (see [Invocation](#invocation) for
  what happens when the enforcement mechanism itself isn't available).

A hook **must not**:

- assume `stdin` is attached;
- assume any dotfiles shell function, `bash-logger`, or `$PATH` entry beyond
  the system default is available — it runs in a bare `bash <script>`
  process, not a login shell. Anything it needs, it must locate itself with
  `command -v` and degrade gracefully (log and `exit 0`) if that thing is
  absent — a missing tool is not a hook failure, it's an environment the
  hook should handle;
- write inside its own clone directory in a way that dirties the git working
  tree. This is the same footgun as `deploy_link_file()` refusing to `chmod`
  a symlink source (see `scripts/external-sync.sh`): a dirty tree trips the
  engine's clean-working-tree guard and **permanently blocks future pulls**
  for that repo until a human notices and cleans it up. If your hook
  generates state, write it outside the clone (e.g. under `$HOME` via a path
  your hook owns, not anything on the [dest denylist](#dest-validation)).

### Failure handling

A hook failing is **non-fatal** — consistent with the engine's stated
design that one repo's problem never aborts the sync of the others, and
extended here to mean a hook's problem never aborts *its own repo's* deploy
either. On non-zero exit or timeout, the engine:

1. logs an ERROR to the repo's own sync log, including the exit code (`124`
   means it was killed for exceeding `timeout`);
2. records the failure in that repo's on-disk state;
3. otherwise carries on exactly as if the hook had not been declared — the
   deploy itself already succeeded; the hook failing doesn't retroactively
   undo that.

On success, the engine records that too, and marks this repo's `run_on:
initial` condition as satisfied (so an `initial` hook fires exactly once,
ever, once it first succeeds — a hook that fails on its first attempt is
retried as `initial` again next run, since it hasn't yet succeeded).

Failures surface in the repo's own log, in `journalctl --user -u
external-sync.service` (Linux), and in `external-sync --status` — see
[docs/external-sync.md](external-sync.md#status-and-troubleshooting). Use
`external-sync <name> --force-hooks` to re-run a hook on demand once you've
fixed whatever made it fail — see [Manual sync](external-sync.md#manual-sync).

### Reference hook skeleton

Copy-paste starting point. This is a shape, not a framework — keep your own
hook this short if you can.

```bash
#!/usr/bin/env bash
set -uo pipefail

# EXTERNAL_SYNC_* is exported by the engine — see "Hook environment" above.
# Never assume anything else from your shell environment is present.

if [[ "${EXTERNAL_SYNC_OS}" != "linux" && "${EXTERNAL_SYNC_OS}" != "macos" ]]; then
    echo "unrecognised EXTERNAL_SYNC_OS='${EXTERNAL_SYNC_OS}' — nothing to do"
    exit 0
fi

# Guard any tool your hook depends on — a missing tool is not a hook
# failure, it's an environment the hook should degrade gracefully in.
if ! command -v some-tool &>/dev/null; then
    echo "some-tool not installed — skipping (install it separately, this hook doesn't)"
    exit 0
fi

# Linux-only step, guarded by EXTERNAL_SYNC_OS before any Linux-only path is
# touched. See "Distro detection for hook authors" if you need distro
# identity specifically, not just linux vs macos.
if [[ "${EXTERNAL_SYNC_OS}" == "linux" && -r /etc/os-release ]]; then
    distro=$(. /etc/os-release && echo "${ID:-unknown}")
    echo "running on ${distro}"
fi

echo "post_deploy hook for ${EXTERNAL_SYNC_NAME} (reason: ${EXTERNAL_SYNC_REASON})"

some-tool --do-the-idempotent-thing

exit 0
```

## What the engine guarantees / does not

- The engine **will not delete** files it did not create.
- The engine **never removes** a destination file when the corresponding
  source disappears from the repo on a later commit. Deploys are
  add-only/update-only — if you remove a file from your repo, its previously
  deployed copy is left in place until a human removes it.
- Deploying is always safe to re-run: copy respects `force`, link
  recreates/repoints idempotently, and a clone-only repo does nothing beyond
  pulling. A hook is expected to be equally safe to re-run — see [Hook
  obligations](#hook-obligations).

## How to make your repo compatible

1. Add `.dotfiles-sync.yml` at the repo root, following one of the
   [archetypes](#archetypes) above.
2. Commit it. **Read this carefully — it is not what you might assume:**
   changes to files **within** an already-registered `deploy` entry (e.g.
   editing a file under a `src: claude/` directory) land on the next sync
   cycle, because the sync script re-deploys from whatever is currently in
   the clone. Changes to the **manifest itself** — a new or altered `deploy`
   entry, a changed `branch`, a new or edited hook — do **not** take effect
   on the next sync cycle. They require an Ansible re-run
   (`ansible-playbook site.yml --tags sync-external` on the machine), because
   `deploy.list`/`hooks.list` are rendered once by Ansible from the manifest,
   not re-parsed by the sync script on every pull — **Bash never parses
   YAML** (see [Purpose](#purpose)). The engine detects this gap and warns
   loudly — in the repo's own log and in `external-sync --status` — when the
   manifest it can see in the clone no longer matches what Ansible last
   rendered from, so this is never a silent no-op.
3. Register the repo on each machine that should sync it, via `install.sh`
   (see [Adding a repo](external-sync.md#adding-a-repo) in the operator
   guide) — this is what actually adds the repo to `external_synced_repos`
   in `host_vars/localhost.yml`, and (if your manifest declares a hook) is
   also where the machine owner opts into `allow_hooks: true`.
4. Run [`scripts/validate-sync-manifest.sh`](#validating-your-manifest)
   against your manifest before pushing.

## Validating your manifest

`scripts/validate-sync-manifest.sh` (in the dotfiles repo) checks a
`.dotfiles-sync.yml` against everything in this spec — the same `src`/`dest`
resolution rules, the same `command[0]` rules, `mode`/`platforms`/`run_on`
enum values, and more — without needing Ansible or a live machine. It's a
developer-time tool (requires `yq`), meant to be run by hand or wired into
your add-on repo's own CI:

```bash
scripts/validate-sync-manifest.sh path/to/your/.dotfiles-sync.yml
```

Exits `0` on a clean manifest, non-zero with a specific error otherwise. See
the script's own `--help` for the full check list.

## See also

- [docs/external-sync.md](external-sync.md) — the operator guide: adding a
  repo, choosing a clone directory, the `allow_hooks` gate, sync cadence,
  DEV_MODE, `external-sync --status`, troubleshooting.

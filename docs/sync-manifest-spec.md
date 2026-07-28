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
  - [4. Symlink the whole repo (link_tree)](#4-symlink-the-whole-repo-link_tree)
  - [5. Clone-only with a post-deploy hook](#5-clone-only-with-a-post-deploy-hook)
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

**The manifest is the single placement contract.** A repo's destinations —
where its files end up on disk — live only in its `.dotfiles-sync.yml`,
never in the machine's `host_vars`. `host_vars` only ever says "sync this
repo" and "trust its hooks." The clone location itself is not something you
choose either: the engine always clones to
`${XDG_DATA_HOME}/external-sync/<name>/repo/` — a fact worth knowing if
you're debugging, but not something this file (or you) configures. See
[docs/external-sync.md's "On-disk layout"](external-sync.md#on-disk-layout)
for the full picture of what lives where.

## Schema version 1

```yaml
# .dotfiles-sync.yml — schema version 1
version: 1
branch: main            # optional; default tracking branch. host_vars/sync.conf value wins if set.

deploy:                 # optional. Omit entirely for clone-only repos.
  - src: claude/                 # required; path within the repo (file or dir), relative to repo root
    dest: ~/.claude/             # required; destination on Linux/WSL (and macOS unless dest_macos given)
    mode: copy                   # optional; copy (default) | link | link_tree
    force: false                 # optional; overwrite/repoint an existing destination? default false
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
| `branch` | no | `main` | Tracking branch. **Only takes effect if committed on the remote's default branch** — see the [bootstrap constraint](#deploy-semantics) below. A `GIT_BRANCH` already set at runtime in the repo's `sync.conf` (e.g. via manual edit) takes precedence over this value on subsequent runs. |
| `deploy` | no | omitted = clone-only | List of deploy entries. Omit the key entirely for a clone-only repo — see [D11](#1-clone-only). |
| `deploy[].src` | yes (per entry) | — | Path to a file or directory, relative to the repo root. No leading `/`, no `..` segments — see [Deploy semantics](#deploy-semantics). |
| `deploy[].dest` | yes (per entry) | — | Destination path. Leading `~` is the **only** expansion performed — `${XDG_*}` and other variables are taken literally, not expanded. Used on Linux/WSL and on macOS unless `dest_macos` is also given. Must resolve under `$HOME` — see [dest validation](#dest-validation). |
| `deploy[].mode` | no | `copy` | `copy` \| `link` \| `link_tree`. See [Deploy semantics](#deploy-semantics). |
| `deploy[].force` | no | `false` | `copy`: overwrite an existing file. `link`/`link_tree`: repoint an existing symlink pointing elsewhere. **Never** deletes a non-symlink destination, regardless of mode. |
| `deploy[].dest_macos` | no | — | Destination override used instead of `dest` when the engine is running on Darwin. Same validation rules as `dest`. |
| `deploy[].platforms` | no | all | List restricting which OSes this entry deploys on. Values: `linux`, `macos`. |
| `hooks` | no | absent | Omit entirely for a repo with no hooks. See [Hook contract](#hook-contract). |
| `hooks.post_deploy` | no | — | The only event in schema v1. Reserved as `hooks.<event>` so a future event can be added without a schema bump. |

Unknown top-level keys, and unknown keys under `deploy[]` and `hooks.<event>`,
are ignored, not fatal — forward compatibility for a repo synced by an older
dotfiles checkout, and for committing a `hooks:` block before the machine's
dotfiles branch has the code to act on it (it simply stays inert until then;
see [How to make your repo compatible](#how-to-make-your-repo-compatible)).

## Archetypes

### 1. Clone-only

No `.dotfiles-sync.yml` at all, or one with no `deploy:` block. The engine
clones to `${XDG_DATA_HOME}/external-sync/<name>/repo/` and keeps it pulled,
but deploys nothing. This is a valid, deliberate end state — a repo you just
want mirrored locally, with nothing to place anywhere else.

The engine will not let this be *accidentally* silent, though: with no
manifest at all, it warns on every sync ("no `.dotfiles-sync.yml` — clone-only
mirror") and `external-sync --status` shows `**no manifest**` for that repo,
so a repo you meant to configure but forgot to finish doesn't quietly sit
there deploying nothing forever. Add a manifest and re-run Ansible and the
warning clears on its own — see [docs/external-sync.md](external-sync.md#renaming-or-removing-a-destination)
for the full self-heal behaviour. A manifest that exists but simply omits
`deploy:` (the example below) is silent — that's the "yes, deliberately
clone-only" spelling.

```yaml
# .dotfiles-sync.yml — schema version 1
version: 1
branch: main
```

If your tool reads its config from a fixed location that isn't the clone
itself (e.g. an editor expecting `~/.config/<tool>`), don't reach for
clone-only — see [archetype 4](#4-symlink-the-whole-repo-link_tree) instead.
There is no per-machine "clone directory" choice to make here; the clone
location is always engine-computed.

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
`~/.local/bin` — commit the executable bit in the repo itself (`git update-index
--chmod=+x`); the engine does not chmod deployed files.

```yaml
# .dotfiles-sync.yml — schema version 1
version: 1
branch: main

deploy:
  - src: bin/my-tool.sh
    dest: ~/.local/bin/my-tool
    mode: link
```

### 4. Symlink the whole repo (link_tree)

`mode: link_tree`, `src: .` — the only src value it accepts. The engine
creates **one** symlink: `dest` → the clone itself. There is no per-file
work, and `dest` *becomes* the clone — `cd <dest> && git status` works, and
you develop directly in place, exactly as if you'd cloned it there by hand.
This is the shape for a tool that reads its config from a fixed location
(an editor expecting `~/.config/<tool>`, for example) and that you also want
to edit in place.

```yaml
# .dotfiles-sync.yml — schema version 1
version: 1
branch: main

deploy:
  - src: .
    dest: ~/.config/nvim
    mode: link_tree
```

`link_tree` **never deletes a real (non-symlink) directory** already at
`dest` — it warns and refuses instead, so a background timer can never
delete a working git clone based on manifest content. Converting an
existing real directory at `dest` to a `link_tree` symlink is therefore a
one-time **manual** migration — see
[docs/external-sync.md](external-sync.md#renaming-or-removing-a-destination)
for the steps.

### 5. Clone-only with a post-deploy hook

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

The three modes differ along one axis: **who owns the destination.**

| Mode | `src` shape | What it does | `force` semantics | Ownership |
| --- | --- | --- | --- | --- |
| `copy` | file or dir | Copies the file, or every file within a dir tree (`.git/` excluded). | `true`: overwrite existing files. `false` (default): skip existing files, leaving them untouched. | **Detached.** A one-way, point-in-time publish. Once deployed, an edit to the deployed file survives and silently stops tracking the repo — see the note below. |
| `link` | file or dir | Symlinks the file, or each file within a dir tree individually (`.git/` excluded), into `dest`. | `true`: repoint an existing symlink to the correct target. `false` (default): leave an existing symlink alone. **Never** deletes a non-symlink — warns instead. | **Contribution.** The repo adds files into a `dest` it does not exclusively own (e.g. `~/.local/bin/`). |
| `link_tree` | must be `.` | Creates **one** symlink: `dest` → the clone. No per-file work. | `true`: replace an existing *symlink* pointing elsewhere. `false` (default): leave it. **Never** deletes a real directory — warns and refuses (see [archetype 4](#4-symlink-the-whole-repo-link_tree)). | **Exclusive.** `dest` *is* the clone. Nothing else may write there. |

Other rules that apply across all three modes:

- **Path resolution.** `src` is resolved relative to the repo's clone
  directory. `dest` (and `dest_macos`) may use a leading `~`, expanded to an
  absolute path when the engine writes `deploy.list` — this is the **only**
  expansion performed; `${XDG_*}` and other variables in `dest` are taken
  literally. The sync script never performs any expansion at runtime.
- **`copy` is a detached, one-way publish, by design (not a default to work
  around).** An edit to a deployed `copy` file stays local and stops
  tracking the repo silently — that's intentional: develop locally, then
  promote your change by editing the source repo and opening a PR. Every
  `copy` destination directory gets an engine-authored `.external-sync-info`
  marker explaining this (rewritten on every deploy, safe to delete — the
  next sync restores it), and `external-sync --status` reports a `Diverged`
  count so a local fork is visible, never silently lost.
- **Directories.** A directory `src` deploys recursively, preserving the
  relative structure under `dest` (`copy`/`link`) or as a single symlinked
  unit (`link_tree`). The repo's own `.git/` directory is always excluded
  from a `copy`/`link` directory deploy, even for `src: .` — you never need
  to account for it yourself. `link_tree` has no such exclusion to make:
  `.git` lives inside the symlinked directory, which is correct, since
  `dest` is meant to be a working clone you develop in.
- **The engine never deletes anything it doesn't already own the shape
  of.** A `dest` that's a real directory where `link_tree` expects a
  symlink, or a plain file where `link` expects a symlink, is a warning and
  a skip — never an automatic removal. See ["What the engine guarantees /
  does not"](#what-the-engine-guarantees--does-not) for the broader
  principle this is one expression of.
- **Per-OS destination.** On Darwin, the engine uses `dest_macos` if the
  entry defines one, otherwise it falls back to `dest`. On Linux/WSL,
  `dest_macos` is ignored.
- **Per-OS filtering.** `platforms`, if given, restricts whether the entry
  deploys at all on the current OS. An entry with `platforms: [macos]` is
  skipped entirely (not just re-pointed) when running on Linux.
- **Branch precedence and the bootstrap constraint.** `branch` in the
  manifest sets the branch the engine tracks. Once `sync.conf` exists for
  the repo, its `GIT_BRANCH` value is authoritative — the same field a user
  edits by hand to track a feature branch temporarily, and Ansible will not
  stomp on that choice on subsequent runs. **Important:** the manifest is
  only ever read from the clone of the remote's *default* branch — the
  initial clone deliberately doesn't pin a `version:`, so it follows
  whatever branch the remote's own HEAD points at, and that's the checkout
  Ansible reads `.dotfiles-sync.yml` from. This means `branch:` can
  redirect tracking *after* the initial clone, but a manifest committed only
  on a feature branch is invisible — it cannot bootstrap discovery of
  itself. Commit `.dotfiles-sync.yml` to your default branch.

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
`deploy:` block — see [Archetype 5](#5-clone-only-with-a-post-deploy-hook).
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
| `EXTERNAL_SYNC_CLONE_DIR` | Absolute path to the clone (same as the invocation `cwd`) — always `${XDG_DATA_HOME}/external-sync/<name>/repo`, the engine-computed clone path. For a `link_tree` repo this same directory is *also* reachable via the symlinked `dest`, but a hook should use this variable, which always points at the real clone regardless of mode. |
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

- **The engine heals forward, never backward.** Adding a manifest, or a new
  `deploy` entry, deploys it on the next sync/Ansible cycle (see [How to
  make your repo compatible](#how-to-make-your-repo-compatible) for exactly
  which). **Renaming or removing** a `dest` — in the manifest, on a later
  commit — deploys the new location (if any) but does **not** remove the
  old one. There is no record of the previous placement to diff against,
  and by deliberate design a background timer executing repo-authored
  instructions is never given the power to delete files based on those
  instructions changing. This is a security posture, not an unfinished
  feature — see [docs/external-sync.md](external-sync.md#renaming-or-removing-a-destination)
  for the operator-facing cleanup steps. Do not expect this to be "fixed"
  into an auto-prune later; it's a design constraint, not a bug.
- The engine **will not delete** files, or real directories, it did not
  create — see the mode table above for what each mode does when it finds
  something at `dest` it didn't expect.
- Deploying is always safe to re-run: `copy` respects `force`, `link`/
  `link_tree` recreate/repoint idempotently, and a clone-only repo does
  nothing beyond pulling. A hook is expected to be equally safe to re-run —
  see [Hook obligations](#hook-obligations).
- A repo with **no manifest at all** is not silently ignored: the engine
  warns on every sync and `external-sync --status` shows `**no manifest**`
  until one is added — see [archetype 1](#1-clone-only).
- `external-sync --status` reports only state it can verify cheaply and
  locally. It does **not** detect orphaned old destinations (the point
  above) — that is a documented manual cleanup, not a tracked diff.

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
  repo, the on-disk layout, the `allow_hooks` gate, sync cadence, DEV_MODE,
  `external-sync --status`, migrating an existing clone to `link_tree`,
  troubleshooting.

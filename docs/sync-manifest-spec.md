# `.dotfiles-sync.yml` — sync manifest spec

This is the authoritative contract for `.dotfiles-sync.yml`. If you are
authoring or updating one, everything you need is in this file.

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
below.

## Table of Contents

- [Purpose](#purpose)
- [Schema version 1](#schema-version-1)
  - [Field reference](#field-reference)
- [Archetypes](#archetypes)
  - [1. Clone-only](#1-clone-only)
  - [2. Copy, never-overwrite](#2-copy-never-overwrite)
  - [3. Symlink, auto-updating](#3-symlink-auto-updating)
- [Deploy semantics](#deploy-semantics)
- [What the engine guarantees / does not](#what-the-engine-guarantees--does-not)
- [How to make your repo compatible](#how-to-make-your-repo-compatible)
- [See also](#see-also)

## Purpose

`.dotfiles-sync.yml` is a small declarative manifest that tells the
[dotfiles external-sync engine](external-sync.md) what to do with your
repository once it's been cloned onto a machine. It lives at the **root of
the add-on repo** — not in the `dotfiles` repo itself.

The dotfiles repo owns the *engine* (cloning, pulling, timers). Your repo
owns the *description of what to do with itself* — which files go where,
copied or symlinked, on which platforms. The dotfiles repo never hardcodes
your repo's internal layout; it only reads this file.

The manifest is read by Ansible (`roles/sync-external`), which parses the
YAML and renders it into a flat `deploy.list` that the runtime sync script
(`scripts/external-sync.sh`) consumes. **Bash never parses YAML** — by the
time your manifest reaches the sync script it has already been flattened.

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
```

### Field reference

| Field | Required | Default | Meaning |
| --- | --- | --- | --- |
| `version` | yes | — | Manifest schema version. Only `1` exists today. |
| `branch` | no | `main` | Branch the engine tracks for this repo. A `GIT_BRANCH` already set at runtime in the repo's `sync.conf` (e.g. via manual edit) takes precedence over this value on subsequent runs — see [Deploy semantics](#deploy-semantics). |
| `deploy` | no | omitted = clone-only | List of deploy entries. Omit the key entirely for a clone-only repo. |
| `deploy[].src` | yes (per entry) | — | Path to a file or directory, relative to the repo root. |
| `deploy[].dest` | yes (per entry) | — | Destination path. May use `~`; the engine expands it to an absolute path before writing `deploy.list`. Used on Linux/WSL and on macOS unless `dest_macos` is also given. |
| `deploy[].mode` | no | `copy` | `copy` or `link`. See [Deploy semantics](#deploy-semantics). |
| `deploy[].force` | no | `false` | `copy` mode only. Whether to overwrite an existing destination file. |
| `deploy[].executable` | no | `false` | `chmod +x` each deployed file. |
| `deploy[].dest_macos` | no | — | Destination override used instead of `dest` when the engine is running on Darwin. |
| `deploy[].platforms` | no | all | List restricting which OSes this entry deploys on. Values: `linux`, `macos`. |

## Archetypes

### 1. Clone-only

No `.dotfiles-sync.yml` at all, or one with no `deploy:` block. The engine
clones and keeps the repo pulled; the consuming tool reads the clone
directory directly. This is how `nvim-config` works — Neovim reads
`~/.config/nvim` directly, there is nothing to "deploy" elsewhere.

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
leaves it alone. This is how `ai-config` protects credentials that live
alongside its deployed config files.

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
  relative structure under `dest`.
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

## What the engine guarantees / does not

- The engine **will not delete** files it did not create.
- The engine **never removes** a destination file when the corresponding
  source disappears from the repo on a later commit. Deploys are
  add-only/update-only — if you remove a file from your repo, its previously
  deployed copy is left in place until a human removes it.
- Deploying is always safe to re-run: copy respects `force`, link
  recreates/repoints idempotently, and a clone-only repo does nothing beyond
  pulling.

## How to make your repo compatible

1. Add `.dotfiles-sync.yml` at the repo root, following one of the three
   archetypes above.
2. Commit it — the engine reads it from the clone after each pull, so
   changes to the manifest take effect on the next sync cycle.
3. Register the repo on each machine that should sync it, via
   `install.sh` (see [Adding a repo](external-sync.md#adding-a-repo) in the
   operator guide) — this is what actually adds the repo to
   `external_synced_repos` in `host_vars/localhost.yml`.

## See also

- [docs/external-sync.md](external-sync.md) — the operator guide: adding a
  repo, sync cadence, DEV_MODE, troubleshooting.

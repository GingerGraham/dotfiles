# Sync

The sync role installs a background timer that keeps the dotfiles installation up to date automatically. It runs as your user — never root — and respects a `DEV_MODE` flag so active development work is not disrupted.

## Table of Contents

- [Install modes](#install-modes)
  - [Mode detection](#mode-detection)
  - [Switching between modes](#switching-between-modes)
  - [dotfiles_install_mode vs DEV_MODE](#dotfiles_install_mode-vs-dev_mode)
- [How it works](#how-it-works)
  - [dev mode](#dev-mode)
  - [release mode](#release-mode)
- [Sync config](#sync-config)
- [dotfiles-branch](#dotfiles-branch)
  - [Typical development workflow](#typical-development-workflow)
  - [Status output](#status-output)
- [Checking timer status directly](#checking-timer-status-directly)
- [Manual sync](#manual-sync)
- [Disabling sync](#disabling-sync)
- [Logs](#logs)

## Install modes

Every machine runs in one of two modes:

| | **dev** | **release** |
| --- | --- | --- |
| Acquired by | `bootstrap.sh --dev` (or a manual `git clone`) | `bootstrap.sh` (default, no flags) |
| On disk | A real `git` checkout under `<projects_base>/Personal/GitHub/dotfiles` | A tarball extraction under `~/.local/share/dotfiles/releases/`, symlinked from `~/.local/share/dotfiles/current` — no `.git` anywhere |
| Tracks | Whatever branch you check out | `main` HEAD only — no tagged/stable channel |
| `dotfiles-branch <branch>` / `--resume` / `--dev` / `--reset` | Work normally | Refuse with a clear error — there is no working checkout to act on |
| Background sync | `git pull --ff-only` | Fetches a fresh tarball, flips `current` to it if the commit changed, prunes old releases |

Release mode exists so that anyone who just wants working shell/git/ssh config doesn't need `git` installed, and doesn't get a foreign repository entangled with their own project tree. Dev mode is unchanged from before this existed — it's what Graham uses on his own workstation.

### Mode detection

Mode is never stored and read back to make decisions — it's re-derived from disk on every run, both by Ansible (`ansible/tasks/detect_install_mode.yml`, tagged `always` so it still runs under `--tags`-filtered invocations) and by the runtime scripts (`dotfiles-sync`, `dotfiles-branch`):

- A valid `git` checkout at the conventional dev-clone location → **dev**.
- Otherwise, a `~/.local/share/dotfiles/current` symlink → **release**.
- Neither present → **dev** (shouldn't happen in practice — by the time anything runs, `bootstrap.sh` has already produced one or the other).
- **Both** present (a stray manual clone, or `bootstrap.sh --dev` run on an already-release machine) → **dev wins**, with a warning surfaced in `dotfiles-branch --status`.

Dev mode also honours a `DOTFILES_REPO_DIR` environment variable override if you keep your checkout somewhere other than the conventional location. Ansible sets `DOTFILES_REPO_DIR` correctly in both modes on first run (rendered into `90-local.sh` — see [ansible/roles/git/README.md](../ansible/roles/git/README.md)), so this is only something you'd set by hand to override that default, not something you need to configure yourself.

### Switching between modes

`ansible/host_vars/localhost.yml` is never overwritten, but *where it lives* differs by mode — dev mode keeps it as a real, gitignored file in the clone (nothing ever forces that directory to move); release mode stores it at `~/.config/dotfiles/host_vars/localhost.yml`, outside every release directory, and symlinks it in — the same reasoning as the `90-local.sh` relocation, since a release directory gets replaced wholesale on every sync.

Re-running the bootstrap one-liner in the other mode (`--dev` when you were on release, or bare when you were on `--dev`) checks the conventional location for a config from the mode you're switching *from*, and offers to reuse it (`[Y/n]`, defaults to yes) rather than re-prompting for everything — see [First-run prompts](installation.md#first-run-prompts). Only the default projects-base convention is checked for a prior dev install.

### dotfiles_install_mode vs DEV_MODE

Two different flags that are easy to confuse:

- **`dotfiles_install_mode`** (in `ansible/host_vars/localhost.yml`) — written once by `install.sh` on first run. It's a **human-readable record only** — nothing reads it back to make decisions, so a stale or hand-edited value doesn't break anything. The effective mode always comes from the disk-based detection above.
- **`DEV_MODE`** (in `~/.config/dotfiles/sync.conf`) — a runtime toggle, unrelated to install mode, that suspends the background sync timer. Only reachable in dev mode — via `dotfiles-branch --dev`, or switching to a non-main branch — since both writers are dev-gated; a release-mode machine can't set it through `dotfiles-branch` at all.

## How it works

On Linux and WSL2 a systemd user timer fires once at login and then daily. On macOS a launchd agent handles the same cadence. Every run acquires a lockfile to prevent concurrent runs, checks `DEV_MODE` (exits cleanly without doing anything if `true`), then branches on the mode detected fresh from `DOTFILES_DIR` (see [Install modes](#install-modes) above):

### dev mode

1. Runs `git pull --ff-only` on the configured branch
2. Writes a last-sync timestamp to `~/.local/share/dotfiles/last-sync`
3. Logs output to `~/.local/share/dotfiles/logs/sync.log`

`--ff-only` is deliberate. If the pull would require a merge (e.g. you have local commits), the sync skips and logs a warning rather than making changes you did not explicitly request.

### release mode

1. Resolves `main`'s current commit via the GitHub API
2. If it matches the currently installed release, logs "up to date" and stops
3. Otherwise fetches a fresh tarball, extracts it to `~/.local/share/dotfiles/releases/<timestamp>-<shortsha>/`, and atomically flips the `~/.local/share/dotfiles/current` symlink to it
4. Prunes releases beyond the most recent 5
5. Writes a last-sync timestamp, same as dev mode

## Sync config

`~/.config/dotfiles/sync.conf` is created on first Ansible run and **never overwritten**. It contains the runtime state for the sync:

```bash
# dev mode
DOTFILES_DIR="/home/user/Projects/Personal/GitHub/dotfiles"
REPO_URL="https://github.com/GingerGraham/dotfiles.git"
GIT_BRANCH="main"
DEV_MODE="false"
```

```bash
# release mode
DOTFILES_DIR="/home/user/.local/share/dotfiles/current"
REPO_URL="https://github.com/GingerGraham/dotfiles.git"
GIT_BRANCH="main"
DEV_MODE="false"
```

`DOTFILES_DIR` is how the runtime scripts tell dev and release mode apart — a `.git` directory there means dev. Edit this file directly to change behaviour. Ansible updates only `REPO_URL` when your `host_vars` changes — `DEV_MODE` and `GIT_BRANCH` are yours to manage at runtime.

## dotfiles-branch

The `dotfiles-branch` command (deployed to `~/.local/bin/dotfiles-branch` by the sync role, sourced from `scripts/switch-branch.sh`) is the recommended way to manage branch switching and dev mode.

```text
dotfiles-branch — manage dotfiles sync branch and dev mode

Usage:
  dotfiles-branch <branch>          Switch to <branch>; enables dev mode if not main
  dotfiles-branch --resume          Return to main and re-enable sync
  dotfiles-branch --dev             Suspend sync on current branch (no branch switch)
  dotfiles-branch --reset           Hard-reset working copy to match remote HEAD
  dotfiles-branch --status          Show sync state, branch, and last sync time
  dotfiles-branch --init <url> <dir>  Initialise sync.conf (normally done by install.sh)
  dotfiles-branch --help            Show this help
```

`<branch>`, `--resume`, `--dev`, and `--reset` all require dev mode — there's no working `git` checkout for them to act on in release mode, so they refuse with a pointer to reinstall with `--dev`. Only `--status` works in both modes.

### Typical development workflow

```bash
# Start working on a feature (sets DEV_MODE=true, updates GIT_BRANCH in sync.conf)
dotfiles-branch feat/new-aliases

# ... make your changes, test, commit ...

# Push your branch
git -C ~/Projects/Personal/GitHub/dotfiles push origin feat/new-aliases

# Return to main and re-enable sync
dotfiles-branch --resume

# Suspend sync temporarily without switching branches
dotfiles-branch --dev
```

### Status output

Dev mode:

```text
  Dotfiles sync status
  ────────────────────────────────────
  Mode:             dev
  Repo:             /home/user/Projects/Personal/GitHub/dotfiles
  Working copy:     main
  Tracking:         main
  Dev mode:         false
  Sync:             active
  Last synced:      2026-06-04 08:42:17
```

Release mode:

```text
  Dotfiles sync status
  ────────────────────────────────────
  Mode:             release
  Release:          a1b2c3d
  Tracking:         main
  Dev mode:         false
  Sync:             active
  Last synced:      2026-08-17 08:00:00
```

If the working copy branch does not match the configured `GIT_BRANCH` (dev mode only), the status output appends:

```text
  *** working copy does not match configured branch ***
```

If both a dev-mode checkout and a release-mode install are present on the same machine (dev always wins — see [Mode detection](#mode-detection)):

```text
  *** both a dev-mode checkout and a release-mode install are present on this machine — dev wins ***
```

## Checking timer status directly

```bash
# Linux / WSL2
systemctl --user status dotfiles-sync.timer
systemctl --user list-timers dotfiles-sync.timer

# macOS
launchctl list | grep com.dotfiles.sync
```

## Manual sync

To sync immediately without waiting for the timer (pulls in dev mode, fetches/flips a release in release mode):

```bash
~/.local/bin/dotfiles-sync

# Or on Linux trigger the service directly
systemctl --user start dotfiles-sync.service
```

## Disabling sync

Set `dotfiles_sync_enabled: false` in `host_vars/localhost.yml` and re-run `./install.sh`. The timer units remain on disk but will not be enabled.

To stop the timer on a running system without changing `host_vars`:

```bash
# Linux / WSL2
systemctl --user stop dotfiles-sync.timer
systemctl --user disable dotfiles-sync.timer

# macOS
launchctl unload ~/Library/LaunchAgents/com.dotfiles.sync.plist
```

## Logs

| Path | Contents |
| --- | --- |
| `~/.local/share/dotfiles/logs/sync.log` | Main dotfiles sync log |
| `~/.local/share/dotfiles/releases/` | Release mode only — the last 5 tarball extractions, `current` symlinked to the active one |
| `~/.local/share/external-sync/<name>/logs/sync.log` | Per-repo log for each registered external add-on repo |

External add-on repos (nvim-config, ai-config, or any other repo you register) are synced independently by the `sync-external` engine, on its own hourly timer — see [External sync](external-sync.md).

# Sync

The sync role installs a background timer that keeps the dotfiles repo up to date automatically. It runs as your user — never root — and respects a `DEV_MODE` flag so active development work is not disrupted.

## How it works

On Linux and WSL2 a systemd user timer fires once at login and then daily. On macOS a launchd agent handles the same cadence. Each run:

1. Acquires a lockfile to prevent concurrent runs
2. Checks `DEV_MODE` — if `true`, exits cleanly without pulling
3. Runs `git pull --ff-only` on the configured branch
4. Writes a last-sync timestamp to `~/.local/share/dotfiles/last-sync`
5. Logs output to `~/.local/share/dotfiles/logs/sync.log`

The sync script uses `--ff-only` deliberately. If the pull would require a merge (e.g. you have local commits), the sync skips and logs a warning rather than making changes you did not explicitly request.

## Sync config

`~/.config/dotfiles/sync.conf` is created on first Ansible run and **never overwritten**. It contains the runtime state for the sync:

```bash
DOTFILES_DIR="/home/user/Projects/Personal/GitHub/dotfiles"
REPO_URL="https://github.com/GingerGraham/dotfiles.git"
GIT_BRANCH="main"
DEV_MODE="false"
```

Edit this file directly to change behaviour. Ansible updates only `REPO_URL` when your `host_vars` changes — `DEV_MODE` and `GIT_BRANCH` are yours to manage at runtime.

## dotfiles-branch

The `dotfiles-branch` command (deployed to `~/.local/bin/dotfiles-branch` by the sync role, sourced from `scripts/switch-branch.sh`) is the recommended way to manage branch switching and dev mode.

```
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

```
  Dotfiles sync status
  ────────────────────────────────────
  Repo:             /home/user/Projects/Personal/GitHub/dotfiles
  Tracking:         main
  Working copy:     main
  Dev mode:         false
  Sync:             active
  Last synced:      2026-06-04 08:42:17
```

If the working copy branch does not match the configured `GIT_BRANCH`, the status output appends:

```
  *** working copy does not match configured branch ***
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

To pull immediately without waiting for the timer:

```bash
~/.local/bin/dotfiles-sync.sh

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
|---|---|
| `~/.local/share/dotfiles/logs/sync.log` | Main dotfiles sync log |
| `~/.local/state/nvim-config-sync/logs/sync.log` | nvim-config sync log (if nvim role enabled) |
| `~/.local/share/ai-config-sync/logs/sync.log` | ai-config sync log (if ai-tools role enabled) |

Each companion repo has its own independent sync timer and log.

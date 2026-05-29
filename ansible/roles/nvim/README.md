# nvim role

Installs neovim, deploys a user-supplied nvim-config repository to
`~/.config/nvim/`, and sets up a daily GitOps sync timer that keeps the config
in sync with the upstream repo.

## Activation

Runs only for the `workstation` profile. It is skipped (and produces no side
effects) when `nvim_config_repo_url` is empty.

## What this role does

1. **Checks whether neovim is installed** and whether the version meets the
   configured minimum (`nvim_min_version`).
2. **Installs neovim** using the method selected by `nvim_install_method`:
   - `package` — distro package manager (default)
   - `appimage` — upstream AppImage binary; no root required
   - `none` — skip installation, only warn if absent
3. **Clones or updates** the nvim-config repo to `~/.config/nvim/`.
   - If a non-git directory exists at that path it is backed up before cloning.
   - Subsequent runs pull if `nvim_config_update: true` (default) and the
     working tree is clean.
4. **Deploys `nvim-config-sync`** — a sync script, `sync.conf`, and a
   systemd user timer (Linux) or launchd agent (macOS) that pulls config
   updates daily.

## Variables

| Variable | Default | Override in | Purpose |
|---|---|---|---|
| `nvim_config_repo_url` | `""` | `host_vars/localhost.yml` | URL of the nvim-config repo to clone. Role is a no-op when empty. |
| `nvim_config_dir` | `~/.config/nvim` | `group_vars/all.yml` | Destination path for the cloned config. |
| `nvim_config_branch` | `main` | `host_vars/localhost.yml` | Branch to track. |
| `nvim_config_update` | `true` | `host_vars/localhost.yml` | Pull on every Ansible run when true. |
| `nvim_min_version` | `0.9.0` | `host_vars/localhost.yml` | Minimum acceptable neovim version. |
| `nvim_install_method` | `package` | `host_vars/localhost.yml` | `package` / `appimage` / `none` |
| `nvim_appimage_version` | `stable` | `host_vars/localhost.yml` | AppImage release tag to download. |
| `nvim_appimage_dir` | `~/.local/share/nvim` | `host_vars/localhost.yml` | Where the AppImage binary is stored. |
| `nvim_bin_wrapper_path` | `~/.local/bin/nvim` | `host_vars/localhost.yml` | Path for the AppImage wrapper script. |
| `nvim_state_dir` | `~/.local/share/nvim-config` | `group_vars/all.yml` | Sync state and logs directory. |
| `nvim_sync_conf_path` | `~/.config/nvim-config/sync.conf` | `group_vars/all.yml` | Runtime config read by the sync script. |
| `nvim_sync_script_dest` | `~/.local/bin/nvim-config-sync` | `group_vars/all.yml` | Deployed sync script path. |

## Package installation by distro

| OS family | Method |
|---|---|
| Fedora | `dnf install neovim` |
| RHEL / Rocky / Alma | EPEL enabled, then `dnf install neovim` |
| Ubuntu / Debian | `apt install neovim` |
| openSUSE / SLES | `zypper install neovim` (via ansible.builtin.command) |
| Arch / Manjaro  | `pacman -S neovim` (via ansible.builtin.command)      |
| macOS | `brew install neovim` |

### When the packaged version is too old

Ubuntu LTS ships an old neovim. If the packaged version is below
`nvim_min_version` the role prints a warning and continues — it will not fail
the run, but the config may not load correctly.

To install the upstream binary instead, set in `host_vars/localhost.yml`:

```yaml
nvim_install_method: appimage
```

The AppImage is downloaded to `~/.local/share/nvim/nvim.appimage` and a
wrapper script at `~/.local/bin/nvim` exec's into it. No root required.

## Sync behaviour

`nvim-config-sync` is a separate sync daemon from the dotfiles sync. It runs:

- **Linux**: `nvim-config-sync.timer` — systemd user timer, fires at boot + daily
- **macOS**: `com.nvim-config.sync` — launchd user agent, fires at midnight + on load

### DEV_MODE

When you are actively editing your nvim config on a machine and don't want
upstream pulls clobbering your work, set `DEV_MODE=true` in
`~/.config/nvim-config/sync.conf`. The timer continues to run but exits early.
Reset to `false` once your changes are pushed upstream.

### Local edits guard

If the working tree in `~/.config/nvim` has uncommitted changes, the sync
script skips the pull and logs a warning rather than overwriting your work.

### Checking sync status

```bash
# Linux
systemctl --user status nvim-config-sync.timer
journalctl --user -u nvim-config-sync.service -n 50

# macOS
launchctl list | grep nvim-config
tail -f ~/.local/share/nvim-config/logs/sync.log

# Both
cat ~/.local/share/nvim-config/last-sync
```

### Manual sync

```bash
nvim-config-sync
```

## Idempotency notes

- `sync.conf` is written with `force: false` — it is never overwritten by
  Ansible, preserving any runtime changes to `DEV_MODE` or `GIT_BRANCH`.
- A backed-up non-git config directory is suffixed with the run date
  (`~/.config/nvim.bak-YYYY-MM-DD`).
- The AppImage download uses `force: false` — it is not re-downloaded on
  subsequent runs unless the file is absent.

## Files deployed

```
~/.config/nvim/                         ← nvim-config repo clone
~/.config/nvim-config/
│   └── sync.conf                       ← runtime sync config (created once)
~/.config/systemd/user/
│   ├── nvim-config-sync.service        ← Linux only
│   └── nvim-config-sync.timer         ← Linux only
~/Library/LaunchAgents/
│   └── com.nvim-config.sync.plist     ← macOS only
~/.local/bin/
│   ├── nvim                           ← AppImage wrapper (appimage method only)
│   └── nvim-config-sync               ← sync script
~/.local/share/nvim-config/
│   ├── last-sync
│   └── logs/sync.log
```

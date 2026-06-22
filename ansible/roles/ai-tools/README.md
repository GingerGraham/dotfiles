# ai-tools role

Clones the `ai-config` private repository and deploys per-tool configuration
files to their correct system locations. Sets up a 30-minute GitOps sync timer
to keep config current across machines.

## Activation

Runs only for the `workstation` profile. It is a no-op when `ai_config_repo_url`
is empty — the role exits cleanly without creating any directories or files.

## What this role does

1. **Clones or updates** the `ai-config` repo to `~/.local/share/ai-config`.
2. **Detects which tool subdirectories exist** in the cloned repo and deploys
   files from each to the correct destination, with `force: no` so existing
   user files are never overwritten.
3. **Deploys `ai-config-sync`** — a sync script, `sync.conf`, and a systemd
   user timer (Linux) or launchd agent (macOS) that re-pulls and re-deploys
   every 30 minutes.

## Tool → Destination Mapping

| Source (in `ai-config` repo) | Linux / WSL destination     | macOS destination                            |
| ---------------------------- | --------------------------- | -------------------------------------------- |
| `antigravity/`               | `~/.gemini/`                | `~/.gemini/`                                 |
| `claude/`                    | `~/.claude/`                | `~/.claude/`                                 |
| `copilot/`                   | `~/.config/github-copilot/` | `~/.config/github-copilot/`                  |
| `cursor/`                    | `~/.cursor/`                | `~/Library/Application Support/Cursor/User/` |
| `kiro/`                      | `~/.kiro/`                  | `~/.kiro/`                                   |

> **Note — Antigravity config path:** Google retained `~/.gemini/` as the config
> directory when renaming Gemini CLI to Antigravity CLI (binary: `agy`). The source
> subdirectory in the `ai-config` repo is named `antigravity/` for clarity, but it
> deploys to `~/.gemini/` on disk.

If a source subdirectory does not exist in the cloned repo, that tool's deploy
block is skipped entirely — no error, no empty directory.

## Variables

| Variable               | Default                         | Override in               | Purpose                                                |
| ---------------------- | ------------------------------- | ------------------------- | ------------------------------------------------------ |
| `ai_config_repo_url`   | `""`                            | `host_vars/localhost.yml` | URL of the ai-config repo. Role is a no-op when empty. |
| `ai_config_branch`     | `main`                          | `host_vars/localhost.yml` | Branch to track.                                       |
| `ai_config_update`     | `true`                          | `host_vars/localhost.yml` | Pull on every Ansible run when true.                   |
| `ai_config_clone_dir`  | `~/.local/share/ai-config`      | `group_vars/all.yml`      | Where the repo is cloned. Not a user-facing directory. |
| `ai_state_dir`         | `~/.local/share/ai-config-sync` | `group_vars/all.yml`      | Sync state and logs.                                   |
| `ai_sync_conf_path`    | `~/.config/ai-config/sync.conf` | `group_vars/all.yml`      | Runtime config for the sync script.                    |
| `ai_sync_script_dest`  | `~/.local/bin/ai-config-sync`   | `group_vars/all.yml`      | Deployed sync script path.                             |
| `ai_tool_destinations` | See defaults                    | `group_vars/all.yml`      | Per-tool destination path map.                         |

## Adding a New Tool

1. Create a subdirectory in the `ai-config` repo (e.g. `windsurf/`).
2. Add config files you want to roam.
3. Add any generated/local-state paths to `.gitignore` in `ai-config`.
4. Add the destination path to `ai_tool_destinations` in `defaults/main.yml`
   and `group_vars/all.yml`.
5. Add `_ai_dest_<tool>` to both `set_fact` tasks at the top of `tasks/main.yml`
   (one for Linux/WSL, one for macOS).
6. Add a deploy block to `tasks/main.yml` following the existing pattern
   (stat check → mkdir dest → find files → deploy subdirs → copy files).
7. Add the same tool deploy call to `scripts/ai-config-sync.sh`'s
   `deploy_all_tools()` function.

## Never-Overwrite Semantics

All file copies use `force: no` in Ansible and a `[[ ! -e "${dest_file}" ]]`
guard in the sync script. This means:

- **Auth tokens, session files, and machine-local config** written by the tools
  themselves are never clobbered, even if the `ai-config` repo contains a file
  at the same path.
- To **reset a file** to the repo version, delete it and re-run Ansible or
  manually trigger `ai-config-sync`.

## Sync Behaviour

`ai-config-sync` fires:

- **Linux**: `ai-config-sync.timer` — systemd user timer, 2 min after boot, then every 30 min
- **macOS**: `com.ai-config.sync` — launchd agent, on load, then every 30 min

### DEV_MODE

Set `DEV_MODE=true` in `~/.config/ai-config/sync.conf` to pause sync while
actively editing config on this machine. The timer continues to run but exits
early. Reset to `false` when changes are pushed upstream.

### Checking sync status

```bash
# Linux
systemctl --user status ai-config-sync.timer
journalctl --user -u ai-config-sync.service -n 50

# macOS
launchctl list | grep ai-config
tail -f ~/.local/share/ai-config-sync/logs/sync.log

# Both
cat ~/.local/share/ai-config-sync/last-sync
```

### Manual sync

```bash
ai-config-sync
```

## Idempotency Notes

- `sync.conf` is written with `force: false` — never overwritten by Ansible.
- `REPO_URL` in `sync.conf` is updated by a `lineinfile` task to track changes
  to `ai_config_repo_url` in `host_vars` (e.g. switching to an SSH alias URL).
- A backed-up non-git clone directory is suffixed with the run date.

## Files Deployed

```
~/.local/share/ai-config/               ← ai-config repo clone
~/.config/ai-config/
│   └── sync.conf                       ← runtime sync config (created once)
~/.config/systemd/user/
│   ├── ai-config-sync.service          ← Linux only
│   └── ai-config-sync.timer           ← Linux only
~/Library/LaunchAgents/
│   └── com.ai-config.sync.plist       ← macOS only
~/.local/bin/
│   └── ai-config-sync                 ← sync script
~/.local/share/ai-config-sync/
│   ├── last-sync
│   └── logs/sync.log

Per-tool destinations (populated from ai-config repo):
~/.gemini/                            ← from ai-config/antigravity/
~/.claude/                              ← from ai-config/claude/
~/.config/github-copilot/              ← from ai-config/copilot/
~/.cursor/                             ← from ai-config/cursor/ (Linux)
~/Library/.../Cursor/User/             ← from ai-config/cursor/ (macOS)
~/.kiro/                               ← from ai-config/kiro/
```

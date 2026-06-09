# Optional components

Two roles are optional within the `workstation` profile: **nvim** and **ai-tools**. Both require a companion private repository and are disabled automatically if no repo URL is provided.

---

## nvim

### What it does

- Clones your `nvim-config` repository to `~/.config/nvim/`
- Installs a background sync timer that pulls updates to `nvim-config` daily (separate from the dotfiles sync)
- Sync state is logged to `~/.local/state/nvim-config-sync/logs/`

The Neovim config itself lives entirely in the separate `nvim-config` repo. This role is purely a deployment and sync mechanism — it does not manage Neovim plugins or configuration content.

### Requirements

- `dotfiles_profile: workstation`
- A `nvim-config` repository accessible via SSH

### Enabling nvim

**During first-run install:**

`install.sh` prompts whether to enable the nvim role and asks for the repo SSH URL:

```
Enable nvim role? [Y/n]: Y
nvim-config repo SSH URL: git@github-dotfiles-nvim:you/nvim-config.git
```

**In host_vars directly:**

```yaml
# ansible/host_vars/localhost.yml
dotfiles_nvim_enabled: true
nvim_config_repo_url: "git@github-dotfiles-nvim:you/nvim-config.git"
```

Then run `./install.sh` (or `./install.sh --only-roles nvim` to target that role alone).

**Backfilling a URL into an existing install:**

If you ran the initial install without a URL and want to add one later, set both values in `host_vars` and run:

```bash
./install.sh --only-roles nvim
```

`install.sh` detects the missing URL in an existing `host_vars` file and prompts for it when the role is explicitly targeted.

### Disabling nvim

```yaml
dotfiles_nvim_enabled: false
```

Or for a single run without touching `host_vars`:

```bash
./install.sh --skip-roles nvim
```

The existing `~/.config/nvim/` directory is left untouched — Ansible will not remove it.

### Sync behaviour

The nvim sync timer runs independently of the main dotfiles sync. On Linux/WSL2 it uses a systemd user timer (`nvim-config-sync.timer`); on macOS a launchd agent (`com.nvim-config.sync`).

```bash
# Linux / WSL2
systemctl --user status nvim-config-sync.timer

# macOS
launchctl list | grep nvim-config
```

Runtime config and logs:

```
~/.config/nvim-config/sync.conf          # REPO_URL, DEV_MODE, GIT_BRANCH (created once, never overwritten)
~/.local/state/nvim-config-sync/logs/sync.log
```

---

## ai-tools

### What it does

- Clones your `ai-config` repository to `~/.local/share/ai-config`
- Deploys its contents to the appropriate destination paths (e.g. `~/.claude/` for Claude skills and configuration)
- Installs a background sync timer that pulls `ai-config` updates every 30 minutes
- New files from upstream are deployed on each sync; existing destination files are **never overwritten** (matching Ansible's `force: false` semantics)

### Requirements

- `dotfiles_profile: workstation`
- A private `ai-config` repository accessible via SSH

### Enabling ai-tools

**During first-run install:**

```
Enable ai-tools role? [Y/n]: Y
ai-config repo SSH URL: git@github-dotfiles-ai:you/ai-config.git
```

**In host_vars directly:**

```yaml
# ansible/host_vars/localhost.yml
dotfiles_ai_tools_enabled: true
ai_config_repo_url: "git@github-dotfiles-ai:you/ai-config.git"
```

### ai-config repo structure

The `ai-config` repo is expected to follow this layout:

```
ai-config/
├── claude/          → ~/.claude/
│   ├── skills/
│   └── ...
└── copilot/         → Copilot config location
```

### Disabling ai-tools

```yaml
dotfiles_ai_tools_enabled: false
```

Or for a single run:

```bash
./install.sh --skip-roles ai-tools
```

### Sync behaviour

The ai-config sync timer runs every 30 minutes. On Linux/WSL2 a systemd user timer (`ai-config-sync.timer`); on macOS a launchd agent (`com.ai-config.sync`).

```bash
# Linux / WSL2
systemctl --user status ai-config-sync.timer

# macOS
launchctl list | grep ai-config
```

Runtime config and logs:

```
~/.config/ai-config/sync.conf
~/.local/share/ai-config-sync/logs/sync.log
```

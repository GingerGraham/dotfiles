# Profiles

A profile controls which Ansible roles run on a machine. It is set in `ansible/host_vars/localhost.yml` and governs what gets deployed.

## Available profiles

| Profile | Roles activated |
|---|---|
| `workstation` | common, shell, git, ssh, tmux, vim, nvim\*, ai-tools\*, sync |
| `server` | common, shell, git, ssh, tmux, vim, sync |
| `minimal` | common, shell, git, ssh |

\* nvim and ai-tools are workstation-only and are additionally gated by their own enable flags and the presence of a companion repo URL. See [Optional components](optional-components.md).

## Choosing a profile

**workstation** is the default for a personal machine. It deploys the full configuration including Neovim, AI tooling, and the background sync timer.

**server** is for remote machines where you want a consistent shell and git setup but not a full editor config or AI tooling. It uses a separate playbook (`server.yml`), selected with `--playbook server`.

**minimal** is for containers, CI environments, or any context where you want only the base shell environment.

## Setting the profile

### At install time

```bash
./install.sh --profile workstation
./install.sh --profile server --playbook server
./install.sh --profile minimal
```

Or via bootstrap:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh) \
  --profile server --playbook server
```

### Changing the profile later

Edit `ansible/host_vars/localhost.yml`:

```yaml
dotfiles_profile: server
```

Then re-run:

```bash
./install.sh
```

Ansible is idempotent — roles that are no longer active for the new profile are simply not applied; they do not remove previously deployed files. If you switch from `workstation` to `server`, the Neovim config directory at `~/.config/nvim/` remains in place.

## Fine-grained overrides

Within the `workstation` profile you can disable individual optional roles without changing the profile:

```yaml
# ansible/host_vars/localhost.yml
dotfiles_profile: workstation
dotfiles_nvim_enabled: false      # skip nvim role on this machine
dotfiles_ai_tools_enabled: false  # skip ai-tools role on this machine
dotfiles_sync_enabled: false      # skip background sync timer
```

These flags default to `true` within the workstation profile. Setting them here avoids having to pass `--skip-roles` on every re-run.

## Extra roles

The `dotfiles_extra_roles` list in `host_vars` runs additional roles on this machine regardless of profile:

```yaml
dotfiles_extra_roles:
  - clamav
  - 1password
```

Each entry must correspond to a role directory under `ansible/roles/`. The role is responsible for any platform or profile guards it needs internally.

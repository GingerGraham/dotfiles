# Profiles

A profile controls which Ansible roles run on a machine. It is set in `ansible/host_vars/localhost.yml` and governs what gets deployed.

## Table of Contents

- [Available profiles](#available-profiles)
- [Choosing a profile](#choosing-a-profile)
- [Setting the profile](#setting-the-profile)
  - [At install time](#at-install-time)
  - [Changing the profile later](#changing-the-profile-later)
- [Fine-grained overrides](#fine-grained-overrides)
- [Extra roles](#extra-roles)

## Available profiles

| Profile | Roles activated |
| --- | --- |
| `workstation` | common, shell, git, ssh, tmux, vim, sync-external\*, sync |
| `server` | common, shell, git, ssh, tmux, vim, sync-external\*, sync |
| `minimal` | common, shell, git, ssh |

\* sync-external runs on both `workstation` and `server`, gated by `dotfiles_sync_enabled`. It deploys/syncs whatever repos are listed in `external_synced_repos` — see [External sync](external-sync.md).

## Choosing a profile

**workstation** is the default for a personal machine. It deploys the full configuration including editor/AI tooling (via registered external add-on repos) and the background sync timers.

**server** is for remote machines where you want a consistent shell and git setup, plus the same external add-on repo sync engine, without the interactive editor roles (`tmux`, `vim` still run; there is no separate editor-config role). It uses a separate playbook (`server.yml`), selected with `--playbook server`.

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

Ansible is idempotent — roles that are no longer active for the new profile are simply not applied; they do not remove previously deployed files. If you switch from `workstation` to `server`, an add-on repo cloned to `~/.config/nvim/` remains in place — `sync-external` still runs under `server` and keeps it synced.

## Fine-grained overrides

You can disable the sync timers without changing the profile:

```yaml
# ansible/host_vars/localhost.yml
dotfiles_sync_enabled: false      # skip both the dotfiles self-sync and sync-external
```

To stop syncing a single external repo without disabling the whole engine, remove its entry from `external_synced_repos` — see [External sync](external-sync.md).

## Extra roles

The `dotfiles_extra_roles` list in `host_vars` runs additional roles on this machine regardless of profile:

```yaml
dotfiles_extra_roles:
  - clamav
  - 1password
```

Each entry must correspond to a role directory under `ansible/roles/`. The role is responsible for any platform or profile guards it needs internally.

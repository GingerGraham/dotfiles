# shell role

## Purpose

Deploys the shell configuration layer to the target machine. This role manages
symlinks only — it does not copy files. Changes to shell config files in the
repo are immediately live in new shell sessions without re-running Ansible.

## What it deploys

| Source (repo)   | Destination                       | Notes                                  |
| --------------- | --------------------------------- | -------------------------------------- |
| `shell/config/` | `~/.config/shell`                 | Directory symlink — entire config tree |
| `shell/bashrc`  | `~/.bashrc`                       | Thin stub that sources loader.sh       |
| `shell/zshrc`   | `~/.zshrc`                        | Thin stub that sources loader.sh       |
| `shell/zshenv`  | `~/.zshenv`                       | Sets ZDOTDIR for zsh                   |
| _(template)_    | `~/.config/shell/env/90-local.sh` | Created once, never overwritten        |
| _(template)_    | `~/.config/starship.toml`         | Created once, never overwritten        |

## Idempotency behaviour

| Scenario                                         | Behaviour                                                                         |
| ------------------------------------------------ | --------------------------------------------------------------------------------- |
| linuxDotFiles symlink at `~/.bashrc` etc.        | Removed; replaced with dotfiles symlink                                           |
| Real file (non-symlink) at `~/.bashrc` etc.      | Backed up to `~/.config/dotfiles/migration/<filename>.pre-dotfiles.bak`; replaced |
| `~/.config/shell` is already the correct symlink | No change (Ansible no-op)                                                         |
| `~/.config/shell` is a real directory            | **Role fails with instructions** — manual step required                           |
| `90-local.sh` already exists                     | Left untouched (`force: false`)                                                   |
| `starship.toml` already exists                   | Left untouched (`force: false`)                                                   |

## Machine-local env file

`~/.config/shell/env/90-local.sh` is templated on first Ansible run and never
overwritten. It is gitignored (`shell/config/env/90-local.sh` in `.gitignore`).

Edit it directly on the machine to add machine-specific PATH extensions, proxy
settings, credentials, or tool version pins. It is sourced last in the `env/`
tier so its values override everything in the shared config.

See the file itself for annotated examples.

## Dependencies

Requires the `common` role to have run first. The `common` role creates the
XDG base directories (`~/.config/`, `~/.config/shell/` parent) that this role
depends on.

## Variables

| Variable                  | Default                       | Source               | Description                                   |
| ------------------------- | ----------------------------- | -------------------- | --------------------------------------------- |
| `shell_config_dir`        | `{{ xdg_config_home }}/shell` | `group_vars/all.yml` | Symlink destination for the shell config tree |
| `shell_migration_targets` | `[~/.bashrc, ~/.zshrc, ...]`  | `defaults/main.yml`  | Paths checked for linuxDotFiles symlinks      |
| `shell_stubs`             | `[bashrc, zshrc, zshenv]`     | `defaults/main.yml`  | Stub files symlinked into HOME                |
| `dotfiles_machine_name`   | `{{ ansible_hostname }}`      | Set by `common` role | Used in 90-local.sh template                  |

## Running this role alone

```bash
ansible-playbook ansible/site.yml --tags shell
```

Note: `common` must run first to create XDG directories. Run both together:

```bash
ansible-playbook ansible/site.yml --tags common,shell
```

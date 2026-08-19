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
| _(template)_    | `~/.config/dotfiles/local/90-local.sh` | Created once, never overwritten. Deliberately outside `~/.config/shell` (a repo symlink) so it survives a release-mode symlink swap |
| _(template)_    | `~/.config/direnv/direnv.toml`    | Created once, never overwritten        |
| _(template)_    | `~/.config/starship.toml`         | Created once, never overwritten        |
| _(none)_         | `~/.config/dotfiles/user`         | Directory only — never managed after creation. See [user-extensions.md](../../../docs/user-extensions.md) |

## Idempotency behaviour

| Scenario                                         | Behaviour                                                                         |
| ------------------------------------------------ | --------------------------------------------------------------------------------- |
| linuxDotFiles symlink at `~/.bashrc` etc.        | Removed; replaced with dotfiles symlink                                           |
| Real file (non-symlink) at `~/.bashrc` etc.      | Backed up to `~/.config/dotfiles/migration/<filename>.pre-dotfiles.bak`; replaced |
| `~/.config/shell` is already the correct symlink | No change (Ansible no-op)                                                         |
| `~/.config/shell` is a real directory            | **Role fails with instructions** — manual step required                           |
| `90-local.sh` already exists at the relocated path | Left untouched (`force: false`)                                                 |
| Legacy `90-local.sh` found in-tree (pre-relocation installs) | Copied to the relocated path (unless already present there), then removed from the repo tree |
| `direnv.toml` already exists                     | Left untouched (`force: false`)                                                   |
| `starship.toml` already exists                   | Left untouched (`force: false`)                                                   |

## Machine-local env file

`~/.config/dotfiles/local/90-local.sh` is templated on first Ansible run and
never overwritten. It lives outside `~/.config/shell` (a symlink into
`dotfiles_repo_root`, the dotfiles repo working tree or release checkout) so
it survives a release-mode symlink swap untouched — see
[docs/sync.md#install-modes](../../../docs/sync.md#install-modes). The `.j2`
template itself stays tracked in the repo, refreshed on every sync, so you
have a reference to diff your deployed copy against — there is no auto-merge.

Edit the deployed file directly on the machine to add machine-specific PATH
extensions, proxy settings, credentials, or tool version pins. `loader.sh`
sources it last, after every shared `env/` file, so its values override
everything in the shared config.

See the file itself for annotated examples.

## direnv configuration

`~/.config/direnv/direnv.toml` is templated on first Ansible run and never
overwritten thereafter. Opinionated defaults:

- `load_dotenv = true` — `.envrc` files using `dotenv_if_exists` will also
  load a sibling `.env` file automatically.
- `[whitelist] prefix` — your `projects_base` directory tree is pre-allowed,
  so new `.envrc` files under it load without an explicit `direnv allow`.
- `warn_timeout = "10s"` — suppresses the slow-`.envrc` warning under 10s.

Shell integration (`tools/direnv.sh`, loaded when `direnv` is present):

- Sets `DIRENV_LOG_FORMAT=""` to silence the per-directory load/unload log lines.
- `edit-direnv-config` — open `direnv.toml` in `$EDITOR`.
- `direnv-init-project [path]` — scaffold a starter `.envrc` (with
  `dotenv_if_exists` and commented examples for AWS/Azure profile vars and
  Python venv layout) in the given directory (default: cwd). Does not
  overwrite an existing `.envrc`.

Edit `direnv.toml` directly on the machine for further customisation
(per-directory `[whitelist.exact]`, additional `[global]` settings, etc.).

The `git` role deploys one additional stdlib function here,
`~/.config/direnv/lib/dotfiles-git-context.sh` (`use git_context`), that wires per-project
gh/glab CLI authentication — see [CLI context](../git/README.md#cli-context) in the git
role README for the full design.

## Dependencies

Requires the `common` role to have run first. The `common` role creates the
XDG base directories (`~/.config/`, `~/.config/shell/` parent) that this role
depends on.

## Variables

| Variable                  | Default                        | Source               | Description                                   |
| ------------------------- | ------------------------------ | -------------------- | --------------------------------------------- |
| `shell_config_dir`        | `{{ xdg_config_home }}/shell`  | `group_vars/all.yml` | Symlink destination for the shell config tree |
| `shell_migration_targets` | `[~/.bashrc, ~/.zshrc, ...]`   | `defaults/main.yml`  | Paths checked for linuxDotFiles symlinks      |
| `shell_stubs`             | `[bashrc, zshrc, zshenv]`      | `defaults/main.yml`  | Stub files symlinked into HOME                |
| `dotfiles_machine_name`   | `{{ ansible_hostname }}`       | Set by `common` role | Used in 90-local.sh template                  |
| `projects_base`           | `{{ xdg_data_home }}/projects` | `group_vars/all.yml` | Used in direnv.toml template                  |
| `shell_user_ext_dir`      | `{{ xdg_config_home }}/dotfiles/user` | `group_vars/all.yml` | User extension drop-in directory — created only, never templated |
| `dotfiles_local_env_dir`  | `{{ xdg_config_home }}/dotfiles/local` | `group_vars/all.yml` | `90-local.sh` destination — outside `shell_config_dir` so it survives release-mode symlink swaps |

## Running this role alone

```bash
ansible-playbook ansible/site.yml --tags shell
```

Note: `common` must run first to create XDG directories. Run both together:

```bash
ansible-playbook ansible/site.yml --tags common,shell
```

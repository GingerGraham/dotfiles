# tmux role

## Purpose

Deploys the tmux configuration to the target machine via a symlink into the
dotfiles repo. Changes to `tmux/tmux.conf` are live immediately in new tmux
sessions without re-running Ansible — a `git pull` from the sync service is
sufficient.

## What it deploys

| Source (repo)          | Destination                | Notes                           |
| ---------------------- | -------------------------- | ------------------------------- |
| `files/tmux/tmux.conf` | `~/.config/tmux/tmux.conf` | Symlink — XDG path, tmux >= 3.1 |

tmux reads `~/.config/tmux/tmux.conf` natively since version 3.1 (2020).
No `$XDG_CONFIG_HOME` export or `TMUX_CONF` override is required.

## Idempotency behaviour

| Scenario                                              | Behaviour                                             |
| ----------------------------------------------------- | ----------------------------------------------------- |
| linuxDotFiles symlink at `~/.tmux.conf`               | Removed; superseded by the XDG-path symlink           |
| Real file at `~/.tmux.conf`                           | Backed up to `~/.tmux.conf.pre-dotfiles.bak`; removed |
| Real file at `~/.config/tmux/tmux.conf`               | Backed up to same path + `.pre-dotfiles.bak`; removed |
| `~/.config/tmux/tmux.conf` is already correct symlink | No change (Ansible no-op)                             |

## TPM (Tmux Plugin Manager)

`tmux.conf` includes a bootstrap snippet that clones TPM and installs all
plugins automatically on the first `tmux` launch after deployment. No manual
step is required:

```
if "test ! -d ~/.tmux/plugins/tpm" \
   "run 'git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm \
   && ~/.tmux/plugins/tpm/bin/install_plugins'"
```

To update plugins later: `prefix` + `U` inside a tmux session.

## Default shell

The config does not set `default-shell`. tmux inherits the user's login shell,
which is the correct behaviour across Fedora, Ubuntu, and servers where the
login shell may differ.

## Variables

| Variable           | Default                                | Override in         | Description                   |
| ------------------ | -------------------------------------- | ------------------- | ----------------------------- |
| `tmux_config_dir`  | `{{ xdg_config_home }}/tmux`           | `defaults/main.yml` | XDG config directory for tmux |
| `tmux_config_dest` | `{{ xdg_config_home }}/tmux/tmux.conf` | `defaults/main.yml` | Symlink destination           |

## Activation

Runs for `workstation` and `server` profiles. Skipped for `minimal`.

## Dependencies

Requires the `common` role to have run first (creates XDG base dirs and sets
`xdg_config_home`).

## Running this role alone

```bash
ansible-playbook ansible/site.yml --tags common,tmux
```

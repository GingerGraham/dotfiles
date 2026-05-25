# vim role

## Purpose

Deploys a plain vim configuration to the target machine via a symlink into the
dotfiles repo. This config is intentionally minimal and dependency-free —
it exists for server and minimal-profile contexts where the neovim sync
option is not in use.

For the full editor experience, the `nvim` role manages neovim via the
separate `nvim-config` companion repo.

## What it deploys

| Source (repo)     | Destination | Notes                           |
| ----------------- | ----------- | ------------------------------- |
| `files/vim/vimrc` | `~/.vimrc`  | Symlink — universally supported |

`~/.vimrc` is used rather than an XDG path. Vim's XDG support requires
`$VIMINIT` workarounds that are unreliable across server distributions.
`~/.vimrc` is recognised by every vim version on every platform.

## Idempotency behaviour

| Scenario                                  | Behaviour                                          |
| ----------------------------------------- | -------------------------------------------------- |
| linuxDotFiles symlink at `~/.vimrc`       | Removed; replaced with dotfiles symlink            |
| Real file at `~/.vimrc`                   | Backed up to `~/.vimrc.pre-dotfiles.bak`; replaced |
| `~/.vimrc` is already the correct symlink | No change (Ansible no-op)                          |

## Variables

| Variable          | Default                                     | Override in         | Description         |
| ----------------- | ------------------------------------------- | ------------------- | ------------------- |
| `vim_config_dest` | `{{ ansible_facts['env']['HOME'] }}/.vimrc` | `defaults/main.yml` | Symlink destination |

## Activation

Runs for `workstation` and `server` profiles. Skipped for `minimal`.

## Dependencies

Requires the `common` role to have run first (gathers `ansible_facts`).

## Running this role alone

```bash
ansible-playbook ansible/site.yml --tags common,vim
```

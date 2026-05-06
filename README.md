# dotfiles

## Overview

This repository is an Ansible-native dotfiles orchestrator for user-level configuration across Fedora/RHEL, Ubuntu/Debian, macOS, and WSL2. It manages dotfile deployment and role coordination only; it does not install packages or apply system-level machine configuration.

## Repo Structure

```text
.
|-- ansible/      # Playbooks, inventory, group and host vars, and roles
|-- shell/        # coming soon
`-- install.sh    # coming soon
```

## Companion Repos

| Repo                 | Visibility | Purpose                                        |
| -------------------- | ---------- | ---------------------------------------------- |
| dotfiles (this repo) | Private    | Shell config, git config, Ansible orchestrator |
| nvim-config          | Public     | Neovim config - cloned to ~/.config/nvim/      |
| ai-config            | Private    | ~/.claude/, Copilot config, AI tooling         |

## Prerequisites

- git
- ansible-core >= 2.14
- Python 3.9+

install.sh (coming soon) will eventually bootstrap prerequisites automatically. For now, install them manually.

## Quick Start

1. Clone this repository.
2. Copy ansible/host_vars/localhost.yml.example to ansible/host_vars/localhost.yml and fill in your values.
3. Run:

```bash
ansible-playbook ansible/site.yml
```

## Running Individual Roles

```bash
ansible-playbook ansible/site.yml --tags common
ansible-playbook ansible/site.yml --tags git,shell
```

## Profiles

| Profile     | Roles Activated                               |
| ----------- | --------------------------------------------- |
| workstation | common, shell, git, ssh, nvim, ai-tools, sync |
| server      | common, shell, git, ssh, sync                 |
| minimal     | common, shell, git, ssh                       |

## Variable Reference

| Variable             | Default                                      | Override in             | Purpose                                                                        |
| -------------------- | -------------------------------------------- | ----------------------- | ------------------------------------------------------------------------------ |
| xdg_config_home      | {{ ansible_env.HOME }}/.config               | group_vars/all.yml      | Base XDG config directory used by roles to avoid hardcoded paths.              |
| xdg_data_home        | {{ ansible_env.HOME }}/.local/share          | group_vars/all.yml      | Base XDG data directory for role-managed data storage.                         |
| xdg_cache_home       | {{ ansible_env.HOME }}/.cache                | group_vars/all.yml      | Base XDG cache directory for transient files.                                  |
| xdg_state_home       | {{ ansible_env.HOME }}/.local/state          | group_vars/all.yml      | Base XDG state directory for persistent runtime state.                         |
| shell_config_dir     | {{ xdg_config_home }}/shell                  | group_vars/all.yml      | Destination path consumed by shell role.                                       |
| git_config_dir       | {{ xdg_config_home }}/git                    | group_vars/all.yml      | Destination path consumed by git role.                                         |
| nvim_config_dir      | {{ xdg_config_home }}/nvim                   | group_vars/all.yml      | Destination path consumed by nvim role.                                        |
| dotfiles_profile     | workstation                                  | host_vars/localhost.yml | Selects which profile-driven role set should run on this machine.              |
| nvim_config_repo_url | ""                                           | host_vars/localhost.yml | Source repository URL for cloning nvim config.                                 |
| ai_config_repo_url   | ""                                           | host_vars/localhost.yml | Source repository URL for cloning AI tool config.                              |
| claude_config_dest   | {{ ansible_env.HOME }}/.claude               | group_vars/all.yml      | Destination path for Claude configuration symlink or files.                    |
| copilot_config_dest  | OS-specific expression in group_vars/all.yml | group_vars/all.yml      | Destination path for GitHub Copilot configuration.                             |
| dotfiles_is_wsl      | false                                        | Set by common role      | Canonical WSL detection fact. Set from ansible_kernel by the common role. Use this in all role when: conditions. |

## Development / Testing

- Dry run with diff output:

```bash
ansible-playbook ansible/site.yml --check --diff
```

- Run specific role tags:

```bash
ansible-playbook ansible/site.yml --tags common
ansible-playbook ansible/site.yml --tags git,shell
```

- ansible/host_vars/localhost.yml is intentionally gitignored and should remain local.

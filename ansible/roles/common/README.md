# common role

## Purpose

The common role is a prerequisite for all other roles. It centralizes required OS and environment fact gathering into one source of truth and exposes consistent derived fact names so downstream roles do not duplicate kernel or distribution detection logic.

## Facts Set

| Fact                  | Example Value  | Used By                     |
| --------------------- | -------------- | --------------------------- |
| dotfiles_os_family    | RedHat         | shell, future package roles |
| dotfiles_distro       | fedora         | shell                       |
| dotfiles_is_wsl       | false          | shell                       |
| dotfiles_machine_name | my-workstation | git                         |

## Directories Created

| Path                        | Purpose                                                      |
| --------------------------- | ------------------------------------------------------------ |
| {{ xdg_config_home }}       | Base XDG configuration root for all role-managed user config |
| {{ xdg_data_home }}         | Base XDG data root for application data                      |
| {{ xdg_cache_home }}        | Base XDG cache root for transient cache files                |
| {{ xdg_state_home }}        | Base XDG state root for persistent state data                |
| {{ xdg_config_home }}/shell | Destination for shell role configuration assets              |
| {{ xdg_config_home }}/git   | Destination for git role configuration assets                |

## Variables

| Variable        | Default                                                                                                                                          | Description                                                                                       |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| common_xdg_dirs | [{{ xdg_config_home }}, {{ xdg_data_home }}, {{ xdg_cache_home }}, {{ xdg_state_home }}, {{ xdg_config_home }}/shell, {{ xdg_config_home }}/git] | Ordered list of directories created by this role to ensure XDG roots and role target paths exist. |

## Dependencies

None.

## Example: Running this role alone

ansible-playbook ansible/site.yml --tags common

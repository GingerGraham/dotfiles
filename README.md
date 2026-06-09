# dotfiles

An Ansible-native, XDG-compliant dotfiles system for Fedora/RHEL, Ubuntu/Debian, macOS, and WSL2.
Manages shell configuration, git identity, SSH key structure, Neovim config, and AI tooling — and keeps itself up to date via a background sync timer.

> **Forking this repo?** The bootstrap URL below points to `GingerGraham/dotfiles`. Update it to your own fork's raw URL before sharing or using your fork's one-liner.

## Quick start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh)
```

The bootstrap script clones the repo and hands off to `install.sh`. On first run you will be prompted for a profile, machine name, git identity, and optional companion repo URLs.

See the [docs/](docs/) directory for full documentation.

## Documentation

| Document                                                   | Contents                                                      |
| ---------------------------------------------------------- | ------------------------------------------------------------- |
| [docs/installation.md](docs/installation.md)               | Bootstrap, `install.sh` reference, all CLI options            |
| [docs/profiles.md](docs/profiles.md)                       | Workstation, server, and minimal profiles                     |
| [docs/optional-components.md](docs/optional-components.md) | nvim and ai-tools roles — what they do and how to enable them |
| [docs/shell-config.md](docs/shell-config.md)               | Shell loading architecture, tiers, local overrides            |
| [docs/sync.md](docs/sync.md)                               | Background sync, DEV_MODE, branch switching                   |
| [docs/gpg.md](docs/gpg.md)                                 | GPG key management, Bitwarden backup, git signing setup       |

## Supported platforms

| Platform                     | Status       |
| ---------------------------- | ------------ |
| Fedora / RHEL / Rocky / Alma | ✅ Primary   |
| Ubuntu / Debian / Pop!\_OS   | ✅ Supported |
| openSUSE Tumbleweed / SLES   | ✅ Supported |
| Arch / Manjaro / EndeavourOS | ✅ Supported |
| macOS                        | ✅ Supported |
| WSL2 (systemd enabled)       | ✅ Supported |

## Prerequisites

`install.sh` checks for and will attempt to install:

- `git`
- `python3 >= 3.9`
- `ansible-core >= 2.14`

Pass `--no-prereqs` to skip this check if they are already present.

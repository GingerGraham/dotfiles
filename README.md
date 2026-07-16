# dotfiles

An Ansible-native, XDG-compliant dotfiles system for Fedora/RHEL, Ubuntu/Debian, macOS, and WSL2.
Manages shell configuration, git identity, and SSH key structure — and keeps itself, plus any number of registered external add-on repos (editor config, AI tooling, or anything else you point it at), up to date via background sync timers. See [External sync](docs/external-sync.md) for the add-on repo engine.

> **Forking this repo?** The bootstrap URL below points to `GingerGraham/dotfiles`. Update it to your own fork's raw URL before sharing or using your fork's one-liner.

## Table of Contents

- [dotfiles](#dotfiles)
  - [Table of Contents](#table-of-contents)
  - [Quick start](#quick-start)
  - [Documentation](#documentation)
  - [Supported platforms](#supported-platforms)
  - [Supported integrations](#supported-integrations)
    - [Git providers](#git-providers)
    - [Password managers](#password-managers)
  - [Prerequisites](#prerequisites)
  - [Keeping tools updated](#keeping-tools-updated)

## Quick start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh)
```

The bootstrap script clones the repo and hands off to `install.sh`. On first run you will be prompted for a profile, machine name, git identity, and any external add-on repos you want synced (e.g. editor config, AI tooling).

See the [docs/](docs/) directory for full documentation.

## Documentation

| Document | Contents |
| --- | --- |
| [docs/installation.md](docs/installation.md) | Bootstrap, `install.sh` reference, all CLI options |
| [docs/profiles.md](docs/profiles.md) | Workstation, server, and minimal profiles |
| [docs/shell-config.md](docs/shell-config.md) | Shell loading architecture, tiers, local overrides |
| [docs/tool-management.md](docs/tool-management.md) | `update-tools`, installers, and the managed tools registry |
| [docs/installers.md](docs/installers.md) | Per-tool installer reference (`install-*` functions) |
| [docs/sync.md](docs/sync.md) | Background sync, DEV_MODE, branch switching |
| [docs/external-sync.md](docs/external-sync.md) | Generic external add-on repo sync engine — adding repos, cadence, troubleshooting |
| [docs/sync-manifest-spec.md](docs/sync-manifest-spec.md) | `.dotfiles-sync.yml` manifest contract for add-on repo authors |
| [docs/gpg.md](docs/gpg.md) | GPG key management, password manager backup, git provider signing setup |

## Supported platforms

| Platform | Status |
| --- | --- |
| Fedora / RHEL / Rocky / Alma | ✅ Primary |
| Ubuntu / Debian / Pop!\_OS | ✅ Supported |
| openSUSE Tumbleweed / SLES | ✅ Supported |
| Arch / Manjaro / EndeavourOS | ✅ Supported |
| macOS | ✅ Supported |
| WSL2 (systemd enabled) | ✅ Supported |

## Supported integrations

### Git providers

Git identity is managed per `context`/`provider` pair (see [docs/installation.md](docs/installation.md) and the [git role](ansible/roles/git/README.md)). Any provider can be configured this way — `provider` is a free-text label used to build the directory path, profile name, and `includeIf` block. The following are tested and have first-class support elsewhere in the system (CLI installers, GPG key publishing, known-host pre-trust):

| Provider | CLI installer | GPG signing key publishing |
| --- | --- | --- |
| GitHub | `install-gh` | `gpg-push-github` |
| GitLab | `install-glab` | `gpg-push-gitlab` |

Bitbucket, Azure DevOps, and other providers work as `context`/`provider` pairs but do not currently have a dedicated CLI installer or GPG publishing helper.

### Password managers

GPG key backup, restore, and rotation (see [docs/gpg.md](docs/gpg.md)) support two password managers. Use whichever matches your vault, or both:

| Password manager | Desktop installer | CLI installer | GPG functions |
| --- | --- | --- | --- |
| Bitwarden | `install-bitwarden` | `install-bw-cli` | `gpg-*-bitwarden` |
| 1Password | `install-1password` | `install-op-cli` | `gpg-*-1password` |

## Prerequisites

`install.sh` checks for and will attempt to install:

- `git`
- `python3 >= 3.9`
- `ansible-core >= 2.14`

Pass `--no-prereqs` to skip this check if they are already present.

## Keeping tools updated

Once dotfiles is installed, you can manage 20+ development tools with a single command:

```bash
# Update all installed tools
update-tools

# Update specific tools
update-tools terraform aws kubectl

# See what's installed
update-tools --list
```

No manual downloads or version tracking required. Supported tools include Terraform, Helm, Kubernetes, AWS CLI, Azure CLI, Ansible, GitHub CLI, GitLab CLI, Bitwarden, 1Password, Node/nvm, and more.

See [docs/tool-management.md](docs/tool-management.md) for the complete list, how to install individual tools, and how to add new tools to the registry.

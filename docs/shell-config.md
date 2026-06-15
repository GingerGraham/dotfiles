# Shell configuration

Shell config lives at `~/.config/shell/` — an XDG-compliant directory that is a symlink back into the dotfiles repo. Editing any file there takes effect in the next shell session with no Ansible re-run required.

## Table of Contents

- [Shell configuration](#shell-configuration)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Loading order](#loading-order)
  - [Three loading tiers](#three-loading-tiers)
    - [Tier 1 — Eager, always](#tier-1--eager-always)
    - [Tier 2 — Conditional eager](#tier-2--conditional-eager)
    - [Tier 3 — Lazy](#tier-3--lazy)
  - [Prompt engine selection](#prompt-engine-selection)
  - [Exported variables](#exported-variables)
  - [Machine-local overrides](#machine-local-overrides)
  - [Shell introspection](#shell-introspection)
  - [Migration from an existing shell config](#migration-from-an-existing-shell-config)
  - [Tool installation \& management](#tool-installation--management)
    - [Installers (lazy/installers.sh)](#installers-lazyinstallerssh)
    - [Maintenance (lazy/maintenance.sh)](#maintenance-lazymaintenancesh)
  - [Lazy loading architecture](#lazy-loading-architecture)
  - [Repo layout](#repo-layout)

## Overview

Both `~/.bashrc` and `~/.zshrc` are thin stubs that do one thing: source `~/.config/shell/loader.sh`. All logic lives there.

## Loading order

`loader.sh` runs once per shell startup in this sequence:

1. Source `bash-logger` (structured logging available to everything downstream)
2. Detect OS → `$DOTFILES_OS` (`Linux` / `Mac`)
3. Detect WSL → `$DOTFILES_WSL` (`true` / `false`)
4. Detect distro → `$DOTFILES_DISTRO` (`rhel` / `debian` / `suse` / `arch` / `unknown`)
5. Detect shell → `$DOTFILES_SHELL` (`bash` / `zsh` / `sh`)
6. Source `env/` files in numeric order
7. Source `core/` unconditionally
8. Source each `tools/` file if its guard passes (`command -v <tool>`)
9. Source `platform/$DOTFILES_OS.sh`; additionally source `platform/wsl.sh` if `$DOTFILES_WSL == "true"`
10. Source `distro/$DOTFILES_DISTRO.sh`
11. Source completions with the same tool guards
12. Elect a prompt engine (oh-my-posh → starship → oh-my-zsh → distro-native → fallback PS1)
13. Register lazy stubs for `lazy/`
14. Source `env/90-local.sh` last — machine-local overrides win

Detection runs exactly once per session. Results are exported as `DOTFILES_*` variables; no repeated `uname` or `/etc/os-release` reads.

## Three loading tiers

### Tier 1 — Eager, always

`env/` and `core/` load unconditionally on every shell start. Files here must be fast — no subprocesses, no network calls.

| File                    | Purpose                                                   |
| ----------------------- | --------------------------------------------------------- |
| `env/00-core.sh`        | XDG paths, base PATH extensions, locale, history          |
| `env/10-editors.sh`     | `EDITOR`, `VISUAL`, pager                                 |
| `env/20-development.sh` | `GOPATH`, `PYENV_ROOT`, language version manager hooks    |
| `env/90-local.sh`       | Machine-local overrides — created once, never overwritten |
| `core/aliases.sh`       | Navigation aliases (`ls`, `cd`, common shortcuts)         |
| `core/functions.sh`     | Shell introspection (`get-my-functions`, `dedupe-path`)   |
| `core/ssh.sh`           | SSH agent helpers, `list-ssh-hosts`                       |

### Tier 2 — Conditional eager

`tools/`, `platform/`, and `distro/` files load only when the relevant condition is true. Each `tools/` file guards itself at the top with `command -v <tool> &>/dev/null || return 0`.

| File            | Guard                            | Contents                                                    |
| --------------- | -------------------------------- | ----------------------------------------------------------- |
| `git.sh`        | `command -v git`                 | Git aliases, worktree helpers, project management functions |
| `kubernetes.sh` | `command -v kubectl`             | `k` alias, context/namespace helpers                        |
| `terraform.sh`  | `command -v terraform` or `tofu` | Workspace aliases, install helper                           |
| `ansible.sh`    | `command -v ansible`             | Playbook aliases, vault helpers                             |
| `containers.sh` | `docker` or `podman`             | Container aliases, image management                         |
| `direnv.sh`     | `command -v direnv`              | direnv hooks, quiet output, config helpers                  |
| `aws.sh`        | `command -v aws`                 | Profile switching, region helpers                           |
| `azure.sh`      | `command -v az`                  | Subscription switching, login helpers                       |
| `security.sh`   | `clamscan` or `sonar-scanner`    | AV scan aliases, scanner shortcut                           |
| `gpg.sh`        | `command -v gpg`                 | Key listing, signing key lookup for git, agent helpers      |
| `go.sh`         | `command -v go`                  | GOPATH helpers, module aliases                              |

Platform and distro files add platform-specific aliases, PATH entries, and environment setup. `platform/wsl.sh` is sourced **in addition to** `platform/linux.sh` on WSL systems (not instead of it).

### Tier 3 — Lazy

`lazy/` files are never sourced at startup. Instead, stub functions are registered automatically at startup by scanning each `lazy/*.sh` file for public function definitions. The stub sources the file and replays the original call on first use; subsequent calls go directly to the real function.

```bash
# gpg-create-key is available immediately after shell start,
# but lazy/gpg-management.sh is not sourced until you actually call it.
gpg-create-key
```

| File                | Contents                                                                                                                                  |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `installers.sh`     | `install-*` functions (gh, glab, nvm, copilot-cli, claude-code, bw-cli, op-cli, oh-my-posh, edit, …). See [installers.md](installers.md). |
| `maintenance.sh`    | `update-tools` — orchestrated update of all managed tools                                                                                 |
| `gpg-management.sh` | Key creation, subkey management, expiry, rotation, export/import (Bitwarden, 1Password), and signing key publishing (GitHub, GitLab)      |

Use `get-my-installers` (alias: `installers`) to list all available lazy install commands.

## Prompt engine selection

`loader.sh` elects a prompt engine in priority order:

1. **oh-my-posh** — if `oh-my-posh` is in `$PATH`
2. **starship** — if `starship` is in `$PATH`, existing config at `~/.config/starship.toml` is detected, or the default config is successfully created at startup (write permissions in `~/.config/` required)
3. **oh-my-zsh** — if `~/.oh-my-zsh` exists and the shell is zsh
4. **distro-native** — if the distro file exports `_DOTFILES_DISTRO_PROMPT_FILE` pointing to a valid file (zsh only)
5. **Fallback PS1** — set unconditionally if none of the above match; detects terminal colour support and sets an appropriate `PS1`

## Exported variables

| Variable                  | Values                                          | Set by            |
| ------------------------- | ----------------------------------------------- | ----------------- |
| `DOTFILES_OS`             | `Linux` / `Mac`                                 | `loader.sh`       |
| `DOTFILES_WSL`            | `true` / `false`                                | `loader.sh`       |
| `DOTFILES_DISTRO`         | `rhel` / `debian` / `suse` / `arch` / `unknown` | `loader.sh`       |
| `DOTFILES_SHELL`          | `bash` / `zsh` / `sh`                           | `loader.sh`       |
| `DOTFILES_SHOW_FUNCTIONS` | `true` / `false` (default: `false`)             | `env/90-local.sh` |
| `SHELL_CONFIG_DIR`        | `~/.config/shell`                               | `loader.sh`       |
| `DOTFILES_REPO_DIR`       | path to repo                                    | `env/00-core.sh`  |

## Machine-local overrides

`~/.config/shell/env/90-local.sh` is the place for anything specific to one machine:

- Additional PATH entries
- Proxy settings
- Credential exports
- Tool version pins

It is created from a template on the first Ansible run and **never overwritten** by subsequent runs. It is gitignored, so it will not appear in commits. Edit it directly on the machine.

Set `DOTFILES_SHOW_FUNCTIONS=true` here to print the function list automatically on every interactive shell start.

## Shell introspection

Two functions are available in every shell:

```bash
get-my-functions    # Lists all loaded functions and aliases
get-my-installers   # Lists lazy install-* commands (alias: installers)
```

`get-my-functions` excludes functions prefixed with `_` (private helpers) and functions prefixed with `install-` (those are shown by `get-my-installers` instead).

## Migration from an existing shell config

If `~/.bashrc`, `~/.zshrc`, or `~/.zshenv` exists as a real file (not already a symlink) when `install.sh` runs, the shell role backs it up:

```text
~/.config/dotfiles/migration/<filename>.pre-dotfiles.bak
```

A warning is printed on every shell start until the backup directory is cleared:

```text
[WARN]  Migration pending: review backup files and merge any needed content
        into env/90-local.sh, then remove ~/.config/dotfiles/migration/ to
        clear this warning.
```

After porting any content you want to keep into `env/90-local.sh`:

```bash
rm -rf ~/.config/dotfiles/migration/
```

## Tool installation & management

Shell config includes two lazy-loaded modules for tool discovery and updates:

### Installers (lazy/installers.sh)

Every development tool supported by dotfiles has an `install-<tool>` function. These are lazy-loaded — the first call sources the file; subsequent calls use the cached function.

```bash
# Install or update a tool directly
install-terraform
install-helm
install-aws

# See all available installers
installers   # Alias for get-my-installers
```

Installers are safe to call repeatedly; they detect the current version and skip re-download if already up-to-date.

### Maintenance (lazy/maintenance.sh)

The `update-tools` command orchestrates all managed tool updates from a central registry:

```bash
# Update all installed tools
update-tools

# Update specific tools
update-tools terraform aws kubectl

# List managed tools and install status
update-tools --list
```

The registry includes ~20 tools (Terraform, Helm, Kubernetes, AWS, Azure, Ansible, GitHub CLI, GitLab CLI, Bitwarden, 1Password, Node/nvm, etc.). Each tool has:

- A **detection method** — checks if it's installed (via `command -v` or file path)
- An **updater function** — runs the appropriate update mechanism
- An **install command** — suggested when the tool is not found

This decouples tool management from system package managers, allowing you to use version managers like tenv (for Terraform/OpenTofu) or nvm (for Node) alongside system-provided tools.

See [tool-management.md](tool-management.md) for the complete registry, how to add new tools, and troubleshooting.

## Lazy loading architecture

Both `lazy/installers.sh` and `lazy/maintenance.sh` are lazy-loaded:

1. **Stub registration** — at shell startup, `loader.sh` greps `lazy/*.sh` to find public function definitions
2. **Stub creation** — each public function becomes a tiny stub that sources the file on first call
3. **Real function** — the stub removes itself and calls the real function
4. **Cached** — subsequent calls use the real function directly

This keeps shell startup fast (no unnecessary sourcing) while providing all tools on demand.

To inspect lazy stubs:

```bash
# See all lazy-loadable functions
declare -f | grep "unset -f"
```

## Repo layout

```text
shell/
├── bashrc                  # Thin stub → sources loader.sh
├── zshrc                   # Thin stub → sources loader.sh
├── zshenv                  # Sets ZDOTDIR
└── config/                 # Symlinked to ~/.config/shell/
    ├── loader.sh
    ├── env/
    │   ├── 00-core.sh
    │   ├── 10-editors.sh
    │   ├── 20-development.sh
    │   └── 90-local.sh     # gitignored — machine-local
    ├── core/
    │   ├── aliases.sh
    │   ├── functions.sh
    │   └── ssh.sh
    ├── tools/              # One file per tool, guards at top
    │   ├── git.sh
    │   ├── kubernetes.sh
    │   ├── terraform.sh
    │   ├── ansible.sh
    │   ├── containers.sh
    │   ├── aws.sh
    │   ├── azure.sh
    │   ├── security.sh
    │   ├── gpg.sh          # Key listing, signing key lookup, agent helpers
    │   └── go.sh
    ├── platform/           # linux.sh, macos.sh, wsl.sh
    ├── distro/             # rhel.sh, debian.sh, suse.sh, arch.sh
    ├── lazy/                   # Lazy-loaded on first call, not at startup
    │   ├── installers.sh       # install-<tool> and set-<tool> commands
    │   │                       # Manages 20+ tools: terraform, helm, aws, nvm, etc.
    │   ├── maintenance.sh      # update-tools orchestration, registry, and per-tool updaters
    │   │                       # Coordinates install-* commands and automatic updates
    │   └── gpg-management.sh   # GPG key creation, rotation, export/import, signing key publishing
    └── completions/        # Same tool guards as tools/
```

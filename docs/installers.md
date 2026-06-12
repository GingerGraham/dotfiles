# Installer functions

`install-*` functions live in `shell/config/lazy/installers.sh`. They are Tier 3
(lazy): a stub is registered at shell start, and the file is sourced on the first
call to any `install-*` function. List them at any time with:

```bash
installers            # alias for get-my-installers
```

All installers are idempotent — running one again updates the tool in place where
the upstream supports it. User-scope binaries are placed in `~/.local/bin`; when a
package manager's npm prefix is system-owned the install is redirected there so no
root is required.

## Table of Contents

- [Installer functions](#installer-functions)
  - [Table of Contents](#table-of-contents)
  - [Available installers](#available-installers)
  - [GitHub CLI — `install-gh`](#github-cli--install-gh)
  - [GitLab CLI — `install-glab`](#gitlab-cli--install-glab)
  - [1Password Desktop — `install-1password`](#1password-desktop--install-1password)
  - [1Password CLI — `install-op-cli`](#1password-cli--install-op-cli)
  - [Node Version Manager — `install-nvm`](#node-version-manager--install-nvm)
  - [GitHub Copilot CLI — `install-copilot-cli`](#github-copilot-cli--install-copilot-cli)
  - [Claude Code — `install-claude-code`](#claude-code--install-claude-code)
  - [Node prerequisite (shared)](#node-prerequisite-shared)

## Available installers

| Command | Installs | Method |
| --- | --- | --- |
| `install-1password` | 1Password Desktop | Official vendor repo per distro (apt/dnf/zypper/AUR); Flatpak fallback |
| `install-bitwarden` | Bitwarden desktop app | Vendor package per distro / Flatpak / Homebrew cask |
| `install-bw-cli` | Bitwarden CLI (`bw`) | npm global `@bitwarden/cli`, with a binary fallback |
| `install-claude-code` | Claude Code (`claude`) | Native installer (preferred), npm `@anthropic-ai/claude-code` fallback |
| `install-copilot-cli` | GitHub Copilot CLI | npm global `@github/copilot` |
| `install-edit` | Microsoft Edit | GitHub release tarball → `~/.local/bin` |
| `install-gh` | GitHub CLI (`gh`) | Official package repo per distro, with a binary tarball fallback |
| `install-glab` | GitLab CLI (`glab`) | Native dnf/pacman repo on Fedora/Arch; release tarball fallback |
| `install-oh-my-posh` | oh-my-posh prompt | Upstream install script / Homebrew |
| `install-oh-my-zsh` | oh-my-zsh framework | Upstream install script |
| `install-op-cli` | 1Password CLI (`op`) | Official vendor repo per distro (apt/dnf/zypper/AUR); Homebrew on macOS |
| `install-opendeck` | Opendeck | Official vendor repo per distro (apt/dnf/zypper/AUR); Homebrew on macOS |
| `install-noteshub` | NotesHub | GitHub release `.deb`/`.rpm` via package manager |
| `install-nvm` | Node Version Manager | Official `install.sh` (version auto-detected), then installs the current LTS |
| `install-starship` | Starship prompt | Official install script / Homebrew |
| `install-tflint` | TFLint (Terraform linter) | GitHub release tarball → `~/.local/bin` |
| `install-terraform` | Terraform CLI | Vendor repo per distro / Homebrew |
| `install-tenv` | tenv (Terraform/OpenTofu version manager) | GitHub release tarball → `~/.local/bin` |
| `install-tofu` | tofu CLI | GitHub release tarball → `~/.local/bin` |
| `install-trivy` | Trivy scanner | Vendor repo per distro / Homebrew |

GPG key backup/restore and signing-key publishing build on the password manager
and git provider CLIs above — see [gpg.md](gpg.md) for the `gpg-*-bitwarden`,
`gpg-*-1password`, `gpg-push-github`, and `gpg-push-gitlab` functions. Update
orchestration for all of the above is covered in [tool-management.md](tool-management.md).

## GitHub CLI — `install-gh`

Uses GitHub's official package repository for the detected distro family:

- **rhel** (Fedora, RHEL, Rocky, Alma): adds `gh-cli.repo`. DNF5 (Fedora 41+) and
  DNF4 use different `config-manager` syntax; the function detects which is present
  (`dnf5-plugins` + `config-manager addrepo` on DNF5, `dnf-command(config-manager)`
  + `config-manager --add-repo` on DNF4) and uses `yum-config-manager` on yum-only
  hosts.
- **debian** (Ubuntu, Debian, Mint): installs the keyring to
  `/etc/apt/keyrings/githubcli-archive-keyring.gpg` and adds the signed
  `github-cli.list` source.
- **suse** (openSUSE, SLES): adds `gh-cli.repo` (skipped if already present) and
  refreshes with `--gpg-auto-import-keys`.
- **arch** (Arch, Manjaro): installs the official `github-cli` package via pacman.
- **macOS**: Homebrew.

If the distro is unknown, or a package-repo path fails, it falls back to the
distro-independent binary: the latest release tarball from `cli/cli` is downloaded,
and the `gh` binary is placed in `~/.local/bin`.

Authenticate after install with `gh auth login`.

## GitLab CLI — `install-glab`

- **rhel** (Fedora, RHEL, Rocky, Alma): `glab` is in the official Fedora/RHEL repos — `dnf install glab`. No extra repo setup needed.
- **arch** (Arch, Manjaro): `extra/glab` via pacman.
- **debian** / **suse**: no official vendor apt/zypper repo exists — falls back to the latest release tarball from the GitLab releases API (`~/.local/bin`).
- **macOS**: Homebrew (`brew install glab`) — the officially supported Linux/macOS method per upstream docs.

Authenticate after install with `glab auth login`.

## 1Password Desktop — `install-1password`

Sets up the official 1Password apt/dnf/zypper repository and installs from there, so updates arrive via the package manager. Uses the same GPG key (`3FEF9748469ADBE15DA7CA80AC2D62742012EA22`) across all distros.

- **rhel**: imports the key, writes `/etc/yum.repos.d/1password.repo`, installs `1password`.
- **debian**: adds the keyring to `/usr/share/keyrings/`, adds the signed apt source, adds the debsig-verify policy, installs `1password`.
- **suse**: imports the key, adds the RPM repo, installs `1password`.
- **arch**: imports the signing key and builds from the official AUR package (via yay if available, otherwise manual `makepkg`).
- **macOS**: Homebrew cask.
- **unknown distro**: Flatpak from Flathub (`com.onepassword.OnePassword`) with a warning that SSH agent and system auth integration are unavailable.

After install, open 1Password → Settings → Developer → **Integrate with 1Password CLI** to enable biometric unlock for `op`.

## 1Password CLI — `install-op-cli`

Installs the `op` command (1Password CLI v2) via vendor repos — the same repos as `install-1password`, so if you've already run that the repo is already in place.

- **rhel** / **debian** / **suse**: repo install of the `1password-cli` package; sets the `onepassword-cli` group and setgid bit automatically, which is needed for biometric unlock via the desktop app.
- **arch**: no vendor package — binary fallback to `~/.local/bin` with a warning that biometric unlock won't work without the group/setgid setup.
- **macOS**: `brew install --cask 1password-cli`.

Authenticate after install: open 1Password → Settings → Developer → enable integration, then run `op signin`.

## Node Version Manager — `install-nvm`

The install URL embeds a version that changes over time, so the target version is
read from the `nvm-sh/nvm` latest release at runtime (falling back to a pinned
version if the GitHub API is unreachable or rate-limited). The official `install.sh`
is then run — this also updates an existing nvm install.

After install, nvm is sourced into the current shell (replacing the lazy stubs from
`env/20-development.sh`). If no nvm-managed Node is in use, the current LTS is
installed, selected, and set as the `default` alias so new shells have Node
available without a manual `nvm use`.

If a **manually installed** system Node.js is detected on `PATH`
(e.g. `/usr/bin/node`), the function warns and — interactively — offers to remove
the distro `nodejs`/`npm` packages so nvm is the sole Node manager. Declining keeps
the system Node in place; nvm installs alongside it and its shims take precedence
when active. In a non-interactive shell the system Node is left untouched.

## GitHub Copilot CLI — `install-copilot-cli`

Installs the npm package `@github/copilot` (the `@github/copilot-cli` and
`@githubnext/*` names are deprecated). Requires **Node.js 22+**; if npm is missing
it is provisioned via nvm or the package manager (see [Node prerequisite](#node-prerequisite-shared) below),
and the function refuses with guidance if the active Node is older than 22.

Launch `copilot` to authenticate with your GitHub account. Requires an active
GitHub Copilot subscription.

## Claude Code — `install-claude-code`

Prefers the **native installer** (`curl -fsSL https://claude.ai/install.sh | bash`),
which Anthropic recommends: it has no Node.js dependency, installs `claude` to
`~/.local/bin`, and self-updates. If the native installer is unavailable or fails,
the function falls back to the npm package `@anthropic-ai/claude-code` (requires
Node.js 18+).

Launch `claude` to authenticate (opens a browser on first run). Requires a Claude
Pro/Max plan or an Anthropic Console (API) account.

## Node prerequisite (shared)

`install-copilot-cli`, `install-claude-code` (npm fallback), and `install-bw-cli`
all rely on a working npm. The shared helper `_ensure_npm` resolves npm in priority
order: an already-available npm → an nvm stub it can activate → a present-but-unsourced
nvm (installing LTS if needed) → a package-manager Node install. If you have no Node
at all, run `install-nvm` first for the cleanest setup.

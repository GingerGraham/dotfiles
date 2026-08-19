# Installation

## Table of Contents

- [Bootstrap (recommended)](#bootstrap-recommended)
  - [Dev mode](#dev-mode)
  - [Passing options through bootstrap](#passing-options-through-bootstrap)
- [Running install.sh directly](#running-installsh-directly)
  - [First-run prompts](#first-run-prompts)
  - [Subsequent runs](#subsequent-runs)
- [After installation: updating tools](#after-installation-updating-tools)
  - [Update installed tools](#update-installed-tools)
  - [Install a new tool](#install-a-new-tool)
- [CLI reference](#cli-reference)
  - [Examples](#examples)
- [SSH deploy keys](#ssh-deploy-keys)
- [host_vars reference](#host_vars-reference)

## Bootstrap (recommended)

The fastest path to a working setup is the one-liner bootstrap.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh)
```

> **Forking this repo?** Replace the URL above with your own fork's raw bootstrap URL, and update `REPO_OWNER`/`REPO_NAME` at the top of `bootstrap.sh` and `dotfiles_release_repo_url` in `ansible/group_vars/all.yml` to match.

By default this fetches a tarball snapshot of `main` to `~/.local/share/dotfiles/` — **no `git clone`, no `.git` anywhere** — and hands off to `install.sh`. This is **release mode**: no `git` required to get started, and nothing entangled with your own project tree. See [docs/sync.md#install-modes](sync.md#install-modes) for the full comparison with dev mode below.

The fetch-and-flip is atomic (an old release stays in place until the new one is fully extracted), so re-running the one-liner is always safe. Only `curl` and `tar` are required for this path — `install.sh` still checks for `git`/`python3`/`ansible-core` afterwards, since Ansible itself needs `git` (to fetch `bash-logger`) regardless of install mode.

On first run you will be prompted for everything `install.sh` prompts for interactively — profile, machine name, git identity, your own projects base directory, and so on (see [First-run prompts](#first-run-prompts) below).

### Dev mode

Actively developing this repo? Add `--dev` for the original clone-and-symlink workflow — a real `git` checkout you can switch branches on with `dotfiles-branch`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh) --dev
```

You'll be prompted for a projects base directory (default: `~/Projects`); the repo is cloned to `<base>/Personal/GitHub/dotfiles`. If it already exists there, `bootstrap.sh` runs `git pull --ff-only` before handing off to `install.sh`, so re-running is safe here too. `--projects-base` can be passed explicitly to skip the prompt — it only takes effect together with `--dev`.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh) \
  --dev --projects-base ~/Code
```

### Passing options through bootstrap

`bootstrap.sh` only handles `--dev` and `--projects-base` itself (and only uses `--projects-base` for the clone location when `--dev` is also given — otherwise it's forwarded straight through to `install.sh` for your own project tree). Every other flag is passed straight through to `install.sh`, so you can suppress interactive prompts from the one-liner:

```bash
# Fully non-interactive workstation install (release mode)
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh) \
  --projects-base ~/Code \
  --profile workstation \
  --machine-name my-laptop

# Same, but dev mode — --projects-base also picks the clone location here
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh) \
  --dev --projects-base ~/Code \
  --profile workstation \
  --machine-name my-laptop

# Server install
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh) \
  --profile server \
  --playbook server

# Minimal install, skip SSH key generation
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh) \
  --profile minimal \
  --skip-ssh
```

## Running install.sh directly

If you already have a dotfiles tree on disk — a dev-mode clone, or a release-mode checkout at `~/.local/share/dotfiles/current` — run `install.sh` from its root:

```bash
./install.sh [OPTIONS]
```

### First-run prompts

On a machine where this mode's config doesn't exist yet, `install.sh` first checks for a config from a *previous install in the other mode* at its conventional location (dev: `~/Projects/Personal/GitHub/dotfiles/ansible/host_vars/localhost.yml`; release: `~/.config/dotfiles/host_vars/localhost.yml`) — e.g. if you switch from `--dev` to the default release mode, or vice versa, on the same machine. If found, you're offered a chance to reuse it (`[Y/n]`, defaults to yes) instead of re-entering everything. Only the default projects-base convention is checked — a dev install under a custom `--projects-base` you don't also pass this run won't be discovered.

Otherwise, `install.sh` prompts interactively to build a fresh config:

1. **Profile** — workstation / server / minimal (see [Profiles](profiles.md))
2. **Machine name** — defaults to `hostname -s`
3. **Projects base directory** — root of your project tree
4. **Git global identity** — name, default email, optional GPG signing key
5. **Git project contexts** — one or more context/provider/email tuples (e.g. Personal/GitHub, Personal/GitLab, Acme/AzureDevOps); press Enter to finish; add more later with `git-add-project`
6. **External add-on repos** — any number of repos synced/deployed by `sync-external` (e.g. `nvim-config`, `ai-config`); for each, a name, repo URL, an explicit public/private choice, and whether to allow that repo's post-deploy hooks (default no) — workstation and server profiles only. There is no clone-directory prompt: the clone location is engine-computed, and where a repo's content is deployed comes from its own manifest. See [External sync](external-sync.md).

`host_vars/localhost.yml` is **never overwritten** by subsequent Ansible runs. In dev mode it's a gitignored real file in the clone; in release mode it's stored at `~/.config/dotfiles/host_vars/localhost.yml` (outside every release directory, since each sync replaces the release directory wholesale) and symlinked into place so `ansible/host_vars/localhost.yml` still resolves normally — see [docs/sync.md#install-modes](sync.md#install-modes). Re-running `install.sh` after it exists goes straight to Ansible.

### Subsequent runs

Once `host_vars/localhost.yml` exists, `install.sh` skips all prompts and runs Ansible directly:

```bash
./install.sh
# or with a dry-run first:
./install.sh --check && ./install.sh
```

## After installation: updating tools

After install.sh completes, you have access to 20+ managed development tools.

### Update installed tools

```bash
# Update everything
update-tools

# Update specific tools
update-tools terraform aws kubectl

# List what's installed
update-tools --list
```

### Install a new tool

If you skipped some tools during initial setup, install them later:

```bash
# Install or update a single tool
install-helm
install-ansible
install-kubectl

# Install the CLI for your git provider or password manager
install-gh      # GitHub CLI
install-glab    # GitLab CLI
install-bw-cli  # Bitwarden CLI
install-op-cli  # 1Password CLI
```

See [docs/tool-management.md](tool-management.md) for the complete tool list, troubleshooting, and how to add custom tools, and [docs/installers.md](installers.md) for a per-tool installer reference.

## CLI reference

| Flag | Description |
| --- | --- |
| `--profile <workstation\|server\|minimal>` | Skip profile prompt and use the given value |
| `--machine-name <name>` | Skip machine name prompt |
| `--playbook <site\|server>` | Ansible playbook to run (default: `site`). Use `server` with `--profile server` for server deployments |
| `--projects-base <path>` | Skip projects base prompt (root of your own project tree; also the dotfiles clone location in dev mode). Tilde expansion handled (`~/Projects` is valid). Forwarded automatically by `bootstrap.sh` when given |
| `--skip-roles <role[,role,...]>` | Skip one or more roles. `common` cannot be skipped |
| `--only-roles <role[,role,...]>` | Run only the named roles. `common` is always prepended |
| `--check` | Ansible dry-run (`--check --diff`) — previews changes without applying |
| `--skip-ssh` | Skip SSH deploy key generation. Use when your personal SSH key already has access to all required repos |
| `--no-prereqs` | Skip prerequisite check and installation |
| `--ask-become-pass`, `-K` | Prompt for sudo password before running Ansible. Required on first run if packages need installing |
| `-h`, `--help` | Show usage |

### Examples

```bash
# Interactive first run
./install.sh

# Dry run — see what would change before applying
./install.sh --check

# Skip prompts for known values
./install.sh --profile workstation --machine-name my-laptop

# Server deployment
./install.sh --profile server --playbook server

# Re-run Ansible only (no prereq check, no SSH key work)
./install.sh --no-prereqs --skip-ssh

# Run only the shell and git roles (common is always included)
./install.sh --only-roles shell,git

# Skip the external add-on repo sync engine on this machine
./install.sh --skip-roles sync-external
```

## SSH deploy keys

The `dotfiles` repo itself is public — no deploy key is needed for it. The background sync uses HTTPS.

Deploy keys are generated for **external add-on repos registered as private only**, one per repo, regardless of which provider hosts it:

```text
~/.ssh/dotfiles-<name>
```

SSH host aliases are written to `~/.ssh/config.d/10-dotfiles.conf`, one `Host dotfiles-<name>` block per private repo, with `HostName` set to that repo's actual host — extracted from the `repo_url` you gave (GitHub, GitLab, self-hosted, etc.), not assumed. The `sync-external` Ansible role rewrites each private repo's URL to its alias form automatically — you never need to hand-edit `host_vars` with the alias URL yourself.

After `install.sh` generates the keys, add each public key as a read-only deploy key in the corresponding repository (Settings → Deploy keys → Add deploy key; write access: **no**). This applies regardless of which provider hosts the repo — GitHub, GitLab, and most other providers expose an equivalent deploy key setting.

If no repo is registered as private, the SSH phase is skipped entirely. Pass `--skip-ssh` to bypass it explicitly when your personal key already has access. See [External sync](external-sync.md) for the full walkthrough.

## host_vars reference

`ansible/host_vars/localhost.yml` is the machine-local variable file created by `install.sh`. An annotated example lives at `ansible/host_vars/localhost.yml.example`.

Key variables:

| Variable | Purpose |
| --- | --- |
| `dotfiles_profile` | Controls which roles run (`workstation` / `server` / `minimal`) |
| `machine_name` | Friendly name used in git config and prompt |
| `dotfiles_install_mode` | `dev` or `release` — a human-readable record only, self-detected and written once by `install.sh`; nothing reads it back to make decisions. See [docs/sync.md#install-modes](sync.md#install-modes) |
| `external_synced_repos` | List of external add-on repos for `sync-external` to clone/adopt and deploy — see [External sync](external-sync.md) |
| `dotfiles_sync_enabled` | Disable both the dotfiles self-sync and `sync-external` |
| `dotfiles_extra_roles` | List of additional role names to run on this machine |
| `git_name` | Git global user name |
| `git_default_email` | Git global default email |
| `git_default_signing_key` | Optional GPG key fingerprint for global commit signing |
| `git_projects` | List of context/provider identity definitions, optionally with per-context gh/glab CLI authentication (`cli`/`cli_host`) — see [the git role README](../ansible/roles/git/README.md#cli-context) |
| `projects_base` | Root of your project directory tree |

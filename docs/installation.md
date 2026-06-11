# Installation

## Bootstrap (recommended)

The fastest path to a working setup is the one-liner bootstrap. It clones the repo to a sensible location under your projects directory and then runs `install.sh` automatically.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh)
```

> **Forking this repo?** Replace the URL above with your own fork's raw bootstrap URL.

On first run you will be prompted for:

- A projects base directory (default: `~/Projects`). The repo will be cloned to `<base>/Personal/GitHub/dotfiles`.
- Everything that `install.sh` prompts for interactively — profile, machine name, git identity, and so on (see [First-run prompts](#first-run-prompts) below).

If the repo already exists at the target path, `bootstrap.sh` runs `git pull --ff-only` before handing off to `install.sh`, so re-running the one-liner is safe.

### Passing options through bootstrap

`bootstrap.sh` only handles `--projects-base` itself. All other flags are passed straight through to `install.sh`, so you can suppress interactive prompts from the one-liner:

```bash
# Fully non-interactive workstation install
bash <(curl -fsSL https://raw.githubusercontent.com/GingerGraham/dotfiles/main/bootstrap.sh) \
  --projects-base ~/Code \
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

---

## Running install.sh directly

If you have already cloned the repo, run `install.sh` from the repo root:

```bash
./install.sh [OPTIONS]
```

### First-run prompts

On a machine where `ansible/host_vars/localhost.yml` does not yet exist, `install.sh` prompts interactively to build it:

1. **Profile** — workstation / server / minimal (see [Profiles](profiles.md))
2. **Machine name** — defaults to `hostname -s`
3. **Projects base directory** — root of your project tree
4. **Git global identity** — name, default email, optional GPG signing key
5. **Git project contexts** — one or more context/provider/email tuples (e.g. Personal/GitHub, Acme/AzureDevOps); press Enter to finish; add more later with `git-add-project`
6. **nvim role** — whether to enable it and the SSH URL for your `nvim-config` repo (workstation profile only)
7. **ai-tools role** — whether to enable it and the SSH URL for your `ai-config` repo (workstation profile only)

`host_vars/localhost.yml` is gitignored and **never overwritten** by subsequent Ansible runs. Re-running `install.sh` after it exists goes straight to Ansible.

### Subsequent runs

Once `host_vars/localhost.yml` exists, `install.sh` skips all prompts and runs Ansible directly:

```bash
./install.sh
# or with a dry-run first:
./install.sh --check && ./install.sh
```

---

## After installation: updating tools

After install.sh completes, you have access to 20+ managed development tools.

### Update installed tools

```bash

# Update everything

update-tools

# Update specific tools

update-tools terraform aws kubernetes

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
```

See [docs/tool-management.md](docs/tool-management.md) for the complete tool list, troubleshooting, and how to add custom tools.

---

## CLI reference

| Flag                                       | Description                                                                                                        |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `--profile <workstation\|server\|minimal>` | Skip profile prompt and use the given value                                                                        |
| `--machine-name <name>`                    | Skip machine name prompt                                                                                           |
| `--playbook <site\|server>`                | Ansible playbook to run (default: `site`). Use `server` with `--profile server` for server deployments             |
| `--projects-base <path>`                   | Skip projects base prompt. Tilde expansion handled (`~/Projects` is valid). Passed automatically by `bootstrap.sh` |
| `--skip-roles <role[,role,...]>`           | Skip one or more roles; also suppresses related prompts. `common` cannot be skipped                                |
| `--only-roles <role[,role,...]>`           | Run only the named roles. `common` is always prepended                                                             |
| `--check`                                  | Ansible dry-run (`--check --diff`) — previews changes without applying                                             |
| `--skip-ssh`                               | Skip SSH deploy key generation. Use when your personal SSH key already has access to all required repos            |
| `--no-prereqs`                             | Skip prerequisite check and installation                                                                           |
| `--ask-become-pass`, `-K`                  | Prompt for sudo password before running Ansible. Required on first run if packages need installing                 |
| `-h`, `--help`                             | Show usage                                                                                                         |

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

# Skip ai-tools on this machine
./install.sh --skip-roles ai-tools
```

---

## SSH deploy keys

The `dotfiles` repo itself is public — no deploy key is needed for it. The background sync uses HTTPS.

Deploy keys are generated for **private companion repos only**:

| Key                    | Repo        |
| ---------------------- | ----------- |
| `~/.ssh/dotfiles_nvim` | nvim-config |
| `~/.ssh/dotfiles_ai`   | ai-config   |

SSH host aliases are written to `~/.ssh/config.d/10-dotfiles.conf`. Use these aliases in your `host_vars` repo URLs:

```
git@github-dotfiles-nvim:you/nvim-config.git
git@github-dotfiles-ai:you/ai-config.git
```

After `install.sh` generates the keys, add each public key as a read-only deploy key in the corresponding repository (Settings → Deploy keys → Add deploy key; write access: **no**).

If neither companion repo URL is provided, the SSH phase is skipped entirely. Pass `--skip-ssh` to bypass it explicitly when your personal key already has access.

---

## host_vars reference

`ansible/host_vars/localhost.yml` is the machine-local variable file created by `install.sh`. An annotated example lives at `ansible/host_vars/localhost.yml.example`.

Key variables:

| Variable                    | Purpose                                                                 |
| --------------------------- | ----------------------------------------------------------------------- |
| `dotfiles_profile`          | Controls which roles run (`workstation` / `server` / `minimal`)         |
| `machine_name`              | Friendly name used in git config and prompt                             |
| `nvim_config_repo_url`      | SSH URL for nvim-config repo (leave empty to skip)                      |
| `ai_config_repo_url`        | SSH URL for ai-config repo (leave empty to skip)                        |
| `dotfiles_nvim_enabled`     | Fine-grained override: disable nvim role within workstation profile     |
| `dotfiles_ai_tools_enabled` | Fine-grained override: disable ai-tools role within workstation profile |
| `dotfiles_sync_enabled`     | Disable background sync timer                                           |
| `dotfiles_extra_roles`      | List of additional role names to run on this machine                    |
| `git_name`                  | Git global user name                                                    |
| `git_default_email`         | Git global default email                                                |
| `git_default_signing_key`   | Optional GPG key fingerprint for global commit signing                  |
| `projects_base`             | Root of your project directory tree                                     |

# Tool Management — update-tools & Installation

The dotfiles shell config automates discovery, installation, and updates for 20+ development tools across all platforms. Tools are orchestrated through a registry-based system that lives in the lazy-loaded `maintenance.sh` module.

## Quick reference

```bash
update-tools               # Update all installed managed tools
update-tools terraform     # Update only a specific tool
update-tools nvm kubectl   # Update multiple specific tools
update-tools --list        # Show all managed tools and install status
```

## Managed tools

The registry currently includes:

| Tool | Detection | Install | Use case |
|------|-----------|---------|----------|
| **tenv** | `command -v` | `install-tenv` | Manages terraform/tofu versions |
| **terraform** | `command -v` | via tenv or `install-tenv` | Infrastructure as code |
| **tofu** | `command -v` | via tenv or `install-tenv` | OpenTofu variant |
| **cosign** | `command -v` | `install-cosign` | Container signing |
| **aws** | `command -v` | `aws-update` | AWS CLI |
| **az** | `command -v` | `az-update` | Azure CLI |
| **kubectl** | `command -v` | `set-kubectl` | Kubernetes client |
| **helm** | `command -v` | `install-helm` | Kubernetes package manager |
| **tflint** | `command -v` | `install-tflint` | Terraform linter |
| **trivy** | `command -v` | `install-trivy` | Container vulnerability scanner |
| **ansible** | `command -v` | `install-ansible` | Configuration management |
| **gh** | `command -v` | `install-gh` | GitHub CLI |
| **nvm** | `command -v` | `install-nvm` | Node version manager |
| **oh-my-posh** | `command -v` | `install-oh-my-posh` | Prompt engine |
| **oh-my-zsh** | `path:~/.oh-my-zsh` | `install-oh-my-zsh` | Zsh framework |
| **edit** | `command -v` | `install-edit` | Microsoft Edit |
| **claude** | `command -v` | `install-claude-code` | Claude Code CLI |
| **copilot** | `command -v` | `install-copilot-cli` | GitHub Copilot CLI |
| **bw** | `command -v` | `install-bw-cli` | Bitwarden CLI |
| **bitwarden** | `command -v` | `install-bitwarden` | Bitwarden Desktop |
| **noteshub** | `command -v` | `install-noteshub` | NotesHub |

## How update-tools works

### Detection

Each tool has a **detection token**:

- **`command -v`** — tool is in `$PATH`
  ```bash
  kubectl | aws | helm | gh | nvm | ...
  ```
- **`path:<file>`** — tool is at a specific filesystem location (not PATH)
  ```bash
  path:~/.oh-my-zsh    # oh-my-zsh is always in ~/.oh-my-zsh
  ```

Detection runs during `--list` and before every update attempt. If a tool is not detected, `update-tools` reports it as "not installed" and suggests the install command.

### Orchestration

When you run `update-tools`:

1. **Load the registry** — reads `_managed_tools_registry()` from `lazy/maintenance.sh`
2. **Filter by name** — if you name specific tools, only those rows are processed; otherwise all are
3. **Detect each tool** — checks if it's actually installed
4. **Run the updater** — calls the updater function defined in the registry
5. **Record outcomes** — collects results into `done_ok`, `failed`, `not_installed`, `unknown` arrays
6. **Print summary** — shows what succeeded, what failed, and what's not installed

Example output:

```
== update-tools: refreshing managed tools ==
[INFO]  -- Terraform --
[INFO]  tenv: installing latest tf ...
[INFO]  -- AWS CLI --
[INFO]  aws-cli: your version is up to date
[INFO]  -- Kubernetes --
[INFO]  set-kubectl -s: kubectl v1.31.0 → latest
[INFO]  -- oh-my-zsh is not installed — install it with: install-oh-my-zsh

== update-tools summary ==
[INFO]  updated       : terraform aws kubectl
[INFO]  not installed : oh-my-zsh
```

## How installers work

Every managed tool has an **installer command** defined in the registry. Installers are lazy-loaded functions from `shell/config/lazy/installers.sh`:

```bash
install-tenv          # Installs or updates tenv (manages terraform/tofu)
install-helm          # Installs or updates Helm
install-ansible       # Installs or updates Ansible
...
```

Calling an installer directly:
- **First time** — downloads and installs the tool
- **Subsequent runs** — updates to the latest version
- **Runs standalone** — no connection to `update-tools` required

Installers are safe to call even if the tool is already installed. They use version detection to skip redundant downloads.

### Built-in installers

All `install-*` commands are discoverable:

```bash
installers             # Lists all available install-* commands (same as get-my-installers)
```

## Updater functions

Each tool's updater is a private function in `lazy/maintenance.sh`, usually named `_update_<tool>()`:

```bash
_update_aws()        # Calls aws-update from tools/aws.sh
_update_terraform()  # Calls install-terraform (proxied via tenv if tenv is present)
_update_omp()        # Updates oh-my-posh
_update_omz()        # Updates oh-my-zsh via its upgrade.sh
```

Some updater functions are simple wrappers (call `install-<tool>` directly). Others are smart and handle special cases:

- **tenv-managed tools** (`terraform`, `tofu`) — if tenv is installed, the updater defers to `_update_tenv_managed()` to avoid duplicate version managers
- **Custom paths** (`oh-my-zsh`) — uses the tool's built-in upgrade mechanism instead of a re-download

### Writing a custom updater

If you add a new tool to the registry, define an updater in `lazy/maintenance.sh`:

```bash
_update_mytool() {
    _update_ensure_fn mytool-update tools/mytool.sh || { 
        log_warn "mytool-update not available"; 
        return 1
    }
    mytool-update
}
```

The `_update_ensure_fn` helper sources the tool file only if the function isn't already loaded, avoiding redundant sourcing.

## The installer ↔ updater contract

**Rule:** Every installer function added to `lazy/installers.sh` must be reachable from `update-tools` — either directly or via the registry.

When you add an `install-<tool>` function:

1. **Add a row to the registry** in `_managed_tools_registry()`:
   ```bash
   mytool|command -v mytool|_update_mytool|install-mytool|My Tool
   ```

   OR

2. **Add to the allowlist** in `tests/check-updater-coverage.sh` with a one-line justification:
   ```bash
   install-mytool-pinned        # Pinned version variant; manual updates only
   ```

**Enforcement:** `bash tests/check-updater-coverage.sh` runs on every PR and verifies:
- Every updater/installer named in the registry actually exists as a defined function
- Every installer has a corresponding updater (or explicit allowlist entry with justification)
- No typos or renamed functions slip through

Failing the test blocks the PR.

## Usage patterns

### Update everything

```bash
update-tools
```

Runs all updaters for tools that are installed. Tools that aren't installed are reported with their install command.

### Update a subset

```bash
update-tools terraform aws kubectl
```

Only runs updaters for the named tools. Unknown names are reported.

### See what's installed

```bash
update-tools --list
```

Shows a table:
```
TOOL          INSTALLED  DESCRIPTION
tenv          yes        tenv (Terraform/OpenTofu)
terraform     yes        Terraform
aws           yes        AWS CLI
gh            -          GitHub CLI
```

### Install a single tool

```bash
install-kubectl
# or
set-kubectl
```

Installs or updates kubectl standalone. Use this when you don't have the tool yet and don't want to run the full `update-tools`.

### Check what installers are available

```bash
get-my-installers
# or
installers
```

Lists all `install-*` and `set-*` commands from `lazy/installers.sh`.

## Troubleshooting

### Tool shows as "not installed" but it is

Check the detection token in the registry. If the tool uses `command -v`, ensure it's in `$PATH`:

```bash
# Verify kubectl is in PATH
which kubectl
echo $PATH
```

If using `path:<file>` detection (like oh-my-zsh), ensure the file exists:

```bash
ls -la ~/.oh-my-zsh
```

### Updater failed

Some updaters check for prerequisites. Review the error message for what's missing. Common cases:

- **AWS CLI**: requires `curl`, `python3`, sometimes `pip`
- **Kubernetes**: requires `curl`
- **tenv**: requires `unzip` or `tar` (platform-dependent)

### "Unknown tool" error

Run `update-tools --list` to see the exact names of managed tools. Tool names are case-sensitive and must match exactly.

### Installer hung or asks for interactive input

Some installers (especially Node/nvm) can require interaction. If an installer is stuck, press `Ctrl+C` and retry with the `--no-prompt` variant if one exists, or check the installer code in `lazy/installers.sh`.

## Advanced: how lazy installers load

When you call `install-terraform` for the first time, it's actually a stub in `loader.sh`:

```bash
install-terraform() {
    unset -f install-terraform        # Remove the stub
    source ~/.config/shell/lazy/installers.sh
    install-terraform "$@"            # Call the real function
}
```

The first call sources the file and replaces the stub with the real function. Subsequent calls skip the sourcing.

This makes shell startup fast — all ~25 installer functions are lazy-loaded on demand, not eagerly.

## See also

- [shell-config.md](shell-config.md) — Shell architecture and lazy loading
- [installation.md](installation.md) — Initial bootstrap and first-run setup
- `lazy/maintenance.sh` — Complete updater/registry implementation
- `lazy/installers.sh` — All installer function implementations

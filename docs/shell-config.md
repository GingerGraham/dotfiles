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
    - [Plain shell](#plain-shell)
    - [Pretty shell](#pretty-shell)
  - [Exported variables](#exported-variables)
  - [Machine-local overrides](#machine-local-overrides)
  - [Shell introspection](#shell-introspection)
    - [Adding a new getter](#adding-a-new-getter)
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
12. Elect a prompt engine (oh-my-posh → starship → oh-my-zsh → distro-native → fallback PS1) — bypassed entirely in [plain shell mode](#plain-shell)
13. Register lazy stubs for `lazy/`
14. Source `~/.config/dotfiles/local/90-local.sh` last — machine-local overrides win
15. Source [user extension](user-extensions.md) files from `DOTFILES_USER_EXT_DIR` — after `90-local.sh` (so user definitions shadow it), before PATH dedupe (so PATH entries they add still get deduped)

Detection runs exactly once per session. Results are exported as `DOTFILES_*` variables; no repeated `uname` or `/etc/os-release` reads.

## Three loading tiers

### Tier 1 — Eager, always

`env/` and `core/` load unconditionally on every shell start. Files here must be fast — no subprocesses, no network calls.

| File                    | Purpose                                                                                                                                                                                                                                                      |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `env/00-core.sh`        | XDG paths, base PATH extensions, locale, history                                                                                                                                                                                                             |
| `env/10-editors.sh`     | `EDITOR`, `VISUAL`, pager                                                                                                                                                                                                                                    |
| `env/20-development.sh` | `GOPATH`, `PYENV_ROOT`, language version manager hooks — including the uv/pyenv gate (`DOTFILES_PYTHON_MANAGER`): uv wins by default when present, and pyenv's shims are skipped (though `pyenv` itself stays on PATH) so the two don't compete for `python` |
| `core/aliases.sh`       | Navigation aliases (`ls`, `cd`, common shortcuts)                                                                                                                                                                                                            |
| `core/functions.sh`     | Shell introspection (`get-fuctions`, `dedupe-path`)                                                                                                                                                                                                          |
| `core/ssh.sh`           | SSH agent helpers, `list-ssh-hosts`                                                                                                                                                                                                                          |

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

| File                   | Contents                                                                                                                                                                                                |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `installers.sh`        | `install-*` functions (gh, glab, nvm, copilot-cli, claude-code, bw-cli, op-cli, oh-my-posh, edit, …). See [installers.md](installers.md).                                                               |
| `installers-python.sh` | `install-uv`, `install-specify` — Python tooling group file, split out from the other installer groups in anticipation of more Python tools                                                             |
| `maintenance.sh`       | `update-tools` — orchestrated update of all managed tools                                                                                                                                               |
| `gpg-management.sh`    | Key creation, subkey management, expiry, rotation, export/import (Bitwarden, 1Password), and signing key publishing (GitHub, GitLab)                                                                    |
| `user-extensions.sh`   | `check-user-extensions` — full syntax/lint/collision pass over `DOTFILES_USER_EXT_DIR`. Registered only when that directory has at least one `*.sh` file. See [user-extensions.md](user-extensions.md). |

Use `get-installers` (alias: `installers`) to list all available lazy install commands.

## Prompt engine selection

`loader.sh` elects a prompt engine in priority order:

1. **oh-my-posh** — if `oh-my-posh` is in `$PATH`
2. **starship** — if `starship` is in `$PATH`, existing config at `~/.config/starship.toml` is detected, or the default config is successfully created at startup (write permissions in `~/.config/` required)
3. **oh-my-zsh** — if `~/.oh-my-zsh` exists and the shell is zsh
4. **distro-native** — if the distro file exports `_DOTFILES_DISTRO_PROMPT_FILE` pointing to a valid file (zsh only)
5. **Fallback PS1** — set unconditionally if none of the above match; detects terminal colour support and sets an appropriate `PS1`

### Plain shell

`plain-shell` (defined in `core/functions.sh`, always available) re-execs the
current shell with `DOTFILES_PLAIN_SHELL=true`. That flag makes `loader.sh`:

- `export NO_COLOR=1` early, in the "Behaviour flags" section — before any
  `tools/` file that reads `NO_COLOR` at init time;
- bypass the entire prompt-engine election chain above (including the
  fallback branch, so nothing from `/etc/bashrc`/`/etc/zshrc` leaks through)
  and set an explicit, colour-free prompt instead — `PS1='\u@\h:\w\$ '` under
  bash, `PROMPT='%n@%m:%~%# '` under zsh;
- set `DOTFILES_PROMPT_ENGINE="plain"`, so introspection stays honest about
  which branch actually ran.

Useful for capturing terminal output for pasting elsewhere (AI tooling,
issue reports, etc.) with no prompt escapes or SGR colour sequences to strip.
`exec` **replaces** the shell process rather than nesting a child — the plain
shell takes over the same PID, so there is no styled shell left underneath
it. Running `exit` ends the session entirely (closes the terminal, or drops
an SSH connection), exactly like `exit` in any top-level shell. To get back
to a styled shell, open a new terminal/session rather than expecting `exit`
to pop back to one.

Under **zsh**, plain mode skips the oh-my-zsh branch entirely — not just a
different prompt, but no omz plugins and no omz completion bindings either,
since that whole branch of the election chain never runs.

You don't need the function to test this: `DOTFILES_PLAIN_SHELL=true zsh -i`
(or `bash -i`) works directly, which is useful when debugging whether a
problem is prompt-engine related versus something else in the config.

`--color=auto`-style aliases in `core/aliases.sh` are deliberately left
alone — plain mode's blast radius is `NO_COLOR` and the prompt only.

### Pretty shell

`pretty-shell` (defined in `core/functions.sh`, always available) is the
counterpart to `plain-shell` — it re-execs the current shell with the two
variables `plain-shell` exports cleared, so `loader.sh` runs its normal
prompt-engine election chain again:

- `DOTFILES_PLAIN_SHELL` is explicitly set to `false` (not merely unset),
  keeping introspection consistent with how `DOTFILES_WSL` and
  `DOTFILES_USER_EXT_ENABLED` report state — a deliberate `false` rather than
  an absent variable;
- `NO_COLOR` is stripped from the child process's environment entirely via
  `env -u NO_COLOR`, rather than restored to some prior value.

Both variables are `export`ed by `plain-shell`, so without this, a bare
`exec zsh -i` or `exec bash -i` from inside a plain shell inherits them —
`loader.sh` sees `DOTFILES_PLAIN_SHELL=true` and stays in plain mode. This is
why starting a subshell doesn't get you back to a styled prompt on its own.

If `NO_COLOR` is set permanently in `90-local.sh`, clearing it here
doesn't lose that preference — `90-local.sh` is sourced last in every
`loader.sh` run, plain or not, so a persistent setting re-applies itself
after the election chain runs.

Same `exec`-replace semantics as `plain-shell`: this takes over the current
PID rather than nesting a child, so calling it doesn't leave a plain-mode
process sitting underneath the styled one. Use it to toggle back out of
`plain-shell` without closing the terminal or dropping an SSH connection.

As with `plain-shell`, you don't need the function to test this directly:
`env -u NO_COLOR DOTFILES_PLAIN_SHELL=false zsh -i` (or `bash -i`) works on
its own.

## Exported variables

| Variable                    | Values                                             | Set by                          |
| --------------------------- | -------------------------------------------------- | ------------------------------- |
| `DOTFILES_OS`               | `Linux` / `Mac`                                    | `loader.sh`                     |
| `DOTFILES_WSL`              | `true` / `false`                                   | `loader.sh`                     |
| `DOTFILES_DISTRO`           | `rhel` / `debian` / `suse` / `arch` / `unknown`    | `loader.sh`                     |
| `DOTFILES_SHELL`            | `bash` / `zsh` / `sh`                              | `loader.sh`                     |
| `DOTFILES_SHOW_FUNCTIONS`   | `true` / `false` (default: `false`)                | `90-local.sh`                   |
| `SHELL_CONFIG_DIR`          | `~/.config/shell`                                  | `loader.sh`                     |
| `DOTFILES_REPO_DIR`         | path to repo/release checkout                      | `90-local.sh` (set by Ansible)  |
| `DOTFILES_USER_EXT_DIR`     | `${XDG_CONFIG_HOME}/dotfiles/user` (default)       | `loader.sh` / `90-local.sh`     |
| `DOTFILES_USER_EXT_ENABLED` | `true` / `false` (default: `true`)                 | `loader.sh` / `90-local.sh`     |
| `DOTFILES_PLAIN_SHELL`      | `true` / `false` (default: `false`)                | `plain-shell` (via `exec env`)  |
| `DOTFILES_PROMPT_ENGINE`    | `plain` / `distro-native` / …                      | `loader.sh`                     |
| `DOTFILES_PYTHON_MANAGER`   | `auto` / `uv` / `pyenv` / `both` (default: `auto`) | `90-local.sh`                   |

## Machine-local overrides

`~/.config/dotfiles/local/90-local.sh` is the place for anything specific to one machine:

- Additional PATH entries
- Proxy settings
- Credential exports
- Tool version pins

It lives outside `~/.config/shell` (a symlink into the dotfiles repo working tree) so it survives a release-mode symlink swap untouched — see [docs/sync.md#install-modes](sync.md#install-modes). It is created from a template on the first Ansible run and **never overwritten** by subsequent runs, and is not tracked by git (it's outside the repo entirely, not merely gitignored). Edit it directly on the machine.

Set `DOTFILES_SHOW_FUNCTIONS=true` here to print the function list automatically on every interactive shell start.

## Shell introspection

`get-functions` lists every loaded function and alias not already covered by a dedicated getter, then prints a Getters section pointing at the rest:

```bash
get-functions    # Lists uncurated functions/aliases, plus a menu of getters
get-installers   # alias: installers — lazy install-* commands
```

Available getters today:

| Getter                                 | Covers                                                 |
| -------------------------------------- | ------------------------------------------------------ |
| `get-gpg-functions`                    | `tools/gpg.sh` + `lazy/gpg-management.sh`              |
| `get-git-functions`                    | `tools/git.sh` — project management vs general helpers |
| `get-terraform-functions`              | `tools/terraform.sh` aliases and functions             |
| `get-installers` (alias: `installers`) | every `install-*` function                             |

### Adding a new getter

Two generic primitives in `core/functions.sh` do the extraction and printing; every getter is a thin wrapper around them:

- `_get_functions_in <label> <pattern> <file...>` — function names defined in the given file(s)
- `_get_aliases_in <label> <pattern> <file...>` — same, for aliases

`<pattern>` is an ERE applied to the extracted names: `""` shows everything, `'^foo-'` keeps only matches, `'!^foo-'` (leading `!`) drops matches instead. Private (`_`-prefixed) functions are always excluded automatically.

A minimal getter for a new `tools/<name>.sh` file:

```bash
get-<name>-functions() {
    local _config_dir="${SHELL_CONFIG_DIR:-${HOME}/.config/shell}"
    local _f="${_config_dir}/tools/<name>.sh"
    _get_aliases_in   "<Name> aliases (tools/<name>.sh)"   "" "${_f}"
    _get_functions_in "<Name> functions (tools/<name>.sh)" "" "${_f}"
}
```

Then register it in `_function_getters_registry()` so `get-functions` excludes its functions/aliases and lists it in the Getters section:

```text
<name>|file:tools/<name>.sh|get-<name>-functions|<Label shown in the Getters section>
```

Filter tokens:

- `file:<comma-separated paths relative to $SHELL_CONFIG_DIR>` — excludes by source file
- `prefix:<name prefix>` — excludes by name prefix instead (used for `installers`, since `install-*` functions live across multiple files rather than one)

No changes to `get-functions` itself are needed — that's the whole contract.

`get-functions` excludes functions prefixed with `_` (private helpers) and functions prefixed with `install-` (those are shown by `get-installers` instead).

## Migration from an existing shell config

If `~/.bashrc`, `~/.zshrc`, or `~/.zshenv` exists as a real file (not already a symlink) when `install.sh` runs, the shell role backs it up:

```text
~/.config/dotfiles/migration/<filename>.pre-dotfiles.bak
```

A warning is printed on every shell start until the backup directory is cleared:

```text
[WARN]  Migration pending: review backup files and merge any needed content
        into ~/.config/dotfiles/local/90-local.sh, then remove
        ~/.config/dotfiles/migration/ to clear this warning.
```

After porting any content you want to keep into `90-local.sh`:

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
installers   # Alias for get-installers
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
    ├── env/                 # 90-local.sh is NOT here — see below
    │   ├── 00-core.sh
    │   ├── 10-editors.sh
    │   └── 20-development.sh
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
    │   ├── installers-X.sh     # install-<tool> and set-<tool> commands
    |   |                       # Split into multiple files to avoid shell startup slowdown from parsing a single large file
    │   │                       # Manages 20+ tools: terraform, helm, aws, nvm, neovim, uv, etc.
    │   ├── installers-python.sh    # install-uv, install-specify — Python tooling group file
    │   ├── maintenance.sh      # update-tools orchestration, registry, and per-tool updaters
    │   │                       # Coordinates install-* commands and automatic updates
    │   ├── gpg-management.sh   # GPG key creation, rotation, export/import, signing key publishing
    │   └── user-extensions.sh  # check-user-extensions — full check of DOTFILES_USER_EXT_DIR
    └── completions/        # Same tool guards as tools/
        └── uv.sh               # version-stamped cache, generated locally — outside the DOTFILES_OFFLINE guard
```

User extension files themselves live outside this tree entirely — see
[user-extensions.md](user-extensions.md). `90-local.sh` also lives outside
this tree, at `~/.config/dotfiles/local/90-local.sh` — deliberately, so it
survives a release-mode symlink swap untouched (see
[docs/sync.md#install-modes](sync.md#install-modes)). Only its `.j2`
template is tracked in the repo, under
`ansible/roles/shell/templates/env/90-local.sh.j2`.

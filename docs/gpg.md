# GPG key management

GPG support spans two shell files:

- `shell/config/tools/gpg.sh` — Tier 2, loaded whenever `gpg` is in `$PATH`. Fast inspection and listing functions always available.
- `shell/config/lazy/gpg-management.sh` — Tier 3, lazy-loaded on first call. Interactive key lifecycle operations: creation, export, import, rotation, and backup.

These functions integrate with two password managers for key backup (**Bitwarden** and **1Password**) and two git providers for publishing your signing key (**GitHub** and **GitLab**). Use whichever combination matches your setup — function names follow the pattern `gpg-<action>-<service>`, so an equivalent exists for each supported service.

## Table of Contents

- [Key structure](#key-structure)
- [Prerequisites](#prerequisites)
- [Typical workflow: new machine setup](#typical-workflow-new-machine-setup)
- [Key lifecycle](#key-lifecycle)
  - [Adding UIDs (email aliases)](#adding-uids-email-aliases)
  - [Extending expiry](#extending-expiry)
  - [Rotating a subkey](#rotating-a-subkey)
  - [Restoring the master key temporarily](#restoring-the-master-key-temporarily)
  - [New machine from existing backup](#new-machine-from-existing-backup)
- [Publishing your signing key](#publishing-your-signing-key)
- [Agent management](#agent-management)
- [Function reference](#function-reference)
- [GPG_TTY](#gpg_tty)

## Key structure

The recommended structure created by `gpg-create-key` is a master key with separate subkeys for each capability:

```text
Master key  [C]    certify only — sign other keys and subkeys
  └─ Subkey [S]    sign — git commits, tags, files
  └─ Subkey [E]    encrypt — files and secrets
  └─ Subkey [A]    authenticate — SSH and API access (optional)
```

The master key is used only for certifying: creating subkeys, signing other people's keys, and extending expiry. Day-to-day operations use subkeys exclusively. This means:

- If a subkey is compromised, it can be revoked and replaced without losing your identity
- The master key can be exported and stored offline (Bitwarden, 1Password, encrypted USB) and then **removed from the local keyring** so it is never exposed during normal use
- Git commit signing uses the `[S]` subkey fingerprint, not the master key

When the master key is needed again (adding a subkey, extending expiry, certifying another key), import it from your backup, perform the operation, then remove it again.

## Prerequisites

`gpg` must be installed. On Fedora it is present by default; on Ubuntu/Debian install `gnupg2`. The `gpg.sh` tools file guards itself with `command -v gpg` and will not load if GPG is absent.

For backup and restore functions, install and authenticate **one or both** of the supported password manager CLIs. The function families work identically — pick whichever matches your vault.

### Bitwarden (`bw`)

```bash
install-bw-cli                          # install the headless CLI
bw login                                # first-time authentication
export BW_SESSION=$(bw unlock --raw)    # unlock and capture session token
```

`BW_SESSION` must be set in the current shell for any `gpg-*-bitwarden` function to work. It is not persisted across sessions by design — re-run the `export` line after each login.

### 1Password (`op`)

```bash
install-op-cli                          # 1Password CLI only
# or, for biometric unlock support:
install-1password                       # 1Password desktop app
op signin                                # authenticate (not needed if using
                                          # desktop app biometric integration)
```

`gpg-*-1password` functions accept an optional `--vault <name>` to target a specific vault; without it, `op`'s default vault is used.

### Backup naming convention

Both families store the same set of items — public key, secret key, subkeys-only, revocation certificate, and an optional passphrase — using the naming convention:

```text
<type> — [<qualifier>] <uid> (<fingerprint>)
```

`<qualifier>` defaults to the short hostname (`hostname -s`) so backups from different machines are distinct and never clobber each other. Override it with `--name <label>`.

## Typical workflow: new machine setup

### 1. Check for existing keys

```bash
gpg-list-signing-keys
```

If you have keys backed up already, import them instead of creating new ones:

```bash
# Bitwarden
export BW_SESSION=$(bw unlock --raw)
gpg-import-bitwarden          # search vault interactively

# 1Password
gpg-import-1password          # search vault interactively

gpg-trust <fingerprint>        # set ultimate trust on your own key
```

### 2. Create a new key set

If starting from scratch:

```bash
gpg-create-key
```

The wizard prompts for name, email, optional comment, master key expiry (default: no expiry), and subkey expiry (default: 2 years). It creates the master `[C]` key and `[S]`/`[E]` subkeys in one pass, then prints the recommended next steps with the specific commands for your new key's fingerprint.

### 3. Generate a revocation certificate

Do this immediately after key creation, before the key is used anywhere:

```bash
gpg-revoke <fingerprint>
```

The certificate is saved to `~/.gnupg/revocations/<fingerprint>-revocation.asc`. It is also stored as part of your backup in the next step. If your key is ever compromised, importing this certificate and uploading it to a keyserver revokes the key publicly.

### 4. Back up your keys

```bash
# Bitwarden
export BW_SESSION=$(bw unlock --raw)
gpg-export-bitwarden <fingerprint>

# 1Password
gpg-export-1password <fingerprint>
# target a specific vault:
gpg-export-1password <fingerprint> --vault "Secrets"
```

Each stores four items:

| Item name | Contents |
|---|---|
| `GPG Public Key — [<host>] <uid> (<fp>)` | Armoured public key |
| `GPG Secret Key — [<host>] <uid> (<fp>)` | Full secret key (master + subkeys) |
| `GPG Subkeys Only — [<host>] <uid> (<fp>)` | Subkeys only, no master key material |
| `GPG Revocation Certificate — [<host>] <uid> (<fp>)` | Revocation certificate |

If a passphrase is entered when prompted, it is also stored as a separate Login item: `GPG Key Passphrase — [<host>] <uid> (<fp>)`.

Re-running either export after a rotation updates the existing items rather than creating duplicates.

### 5. Remove the master key from local keyring

Once your keys are backed up, remove the master key's secret material from this machine:

```bash
gpg-remove-master <fingerprint>
```

The function verifies you've confirmed the backup, then removes only the primary secret key — subkeys remain intact. Afterwards the key shows as `sec#` in `gpg --list-secret-keys`, meaning the public key and subkeys are present but the master secret is offline.

Your subkeys are sufficient for all day-to-day operations: signing commits, encrypting files, and SSH authentication.

### 6. Wire up git commit signing

```bash
gpg-list-signing-keys your@email.com
```

This prints the long key ID of your `[S]` subkey and the exact `git-add-project` command to run:

```bash
git-add-project Personal GitHub your@email.com <signing-subkey-id>
```

The same applies for any other provider — substitute `GitLab`, `Bitbucket`, `AzureDevOps`, etc. for the context's `provider` value.

Or to add signing to an existing project:

```bash
git-update-project Personal GitHub --signing-key <signing-subkey-id>
```

To enable signing globally (all contexts where no project-specific key is set), add the key ID to `host_vars/localhost.yml`:

```yaml
git_default_signing_key: ABCDEF1234567890
```

Then re-run Ansible to apply it to `~/.gitconfig`.

## Key lifecycle

### Adding UIDs (email aliases)

UIDs are always added to the **master key** (`[C]`), never to subkeys. Subkeys carry no identity — they inherit it from the master. `gpg-add-uid` only lists master keys for this reason; the signing subkey fingerprint you may see in `gpg --list-secret-keys` output is not a valid target for a UID.

```bash
gpg-add-uid                      # interactive: lists master keys, prompts for email
gpg-add-uid <master-fingerprint> # non-interactive key selection
```

Common use cases:

- GitHub noreply address: `<id>+username@users.noreply.github.com`
- GitLab noreply address: `<id>-<username>@users.noreply.gitlab.com`
- Work email alias
- Alternate personal address

Both GitHub and GitLab verify signed commits against **any UID on the key** — you do not need to set a provider's noreply address as the primary UID, and doing so is usually wrong. Leave your real email as primary.

After `gpg-add-uid` completes, the new UID will show as `[ unknown]` trust in `gpg --list-keys`. This is expected — ownertrust is set on the key as a whole, not per-UID, but GPG resets the display state when a UID is added. The function re-applies ultimate ownertrust automatically. If you see `[ unknown]` persisting, run:

```bash
gpg-trust <master-fingerprint>
```

Re-export your backup after adding a UID so it reflects the new identity:

```bash
gpg-export-bitwarden <master-fingerprint>     # or: gpg-export-1password
```

The master secret key must be present locally to add a UID. If it has been removed, import it first, add the UID, re-export, then remove it again:

```bash
export BW_SESSION=$(bw unlock --raw)
gpg-import-bitwarden          # or: gpg-import-1password
gpg-add-uid <fingerprint>
gpg-export-bitwarden <fingerprint>    # or: gpg-export-1password
gpg-remove-master <fingerprint>
```

### Extending expiry

```bash
gpg-extend-expiry <fingerprint> 2y
```

This extends both the master key and all subkeys. The master secret key must be present locally — if it has been removed, import it first:

```bash
export BW_SESSION=$(bw unlock --raw)
gpg-import-bitwarden                  # or: gpg-import-1password
gpg-extend-expiry <fingerprint> 2y
gpg-export-bitwarden <fingerprint>    # or: gpg-export-1password — update backup with new expiry
gpg-remove-master <fingerprint>       # take master offline again
```

### Rotating a subkey

Rotation replaces an individual subkey without changing your identity:

```bash
gpg-rotate-subkey <master-fp> <subkey-fp> sign 2y
```

Interactive mode (no arguments) will list available subkeys and prompt for each value. The same import-operate-export-remove workflow applies when the master is offline.

After rotation:

1. Update git projects that reference the old subkey ID: `git-update-project <ctx> <prov> --signing-key <new-subkey-id>`
2. Re-export your backup: `gpg-export-bitwarden <master-fp>` (or `gpg-export-1password`)
3. Remove master again: `gpg-remove-master <master-fp>`

### Restoring the master key temporarily

```bash
# Bitwarden
export BW_SESSION=$(bw unlock --raw)
gpg-import-bitwarden                  # imports the full secret key

# 1Password
gpg-import-1password                  # imports the full secret key

# ... perform master-key operations ...

gpg-export-bitwarden <fingerprint>    # or: gpg-export-1password — update backup if anything changed
gpg-remove-master <fingerprint>       # take it offline again
```

### New machine from existing backup

```bash
# Bitwarden
export BW_SESSION=$(bw unlock --raw)
gpg-import-bitwarden "GPG Subkeys Only — …"   # import subkeys only

# 1Password
gpg-import-1password "GPG Subkeys Only — …"   # import subkeys only

gpg-trust <fingerprint>                        # set ultimate trust
```

Import the subkeys-only item rather than the full secret key — there is no reason to put the master key on a new daily-use machine.

A key exported to a file can also be imported directly:

```bash
gpg-import ~/transfer/gpg-<fp>-subkeys-only.asc
gpg-trust <fingerprint>
```

## Publishing your signing key

Once your signing subkey exists, publish its public key to your git provider so signed commits show as verified.

```bash
gpg-push-github     # interactive key selection
gpg-push-gitlab     # interactive key selection
```

Both accept an explicit key ID to skip interactive selection, e.g. `gpg-push-github <key-id>`. Each requires the matching provider CLI to be installed and authenticated first:

```bash
install-gh    && gh auth login      # for gpg-push-github
install-glab  && glab auth login    # for gpg-push-gitlab
```

`gpg-push-github` reports duplicates if the key is already registered; `gpg-push-gitlab` does the same.

## Agent management

```bash
gpg-agent-restart    # restart the agent after config changes
gpg-agent-forget     # clear cached passphrases without restart
gpg-card-status      # show YubiKey / smartcard status
```

## Function reference

### tools/gpg.sh — always available

| Function | Description |
|---|---|
| `gpg-list` | List all public keys with fingerprints |
| `gpg-list-secret` | List all secret keys with fingerprints |
| `gpg-list-signing-keys [email]` | List signing subkeys formatted for `git-add-project` |
| `gpg-show <id>` | Full detail for one key by fingerprint, ID, or email |
| `gpg-verify <file> [sigfile]` | Verify a detached signature |
| `gpg-agent-restart` | Kill and restart the GPG agent |
| `gpg-agent-forget` | Clear passphrase cache |
| `gpg-card-status` | Show smartcard / YubiKey GPG status |

### lazy/gpg-management.sh — loaded on first call

| Function | Description |
|---|---|
| `gpg-create-key` | Interactive wizard: master `[C]` + `[S]` + `[E]` subkeys |
| `gpg-add-uid [fp]` | Add an email address / identity to an existing key |
| `gpg-add-subkey [fp] [type] [expiry]` | Add a subkey to an existing master key |
| `gpg-extend-expiry [fp] [expiry]` | Extend expiry on master key and all subkeys |
| `gpg-remove-master [fp]` | Remove master secret key from local keyring (keeps subkeys) |
| `gpg-rotate-subkey [master-fp] [subkey-fp] [type] [expiry]` | Retire a subkey and add a replacement |
| `gpg-revoke [fp] [--apply]` | Generate or apply a revocation certificate |
| `gpg-export [fp] [dir]` | Export public and full secret key to files |
| `gpg-export-master [fp] [dir]` | Export master key secret material only |
| `gpg-export-subkeys [fp] [dir]` | Export subkeys-only (no master key material) |
| `gpg-export-bitwarden [fp] [--name <label>] [--master-only]` | Back up all key material to Bitwarden |
| `gpg-export-1password [fp] [--name <label>] [--vault <name>] [--master-only]` | Back up all key material to 1Password |
| `gpg-import <file>` | Import a key from an armoured file |
| `gpg-import-bitwarden [note-name]` | Import a key from a Bitwarden secure note |
| `gpg-import-1password [item-name] [--vault <name>]` | Import a key from a 1Password item |
| `gpg-trust [fp] [level]` | Set owner trust (default: `ultimate`) |
| `gpg-push-github [key-id]` | Push a public signing key to the authenticated GitHub account |
| `gpg-push-gitlab [key-id]` | Push a public signing key to the authenticated GitLab account |

All functions with optional arguments support interactive prompts when arguments are omitted.

### lazy/installers.sh

| Function | Description |
|---|---|
| `install-bw-cli` | Install the Bitwarden CLI (`bw`) |
| `install-bitwarden` | Install the Bitwarden desktop app |
| `install-op-cli` | Install the 1Password CLI (`op`) |
| `install-1password` | Install the 1Password desktop app |
| `install-gh` | Install the GitHub CLI (`gh`), used by `gpg-push-github` |
| `install-glab` | Install the GitLab CLI (`glab`), used by `gpg-push-gitlab` |

See [installers.md](installers.md) for details on each.

## GPG_TTY

`gpg.sh` sets `GPG_TTY=$(tty)` at source time. This is required for `pinentry-curses` to work correctly in terminals without a display (SSH sessions, tmux panes, headless servers). If you see `gpg: signing failed: Inappropriate ioctl for device`, ensure this variable is set:

```bash
echo $GPG_TTY     # should show something like /dev/pts/0
```

If it is empty, add to `env/90-local.sh`:

```bash
export GPG_TTY=$(tty)
```

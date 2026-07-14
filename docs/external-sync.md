# External sync

The `sync-external` engine clones/adopts any number of add-on repos, keeps
them pulled on an hourly timer, and deploys files from each according to
that repo's own [`.dotfiles-sync.yml`](sync-manifest-spec.md) manifest. It
replaced the old per-repo `nvim` and `ai-tools` roles — those hardcoded
exactly two companion repos and their internal layout; `sync-external`
knows nothing about any add-on repo's contents beyond what its manifest
declares.

## Table of Contents

- [How this differs from the dotfiles self-sync](#how-this-differs-from-the-dotfiles-self-sync)
- [The `external_synced_repos` shape](#the-external_synced_repos-shape)
- [Adding a repo](#adding-a-repo)
  - [Public repo](#public-repo)
  - [Private repo](#private-repo)
- [Per-repo `sync.conf`](#per-repo-syncconf)
  - [DEV_MODE](#dev_mode)
  - [Branch handling](#branch-handling)
- [Manual sync](#manual-sync)
- [Cadence](#cadence)
- [Status and troubleshooting](#status-and-troubleshooting)
- [Migrating from the old nvim/ai-tools sync](#migrating-from-the-old-nvimai-tools-sync)
- [Authoring a compatible repo](#authoring-a-compatible-repo)

## How this differs from the dotfiles self-sync

| | Dotfiles self-sync (`roles/sync`, `dotfiles-branch`) | `sync-external` |
| --- | --- | --- |
| Syncs | The dotfiles repo itself | Any number of separately-registered add-on repos |
| Cadence | 30 minutes | 1 hour |
| Deploy step | None — the dotfiles repo *is* the checkout | Per-repo, driven by that repo's `.dotfiles-sync.yml` |
| Config | `~/.config/dotfiles/sync.conf` | `~/.config/external-sync/<name>/sync.conf`, one per repo |
| Runs on | `workstation` and `server` | `workstation` and `server` |

They are independent, unrelated services — disabling one does not affect
the other. Both are gated by the same `dotfiles_sync_enabled` flag, so
turning that off in `host_vars` disables both timers together. See
[docs/sync.md](sync.md) for the self-sync mechanism.

## The `external_synced_repos` shape

Registered in `ansible/host_vars/localhost.yml`:

```yaml
external_synced_repos:
  - name: nvim-config
    repo_url: "https://github.com/you/nvim-config.git"
    clone_dir: "~/.config/nvim"
    private: false            # public → HTTPS, no deploy key

  - name: ai-config
    repo_url: "git@github-dotfiles-ai-config:you/ai-config.git"
    clone_dir: "~/.local/share/ai-config"
    private: true             # private → deploy key + github-dotfiles-<name> alias
```

| Field | Required | Purpose |
| --- | --- | --- |
| `name` | yes | Unique. Used for the config/state directory, the SSH alias (private repos), and as the `external-sync` script argument. Lowercase letters, digits, hyphens only. |
| `repo_url` | yes | HTTPS URL (public), or HTTPS/SSH/alias URL (private — rewritten to the alias form automatically by Ansible). |
| `clone_dir` | yes | Where the repo is cloned. May use `~`. |
| `private` | yes | `true`/`false` — controls the URL rewrite and whether a deploy key is expected. |

Cadence and deploy rules are **not** set here — cadence is fixed by the
engine (hourly), and deploy rules come from the repo's own
`.dotfiles-sync.yml` (see [Authoring a compatible repo](#authoring-a-compatible-repo)).

## Adding a repo

### Public repo

During `install.sh`'s interactive setup (`workstation` or `server`
profile), answer "y" to "Add an external add-on repo?", give it a name and
URL, accept or override the suggested clone directory, and answer "N" (or
Enter) at "Is `<name>` private?". Nothing further is needed — the repo is
cloned over HTTPS on the next Ansible run.

### Private repo

Same flow, but answer "y" at the private prompt. `install.sh` then:

1. Generates a dedicated deploy key at `~/.ssh/github-dotfiles-<name>`
   (skipped if it already exists).
2. Writes an SSH host alias block (`Host github-dotfiles-<name>`) to
   `~/.ssh/config.d/10-dotfiles.conf`.
3. Prints the public key and pauses for you to add it to the repository as
   a **read-only** deploy key (repo Settings → Deploy keys → Add deploy
   key; allow write access: **no**).

You do **not** need to hand-edit `host_vars` with the alias URL — the
`sync-external` role rewrites `repo_url` to `git@github-dotfiles-<name>:owner/repo.git`
automatically at Ansible run time, based on `private: true`.

Verify access once the key is added:

```bash
ssh -T git@github-dotfiles-<name>
```

### Adding a repo to an already-provisioned machine

The interactive collection loop only runs the first time `install.sh`
generates `host_vars/localhost.yml` (same as the `git_projects` loop). To
add a repo later, append an entry to `external_synced_repos` directly in
`ansible/host_vars/localhost.yml`, then:

- **Public repo:** just re-run `ansible-playbook site.yml --tags sync-external`.
- **Private repo:** re-run `./install.sh` (host_vars already exists so it
  won't be regenerated or prompt again). It parses your hand-added entry
  back out of `external_synced_repos`, generates its deploy key and SSH
  alias the same way it would during first-run setup, and pauses for you to
  add the printed public key to the repository as a deploy key — then run
  `ansible-playbook site.yml --tags sync-external` (or let `install.sh`'s
  own Ansible phase do it). Use `--skip-ssh` on `install.sh` if you'd rather
  generate the key and alias by hand
  (`ssh-keygen -t ed25519 -f ~/.ssh/github-dotfiles-<name>`, then a
  `Host github-dotfiles-<name>` block in `~/.ssh/config.d/10-dotfiles.conf`
  following the format in [Private repo](#private-repo) above).

## Per-repo `sync.conf`

Rendered once by Ansible at `~/.config/external-sync/<name>/sync.conf` and
**never overwritten** after creation — only its `REPO_URL` line is kept in
sync automatically if `repo_url` changes in `host_vars`.

```bash
REPO_URL="git@github-dotfiles-ai-config:you/ai-config.git"
GIT_BRANCH="main"
CLONE_DIR="/home/you/.local/share/ai-config"
DEV_MODE="false"
```

### DEV_MODE

Set `DEV_MODE=true` to suspend sync for **that repo only** — every other
registered repo keeps syncing on schedule. Reset to `false` to resume.
Useful while actively developing the add-on repo itself on this machine.

### Branch handling

`GIT_BRANCH` defaults to the repo's `.dotfiles-sync.yml` `branch` field (or
`main` if it has none) at the time `sync.conf` is first created. Edit it
directly to track a different branch temporarily — Ansible will not
overwrite your change on subsequent runs.

## Manual sync

Sync every registered repo immediately, without waiting for the timer:

```bash
external-sync
```

Sync a single repo:

```bash
external-sync <name>
```

Or bypass the engine entirely and just pull the clone directly — it's a
normal git repo:

```bash
cd ~/.local/share/ai-config && git pull
```

## Cadence

`external-sync.timer` (Linux) / `com.external-sync` (macOS) fires once
shortly after boot/login and then hourly, syncing every registered repo in
one run. That's a coarser cadence than the 30-minute dotfiles self-sync,
deliberately: add-on repos are usually not edited minute-to-minute, and a
single hourly run keeps the number of outbound git operations low even
when several repos are registered. If you want changes sooner, it's just
git — see [Manual sync](#manual-sync) above.

## Status and troubleshooting

```bash
# Linux / WSL2
systemctl --user list-timers external-sync.timer
systemctl --user status external-sync.timer
journalctl --user -u external-sync.service -n 50

# macOS
launchctl list | grep com.external-sync
```

Per-repo logs and last-sync timestamp:

```bash
cat ~/.local/share/external-sync/<name>/logs/sync.log
cat ~/.local/share/external-sync/<name>/last-sync
```

Common causes of a stalled repo:

- **`sync.conf not found` in the log** — the repo isn't registered yet, or
  Ansible hasn't run since it was added. Run
  `ansible-playbook site.yml --tags sync-external`.
- **`git fetch failed`** — network issue, or (for a private repo) the
  deploy key hasn't been added to the repository yet, or the SSH alias in
  `~/.ssh/config.d/10-dotfiles.conf` doesn't match `sync.conf`'s
  `REPO_URL`.
- **`Working tree has uncommitted changes — skipping pull`** — you have
  local edits in the clone directory. Commit, stash, or discard them, or
  set `DEV_MODE=true` to suppress the warning while you work.
- **`pull --ff-only failed`** — local and remote have diverged (e.g. a
  manual commit was made in the clone). Resolve manually in the clone
  directory.
- **Ansible fails on `Ensure systemd user instance is available (WSL
  workaround)` with `Failed to connect to bus`** — there is no systemd user
  session/D-Bus available (common in minimal containers or a fresh WSL
  instance that hasn't started its systemd user manager yet). This affects
  every role that manages a systemd user unit, not just `sync-external`.
  On WSL, ensure `systemd=true` is set in `/etc/wsl.conf` and restart the
  distro; in a container, either start a user D-Bus session or run without
  the timer (`dotfiles_sync_enabled: false`) and invoke `external-sync`
  manually/via an external scheduler instead.

## Migrating from the old nvim/ai-tools sync

If this machine previously ran the retired `nvim` / `ai-tools` Ansible
roles, run the one-shot teardown once:

```bash
scripts/migrate-legacy-sync.sh
```

This disables and removes the legacy `nvim-config-sync` / `ai-config-sync`
timers (or launchd agents), their sync scripts, and their runtime state.
It does **not** touch `~/.config/nvim` or `~/.local/share/ai-config` — those
clones are left exactly as they are so `sync-external` can adopt them in
place without re-cloning.

Then register the two repos as external add-on repos — either re-run
`./install.sh` (it will prompt for them, same as [Adding a repo](#adding-a-repo)
above) or hand-edit `external_synced_repos` in
`ansible/host_vars/localhost.yml` — and apply:

```bash
ansible-playbook site.yml --tags sync-external
```

A subsequent run adopts both clone directories in place with no re-clone
and no data loss.

## Authoring a compatible repo

What an add-on repo deploys (if anything) is entirely up to its own
`.dotfiles-sync.yml` manifest — see
[docs/sync-manifest-spec.md](sync-manifest-spec.md) for the full field
reference, the three deploy archetypes (clone-only, copy never-overwrite,
symlink auto-updating), and a copy-paste starting template.

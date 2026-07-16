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
- [Choosing a clone directory](#choosing-a-clone-directory)
- [Adding a repo](#adding-a-repo)
  - [Public repo](#public-repo)
  - [Private repo](#private-repo)
  - [Enabling hooks](#enabling-hooks)
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

They are independent, unrelated services at runtime — separate timers,
separate config/state directories, separate failure domains; a stalled
`sync-external` repo never blocks or affects dotfiles self-sync, or vice
versa. Where they're **not** independent is provisioning: both are gated by
the single `dotfiles_sync_enabled` flag in `host_vars`, so turning that off
disables both timers together. To disable only one, skip its role/tag
instead of the shared flag — e.g. `ansible-playbook site.yml --skip-tags
sync-external` (or `--skip-roles sync-external` on `install.sh`) leaves
self-sync running. See [docs/sync.md](sync.md) for the self-sync mechanism.

One more asymmetry worth knowing up front: self-sync has no deploy step, so
a `git pull` is the entire sync cycle for the dotfiles repo itself.
`sync-external` does have a deploy step, and that step is driven by
Ansible-rendered files (`deploy.list`, `hooks.list`), not by re-parsing each
repo's manifest on every pull — a manifest change needs an Ansible re-run to
take effect, not just a pull. See
[docs/sync-manifest-spec.md's "How to make your repo compatible"](sync-manifest-spec.md#how-to-make-your-repo-compatible)
for exactly where that line falls, and `external-sync --status` for how to
tell when a repo is waiting on that re-run.

## The `external_synced_repos` shape

Registered in `ansible/host_vars/localhost.yml`:

```yaml
external_synced_repos:
  - name: nvim-config
    repo_url: "https://github.com/you/nvim-config.git"
    clone_dir: "~/.config/nvim"
    private: false            # public → HTTPS, no deploy key

  - name: ai-config
    repo_url: "https://github.com/you/ai-config.git"  # or git@github.com:you/ai-config.git
    clone_dir: "~/.local/share/ai-config"
    private: true             # private → deploy key + dotfiles-<name> alias;
                               # Ansible rewrites repo_url to the alias form
                               # automatically — give the real URL here, not
                               # an already-rewritten dotfiles-<name> one (the
                               # alias doesn't encode the real host, so
                               # install.sh can't derive HostName from it)
    allow_hooks: false        # optional, default false — see "Enabling hooks" below
```

| Field | Required | Purpose |
| --- | --- | --- |
| `name` | yes | Unique. Used for the config/state directory, the SSH alias (private repos), and as the `external-sync` script argument. Lowercase letters, digits, hyphens only. |
| `repo_url` | yes | HTTPS, SSH, or alias URL — any git host (public), or same forms for private (rewritten to the alias form automatically by Ansible; the real host is extracted from whatever form you give and doesn't need to be GitHub). |
| `clone_dir` | yes | Where the repo is cloned. May use `~`. See [Choosing a clone directory](#choosing-a-clone-directory). |
| `private` | yes | `true`/`false` — controls the URL rewrite and whether a deploy key is expected. |
| `allow_hooks` | no | `true`/`false`, default `false` — whether this repo's declared post-deploy hook (if any) is allowed to run on this machine. See [Enabling hooks](#enabling-hooks) and [the spec's hook contract](sync-manifest-spec.md#hook-contract). |

Cadence and deploy rules are **not** set here — cadence is fixed by the
engine (hourly), and deploy rules (and any hook) come from the repo's own
`.dotfiles-sync.yml` (see [Authoring a compatible repo](#authoring-a-compatible-repo)).

## Choosing a clone directory

`clone_dir` has two legitimate patterns, and picking the wrong one for a
given repo is a common (and confusing) mistake — `install.sh` suggests
`~/.local/share/<name>` by default, which is correct for one pattern and
silently wrong for the other:

- **Deployed elsewhere via a manifest.** The repo's content is copied or
  symlinked out to its real destinations by `deploy:` entries in its
  `.dotfiles-sync.yml` — the clone directory itself is just working storage,
  nobody reads it directly. `~/.local/share/<name>` (the suggested default)
  is fine here, and so is anywhere else — it doesn't matter, since nothing
  reads the clone path itself.
- **Clone-only, read directly by the tool.** The repo *is* the config a tool
  reads from a fixed location — e.g. an editor that always reads
  `~/.config/<tool>`, with no `deploy:` block (or none at all) in its
  manifest. Here `clone_dir` **must be that fixed location** — accepting the
  generic `~/.local/share/<name>` default would clone the repo somewhere the
  tool never looks, syncing perfectly while deploying to nowhere. See
  [Archetype 1: Clone-only](sync-manifest-spec.md#1-clone-only) in the spec.

`install.sh`'s clone-directory prompt explains both patterns before asking,
precisely so you pick correctly the first time — it never special-cases a
repo by name to guess for you.

**A note on tools that rewrite their own tracked state.** If `clone_dir`
points at a location the tool itself writes back into — a lockfile, a cache
index, anything the tool re-generates and the repo also tracks in git — that
write dirties the working tree exactly the same way any other uncommitted
change would. The next sync sees `Working tree has uncommitted changes —
skipping pull` and stops updating that repo until you commit the file (or
add it to `.gitignore` if it shouldn't be tracked at all). This is often the
*correct* behaviour — the file probably should be committed so other
machines pick up the same state — but it needs to be a deliberate choice on
your part, not a mystery you discover from a silently stalled timer.
`external-sync --status` surfaces this immediately (see [Status and
troubleshooting](#status-and-troubleshooting)).

## Adding a repo

### Public repo

During `install.sh`'s interactive setup (`workstation` or `server`
profile), answer "y" to "Add an external add-on repo?", give it a name and
URL, accept or override the suggested clone directory (see [Choosing a
clone directory](#choosing-a-clone-directory) — the prompt explains both
patterns before asking), and answer "N" (or Enter) at "Is `<name>`
private?". You're then asked whether to allow post-deploy hooks for this
repo — see [Enabling hooks](#enabling-hooks); answer "N" (the default)
unless you specifically need one. Nothing further is needed — the repo is
cloned over HTTPS on the next Ansible run.

### Private repo

Same flow, but answer "y" at the private prompt. `install.sh` then:

1. Extracts the real host (GitHub, GitLab, self-hosted, etc.) from the
   URL you gave and generates a dedicated deploy key at
   `~/.ssh/dotfiles-<name>` (skipped if it already exists).
2. Writes an SSH host alias block (`Host dotfiles-<name>`, `HostName
   <the extracted host>`) to `~/.ssh/config.d/10-dotfiles.conf`.
3. Prints the public key and pauses for you to add it to the repository as
   a **read-only** deploy key (repo Settings → Deploy keys → Add deploy
   key; allow write access: **no**).

You do **not** need to hand-edit `host_vars` with the alias URL — the
`sync-external` role rewrites `repo_url` to `git@dotfiles-<name>:owner/repo.git`
automatically at Ansible run time, based on `private: true`.

Verify access once the key is added:

```bash
ssh -T git@dotfiles-<name>
```

### Enabling hooks

If a repo's `.dotfiles-sync.yml` declares a `hooks.post_deploy` (see [the
spec's hook contract](sync-manifest-spec.md#hook-contract)), it does **not**
run anywhere by default. `install.sh` asks "Allow post-deploy hooks for
`<name>`? [y/N]" for every registered repo, with a one-line reminder that a
hook is arbitrary code from that repo, run unattended on a timer — answer
"y" only for repos whose hook you specifically want.

If you answer "N" (or the repo's manifest adds a hook later, after you
registered it), Ansible still succeeds — it renders an empty `hooks.list`
for that repo and prints a one-line reminder in the run's output naming the
exact fix:

```yaml
external_synced_repos:
  - name: nvim-config
    repo_url: "https://github.com/you/nvim-config.git"
    clone_dir: "~/.config/nvim"
    private: false
    allow_hooks: true    # set this, then re-run ansible-playbook site.yml --tags sync-external
```

There's no separate "add a hook" flow beyond this — the hook itself lives
entirely in the add-on repo's own manifest; `host_vars` only ever grants or
withholds permission to run whatever that repo currently declares.

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
  (`ssh-keygen -t ed25519 -f ~/.ssh/dotfiles-<name>`, then a
  `Host dotfiles-<name>` block in `~/.ssh/config.d/10-dotfiles.conf`
  following the format in [Private repo](#private-repo) above).
- **Enabling hooks on an already-registered repo:** add `allow_hooks: true`
  to that repo's existing entry by hand, then re-run
  `ansible-playbook site.yml --tags sync-external` — see [Enabling
  hooks](#enabling-hooks).

## Per-repo `sync.conf`

Rendered once by Ansible at `~/.config/external-sync/<name>/sync.conf` and
**never overwritten** after creation — only its `REPO_URL` line is kept in
sync automatically if `repo_url` changes in `host_vars`.

```bash
REPO_URL="git@dotfiles-ai-config:you/ai-config.git"
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

Re-run a repo's post-deploy hook regardless of its `run_on` policy — the
affordance for "I fixed the hook, run it again now" without waiting for the
next `changed`/`always` firing:

```bash
external-sync <name> --force-hooks
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

Start here — a per-repo status table, no git fetch/pull performed and no
sync lock taken, so it's always safe to run even while a sync is in
progress:

```bash
external-sync --status
```

Reports each repo's branch, clone location (flagged if missing or not a git
repo), `DEV_MODE`, last sync time, deploy entry count, **manifest** state
(`ok`, or `**drift**` — see below), and **hook** state (`none`, `ok`, or
`failed (<rc>)`). Exits non-zero if anything needs attention, so it's usable
as a health check.

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
  local edits in the clone directory (including a tool rewriting its own
  tracked state — see [Choosing a clone directory](#choosing-a-clone-directory)).
  Commit, stash, or discard them, or set `DEV_MODE=true` to suppress the
  warning while you work.
- **`pull --ff-only failed`** — local and remote have diverged (e.g. a
  manual commit was made in the clone). Resolve manually in the clone
  directory.
- **`external-sync --status` shows `Manifest: **drift**`** — the repo's
  `.dotfiles-sync.yml` in the clone has changed since Ansible last rendered
  `deploy.list`/`hooks.list` from it. Expected whenever you edit the
  manifest upstream — a plain `git pull` is not enough to apply a manifest
  change, only an Ansible re-run is (see
  [docs/sync-manifest-spec.md](sync-manifest-spec.md#how-to-make-your-repo-compatible)).
  Run `ansible-playbook site.yml --tags sync-external` to clear it.
- **`external-sync --status` shows `Hook: failed (<rc>)`** — the repo's
  post-deploy hook exited non-zero (`124` means it was killed for exceeding
  its `timeout`). Check `logs/sync.log` for the hook's own output, fix the
  underlying issue, then `external-sync <name> --force-hooks` to re-run it
  without waiting for the next `changed`/`always` firing.
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

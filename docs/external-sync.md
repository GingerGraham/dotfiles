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
- [On-disk layout](#on-disk-layout)
- [The `external_synced_repos` shape](#the-external_synced_repos-shape)
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
- [Renaming or removing a destination](#renaming-or-removing-a-destination)
- [Migrating an existing clone to link_tree](#migrating-an-existing-clone-to-link_tree)
- [Migrating from the old nvim/ai-tools sync](#migrating-from-the-old-nvimai-tools-sync)
  - [Machines that ran a pre-release layout of sync-external itself](#machines-that-ran-a-pre-release-layout-of-sync-external-itself)
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

## On-disk layout

For a repo named `<name>`, two **parallel** trees — the clone is not a
sibling of `deploy.list`, it lives under the data root:

```
${XDG_CONFIG_HOME}/external-sync/<name>/          # config root — human-facing, mostly force:false
    ├── sync.conf                                 # runtime state: GIT_BRANCH, DEV_MODE (never clobbered)
    ├── deploy.list                                # Ansible-rendered every run; the placement answer
    └── hooks.list                                 # Ansible-rendered every run; empty unless hooks

${XDG_DATA_HOME}/external-sync/<name>/            # data root — engine-owned
    ├── repo/                                      # THE CLONE — always here, never a host_vars choice
    ├── logs/sync.log
    ├── last-sync
    ├── manifest-hash                              # Ansible-written; drift detection
    ├── hook-ran                                   # run_on: initial sentinel
    └── last-hook-status
```

The clone location is **engine-computed** — always
`${XDG_DATA_HOME}/external-sync/<name>/repo/`, never a per-repo choice in
`host_vars`. `ls ~/.local/share/external-sync/` enumerates the whole managed
fleet; nothing scatters elsewhere under `~/.local/share/`. Where a repo's
*content* ends up (if anywhere) is a separate question, answered entirely by
that repo's own `.dotfiles-sync.yml` — see
[deploy.list becomes the universal answer to "where did this repo's content
go?"](sync-manifest-spec.md#deploy-semantics): it lists every deployed
file's real destination, pre-expanded to an absolute path, for every repo,
uniformly.

## The `external_synced_repos` shape

Registered in `ansible/host_vars/localhost.yml`:

```yaml
external_synced_repos:
  - name: nvim-config
    repo_url: "https://github.com/you/nvim-config.git"
    private: false            # public → HTTPS, no deploy key

  - name: ai-config
    repo_url: "https://github.com/you/ai-config.git"  # or git@github.com:you/ai-config.git
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
| `private` | yes | `true`/`false` — controls the URL rewrite and whether a deploy key is expected. |
| `allow_hooks` | no | `true`/`false`, default `false` — whether this repo's declared post-deploy hook (if any) is allowed to run on this machine. See [Enabling hooks](#enabling-hooks) and [the spec's hook contract](sync-manifest-spec.md#hook-contract). |

There is no `clone_dir` field — see [On-disk layout](#on-disk-layout) above.
Cadence and deploy rules are **not** set here either — cadence is fixed by
the engine (hourly), and deploy rules (and any hook) come from the repo's
own `.dotfiles-sync.yml` (see [Authoring a compatible
repo](#authoring-a-compatible-repo)). A repo registered here with no
manifest at all is still valid — it's cloned and kept pulled, deploying
nothing (see [the spec's clone-only archetype](sync-manifest-spec.md#1-clone-only))
— but the engine warns about it on every sync, and `external-sync --status`
shows `**no manifest**`, until a manifest is added.

## Adding a repo

### Public repo

During `install.sh`'s interactive setup (`workstation` or `server`
profile), answer "y" to "Add an external add-on repo?", give it a name and
URL, and answer "N" (or Enter) at "Is `<name>` private?". You're then asked
whether to allow post-deploy hooks for this repo — see [Enabling
hooks](#enabling-hooks); answer "N" (the default) unless you specifically
need one. Nothing further is needed — the repo is cloned over HTTPS to
`~/.local/share/external-sync/<name>/repo` on the next Ansible run, and
deployed according to its own manifest (if it has one).

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
DEV_MODE="false"
```

The clone path is deliberately not a `sync.conf` field — it's always the
engine-computed path (see [On-disk layout](#on-disk-layout)), derived
identically by Ansible and the sync script, so there's nothing to configure
or drift. A `CLONE_DIR` line left over from an older layout is ignored.

### DEV_MODE

Set `DEV_MODE=true` to suspend sync for **that repo only** — every other
registered repo keeps syncing on schedule. Reset to `false` to resume.
Useful while actively developing the add-on repo itself on this machine.

### Branch handling

`GIT_BRANCH` defaults to the repo's `.dotfiles-sync.yml` `branch` field (or
`main` if it has none) at the time `sync.conf` is first created. Edit it
directly to track a different branch temporarily — the engine switches the
clone onto it (fetching first, refusing on a dirty working tree or a branch
absent on the remote — see the troubleshooting entries below), and Ansible
will not overwrite your change on subsequent runs.

**Bootstrap constraint.** The manifest itself is only ever read from the
clone of the remote's *default* branch — the first clone deliberately omits
a pinned `version:`, so it follows the remote's actual default, and that's
the checkout Ansible parses `.dotfiles-sync.yml` from. A `branch:` value (or
a hand-edited `GIT_BRANCH`) redirects tracking *after* that initial clone;
it cannot make Ansible discover a manifest that exists only on a feature
branch. If a repo's manifest doesn't seem to be taking effect, check it's
committed on the remote's default branch.

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
cd ~/.local/share/external-sync/ai-config/repo && git pull
```

(For a `link_tree` repo, its deployed `dest` — e.g. `~/.config/nvim` — *is*
the clone, so `cd`-ing there works identically and is usually more natural.)

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
repo), `DEV_MODE`, last sync time, **deploy** state (an entry count,
`clone-only`, or `**no manifest**` — see below), **manifest** state (`ok`,
or `**drift**` — see below), **diverged** count (`copy`-deployed files that
differ from their source — blank when none or the repo has no `copy`
entries), and **hook** state (`none`, `ok`, or `failed (<rc>)`). Exits
non-zero if anything needs attention, so it's usable as a health check. It
does **not** detect orphaned old destinations — see [Renaming or removing a
destination](#renaming-or-removing-a-destination).

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
  local edits in the clone (including a tool rewriting its own tracked
  state — e.g. a lockfile the repo tracks and also regenerates). Commit,
  stash, or discard them, or set `DEV_MODE=true` to suppress the warning
  while you work. The same message, worded around a branch switch instead
  of a pull, appears when `GIT_BRANCH` was changed but the tree is dirty —
  the engine will not discard in-progress work to switch branches either.
- **`pull --ff-only failed`** — local and remote have diverged (e.g. a
  manual commit was made in the clone). Resolve manually in the clone
  directory (`~/.local/share/external-sync/<name>/repo`, or the `link_tree`
  `dest` if this repo uses that mode).
- **`Could not switch from '<a>' to '<b>' — '<b>' does not appear to exist
  on the remote`** — `GIT_BRANCH` in `sync.conf` (or `branch:` in the
  manifest) names a branch that isn't on the remote, most likely a typo.
  The clone is left exactly where it was; fix the branch name and re-run.
- **`external-sync --status` shows `Deploy: **no manifest**`** — this repo
  has no `.dotfiles-sync.yml` at all. Valid if deliberate (see [the spec's
  clone-only archetype](sync-manifest-spec.md#1-clone-only)); otherwise add
  one and run `ansible-playbook site.yml --tags sync-external` — it
  self-heals on the next Ansible run, no other action needed.
- **`external-sync --status` shows `Manifest: **drift**`** — the repo's
  `.dotfiles-sync.yml` in the clone has changed since Ansible last rendered
  `deploy.list`/`hooks.list` from it. Expected whenever you edit the
  manifest upstream — a plain `git pull` is not enough to apply a manifest
  change, only an Ansible re-run is (see
  [docs/sync-manifest-spec.md](sync-manifest-spec.md#how-to-make-your-repo-compatible)).
  Run `ansible-playbook site.yml --tags sync-external` to clear it.
- **`external-sync --status` shows a `Diverged` count** — one or more
  `copy`-deployed files no longer match their source in the clone, because
  they (or the source) were edited locally after deployment. This is
  expected under `copy`'s detached, one-way-publish model (see [the spec's
  deploy semantics](sync-manifest-spec.md#deploy-semantics)) — not an
  error, just visibility. Promote a local edit by making the same change in
  the source repo and opening a PR, or accept the fork.
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

## Renaming or removing a destination

The engine heals forward, never backward. Adding a manifest, or a `deploy`
entry, deploys it. **Changing** a `dest` (renaming it upstream, or removing
the entry) deploys the new location but does **not** remove the old one —
there is no record of the previous placement to diff against, and by
deliberate design a background timer executing repo-authored instructions
is never given the power to delete files based on those instructions
changing. The old location is left as an orphan for you to remove by hand.
`external-sync --status` will not flag it; it reports only state it can
verify locally.

This is the same shape as two other manual-cleanup cases in this doc: the
`link_tree` migration below (an old real clone directory left over once
you've verified the new symlinked one), and any leftover clone directory
from a repo's clone location changing (e.g. after adopting the
`external-sync` engine, an old ad-hoc clone at a different path). In every
case: the engine adds and repoints, you remove, once you've verified the
new state is correct.

## Migrating an existing clone to link_tree

If a repo already has a real (non-symlink) directory at the location its
manifest now declares as a `mode: link_tree` destination — most likely
because you cloned it there by hand before registering it, or before its
manifest existed — the engine will **refuse** to replace it (see [the
spec's `link_tree` archetype](sync-manifest-spec.md#4-symlink-the-whole-repo-link_tree)).
This is deliberate: a background process must never delete a git clone.
Convert it by hand, once, per machine:

1. Confirm the existing clone is clean: `cd <dest> && git status` — commit
   or stash anything outstanding (a lockfile especially — see [Branch
   handling](#branch-handling) for why a dirty tree matters here). Note the
   branch and remote so you can verify afterwards.
2. Remove the old directory: `rm -rf <dest>` — safe once `git status` is
   clean, since nothing unique is lost; it's a clone of a pushed repo.
3. Run `ansible-playbook site.yml --tags sync-external`. The role clones to
   `~/.local/share/external-sync/<name>/repo` and `link_tree` symlinks
   `<dest>` to it.
4. Verify: `readlink <dest>` points into `~/.local/share/external-sync/`,
   and the consuming tool starts clean.
5. If an *older* clone-only attempt left a leftover directory elsewhere
   (e.g. under the old ad-hoc clone-dir pattern), remove that too once
   you've verified the new symlink is correct — see [Renaming or removing a
   destination](#renaming-or-removing-a-destination) above.

## Migrating from the old nvim/ai-tools sync

If this machine previously ran the retired `nvim` / `ai-tools` Ansible
roles, run the one-shot teardown once:

```bash
scripts/migrate-legacy-sync.sh
```

This disables and removes the legacy `nvim-config-sync` / `ai-config-sync`
timers (or launchd agents), their sync scripts, and their runtime state.
It does **not** touch `~/.config/nvim` or `~/.local/share/ai-config` — those
clones are left exactly as they are; the legacy teardown has no opinion
about them.

Then register the two repos as external add-on repos — either re-run
`./install.sh` (it will prompt for them, same as [Adding a repo](#adding-a-repo)
above) or hand-edit `external_synced_repos` in
`ansible/host_vars/localhost.yml` — and apply:

```bash
ansible-playbook site.yml --tags sync-external
```

**The clone location has changed since this workflow was first written.**
`sync-external` always clones to `~/.local/share/external-sync/<name>/repo`
now (see [On-disk layout](#on-disk-layout)) — it does not adopt an old
`~/.config/nvim` or `~/.local/share/ai-config` clone in place. What happens
next depends on the repo's own manifest:

- **A repo whose manifest uses `mode: link_tree`** (nvim-config's shape —
  its `dest` *is* the clone) needs the manual conversion in [Migrating an
  existing clone to link_tree](#migrating-an-existing-clone-to-link_tree)
  above: the old real directory at `~/.config/nvim` must be removed by hand
  once verified clean, then the Ansible run creates the new clone and
  symlinks `~/.config/nvim` to it.
- **A repo whose manifest uses `copy`/`link` entries** (ai-config's shape —
  content is published *out* to `~/.claude/` etc.) just clones fresh to the
  new location and deploys as normal; the old `~/.local/share/ai-config`
  clone becomes an orphan. Verify it's clean (nothing uncommitted you still
  need), then remove it — see [Renaming or removing a
  destination](#renaming-or-removing-a-destination) above.

### Machines that ran a pre-release layout of sync-external itself

If a machine ran an earlier, pre-release iteration of `sync-external` — the
one where each repo's clone location was a per-machine `clone_dir` choice —
its per-repo engine state describes the old layout: `deploy.list` carries
absolute source paths under the old clone location, `manifest-hash` was
computed from the old clone, and `sync.conf` may still carry a now-ignored
`CLONE_DIR` line. Before the first Ansible run with the new layout, clear
both engine trees:

```bash
rm -rf ~/.config/external-sync ~/.local/share/external-sync
```

Both trees are wholly engine-owned and fully regenerated by the next
`ansible-playbook site.yml --tags sync-external`. The only user-mutated
values in them (`GIT_BRANCH`, `DEV_MODE` in each `sync.conf`) reset to
defaults — re-apply any you'd changed. The old clones themselves (e.g.
`~/.local/share/nvim-config`, `~/.local/share/ai-config`) are now orphans;
verify and remove them per [Renaming or removing a
destination](#renaming-or-removing-a-destination).

## Authoring a compatible repo

What an add-on repo deploys (if anything) is entirely up to its own
`.dotfiles-sync.yml` manifest — see
[docs/sync-manifest-spec.md](sync-manifest-spec.md) for the full field
reference, the five deploy archetypes (clone-only, copy never-overwrite,
symlink auto-updating, symlink the whole repo, clone-only with a hook), and
a copy-paste starting template. Run
[`scripts/validate-sync-manifest.sh`](sync-manifest-spec.md#validating-your-manifest)
against a manifest before pushing it.

# Persistence, Ownership and Diagnostics

Installed tools, harnesses and mise state live under the
unprivileged user's persistent home, so the home volume is the unit of
durability. This note records how UID/GID migration survives interruption, how
`t3-doctor` reports what is actually mounted, and where the boundary between
"observed" and "guaranteed" persistence sits.

The canonical product contract is
[`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md). The
mise paths it reports are defined in
[`project-execution.md`](./project-execution.md); the immutable T3 paths are in
[`infrastructure.md`](./infrastructure.md).

## Whole-home persistence

One mount is durable:

| Mount | Preserves | Does not preserve |
| --- | --- | --- |
| `/home/t3` (whole home) | T3 state and credentials, mise config/data/state/cache, installed tools and harnesses, shell history | — |
| `/home/t3/.t3` only (state-only) | T3 state and credentials | installed tools, mise global selections, and the trust store |

The state directory is the one path every deployment mounts, so the migration
marker and the agent-credential store are anchored there. That keeps state and
credentials durable even for a deployment that mounted only `/home/t3/.t3`, but
it deliberately does **not** make installed tools durable: those live under
`/home/t3/.local/share/mise` and are lost on recreate unless the whole home is
mounted. `t3-doctor` says so explicitly (see below).

## Ownership migration

The entrypoint runs as root, maps the `t3` account and the user trees to
`PUID`/`PGID`, then drops privileges. A recursive `chown` over a large tool tree
can be slow, and both `usermod` and the explicit traversal can be interrupted.
`usermod -u` rewrites ownership of files it owns inside the user's home by
itself, so an interruption can leave a half-migrated tree whose top directory
already looks correct and is never repaired by a naive writability probe.

To make that recoverable, the entrypoint records the *intent* before the first
account or ownership change and clears it only when the migration has completed
and been verified.

### Marker location and format

```text
$T3CODE_HOME/.ownership-migration
```

`$T3CODE_HOME` is `/home/t3/.t3` by default and follows an external override, so
the marker always lives on the state volume - the one mount every deployment has
and the same volume that survives a restart or a recreate.

The file is plain `key=value`, written atomically (temp file plus rename) and
world-readable so diagnostics can read it even if it is still root-owned:

| Key | Meaning |
| --- | --- |
| `version` | Marker format version; currently `1`. |
| `target_uid` | The `PUID` the tree is being migrated to. |
| `target_gid` | The `PGID` the tree is being migrated to. |
| `started` | UTC timestamp of the attempt that recorded the marker. |

### Recovery semantics

1. On every start the entrypoint decides whether any ownership work is needed:
   the account ids differ from `PUID`/`PGID`, a target directory is not writable
   by `t3`, or a marker is already present.
2. If work is needed and no marker exists, the marker is written **before**
   `groupmod`, `usermod`, or the first `chown`.
3. The account is remapped, then `/home/t3` and `$T3CODE_HOME` are traversed
   recursively. A pending marker forces the traversal even when the account
   already carries the target ids and the top directory probes as writable,
   because the interruption may have left deep files owned by the old uid.
4. The marker is removed only after both trees are verified writable by `t3`.
   A failing `chown` aborts the entrypoint (`set -e`) with the marker in place,
   so the next start retries instead of trusting a partial migration.

Recovery therefore works across a plain restart and across a recreate on the
same volume, and it is idempotent: an already-migrated tree is simply walked
again and the marker is cleared.

### Steady state

When no marker is pending and the account ids already match `PUID`/`PGID`, the
entrypoint only runs writability probes - `gosu t3 test -w` on `/home/t3` and
`$T3CODE_HOME`. It does not traverse anything. A fresh named volume arrives from
the image already owned by `t3`, so the common boot and every restart on the
same volume are steady state.

### Preserved behavior

- **Workspace adoption stays non-recursive.** `/workspace` is only `chown`ed
  when it is root-owned, and only the directory itself; nested files owned by
  another user are never rewritten.
- **Direct state mounts are adopted.** A root-owned volume mounted at
  `$T3CODE_HOME` is still detected via a writability probe and taken ownership
  of, without relying on the home directory's uid.
- **External `T3CODE_HOME` is supported.** The marker, the traversal and the
  diagnostics all follow the override; the home and the external state directory
  are each migrated.

### Known risk

`usermod` rewrites home ownership as part of changing the uid. The marker is
written before that call, and the explicit traversal always follows it, so the
combination is recoverable; the traversal is not skipped just because `usermod`
already changed the top-level owner.

## Diagnostics

`t3-doctor` steps down to `t3` before doing anything, so it creates no
root-owned state. Its mise probes may initialise user-owned directories under
the home (that is where mise state belongs), but never a root-owned file.

### Toolchain fields

Added under **Toolchains (mise)**:

| Field | Source |
| --- | --- |
| `mise` | `mise --version`, the pinned release |
| `config dir` / `data dir` / `state dir` / `cache dir` | The persistent `MISE_*` paths, defaulting to the same values as `docker/user-env.sh` |
| `active config` | `mise config ls`, run with `-C "$HOME"` so it is the system and personal config rather than whichever project the doctor was run from |
| `policy` | Effective `auto_install`, `not_found_system_fallback` and `pin` |
| `installed tools` | `mise ls --installed`, tool plus exact version, or `none` |

### Ownership and mount fields

| Field | Meaning |
| --- | --- |
| `migration` | `complete`, or `pending` with the target ids and the marker path; a pending marker means the next start retries |
| `Persistence (observed now)` | One verdict per path: `tools & mise` (`$MISE_DATA_DIR`), `T3 state` (`$T3CODE_HOME`), `workspace` (`$T3_WORKSPACE`) |

Each mount verdict is one of:

- `named volume '<name>'` - durable, survives a restart and a recreate;
- `host path <source>` - durable, whatever the operator mounted;
- `anonymous volume` - survives a restart only, replaced on recreate;
- `not on a mount` - nothing survives even a restart.

When the tools mount is not durable, the doctor adds an explicit warning that a
state-only mount loses installed tools and harnesses on recreate. The section
closes by stating that this layout is **observed at this start only** and that
the next container can mount something else - the volume, not the container,
is what persists.

### Volume classification

Mount sources are matched as `*/var/lib/docker/volumes/*/_data` rather than only
at the filesystem root. A daemon whose data root sits under a btrfs subvolume
reports sources such as `/@/var/lib/docker/volumes/<name>/_data`; the anchored
pattern would misclassify a named volume as a host path and an anonymous volume
as durable. The same pattern is used by the boot-time persistence verdict in the
entrypoint.

## Verification

```sh
scripts/build.sh --target core
scripts/test-ownership.sh t3code:core
scripts/test-mise.sh t3code:core
scripts/test-infrastructure.sh t3code:core
scripts/smoke-test.sh t3code:core
```

`test-ownership.sh` seeds volumes directly (root-owned, foreign-owned, partial
migrations) and covers: a fresh home that is never traversed; a recreate on the
same volume that is never traversed; root-owned home adoption with the intent
recorded before the traversal; an interruption forced by a read-only mount,
with the marker and its format inspected and the retry completed; a `PUID`/`PGID`
remap with the marker written before the account change; a direct state mount;
an external `T3CODE_HOME`; workspace non-recursion; and `t3-doctor` reporting
the mise fields, the observed mounts, the state-only warning, and no root-owned
state. Verification is amd64-only, per the plan.

Managed harnesses are tools under `$MISE_DATA_DIR`, so they survive recreation
and appear in `t3-doctor`'s installed-tool report. Mount verdicts are local,
read-only `/proc/self/mountinfo` parses and require no network.

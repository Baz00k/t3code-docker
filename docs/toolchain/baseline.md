# Toolchain Management Baseline

The reproducible starting point for the mise toolchain-management effort. Every
child ticket branches from the integration branch recorded here, and every
size/startup claim later in the effort is compared against these numbers.

The canonical product contract is [`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md).

## Repository Setup

| Field | Value |
| --- | --- |
| Integration branch | `integration/mise-toolchains` |
| Plan commit | `ff05d3367fb0dedc0b93ed6382fd855bd2ea1522` — *Add mise toolchain management plan* |
| Integration branch base | `2ffeaede9166404a0a607ea7cd1356a9588366db` |
| `origin` (writable) | `https://github.com/Baz00k/t3code-docker.git` |
| `upstream` (read-only) | `https://github.com/dizys/t3code-docker` |

The plan commit is a single commit on top of the integration base; the base is
the same revision that produced the published `v0.4.5` images.

### Remote protection

`upstream` is fetch-only. Its push URL is the literal string `DISABLED`, so an
accidental `git push upstream` fails rather than opening a direct upstream PR:

```text
$ git remote -v
origin   https://github.com/Baz00k/t3code-docker.git (fetch)
origin   https://github.com/Baz00k/t3code-docker.git (push)
upstream https://github.com/dizys/t3code-docker (fetch)
upstream DISABLED (push)
```

`origin` is the fork and is writable. All pushes go to `origin`.

## Worktree And Branch Convention

Every ticket works on an isolated branch so concurrent sessions cannot collide,
and every branch is named after the ticket that owns it.

- **Branch:** `tm/<NN>-<slug>`, created from `integration/mise-toolchains`.
  `<NN>` is the zero-padded GitHub issue number; `<slug>` is the ticket title
  after the `TM-NN:` prefix, lowercased and kebab-cased. Example: issue
  [TM-02: Audit T3 provider execution and updates](https://github.com/Baz00k/t3code-docker/issues/4)
  becomes `tm/02-audit-t3-provider-execution-and-updates`.
- **Worktree:** a sibling of the repository,
  `../t3code-worktrees/<NN>-<slug>`. Keeping worktrees out of the checkout means
  no `.gitignore` or in-tree churn is needed to make `git status` clean.

  ```sh
  git worktree add -b tm/04-add-verified-mise-and-project-execution \
    ../t3code-worktrees/04-add-verified-mise-and-project-execution \
    integration/mise-toolchains
  ```

- **Commits:** repo style (imperative subject, wrapped body). Reference the
  ticket that owns the branch, e.g. `Refs #6` in the body.
- **Merge:** fast-forward `integration/mise-toolchains` when the ticket branch
  is linear; otherwise `git merge --no-ff` with a `Merge TM-NN` message. Delete
  the branch and remove the worktree after the merge.
- **Push:** `origin/integration/mise-toolchains` is the shared line. Push a
  ticket branch to `origin` only when that ticket needs remote CI. Never push to
  `upstream`.

## Baseline Images

`scripts/measure-image.sh` is the single measurement entry point. It measures a
locally built target through the container runtime (`slim full`), or a pushed
reference through the registry API without a daemon
(`--registry HOST/REPO`).

The baseline is measured on `linux/amd64` only. `linux/arm64` is expected to
behave analogously but is not separately built, tested, or required as evidence
(the same policy as [`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md)).

The numbers below were measured with:

```sh
scripts/measure-image.sh \
  --registry ghcr.io/dizys/t3code-docker \
  --platform linux/amd64 \
  --unpacked slim full
```

The registry reports the compressed size directly from the image manifest, so
the compressed totals are exact; `--unpacked` streams every layer through
`gzip -dc` and sums the uncompressed bytes.

| Target | Arch | Compressed | Unpacked | Compressed (bytes) | Unpacked (bytes) |
| --- | --- | ---: | ---: | ---: | ---: |
| `slim` | amd64 | 1.10 GiB | 2.94 GiB | 1,179,995,124 | 3,156,061,184 |
| `full` | amd64 | 1.96 GiB | 5.19 GiB | 2,107,246,452 | 5,571,555,840 |

### Artifact identity

Both targets resolve to the same published release, `v0.4.5`, built from the
integration base revision. The labels are baked into each image config by the
build workflow.

| Target | Arch | Manifest digest |
| --- | --- | --- |
| `slim` | amd64 | `sha256:12ddceb1b60f8f4edbc627b3b25550a3a223ad5cd71b12e4f47e0b32e75d9b20` |
| `full` | amd64 | `sha256:57f675f336d00e0d1d0034c20612b44312310b8d5fecba71b5dd771fabe26034` |

Both images carry:

```text
org.opencontainers.image.revision = 2ffeaede9166404a0a607ea7cd1356a9588366db
org.opencontainers.image.version  = v0.4.5
```

### Native rebuild and startup

A local image is the authoritative measure of the source on the integration
branch. On a native amd64 host with Docker:

```sh
scripts/measure-image.sh slim full          # builds a missing target, then measures
scripts/measure-image.sh --no-startup slim  # skip the first-healthy timing
```

This additionally records the compressed size (the gzipped `docker save`
archive), the unpacked size (the sum of the uncompressed layer tars in that
archive, which matches the registry `--unpacked` figure exactly), the image
digest, and the time from `docker run` to the first
`/.well-known/t3/environment` response. Startup timing is **not** available from
the registry and must run on native hardware.

Measured on a native amd64 host, one sample per row:

| Source | Target | Compressed | Unpacked | Startup |
| --- | --- | ---: | ---: | ---: |
| published `v0.4.5`, pulled | `slim` | 1.10 GiB (1,175,874,628 B) | 2.94 GiB (3,156,061,184 B) | 3.65 s |
| published `v0.4.5`, pulled | `full` | 1.95 GiB (2,097,056,511 B) | 5.19 GiB (5,571,555,840 B) | 3.22 s |
| rebuilt from source | `slim` | 1.10 GiB (1,181,793,153 B) | 2.98 GiB (3,197,304,320 B) | 3.24 s |
| rebuilt from source | `full` | 1.97 GiB (2,112,396,698 B) | 5.25 GiB (5,639,725,056 B) | 3.23 s |

All four rows were produced by the commands above (`--no-build` against the
pulled `v0.4.5` tags for the first two). The local compressed figure is a
fraction of a percent away from the registry per-layer sum because a local pull
re-compresses the layers into the image store; the unpacked figures for the
pulled rows are byte identical to the registry ones.

Startup is variable: repeated runs on the same image span roughly 3.0-3.7 s, so
treat "about 3-4 s to first healthy response" as the baseline rather than the
last two digits. The script polls well below a second, because a 1 s sleep
quantises the result and can make the same boot look a second slower.

The source rebuild ran from the integration HEAD (`ee904d4`, identical
`Dockerfile` to the `v0.4.5` base). It landed ~1.3% larger unpacked for `slim`
and ~1.2% for `full`, which is the drift the floating inputs below describe. It
is a fresh measurement of the current source, not a byte-identical reproduction
of `v0.4.5`.

The amd64 baseline is complete: registry compressed/unpacked totals, artifact
digests, and native startup times are all recorded above. No arm64 work is
outstanding, because arm64 is not part of this effort's evidence.

## Known Floating Inputs

Do not describe the transitional `slim`/`full` builds as reproducible, and do
not treat a fresh source build as byte-identical to the published `v0.4.5`
artifacts. The following inputs float and can change without a source commit:

| Input | Where | Drift |
| --- | --- | --- |
| `node:24-trixie-slim` base tag | `Dockerfile` `NODE_IMAGE` | mutable tag |
| Debian apt packages | `Dockerfile` `apt-get install` | archive updates |
| `gh` | GitHub CLI apt repo | deliberately unpinned, floor asserted only |
| Cursor installer | `curl https://cursor.com/install` | unversioned |
| Rust toolchain | `RUST_VERSION=stable` | rolling |
| Bun | `curl https://bun.sh/install` | unversioned |
| Deno | `curl https://deno.land/install.sh` | unversioned |
| uv | `curl https://astral.sh/uv/install.sh` | unversioned |

T3 Code, Claude Code, Codex, OpenCode, Grok, and the browser MCP servers are
pinned in the `Dockerfile` and are checked for drift by
`scripts/bump-versions.sh --check`.

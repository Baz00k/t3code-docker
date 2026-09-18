# Immutable T3 Infrastructure

TM-03 deliverable. T3 Code and the setup service run under the image's own Node
against a root-owned T3 bundle; user-installed and baked tooling lives somewhere
writable, separately. This note records the paths, the one launcher every
administrative call goes through, the mutable npm prefix, and where user
initialization belongs.

The canonical product contract is
[`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md). The
provider matrix is
[`provider-audit.md`](./provider-audit.md).

## Paths

| Role | Path | Owner | Writable at runtime |
| --- | --- | --- | :---: |
| Image Node | `/usr/local/bin/node` | `root` | no |
| T3 bundle | `/opt/t3/lib/node_modules/t3/dist/bin.mjs` | `root` | no |
| Immutable launcher | `/usr/local/bin/t3-admin` | `root` | no |
| `t3` command | `/usr/local/bin/t3` (symlink to `t3-admin`) | `root` | no |
| Setup service | `/opt/t3-setup/server.mjs` (run by the image Node) | `root` | no |
| Mutable npm prefix | `/opt/npm-global` | `t3` | yes |
| Baked harnesses | `/opt/npm-global/bin` | `t3` | yes |
| Browser MCP servers | `/opt/npm-global/bin` | `t3` | yes |
| Baked Cursor | `/opt/cursor/.local/bin` | `t3` | yes |

`/usr/local/bin` precedes every npm prefix on `PATH`, so `t3` always resolves to
the launcher. The mutable prefix is deliberately not T3's prefix: the server is
image infrastructure, and a writable tree it shared with user packages could be
used to rewrite the server out from under itself.

## Launcher interface

`docker/bin/t3-admin` is the single resolution rule:

```sh
exec "$T3_INFRA_NODE" "$T3_INFRA_ENTRY" "$@"
```

with defaults `T3_INFRA_NODE=/usr/local/bin/node`,
`T3_INFRA_PREFIX=/opt/t3`, and
`T3_INFRA_ENTRY=${T3_INFRA_PREFIX}/lib/node_modules/t3/dist/bin.mjs`. It exits
`127` with a message if the Node binary or the bundle is missing, so a broken
image fails loudly instead of silently falling back to something on `PATH`.

Every administrative call goes through it or the `t3` symlink:

| Call site | Invocation |
| --- | --- |
| `docker/entrypoint.sh` | `"$T3_INFRA_LAUNCHER" project add ...`, `exec "$T3_INFRA_LAUNCHER" serve ...` |
| `docker/entrypoint.sh` | setup service under `"$T3_INFRA_NODE" /opt/t3-setup/server.mjs` |
| `docker/bin/t3-pair` | `"$T3_INFRA_LAUNCHER" auth pairing create ...` |
| `docker/bin/t3-login` | `"$T3_INFRA_LAUNCHER" connect` |
| `docker/bin/t3-doctor` | `"$T3_INFRA_LAUNCHER" --version` |
| `docker/setup/server.mjs` | `run(T3_LAUNCHER, ...)` with `T3_LAUNCHER` defaulting to `/usr/local/bin/t3-admin` |

`T3_INFRA_NODE`, `T3_INFRA_PREFIX`, `T3_INFRA_ENTRY`, and `T3_INFRA_LAUNCHER` are
overridable so `scripts/test-infrastructure.sh` can point at a fixture - and so
the launcher itself is testable - but the image sets sane immutable defaults.

The npm-generated `#!/usr/bin/env node` bin shim under `/opt/t3/bin` is **not**
on `PATH` and must not be used by any runtime path: `env node` is exactly the
shebang that reintroduces whatever a project or mise put first on `PATH`.

## Mutable npm prefix

`/opt/npm-global` is the writable prefix for the browser MCP servers and plain
`npm i -g` by the unprivileged user. It is configured through the user's own
npm config rather than a process-wide variable:

```text
/home/t3/.npmrc   ->   prefix=/opt/npm-global
```

`NPM_CONFIG_PREFIX` is no longer set in the image environment, so:

- `npm i -g` as `t3` (including a bare `docker exec -u t3 npm i -g ...`) installs
  into `/opt/npm-global`, which the user owns;
- `npm i -g` as `root` keeps npm's own root-owned system prefix `/usr/local` and
  creates no user-owned state;
- a project that changes its own `~/.npmrc` only ever redirects its own installs,
  never the T3 installation.

T3 Code's provider updater is deliberately not used for managed harnesses:
they install through mise, and their resolved paths are manual-only in the
provider audit, so T3's update action cannot fight the manager (see
[`provider-audit.md`](./provider-audit.md)).

## User initialization hook

Two mechanisms, one rule - user tool state is never in the image environment:

- `docker/user-env.sh` installs to `/etc/profile.d/t3-user-env.sh`. It returns
  early for uid 0 and otherwise sets `GOPATH=/home/t3/go` and prepends
  `${GOPATH}/bin` to `PATH`. The entrypoint sources it before launching
  anything, and login shells get it from `/etc/profile.d`.
- `/home/t3/.npmrc` (`prefix=/opt/npm-global`) covers npm, which does not need a
  shell. Docker sets `HOME=/home/t3` for `docker exec -u t3`, and `gosu` sets it
  for the server, so it applies to every npm invocation by the user.

This is why `GOPATH` and `/home/t3/go/bin` are not image-wide `ENV`: root's
`go install` then uses `/root/go`, and a binary the t3 user drops in their Go
bin directory is not resolvable by root.

Future user-only tool environment - mise activation, additional `PATH`
entries - belongs in the same hook. It must never be exported process-wide:
root's default `HOME` and `PATH` stay free of user-controlled tools.

## Root isolation

- root `HOME` is `/root`; root `PATH` contains no `/home/t3` entry;
- `NPM_CONFIG_PREFIX` is unset, so root npm uses `/usr/local`;
- the T3 tree and the image Node are root-owned and not group/other writable;
  the `t3` user cannot write them.

## Verification

```sh
scripts/test-infrastructure.sh t3code:core
scripts/test-infrastructure.sh t3code:browser
scripts/smoke-test.sh t3code:core
scripts/smoke-test.sh t3code:browser
```

`test-infrastructure.sh` covers:

- `t3` resolves to `/usr/local/bin/t3`, which is the immutable launcher, and the
  immutable bundle is present with no `t3` under the mutable prefix;
- decoy `node`/`t3`/`t3-admin` come first on `PATH`: a bare command is shadowed,
  but `t3-admin`, `t3`, and `t3-pair` still succeed and execute no decoy;
- the running server and setup service processes are `/usr/local/bin/node` with
  the immutable bundle on their command line, including a server started under
  the shadowed `PATH`;
- the `t3` user cannot write the T3 prefix, the entry module, the image Node, or
  `/usr/local/lib/node_modules`, and nothing under `/opt/t3` is group/other
  writable;
- a user npm global install from a local tarball succeeds into
  `/opt/npm-global`, runs, and leaves the T3 tree byte-identical;
- root has no `NPM_CONFIG_PREFIX`, keeps the `/usr/local` prefix, `HOME=/root`,
  and no user directory on `PATH`.

## Handoff to dependent tasks

- **TM-04 (mise):** persistent user paths live under `/home/t3`; add their
  activation to the user initialization hook, never process-wide.
- **TM-06/TM-07 (harness manager):** managed executables resolve to concrete
  absolute paths under the user home and are passed to T3 as
  `<Provider>Settings.binaryPath`; the launcher and mutable prefix here are
  unchanged by that.
- **TM-13 (product switch):** the baked harness set and the Cursor vendor
  installer were removed with the `slim`/`full` targets; only the immutable T3
  infrastructure described above ships now.

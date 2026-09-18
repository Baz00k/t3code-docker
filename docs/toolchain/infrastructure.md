# Immutable T3 Infrastructure

T3 Code runs as a root-owned native
platform binary, while the setup service runs under the image's own Node;
user-installed tooling lives somewhere writable, separately. This note records
the paths, the one launcher every
administrative call goes through, the mutable npm prefix, and where user
initialization belongs.

The image contract is [`image-contract.md`](./image-contract.md). The provider
matrix is
[`provider-contract.md`](./provider-contract.md).

## Paths

| Role | Path | Owner | Writable at runtime |
| --- | --- | --- | :---: |
| Image Node | `/usr/local/bin/node` | `root` | no |
| T3 platform binary | `/opt/t3/t3` | `root` | no |
| T3 client assets | `/opt/t3/client` | `root` | no |
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
exec "$T3_INFRA_BINARY" "$@"
```

with defaults `T3_INFRA_PREFIX=/opt/t3` and
`T3_INFRA_BINARY=${T3_INFRA_PREFIX}/t3`. It exits
`127` with a message if the platform binary is missing, so a broken
image fails loudly instead of silently falling back to something on `PATH`.
`T3_INFRA_NODE=/usr/local/bin/node` remains the absolute runtime for setup and
the image's own JavaScript helpers; it is no longer T3's runtime.

Every administrative call goes through it or the `t3` symlink:

| Call site | Invocation |
| --- | --- |
| `docker/entrypoint.sh` | `"$T3_INFRA_LAUNCHER" project add ...`, `exec "$T3_INFRA_LAUNCHER" serve ...` |
| `docker/entrypoint.sh` | setup service under `"$T3_INFRA_NODE" /opt/t3-setup/server.mjs` |
| `docker/bin/t3-pair` | `"$T3_INFRA_LAUNCHER" auth pairing create ...` |
| `docker/bin/t3-login` | `"$T3_INFRA_LAUNCHER" connect` |
| `docker/bin/t3-doctor` | `"$T3_INFRA_LAUNCHER" --version` |
| `docker/setup/server.mjs` | `run(T3_LAUNCHER, ...)` with `T3_LAUNCHER` defaulting to `/usr/local/bin/t3-admin` |

`T3_INFRA_NODE`, `T3_INFRA_PREFIX`, `T3_INFRA_BINARY`, and `T3_INFRA_LAUNCHER` are
overridable so `scripts/test-infrastructure.sh` can point at a fixture - and so
the launcher itself is testable - but the image sets sane immutable defaults.

The tiny `t3` npm launcher's `#!/usr/bin/env node` shim is not installed. The
image installs `@t3code/t3-linux-{x64,arm64}` explicitly and flattens the
matching package into `/opt/t3`, preserving its executable, native modules,
resource monitor, and patchable `client/index.html` together.

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
they install through mise, and the four non-Cursor providers resolve to
manual-only updates for mise-owned paths, so T3's update action cannot fight the
manager. Cursor's accepted self-update exception is documented in
[`provider-contract.md`](./provider-contract.md).

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
- the T3 tree, platform binary, and image Node are root-owned and not
  group/other writable;
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
  immutable platform binary is present with no `t3` under the mutable prefix;
- decoy `node`/`t3`/`t3-admin` come first on `PATH`: a bare command is shadowed,
  but `t3-admin`, `t3`, and `t3-pair` still succeed and execute no decoy;
- the running server is `/opt/t3/t3`, while setup is `/usr/local/bin/node`; the
  same remains true for a server started under the shadowed `PATH`;
- the `t3` user cannot write the T3 prefix, platform binary, image Node, or
  `/usr/local/lib/node_modules`, and nothing under `/opt/t3` is group/other
  writable;
- a user npm global install from a local tarball succeeds into
  `/opt/npm-global`, runs, and leaves the T3 tree byte-identical;
- root has no `NPM_CONFIG_PREFIX`, keeps the `/usr/local` prefix, `HOME=/root`,
  and no user directory on `PATH`.

Persistent user paths are activated only through the user initialization hook,
never process-wide. Managed harnesses resolve to concrete absolute paths under
the user home and are passed to T3 through provider `binaryPath` settings. No
baked harness or Cursor vendor installer is part of the immutable infrastructure.

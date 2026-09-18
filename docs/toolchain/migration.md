# Migration: `slim`/`full` To `core`/`browser`

The image moved to its final product shape:

| Before | After |
| --- | --- |
| `slim` (baked harnesses, no toolchains) | removed; historical artifacts remain, no updates |
| `full` (default: baked harnesses + toolchains + browser) | removed; historical artifacts remain, no updates |
| `latest` → `full` | `latest` → `core` |
| Compose default target `full` | Compose default target `core` |
| Agent harnesses baked into the image | installed on demand through the setup UI or `t3-harness`, into the persistent home |
| Go, Rust, Bun, Deno, uv, and project language versions baked | installed by [mise](https://mise.jdx.dev/) on demand, into the persistent home |
| Chromium/fonts/MCP only in `full` | Chromium/fonts/MCP in `browser` |

The two targets that still exist:

- **`core`** (`latest`) — default. No baked harness executables, no baked
  language runtimes, no browser.
- **`browser`** — `core` plus headless Chromium, fonts, and both browser MCP
  servers.

Published images are multi-arch (`linux/amd64`, `linux/arm64`). The historical
`slim` and `full` tags are not deleted and keep their last artifacts, but they
stop receiving updates.

## Updating an existing deployment

1. Set the image and build target in `.env` (the old names are no longer built):

   ```sh
   T3_IMAGE=ghcr.io/<owner>/t3code-docker:latest   # `core`
   T3_BUILD_TARGET=core                            # or `browser`
   ```

   `docker compose up -d` on an unchanged `.env` would reference `t3code:full`
   and fail to build; update both variables before recreating.

2. Recreate the container. T3 state, credentials, threads, and projects are
   untouched: they live on the `/home/t3` volume and in `/workspace`.

3. Install the agent harnesses you use. They are no longer in the image; the
   setup page's **Agents** card and the `t3-harness` CLI install, update, and
   uninstall them:

   ```sh
   docker compose exec -u t3 t3code t3-harness list
   docker compose exec -u t3 t3code t3-harness install claude
   docker compose exec -u t3 t3code t3-harness install codex
   ```

   Install resolves the latest available version, records the exact resolved
   version, and places the executable under
   `/home/t3/.local/share/mise/installs/`. T3 is pointed at that managed
   executable, so its own "update provider" action stays manual-only instead of
   fighting mise.

4. Install project toolchains where you need them. Nothing installs or updates
   during ordinary command invocation; the explicit boundaries are:

   ```sh
   docker compose exec -u t3 t3code mise install     # in a project with mise.toml/.tool-versions
   docker compose exec -u t3 t3code mise exec -- node --version
   docker compose exec -u t3 t3code mise run <task>
   ```

   Interactive T3 terminals get mise activation automatically. A raw
   `docker exec -u t3 t3code <tool>` that bypasses mise is not promised to
   select a project toolchain.

## Whole-home persistence

The `/home/t3` volume is the unit of durability. Installed tools, harness
executables, mise selections, trust state, credentials, and shell history all
live under it.

| Mounted | Keeps on recreate | Loses on recreate |
| --- | --- | --- |
| `/home/t3` (whole home) | everything above | — |
| `/home/t3/.t3` only | T3 state, threads, credentials | installed tools, harness executables, mise global selections, trust state |

The compose file mounts the whole home as the `t3-home` named volume, so the
default deployment is durable. If you mounted only `.t3`, switch to the whole
home (or a host directory) before relying on installed harnesses: otherwise the
next recreate silently removes every tool you installed. `t3-doctor` reports the
observed mount layout and warns when the tools mount is not durable.

The image still declares `VOLUME /home/t3`, so a container run with no `-v`
gets an anonymous volume: it survives a restart, but a recreate makes a fresh
one and every installed tool, sign-in, thread, and project goes with the old
one. The entrypoint prints a warning for exactly this case.

## Exact versions

- **Harnesses.** Install resolves the latest available version and records the
  exact version. `t3-harness update <id>` and the UI's Update action are the
  only ways a managed harness moves. Status polling, T3 provider discovery, and
  session launch never install or update. Uninstall removes the selection and
  executable but keeps credentials and user data.
- **Cursor is the deliberate exception.** Its CLI is its own updater, so a
  managed Cursor can move past the version recorded at install time; the
  recorded version is advisory, not a lock.
- **Project tools.** Project declarations (`mise.toml`, `.tool-versions`,
  idiomatic files) select versions; `mise.lock` improves reproducibility, but it
  is resolution and verification metadata, not an offline artifact store.
- **Personal global tools.** Resolve the exact version before setting a global
  selection with the pinned mise release; the image never updates them on its
  own.

## Rollback

Rolling back is pinning the image back to the last pre-switch artifact and
recreating; the data does not move or downgrade.

1. Before upgrading, record the digest you are running and keep it:

   ```sh
   docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/<owner>/t3code-docker:latest
   ```

2. To roll back, set `T3_IMAGE` to that digest (or to a historical
   `:<version>` / `:slim` / `:full` tag) and recreate:

   ```sh
   T3_IMAGE=ghcr.io/<owner>/t3code-docker@sha256:<recorded>
   ```

   Historical `slim`/`full` artifacts remain pullable and are the rollback
   target. They are no longer built or updated by this repository, so a rollback
   that needs a rebuild would require reverting the product-switch commit.

3. The home volume is preserved across the rollback. Managed tools installed
   under `/home/t3/.local/share/mise`, credentials, and T3 state are all still
   there; the old image does not see mise-managed harnesses as its providers
   (its providers are the baked ones), so expect to sign in to the providers the
   old image discovers. Going forward again reuses the managed installs.

4. Do not delete or re-create the `t3-home` volume as part of a rollback. If the
   volume is lost, every installed tool, sign-in, thread, and project goes with
   it.

## Compatibility notes

- **Old `slim`/`full` command defaults are gone.** `scripts/build.sh` rejects
  both targets; `core` is the default. The same applies to the capability
  scripts (`--variant core|browser`).
- **No language compatibility image remains.** Old `full` users who relied on
  baked Go/Rust/Bun/Deno/uv install them through mise, per project. The
  representative set the runtime matrix verifies is Go, Rust (with `clippy` and
  `rustfmt`), Bun, Deno, uv, Node, and Python.
- **No undeclared global command stubs ship.** Nothing intercepts a command that
  bypasses mise.
- **The `browser` target is the only one with Chromium.** Use it for
  `t3-browser-mcp` and page-driving MCP servers.
- **Sizes shrink.** Compared with the historical published baselines, `core` is
  materially smaller than `slim` while carrying the non-browser OS union, and
  `browser` is materially smaller than `full` while carrying
  Chromium/fonts/MCP. Measured numbers are in
  [`image-contract.md`](./image-contract.md).

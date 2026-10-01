# Minimum mise infrastructure boundary

Evidence for #22, October 1, 2026; static inspection, not an approved implementation.
**U** = upstream `16e59c7f21e43698ee9efbdcc2827b619c97e64d`;
**D** = donor `0fd91c73a06e8bbef459f88d22ec03df2b279b2d`.
References `U/D path:lines` identify those exact Git objects. Captured planning
context is `docs/research/review-split-context.md:3–17` at `9a75443`.

## Observed facts

1. **The version/platform transition is already upstream.** U `Dockerfile:142–163`
   installs T3 0.0.44 with the harnesses globally, then gives the entire
   `/opt/npm-global` tree to t3. U `docker/t3-client/patch.mjs:15–39` and
   `scripts/smoke-test.sh:84–92` already handle nested/hoisted platform packages.
   T3's 0.0.44 source separates a Node forwarding launcher from a self-contained
   platform executable; the package includes client assets and native dependencies
   ([E6], lines 3–20, 91–119, 171–206). Do not resurrect the old ESM-server migration.

2. **Runtime selection remains PATH-dependent.** U `docker/entrypoint.sh:100–117,
   200–225,266–270` invokes bare `t3` for registration/server and bare `node` for
   setup/key generation. Setup invokes `run("t3", …)` with inherited environment
   (`docker/setup/server.mjs:73–78`); pairing, Connect login and diagnostics also
   resolve names (`docker/bin/t3-pair:62–66`, `docker/bin/t3-login:37–58`, `docker/bin/t3-doctor:18–30`).
   An absolute npm launcher pathname alone still leaves its `env node` interpreter
   PATH-dependent ([E6]:195–206).

3. **Root exposure predates mise.** U `Dockerfile:128–132,168–181,249–274`
   exports one npm prefix for both identities and places mutable npm, Cursor,
   home Go binaries and writable Cargo directories on image PATH. The entrypoint
   drops privileges, but independent root execs are explicitly acknowledged
   (`docker/bin/t3-pair:11–16`). D moves npm prefix selection into user `.npmrc`
   (`Dockerfile:139–146`), but still exports `/opt/npm-global/bin` image-wide
   (`:136–137`): its blanket root-PATH isolation claim is not established.
   npm reads `$HOME/.npmrc`; project `.npmrc` is ignored for `npm install -g`
   ([E5], “Per-project”/“Per-user config file”).

4. **Activation is launch-surface-specific.** D sources a non-root fragment in
   the entrypoint (`docker/entrypoint.sh:166–173`); the fragment prepends shims and
   activates only interactive Bash (`docker/user-env.sh:13–54`). Installation in
   `/etc/profile.d` does not establish interactive non-login Bash coverage.
   Independent execs do not source this fragment or inherit entrypoint exports
   (D `docker/bin/t3-doctor:19–27`; U `docker/entrypoint.sh:211–214`). Thus bare
   `docker exec -u t3 … node` is not proven project-aware.

5. **Persistence and writability are separate.** U `compose.yaml:37–41` mounts
   the whole named home; U `Dockerfile:210` declares a home volume, anonymous
   without an explicit mount (`docker/entrypoint.sh:148–183`).
   Credential symlinks cover selected agents only (`docker/entrypoint.sh:126–145`),
   not mise directories. A state-only mount therefore does not persist home-based
   mise across recreation. Existing homes obscure image-seeded `.npmrc`/startup
   files. D names four home trees for config/data/state/cache
   (`docker/user-env.sh:32–36`); current docs explain config/data/cache discovery
   ([E2], “Environment variables”).

6. **Ownership recovery has limits.** U `docker/entrypoint.sh:25–64` remaps IDs,
   conditionally traverses home/state, and changes only workspace-root ownership;
   `:81–93` diagnoses direct-user state failure. It does not remap the separately
   owned `/opt/npm-global`/Cursor trees. Top-directory writability cannot prove
   every nested tool/cache file is writable or repair interrupted remaps. D adds
   retry intent, but root redirects into predictable `.ownership-migration.tmp`
   inside user-controlled state (`docker/entrypoint.sh:34–49,60–65,84–123`): that
   donor marker is not a safe drop-in guarantee against symlink substitution.

## Minimum alternatives — recommendations, not decisions

**Separate selection from integrity.** Fixed image Node plus an absolute T3
launcher at every infrastructure call site prevents project runtime selection;
leaving the target in the writable global prefix does **not** prevent replacement.
For an integrity boundary, protect the launcher, executable, assets/dependencies
and ancestor directories from t3 writes. Two narrow alternatives are:

- Keep the 0.0.44 npm launcher/package layout in a **dedicated protected prefix**,
  explicitly execute it with `/usr/local/bin/node`, and leave harness/user globals
  elsewhere. No flattening/native-package migration is required ([E6]).
- Execute the protected **platform binary directly**, retaining its accompanying
  tree; D `Dockerfile:220–253`, `docker/bin/t3-admin:15–23` demonstrate this shape.
  Adapt only path-dependent patch/floor lookups, not the already-completed upgrade.

Both require absolute setup Node and administrative dispatch. D demonstrates
those changes (`docker/entrypoint.sh:183–192,303–324,366–370`,
`docker/setup/server.mjs:78–87`), but its launcher still uses `#!/usr/bin/env bash`
(`docker/bin/t3-admin:1`) and accepts environment overrides (`:15–16`). Guarantees
therefore require fixed interpreters/launch settings, not merely absolute wrapper
names. These are PATH-selection/file-integrity guarantees, not a sandbox against
same-UID access to credentials/state, privileged mounts, or operator root access.

**Keep project tools user-scoped.** Install mise itself as protected infrastructure;
keep its writable trees under the intended persistent user home, with root's
HOME/npm configuration/PATH separate. Remove mutable directories from privileged
PATH, not just move npm configuration. Per-user `.npmrc` or explicit user-command
prefix options are alternatives; preserve existing `.npmrc` and account for reused
homes. Retained `/opt` user installs need UID-remap handling; home-based installs
need actual persistent mounts. Check required nested directories, not only `.t3`.
These follow the ownership/exposure observations above, not a new volume policy.

**Specify shell versus exec integration.** Interactive startup hooks, inherited
shims for server-launched commands, and explicit unprivileged
`/usr/local/bin/mise exec -- command` for non-interactive/direct-exec paths are
alternatives with different coverage ([E1], [E3]:14–27,63–72; [E4]:23–32).
`mise exec node@VERSION` still loads other project tools: it is not infrastructure
isolation ([E4]:28–30). Never activate/execute project toolchains in the privileged
ownership phase. D pins 2026.9.10 (`Dockerfile:165–193`); that release's full
activation can remove manually prepended shims unless `activate_shims` and
`not_found_auto_install` both permit retention ([E3]:176–181). Validate the chosen pin's actual shell output;
current docs alone cannot guarantee combined hook/shim behavior.

## Unnecessary migration; remaining limitations

Keep full/slim, their bundled tools and pins. Harness lifecycle management,
provider synchronization, lean/default changes, and comprehensive relocation of
bundled languages are not prerequisites (U `Dockerfile:5–8,142–181,247–308`).
Project-less bundled-command availability still needs verification after PATH
changes; direct PATH execution is not automatically governed by mise settings.
System config is defaults, not an immutable security boundary ([E2], hierarchy;
D `docker/mise/config.toml:3–6`). Trust, missing-tool/fallback policy and delivery
architecture remain undecided. No builds, runtime/UID fault-injection, or shell
activation tests were run; donor comments are not test evidence.

## External first-party references (six; consulted October 1, 2026)

- [E1: mise development tools, activation/exec](https://mise.jdx.dev/dev-tools/).
- [E2: mise configuration, hierarchy/environment](https://mise.jdx.dev/configuration.html).
- [E3: pinned mise 2026.9.10 activation source](https://github.com/jdx/mise/blob/v2026.9.10/src/cli/activate.rs).
- [E4: pinned mise 2026.9.10 exec source](https://github.com/jdx/mise/blob/v2026.9.10/src/cli/exec.rs).
- [E5: npm v11 npmrc configuration](https://docs.npmjs.com/cli/v11/configuring-npm/npmrc/).
- [E6: T3 0.0.44 package/launcher source](https://github.com/pingdotgg/t3code/blob/v0.0.44/scripts/build-npm-platform-packages.ts).

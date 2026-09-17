# Harness Lifecycle UI and CLI

TM-08 deliverable. The existing Agents card and the noninteractive
`t3-harness` CLI expose the same managed Install, Update, Uninstall, and
status behavior over the one shared harness manager (TM-06). T3 learns about
a new selection through one provider-integration `sync()` (TM-07), never a
second settings writer.

Companion verification:

```sh
node scripts/harness-ui-audit.js                              # 19 static checks
node scripts/harness-ui-audit.js http://127.0.0.1:13778 KEY   # plus live schema
scripts/test-harness-surfaces.sh t3code:slim                  # container assertions
```

The manager API is in [`harness-api.md`](./harness-api.md); the T3 seam is in
[`provider-integration.md`](./provider-integration.md); the offline budgets
are in [`offline.md`](./offline.md) (TM-09). The canonical product contract
is [`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md).

## Routes

All lifecycle routes live under the same setup auth and prefix inference as
the rest of the console: the page sends the `t3setup` cookie, in-container
CLIs send `x-t3-setup-key`, and `/__setup/harnesses` answers the same JSON as
`/harnesses`. Unauthenticated reads and mutations return `401`.

| Method | Route | Meaning |
| --- | --- | --- |
| `GET` | `/harnesses` | Read-only managed facts for all five harnesses. |
| `GET` | `/harnesses?id=<id>` | Read-only facts for one harness. |
| `GET` | `/harnesses?authenticate=false` | Skip sign-in probes; one `mise ls` plus filesystem checks. |
| `POST` | `/harnesses/install` | Install a harness (latest unless `version` is given). |
| `POST` | `/harnesses/update` | Update an installed harness (latest unless `version` is given). |
| `POST` | `/harnesses/uninstall` | Remove the managed selection and executables. |

`GET /status` keeps its shape and now carries the same enriched harness
entries, so the Agents card renders from the poll it already makes.

### Schemas

`GET /harnesses` returns `{ harnesses, degraded }`. Each entry is the
manager's facts plus the sign-in affordances the card needs:

```json
{
  "id": "claude",
  "name": "Claude Code",
  "installed": true,
  "runnable": true,
  "signedIn": true,
  "version": "2.1.270",
  "installedVersion": "2.1.270",
  "recordedVersion": "2.1.270",
  "verifiedVersion": "2.1.270",
  "configuredVersion": "2.1.270",
  "executable": "/home/t3/.local/share/mise/installs/claude/2.1.270/claude",
  "configured": true,
  "minimumVersion": null,
  "minimumSatisfied": null,
  "supported": true,
  "failed": false,
  "failure": null,
  "operation": null,
  "operationState": "ok",
  "inProgress": false,
  "managedVersions": ["2.1.270"],
  "bakedFallback": { "present": true, "executable": "/opt/npm-global/bin/claude", "version": null },
  "credentialsPresent": false,
  "canSignIn": true,
  "canSetKey": false,
  "keyKind": null
}
```

`version` is `installedVersion ?? recordedVersion ?? null`: the exact version
the card shows. `signedIn` is `true`, `false`, or `null` (not readable) from
the manager's bounded probe of the managed executable. `bakedFallback`
reports the transitional baked binary; `present: true` means Uninstall must
not claim the provider is absent. `operation`/`operationState`/`inProgress`
describe the last or live operation; `failed`/`failure` carry the
interrupted, failed, or below-minimum reason.

Mutations take `{ id, version? }` (`version` omitted means latest) and return
`{ ok, code, error?, harness, sync? }`:

```json
{ "ok": true, "code": "ok", "harness": { "...": "..." }, "sync": { "ok": true, "applied": [], "cleared": [] } }
```

`code` is the manager's code: `ok`, `unknown-harness`, `unsupported-arch`,
`busy`, `lock-error`, `invalid-version`, `version-below-minimum`,
`not-runnable`, `not-installed`, `failed`. HTTP status mirrors it: `200` ok,
`404` unknown harness, `409` busy, `400` bad version / not installed /
unsupported arch, `500` anything else. `sync` is the provider-integration
report (or its error); a failed sync never fails the operation itself.

Long operations outlive HTTP requests: mise installs take minutes. Clients
poll `GET /harnesses` (or `/status`) for `inProgress` rather than holding one
request, and auth status is never inferred from install success.

## CLI contract

```sh
t3-harness list [--json]
t3-harness status [--json] [id]
t3-harness install <id> [--version <version>] [--json]
t3-harness update <id> [--version <version>] [--json]
t3-harness uninstall <id> [--json]
```

`id` is one of `claude`, `codex`, `opencode`, `grok`, `cursor`. Without
`--json`, `list`/`status` print `id<TAB>version<TAB>state` lines and mutations
print one summary line; with `--json`, the same objects the UI receives are
printed. `--version` only applies to `install`/`update`.

Exit codes: `0` ok; `1` the lifecycle operation failed (the JSON `error`
names the manager `code`); `2` usage (bad args, unknown harness id);
`4` the manager module could not load. A busy lock exits `1` with
`code: busy`, matching the UI's `409`.

The CLI drops privileges (`gosu t3` when started as root) and sources
`/etc/profile.d/t3-user-env.sh`, so it sees the same `MISE_*` paths the
server does and leaves `t3`-owned state. `T3_HARNESS_MODULE`,
`T3_PROVIDER_MODULE`, and `T3_INFRA_NODE` override the baked paths for tests.

## Lifecycle notifications

After every successful Install/Update/Uninstall, both surfaces call
`createProviderIntegration({ harness }).sync()` from
`/opt/t3-provider/index.mjs` (overridable via `T3_PROVIDER_MODULE`). T3
watches its settings file live, so the new `binaryPath` reaches a running
server without a restart and applies to new provider sessions; in-flight
sessions keep the executable they launched with. `sync` retracts only values
it previously wrote, so a user-edited `binaryPath` survives. `status`,
`resolve`, and every poll never install or update.

## UI polling state

The console polls `/status` every 15s and `/ports` every 4s. The Agents card
additionally:

- renders `inProgress`/`operationState` as Installing…/Updating…/Removing…,
  `failed`/`failure` inline, `runnable` plus `signedIn`, and the baked
  fallback whenever the managed harness is absent;
- keeps explicit version drafts in a map across re-renders, so the poll does
  not wipe a version mid-typing;
- tracks in-flight POSTs in a busy set and disables the row while the server
  reports `inProgress`, so polling never erases an operation;
- leaves sign-in and API-key panels alone while one is open (`panelActive`),
  exactly as before, and clears the manager's auth cache (`invalidateAuth`)
  after every sign-in or key save so the next poll re-probes.

Sign-in and the Codex stdin key flow run through the managed executable when
one is runnable, falling back to the baked binary otherwise, so credentials
land where the executable T3 launches reads them.

## Out of scope

Setup wizard or redesign (none added); offline cache budgets and freshness
(TM-09 owns `/status`/`/providers` under `--network none`).

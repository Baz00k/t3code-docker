# Offline-Safe Setup Status

Under `--network none`, authenticated `/status` and
`/providers` each complete within five seconds from bundled or cached state,
without triggering installs or updates.

Companion verification:

```sh
node --test tests/setup-cache.test.mjs   # 21 unit tests
scripts/test-offline.sh t3code:core      # container assertions, --network none
```

The manager API is in [`harness-api.md`](./harness-api.md); the lifecycle
routes are in [`harness-usage.md`](./harness-usage.md); the T3 seam is in
[`provider-integration.md`](./provider-integration.md). The canonical product
contract is [`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md).

## Strategy

Serve immediately, refresh asynchronously, deduplicate concurrent work:

- Every sub-read on these paths is local or bounded. The only network fetch
  (the OpenCode provider catalogue) never blocks a response; it runs only as
  a background refresh.
- Authenticated harness facts race one coalesced refresh against a 4 s
  budget. When the budget loses, the endpoint answers from local state and
  the refresh keeps running so the next poll is warm.
- One refresh at a time per source. Concurrent polls share the in-flight
  promise; a harness refresh starts at most every 15 s and a catalogue fetch
  at most every 60 s, so background work cannot accumulate no matter how
  tightly clients poll.
- The cache helpers live in `docker/setup/cache.mjs` (no dependencies,
  injectable clocks and filesystems) and are unit-tested without a container.

## Schemas

Both endpoints keep the fields older clients read and add one freshness
object each.

`GET /status` adds `harnessCache`:

```json
{
  "harnesses": ["... five managed facts, as before ..."],
  "harnessCache": { "at": 1750000000000, "stale": false, "source": "live", "refreshing": false },
  "pairings": [],
  "sessions": [],
  "degraded": []
}
```

`GET /providers` adds `cache`:

```json
{
  "providers": [{ "id": "anthropic", "name": "Anthropic" }],
  "configured": ["anthropic"],
  "cache": { "at": 1750000000000, "stale": false, "source": "live", "refreshing": false }
}
```

### Freshness fields

| Field | Meaning |
| --- | --- |
| `at` | When the served data was produced (`null` for bundled/local-only answers). |
| `stale` | The data is usable but not fresh. A stale `signedIn` is the last definite verdict, never a fresh claim. |
| `source` | Where the data came from (below). |
| `refreshing` | A background refresh is in flight; the next poll is likely warmer. |

Harness sources: `live` (the authenticated refresh completed on this
request), `cache` (last authenticated facts, stale by age past 30 s),
`cheap` (local-only `authenticate: false` read: one `mise ls` plus
filesystem checks), `unavailable` (even the cheap read failed; harnesses are
empty and `degraded` says why).

Provider sources: `live` (fetched from models.dev within the 24 h TTL),
`disk` (the `$T3CODE_HOME/setup/providers.json` cache, served even when
stale), `bundled` (the 15-entry fallback for a container that never reached
the network).

`GET /harnesses` carries the same `harnessCache` object; `?authenticate=false`
polls answer `cheap` directly without starting an auth refresh.

## Refresh scheduling

| Source | Trigger | Interval gate |
| --- | --- | --- |
| Harness authenticated facts | any `/status` or authenticated `/harnesses` | at most one refresh per 15 s, shared by concurrent polls |
| Provider catalogue | any `/providers` serving stale/bundled data | at most one fetch per 60 s, shared by concurrent polls |

A cold offline `/status` serves cheap local facts (installed, runnable, exact
versions, no baked fallback) with auth unknown (`signedIn: null` where nothing
was ever probed, else the last definite verdict via the existing `stableAuth`
mapping, marked stale). A warm server serves its last authenticated facts.
Either way the in-flight refresh lands in the background and the following
poll (the console polls every 15 s) picks it up.

## Latency

Measured with `--network none` by `scripts/test-offline.sh` (cold and warm
cache, plus ten concurrent polls):

| Endpoint | Budget | Typical offline |
| --- | --- | --- |
| `GET /status` (authenticated) | < 5 s | local reads plus at most a 4 s harness race |
| `GET /providers` (authenticated) | < 5 s | milliseconds: memory, one file read, or the bundled list |
| `GET /harnesses` | < 5 s | same harness race as `/status` |

The legs inside `/status` are bounded individually: T3 health 3 s
(localhost), harness snapshot 4 s, pairing/session lists 4 s each (local
SQLite reads with a backstop for a locked database). They run in parallel,
so the whole stays inside five seconds.

## What offline does and does not cover

Stays responsive offline: T3 and setup health, local project registration,
pairing/session inspection, cached harness and provider status, and the
footer paths. Polling any of these never installs or updates a tool or
harness: the manager reads run with `MISE_AUTO_INSTALL=false`, and the
container test diffs `mise ls`, the mise config, and the manager state
before and after polling.

Explicitly not offline-capable, and not claimed otherwise: provider
sign-in, first-time tool or harness downloads, tunnels and the public URL,
remote API checks (individual auth probes may report unknown until the
network returns), and anything behind `models.dev` beyond the bundled or
cached catalogue. A stale answer is always marked stale; missing credentialed
checks stay visible as `null`/degraded rather than reading as signed out.

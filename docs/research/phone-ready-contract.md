# Phone install-to-ready: evidence and options

**October 1, 2026 · research #24 · static, not verified usability.** No builds, browser/viewport sessions, lifecycle execution, credentialed sign-ins, or model calls. Read the [captured audit](pr-1-phone-install-readiness.md), then traced manager/cache internals. This is evidence, **not a final UX contract or human acceptance**.

## Source boundary

`M:path:lines` denotes upstream-main snapshot [`16e59c7f21e43698ee9efbdcc2827b619c97e64d`](https://github.com/dizys/t3code-docker/tree/16e59c7f21e43698ee9efbdcc2827b619c97e64d), inspected in `/tmp/t3-wayfinder-phone`; `D:path:lines` denotes donor [`0fd91c73a06e8bbef459f88d22ec03df2b279b2d`](https://github.com/dizys/t3code-docker/tree/0fd91c73a06e8bbef459f88d22ec03df2b279b2d), inspected in `/tmp/t3code-pr1-review`.

**Main has baked harnesses and browser authentication, but no browser Install/Update/Uninstall.** An absent harness has no action. Donor adds those actions for all five; blank version resolves `latest` to an exact pin, verifies `--version`, and attempts T3 settings synchronization. Its catalogue permits x64/arm64 and enforces OpenCode ≥1.14.19. These donor capabilities are not shipped-main behavior. Sources: `M:Dockerfile:139-156`, `M:docker/setup/app.js:347-379`; `D:docker/setup/app.js:407-489`, `D:docker/harness/catalogue.mjs:25-103`, `D:docker/harness/manager.mjs:205-249`.

The available donor sequence is unlock → Install → provider authentication → pair/open T3 → select/use its provider. Setup-key login, T3 device pairing, and provider login are separate authorizations. Pairing requires operator-configured `T3_PUBLIC_URL`; absent configuration is rejected, not repaired in-browser (`D:docker/setup/server.mjs:475-493,1190-1209`; `D:docker/setup/app.js:246-290,550-562`).

## Five-provider capability/readiness table

All donor authentication controls require a runnable, non-busy harness. Shared browser UI supplies **Open**, code entry where needed, polling, and cancellation (`D:docker/setup/app.js:429-435,867-956`).

| Harness | Browser path after installation | What the status proves; missing boundary |
|---|---|---|
| Claude Code | Backend runs `auth login`; browser approval and pasted code. No Claude key-entry UI. | `auth status --json` reads `loggedIn`; nonempty configured Anthropic key/OAuth-token environment also yields true without validation. Account authorization/model access remains untested. |
| Codex | Device-code approval, or key pasted into setup and sent to `login --with-api-key`. | `login status` text, not a successful turn. Device login must be enabled personally/by workspace admin; managed policy can restrict login method/workspace [OA]. Official cache-copy/SSH-callback fallbacks are command-based, outside this boundary. |
| OpenCode | Choose model provider/custom ID and paste key; setup writes `~/.local/share/opencode/auth.json`. No subscription/OAuth setup flow. | Nonempty JSON object means “authenticated”; invalid/revoked keys can pass. Catalogue/configured-key lists do not prove model access. Custom endpoints/configuration and non-key authentication are not covered by this form [OC]. |
| Grok Build | Browser device approval through `login --device-auth`; no Grok key-entry UI. | `models` output patterns, or nonempty `XAI_API_KEY`, determine auth. Credential-file existence alone is insufficient; environment-key setup is outside browser UI. Entitlement/usable turn untested. |
| Cursor | Backend runs `cursor-agent login` with `NO_OPEN_BROWSER=1`; browser approval. No Cursor key-entry UI. | `status --format json` reads `isAuthenticated`; this does not establish T3 session/model usability. |

Exact shared sources: `D:docker/setup/server.mjs:511-527,565-589,693-734`; provider-specific verdicts: `D:docker/harness/probe.mjs:30-91`. Account-dependent evidence is still needed for **each claimed authentication mode**, including refusal, expired credentials, model availability and successful T3 use; no blanket plan compatibility is established.

**Five different facts:** credentials present = environment/file existence; authenticated = provider-specific true/false/null above; runnable = configured installed executable, no recorded failure/live operation; provider discovered = T3's own provider snapshot, **not** setup `/providers` (the OpenCode model catalogue); usable = successful intended T3 session/turn, not established here. Install verifies execution once; routine status checks executable presence. T3 separately probes provider snapshots and responds to settings changes [T3]. Sources: `D:docker/harness/manager.mjs:70-135,205-223`, `D:docker/setup/server.mjs:212-238,326-386,1259-1271`.

## Request/cache/failure boundaries

| Boundary | Actual source behavior and limitation |
|---|---|
| Lifecycle POST | **Synchronous:** route awaits manager, returned facts and sync; no 202/job ID. Comments claiming otherwise are not implementation. Install subprocess timeout is 15 minutes; other mise calls 120s, probes 20s. Client has no explicit fetch deadline. `D:docker/setup/server.mjs:1088-1128,1232-1239`; `D:docker/harness/manager.mjs:22-26,195-198`; `D:docker/setup/app.js:452-476`. |
| Transport/reload/duplicates | No request-disconnect cancellation hook; inference: backend work may finish after timeout/disconnect. Global file lock returns 409, not idempotent joining. Lock age ceiling is 15 minutes even with a live PID. Persistent last-operation state permits later status observation/interruption detection, not automatic resume. Page busy/errors/drafts vanish on reload; no lifecycle cancellation. `D:docker/harness/lock.mjs:32-94`, `D:docker/harness/state.mjs:12-49`, `D:docker/harness/manager.mjs:22-52,70-125,152-198`; `D:docker/setup/app.js:353-355,452-476`. |
| Failure/sync | Failed update records failure and suppresses `runnable` even if prior files remain; no rollback is implemented. Successful install can return top-level `ok:true` with `sync.ok:false`; UI ignores sync/harness details and toasts “Installed” even for Update. Sync can overwrite custom binary paths. `D:docker/harness/manager.mjs:84-115,186-198,228-249`; `D:docker/setup/server.mjs:1113-1128`; `D:docker/setup/app.js:463-469`; `D:docker/provider-integration/settings.mjs:45-68`. |
| Freshness | Auth probe cache 10s; snapshot refresh interval 15s/TTL 30s. Explicit key writes invalidate snapshot generations; lifecycle and OAuth completion do not. Warm lifecycle facts can lag; null auth preserves last definite verdict. Cold fallback can consume **two sequential 4s budgets** (full then cheap), so the commented five-second bound is not established. UI hides age and suspends all Agent rendering while an auth panel is active. `D:docker/harness/manager.mjs:51-53`; `D:docker/setup/server.mjs:173-205,259-271,625-674`; `D:docker/setup/cache.mjs:174-288,322-333`; `D:docker/setup/app.js:747-766,963`. |
| Prefix/auth | Browser-visible base, inferred route suffix, forwarded-prefix header/config override support prefixed routing. Key cookie/header guard precedes lifecycle/auth APIs; cookie is HttpOnly, SameSite=Strict, mount-scoped, 24h, without Secure. No proxy configuration or phone cookie behavior was tested. `D:docker/setup/app.js:22-54`; `D:docker/setup/server.mjs:1131-1209`. |

Sign-in IDs live only in server memory and browser closure: reload cannot rediscover/resume them; restart loses them. Awaiting-state deadline is 15 minutes; submitted-code deadline 90s. Sources: `D:docker/setup/server.mjs:555-558,640-681,1291-1311`; `D:docker/setup/app.js:880-956`.

## Current external constraints and recommendations

[CF] currently documents **125s default Proxy Read Timeout**, **30s non-adjustable Proxy Write Timeout**, and Enterprise read-timeout increases up to 6,000s—not the review's 100s. These are proxy/request limits, not overall install deadlines. Cloudflare recommends status polling. **Inference:** donor's unanswered multi-minute POST risks 524; parallel GET polling does not shorten that POST. Actual tunnel/zone configuration was not inspected.

**Recommendations/options, not decisions:** consider promptly acknowledged durable operations with reload/reconnect discovery; lifecycle snapshot invalidation and honest sync failure reporting; rollback/previous-version availability; separately visible executable/auth/T3 readiness. Plan deterministic slow/offline/restart/prefix tests and consented account-specific T3 turns, plus an actual-phone walkthrough. Static substring checks and optional GET-schema audits do not demonstrate those outcomes (`D:scripts/harness-ui-audit.js:32-86,103-135`). Preserve the distinction between research completion and phone-ready acceptance.

### Official sources (consulted October 1, 2026)

- [CF] Cloudflare Error 524 — updated July 23, 2026.
- [OA] OpenAI authentication/headless login — current docs, not proof for every installed version.
- [OC] OpenCode providers/credentials/configuration.
- [T3] v0.0.44 managed provider snapshot code, lines 119-169; settings subscription, lines 232-234.

[CF]: https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/
[OA]: https://learn.chatgpt.com/docs/auth#login-on-headless-devices
[OC]: https://opencode.ai/docs/providers/
[T3]: https://github.com/pingdotgg/t3code/blob/451afcb22d93f06cb24f9bc16703404564952553/apps/server/src/provider/makeManagedServerProvider.ts#L119-L169

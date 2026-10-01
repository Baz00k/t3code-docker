# PR #1: phone install readiness

**October 1, 2026 — static inspection only.** Source: `/tmp/t3code-pr1-review`, confirmed HEAD `0fd91c7`; only the four requested source files inspected. No fetching, builds, browser sessions, or audit execution. **Phone usability is not verified.** Imported manager/cache internals were outside scope.

**Decision context:** The maintainer’s September 30, 2026 gate keeps `latest` batteries included until on-demand installation is easy from a phone without commands. The already-handled 0.0.44 upgrade is not reassessed here.

## Existing no-command capabilities

- Setup-key login supports browser-visible path prefixes; lifecycle APIs require authentication (`docker/setup/app.js:22-54`; `docker/setup/server.mjs:1190-1209`).
- Agents offer Install with blank/default `latest`, optional explicit versions, Update, and confirmed Uninstall. Runnable agents expose browser sign-in/API-key entry; sign-in includes a same-device **Open** link and optional code submission (`docker/setup/app.js:408-489,801-862,908-943`).
- Cards distinguish working, failed, absent, runnable, and sign-in states; show versions and inline failures; preserve version text and suppress lifecycle actions while busy. Responsive wrapping is present (`docker/setup/app.js:357-449`; `docker/setup/console.css:1118-1136,1642-1706`).
- Server delegates lifecycle mutations to the shared manager, attempts provider synchronization, and exposes cache freshness metadata. Credential writes have an explicit cache-invalidation helper (`docker/setup/server.mjs:188-192,277-285,1095-1128`).

## Concrete progress/error/cache UX gaps

- **Asynchronous completion is not established:** comments describe operations outliving requests, but the route awaits the manager. The UI treats any successful POST as “Installed” (including Update), ignoring returned harness/sync details. These files do not establish an accepted-job versus completed-job contract (`docker/setup/server.mjs:1088-1128,1232-1237`; `docker/setup/app.js:459-469`).
- Progress is a spinner/operation label with 15-second polling, not phases, elapsed time, logs, cancellation, or recovery guidance. Lifecycle/status fetches have no explicit timeout; whole-list replacement preserves text but does not restore input focus (`docker/setup/app.js:357-386,407-476,712-727,963`).
- Provider-sync failure can accompany top-level success, yet the UI ignores it. Manager failure text is truncated to 220 escaped characters; transport errors lack operation-specific next steps (`docker/setup/server.mjs:1113-1126`; `docker/setup/app.js:382-386,463-472`).
- Lifecycle mutations do not explicitly invalidate the snapshot, unlike credential writes. The UI ignores returned harness facts and refreshes status; its generic cached-sign-in notice omits timestamp/age and refresh outcome. **Stale lifecycle display is a risk, not a reproduced failure** (`docker/setup/server.mjs:188-192,277-285,1095-1128`; `docker/setup/app.js:463-476,747-759`).
- Opening an authentication panel suspends all Agents rendering, potentially hiding another harness’s progress (`docker/setup/app.js:766,789,822`). The audit uses substring checks; optional live checks cover GET schemas/authentication, not phone gestures or lifecycle mutations (`scripts/harness-ui-audit.js:32-86,103-135`).

## Phone-browser acceptance checks — proposed, not executed

1. Unlock at root and proxied prefix; install an absent harness with one tap and no version/command entry (`docker/setup/app.js:22-54,418-421`).
2. At 320–430px, verify wrapping, distinct touch targets, visible errors/dialogs, and no horizontal overflow (`docker/setup/console.css:1118-1136,1321-1364,1642-1706`).
3. During a multi-minute install, double-tap, background/reopen, and reload: recover progress, prevent duplicates, and never announce completion prematurely (`docker/setup/app.js:408-476,963`).
4. Type an explicit version across polling; retain text, focus, keyboard, and caret; verify the resulting version (`docker/setup/app.js:375-376,402-450`).
5. Exercise invalid version, offline download, interrupted connection, busy conflict, and sync failure: show actionable errors and permit command-free recovery (`docker/setup/server.mjs:307-316,1113-1126`; `docker/setup/app.js:463-476`).
6. Complete same-phone sign-in/key entry; verify fresh runnable/auth state, honest cached-state labeling, and concurrent lifecycle progress (`docker/setup/app.js:747-766,801-956`).
7. Update, cancel/confirm Uninstall, then reinstall; verify truthful completion, provider availability, and credential retention (`docker/setup/app.js:423-489`; `docker/setup/server.mjs:1110-1126`).

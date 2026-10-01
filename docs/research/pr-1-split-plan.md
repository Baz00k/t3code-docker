# PR #1: actionable split plan

Updated October 1, 2026, after reading the September 30 follow-up discussion. This is a decision and execution plan, not implemented changes. The current decision below supersedes the September 30 four-PR ordering.

## Current decision (October 1; supersedes the previous ordering)

1. **Remove the T3 upgrade/packaging request from the active standalone PR queue.** The maintainer explicitly answered that they already handled the 0.0.44 update. Preserve upstream's fix and version. Do not ask the same question again or pitch a redundant version unblock. Root-owned `/opt/t3` and absolute launcher isolation remain useful technical mechanisms in the original branch, but are not newly requested work: carry only the isolation necessary for mise as a tightly scoped part of that foundation, or propose a separate isolation PR only if it materially expands the scope. Source: maintainer follow-up, September 30, 18:41:58 UTC, comment 5917472097.
2. **Lead with tested-digest publishing.** It remains an explicitly welcomed independent change from the original review and was not withdrawn in the follow-up. It requires neither mise nor a product-default decision. Sources: comments 5901107438 and 5917472097.
3. **Treat phone-first, no-command installation as the product gate.** The latest reply is conditional: the maintainer wants the current batteries-included default preserved until on-demand installation is easy from a phone without entering shell commands. This is not a permanent rejection of a lean default, but also not approval to switch latest automatically once we believe the UI is ready. Initial delivery keeps full/slim and their defaults; a later default change requires explicit agreement and its own rollout decision. Source: comment 5917472097.
4. **Retain mise and narrow adapter fixes.** Inventory failure must mean unknown rather than removed; operation failure must not invalidate the last verified install. Do not introduce another installer/package manager to work around hypothetical mise instability. The latest reply does not retract the original concrete review issues or auth-test requests. Sources: original review plus September 30 adapter reproductions recorded below.
5. **Use three active delivery slices, not four mandatory PRs:** CI publishing; mise foundation with necessary infrastructure isolation; phone-ready managed-harness/lean variants. The foundation split is our proposed decomposition, not an explicitly approved independent product addition. If the last slice remains too large, split backend and UI only when the intermediate change has a useful opt-in contract.

### What changed from the previous plan

| Previous decision | Updated decision |
| --- | --- |
| First extract standalone immutable-T3/packaging PR | Upgrade handled upstream; no standalone upgrade PR. Preserve only needed isolation as foundation work. |
| CI after infrastructure | CI first; it has no dependency on runtime isolation or mise. |
| Preserve latest as a fixed long-term policy | Preserve it initially; revisit only after phone-first UX is demonstrated and the maintainer agrees. |
| Mobile UX one test among many | Mobile no-command install, completion, error recovery and reconnect are explicit product acceptance gates. |
| Ask whether the 0.0.44 work is still wanted | Already answered; proceed with the remaining work and acknowledge the new condition. |

## Verified snapshots and chronology

- PR #1 head: `0fd91c73a06e8bbef459f88d22ec03df2b279b2d`; created September 21, 2026, 09:45 UTC. Its `Dockerfile:217` pins T3 **0.0.42**. Commit `5e96b91` introduced the native-package migration on September 18. Sources: `gh pr view 1 --json createdAt,headRefOid,commits`, `git show origin/pr-1:Dockerfile`.
- Maintainer comment: September 29, 2026, 23:36:18 UTC, issue comment 5901107438. The request to unblock main's 0.0.40 did not mean the PR itself was on 0.0.40. Source: `gh pr view 1 --json comments`.
- Main now: `16e59c7f21e43698ee9efbdcc2827b619c97e64d`. `544af68` adapted patching and smoke tests to the platform package; `1da1c9b` bumped T3 to 0.0.44 at September 29, 23:40:12 UTC; `16e59c7` fixed nested global npm package discovery at 23:45:31 UTC. Main retains T3 in the writable `/opt/npm-global` prefix, whereas the PR installs directly into root-owned `/opt/t3`. Sources: these commits, main `Dockerfile:128-160`, PR `Dockerfile:217-255`, PR `docker/bin/t3-admin`.
- Follow-up discussion: author agreed to fix/split the draft at September 30, 14:35:45 UTC (5913458523), then asked whether T3 changes were still needed at 14:39:18 UTC (5913520819). Maintainer replied at 18:41:58 UTC (5917472097): the upgrade was handled and the batteries-included default should remain until phone-friendly no-command installation is available. Sources: `gh pr view 1 --json comments` and the public PR conversation.
- October 1 refetch confirms main remains `16e59c7` and PR head remains `0fd91c7`; no new implementation commits accompany the discussion. No inline review comments were returned by `gh api repos/dizys/t3code-docker/pulls/1/comments`.
- The combined merge against main conflicts only in `Dockerfile`, `docker/t3-client/patch.mjs`, and `scripts/smoke-test.sh`. Checked with `git merge-tree --write-tree origin/main origin/pr-1`; this is a combined merge preview, not a claim that replaying every original commit in a rebase has only three conflict resolutions.

## Branch and extraction strategy

1. Preserve the original PR head as the source of truth; do not force-push, close, or rewrite PR #1 during planning.
2. Start clean feature branches/worktrees from current upstream main. Extract selected hunks, not entire final files or the original commit sequence. The final files encode the rejected replacement of slim/full.
3. Use `58c5ea2` (infrastructure), `5e96b91` (native T3), `a99d657` (mise), `a1f8486` plus `ebf76ab`/`6711aae` (CI) as historical donor references. These are not guaranteed clean cherry-picks.
4. Keep T3 0.0.44, main's package-layout fix, and current harness pins. Only adapt the client patch and native-binary floor lookup if the mise foundation actually changes the infrastructure location. Retain all existing authentication regressions.
5. Prepare CI first, then mise/isolation, then phone-ready managed variants. Rebase remaining feature branches on merged main. Keep the original integration branch as an archive until the split is accepted.
6. No default flip in these extraction PRs. Demonstrate phone readiness and request a separate rollout decision before changing latest or compose defaults.

## PR 1: test exactly the artifact that is released

Suggested branch: `split/tested-digest-promotion`, directly from current main. First implementation priority; no mise/isolation dependency.

Primary write scope: `.github/workflows/build.yml`; only narrowly necessary smoke arguments/helpers.

Keep matrix slim/full x amd64/arm64 and existing aliases (latest and bare versions map to full). Preserve full-image disk reclamation: the PR removed it because lean images were smaller, which does not apply here.

For PR/main builds, build locally and smoke-test without registry credentials. For release tag pushes, build once, push by digest, resolve the platform member, smoke-test that exact reference on its native runner, then export evidence only after successful tests. Promotion waits for every required matrix member and creates manifests from the tested artifacts without a rebuild. Gate registry writes specifically on tag push events, not merely ref_type=tag.

Keep evidence minimal: variant, platform, member digest, source SHA, and pushed index digest if retaining provenance. Validate one member per required platform and matching source/variant; use the immutable source digest, not a movable candidate tag. Retain provenance by assembling the pushed indexes while asserting their tested platform members. A small inline manifest-member check is sufficient; do not include standalone `verify-promoted-manifest.sh`, `measure-image.sh`, size reporting, or harness E2E in this PR.

Acceptance: failed/missing smoke gate prevents release tag promotion; no second build; correct full/slim tags; both architectures; exact member identity; provenance preserved if enabled; fork PRs do not require publish secrets. A maintainer-owned tag run is needed to prove the actual release path; non-tag PR CI alone does not exercise registry promotion.

## PR 2: mise foundation, project toolchains, and required isolation

Suggested branch: `split/mise-project-toolchains`, refreshed onto main after PR 1 merges. PR 1 is an ordering choice, not a code dependency.

Scope: pinned checksum-verified mise binary for both architectures; system policy/generated idiomatic allowlist; persistent MISE directories; user-only shell/exec activation; diagnostics; concise documentation and focused tests. Use `a99d657` and final deterministic generator as donors. Revalidate the pinned release's own CLI/schema rather than assuming current docs exactly describe that pin.

Keep baked harnesses/runtimes and legacy image profiles. Do not add harness lifecycle or settings synchronization here. Include the smallest necessary infrastructure isolation from the donor branch (absolute T3/setup runtime resolution and root-owned server assets where needed) so a project's Node choice affects project commands only. Keep the existing 0.0.44 release; this is a prerequisite for introducing project-controlled PATH, not a second upgrade. If root-owned prefix migration makes this slice too large, explicitly propose it as a narrow prerequisite rather than reviving it as maintainer-requested upgrade work. Test legacy defaults without project configuration as well as declared-tool installation/failure behavior; shell activation and fallback policy must not silently break full's bundled tools. No root activation or broad automatic trust of project configurations.

Acceptance: project mise.toml/.tool-versions/idiomatic selection; fresh and reused home; offline reuse; missing tool behavior; root isolation; decoy PATH isolation; no regression to legacy harnesses. Reintroduce necessary deleted test cases and wire them into CI, rather than importing implementation-era reports wholesale.

## PR 3: phone-ready opt-in managed-harness core/browser variants

Suggested branch: `split/managed-harness-variants`, based on the merged mise foundation.

Propose this initial delivery contract in the review thread (do not ask the answered T3 question again): full/slim continue receiving updates; latest, bare version tags, compose and .env defaults remain full; core/browser are additive explicit tags with versioned suffixes; no harnesses baked into lean variants; persistent exact-version installs; user wrappers are respected; uninstall preserves credentials. Explicitly state that the default stays batteries-included for this delivery while phone-first install UX is proven. A future default switch is deferred, not permanently rejected and not pre-approved.

Scope: manager, provider integration, CLI as an optional secondary interface, phone-first setup lifecycle/UI, additive targets, relevant tests and concise docs. The browser UI is the primary install path; neither t3-harness nor mise shell commands may be required to install a supported harness. Recover the earlier transitional four-target design from `ee6e872`; do not blindly import the final two-target Dockerfile or its reduced test matrix. Prefer shared immutable infrastructure and separate baked/managed layers to avoid duplicating server installation. Limit managed synchronization to opted-in managed providers; legacy full/slim startup must not rewrite user settings.

Fix the review issues before exposing lifecycle to users. The confirmed adapter reproductions are recorded in the verification section below. Required semantics:

- Last successful selected version remains runnable after a failed update. Separate operation error from selected-install health; commit selection/settings only after verification. Inspect rollback of mise global selection as well as manager JSON.
- Claim a provider path only if unset/default or still equal to the integration's last owned value. Preserve user overrides in both legacy and explicit-instance settings; report conflicts instead of silently replacing wrappers.
- Failed inventory is unknown, not an uninstall. Skip destructive settings edits on degraded inspection, preserve known-good paths, and surface diagnostics. Test actual nonempty managed entries, not an empty fixture. This is adapter error handling, not replacing mise's installer.
- Lock identity must survive PID reuse safely (per-container-session identity plus process identity/owner token); safe stale reclamation and token-checked release. Test restart with reused PID and simultaneous attempts.
- Invalidate cached facts after every lifecycle result and prevent pre-operation refreshes from republishing stale facts.
- POST starts an operation and returns promptly (202/id); status endpoint polls completion. Duplicate requests do not launch duplicate operations; restart marks incomplete jobs interrupted and leaves prior installs usable. CLI remains synchronous by waiting on the same operation. Keep this small, not a general job platform.
- Do not privileged-write through predictable temporary files in a user-owned directory. Choose an unprivileged marker write where permissions allow, or a root-owned staging area and safe replacement for root-owned mounts. Test temp symlinks, directory substitution, root-owned initial homes, and interrupted remapping. A bare rm -f before redirection is not a full race-resistant fix.
- Restore /auth/signin and /auth/code regression coverage. Legacy images can run baked-harness tests directly; lean images need installed harnesses in E2E and deterministic auth-flow fixtures. Provider boot/credential preservation is not equivalent to sign-in prompt plumbing.

Acceptance: the phone gate below plus all seven regression cases and auth routes; no-network reuse; install/update/uninstall/recreate; project/runtime isolation; browser MCP; all supported profiles smoke-tested on native amd64/arm64. Keep expensive harness E2E explicitly scoped and documented. If PR 3 is still too large, split internally into backend/CLI plus UI/lean-image integration only when the intermediate PR has a useful opt-in contract (avoid dead modules without a user).

### Phone-first product acceptance gate

These are proposed verifiable acceptance criteria translating the maintainer's latest condition, not new requirements they individually specified:

- Fresh core/browser home: phone-sized setup page clearly shows supported agents, an obvious Install action and sensible default version. No terminal or shell command is needed; version entry is optional.
- Tapping Install returns promptly and shows persistent operation state until completion. Test an operation longer than the tunnel request timeout; do not leave a hanging POST or a misleading request-error banner while the install continues.
- Repeated taps, page reload, phone tab suspension and reconnect join/show the existing operation instead of creating duplicates. Surface interrupted operations after server restart without disabling a prior working install.
- Completion updates version/actions immediately without a manual refresh. Distinguish accepted/running/completed operations, Update versus Install, and installed-but-provider-sync-failed outcomes; do not announce Installed solely because the POST returned HTTP success. Failure shows an actionable explanation and Retry/Update actions; failed updates leave the prior version and provider path working.
- A user can continue into the supported existing sign-in/API-key UI and make the provider ready in T3 without running shell commands. Preserve OAuth/code/device regressions. Necessary credential entry is not the same as entering commands.
- Controls and operation/error text are usable at representative phone widths (at least 320 and 390 CSS pixels), without clipped actions, accidental double submission or unusable confirmations. Make operation/error status accessible. Optional version entry must retain focus/keyboard/caret across polling, not just its text. An open sign-in panel must not hide another harness's lifecycle progress.
- Verify prefixed/tunnel URLs as well as local routes. Retain existing setup authentication; the new async operation endpoints must not weaken it.
- Record a fresh-volume install-to-ready walkthrough at mobile viewport, plus an actual-phone check before claiming the phone condition is met. Viewport emulation alone is not proof of real mobile-browser behavior. All supported install choices should have coverage; use slow/failure fixtures for deterministic UI tests and at least one real installation path.

The original branch already contains lifecycle buttons/version defaults; harden and demonstrate that flow, rather than designing another installer. Static presence of buttons or prior unit-test totals is not evidence that this gate passes. The focused October 1 source audit and exact file/line references are in `docs/research/pr-1-phone-install-readiness.md`; its results are static only, with no live phone verification.

## Deferred: any change to latest/defaults

After PR 3 proves the phone gate, provide the maintainer a short recording/walkthrough and propose the default policy separately. Obtain explicit agreement on whether to change latest/bare tags, compose defaults, browser capabilities and migration behavior. Phone readiness is a necessary condition from their reply, not a guarantee they will accept every default change. Preserve full/slim updates throughout the initial rollout. Do not automatically redirect latest to core at the end of the implementation.

## Immediate execution order

1. Acknowledge that the 0.0.44 work is done and the initial default will stay batteries-included; explain CI first, followed by phone-first on-demand work. This document contains a suggested reply below, but no GitHub reply has been posted.
2. Extract the small CI PR from current main; keep full/slim tags, disk reclamation and auth checks, and leave measurement/large verifier scripts out.
3. Extract the mise foundation with only required runtime isolation; state scope explicitly rather than asking for a redundant upgrade.
4. Fix lifecycle/state/sync bugs in the donor work while preparing the additive variant/UI extraction. Wire deterministic regression tests into CI and restore auth-flow coverage.
5. Record the phone walkthrough and slow/reconnect/failure behavior before claiming install-on-demand is ready. Keep the default decision out of this PR.

### Suggested review-thread reply (not posted)

> Understood—the 0.0.44 update is handled, so I will leave that out of the split. I'll start with the small tested-digest publishing PR and keep latest/full unchanged. For the mise/on-demand work, I'll make the setup-page install flow usable from a phone without shell commands, including long installs, progress, retries and reconnect, and retain the sign-in regression coverage. I'll bring that back as an opt-in variant first; any change to the default can be a separate discussion once the phone flow is demonstrated.

## Verification performed during this investigation

PR snapshot's `node --test tests/*.test.mjs`: 60 passed, 0 failed. This shows current tests pass; it does not establish coverage of the review cases. A separate disposable Node reproduction confirmed `applyManaged` replaces a custom wrapper and `sync()` clears a previously managed path when given nonempty degraded/not-runnable inventory facts. The latter uses an injected failed-inventory result, not an observed failure of the mise binary. Image-profile tests also passed 8/8, and the harness UI static audit reported 19/19; its live browser checks were not enabled. No Docker image builds, authenticated sign-ins, tunnel installations, or release-promotion rehearsals were run. No source implementation was edited, and no rebase or PR publication was performed. These test results are from September 30; they were not rerun as part of the October 1 discussion/plan update. October 1 checks reread the complete PR conversation/reviews, checked the inline-comments API, and refetched main and PR refs. No new mobile usability or release rehearsal was performed.

## Primary source references

- Repository snapshots and commit objects listed above, fetched via `git fetch origin main` and `git fetch origin pull/1/head:refs/remotes/origin/pr-1`.
- PR/comment metadata via the GitHub CLI/API. Original review: https://github.com/dizys/t3code-docker/pull/1#issuecomment-5901107438. Author follow-ups: https://github.com/dizys/t3code-docker/pull/1#issuecomment-5913458523 and https://github.com/dizys/t3code-docker/pull/1#issuecomment-5913520819. Latest maintainer decision: https://github.com/dizys/t3code-docker/pull/1#issuecomment-5917472097.
- Official mise `ls` contract: https://mise.jdx.dev/cli/ls.html (read-only inventory; installed versions and configured requests are distinct).
- Official mise configuration precedence: https://mise.jdx.dev/configuration.html.

Current web docs are contextual references, not proof of the older pinned mise release's exact behavior. Recommendations above are proposed implementation designs, not claims that these fixes already exist.

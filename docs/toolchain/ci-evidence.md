# Native CI And Tested-Digest Promotion

TM-11 deliverable. The transition targets are built for `linux/amd64` and
`linux/arm64` on native runners, the amd64 members are proven by the capability
checks, and a release tag can only be promoted from the exact digests that were
built and tested. Nothing is rebuilt between testing and tagging.

The canonical product contract is
[`TOOLCHAIN-MANAGEMENT-PLAN.md`](../../TOOLCHAIN-MANAGEMENT-PLAN.md); target
profiles and measured sizes are in
[`image-contract.md`](./image-contract.md); the baseline this evidence is
compared against is in [`baseline.md`](./baseline.md).

## The Promotion Rule

> A tag may only resolve to a multi-platform manifest whose members are the
> exact digests CI built, and whose `linux/amd64` member is the digest the
> capability checks ran against.

Two mechanisms enforce it:

- **Build by digest.** On a release tag the build job pushes each platform
  image by digest (`push-by-digest=true`). buildx attaches provenance, so the
  pushed digest is an *index* whose `linux/<arch>` member is the platform
  manifest. The job resolves that member and records both digests; the smoke
  test runs against the exact member (`registry/repo@sha256:<platform>`). The
  digest-only evidence artifact is written *after* that step, so a failed smoke
  test leaves nothing to promote.
- **Verify the manifest.** Promotion copies the pushed indexes (so provenance
  stays attached) and `scripts/verify-promoted-manifest.sh` re-reads the
  promoted tag through the registry and asserts that each platform member is
  the exact digest that was built - and, for amd64, tested. It fails on a
  missing, duplicated, or unexpected image member, including any non-Linux
  platform that is not an attestation descriptor (`unknown/unknown`); those are
  reported, not failed, because they are not pullable image members.

The arm64 member is built and digest-mapped but not smoke-tested. That matches
the effort's verification policy: both architectures are supported and
published, amd64 is the evidence platform, and nothing is blocked on arm64
hardware.

### Pin Freshness In Rehearsals

Smoke's final assertion is that the pins were current at build time. That is a
source-hygiene check, not an artifact property, and `build.yml` reports drift
informationally in `versions`. The candidate rehearsal waives it with
`T3_SMOKE_ALLOW_OUTDATED_PINS=1` and records `pinFreshness: "waived"` in its
evidence, while reporting the same drift informationally in the run summary.
The release path in `build.yml` never sets the waiver, so an official tag still
requires current pins.

The waiver exists because T3 0.0.42 replaced the patchable npm bundle with a
platform-specific binary distribution, which the immutable-infrastructure and
setup-pill steps do not survive; see [Known Blocker](#known-blocker-t3-0042-binary-distribution).
Rehearsals must not be blocked by a migration owned by another effort.

## Workflows

### `build.yml` - the official transitional path

| Event | Behaviour |
| --- | --- |
| pull request, `main`, dispatch | All four targets build for both architectures. `linux/amd64` runs `smoke-test.sh` against the locally loaded image. arm64 builds without smoke testing. |
| tag `v*` | `slim`/`full` push by digest, the exact pushed amd64 digest is smoke-tested, and `merge` assembles the historical tags from the tested digests. `core`/`browser` build and smoke locally but are not published (TM-13 switches publication). |

`merge` creates the tag list with `docker/metadata-action` exactly as before
(`:slim`, `:full`, `:latest`, semver variants), then:

1. requires one digest per platform from the evidence artifacts, with the amd64
   member marked `tested: true`;
2. calls `docker buildx imagetools create` with the recorded digests - a
   registry-side manifest copy, never a rebuild;
3. calls `scripts/verify-promoted-manifest.sh` with the expected digests and
   fails the job on any mismatch.

`lint` (shellcheck + `docker compose config`) and `versions`
(`bump-versions.sh --check`, informational) are unchanged.

### `toolchain-candidate.yml` - the fork rehearsal

```sh
gh workflow run toolchain-candidate.yml --ref <branch> \
  -f targets="slim full core browser" -f run_e2e=true
```

Builds every requested target for both architectures, pushes each by digest,
runs the capability checks against the exact amd64 digest, and promotes the
digests into candidate manifests:

- `<target>-candidate` - moving rehearsal pointer;
- `<target>-candidate-<short sha>` - run-scoped copy of the same manifest.
  Re-running the workflow at the same commit overwrites it, so the evidence
  records the promoted index digest (`manifestDigest`) as the immutable
  reference, not the tag.

The workflow refuses to run on the upstream repository (`dizys/*`), so a
rehearsal can never publish to the upstream package. Official tag names are
constructed nowhere in this workflow; a guard fails the job if a tag would not
end in `-candidate`.

Candidate evidence is collected in the `candidate-evidence.json` artifact (see
below) and the run summary.

## Capability Matrix

Checks are selected by declared capability, never inferred from a binary or a
tag. `--variant` is passed explicitly for the two scripts that select profiles.

| Capability | Script | `slim` | `full` | `core` | `browser` |
| --- | --- | :---: | :---: | :---: | :---: |
| Infrastructure isolation | `test-infrastructure.sh` | yes | yes | yes | yes |
| Mise contract | `test-mise.sh` | yes | yes | yes | yes |
| Ownership migration | `test-ownership.sh` | yes | yes | yes | yes |
| Harness lifecycle | `test-harness-manager.sh`, `test-harness-surfaces.sh` | yes | yes | E2E | E2E |
| Offline setup status | `test-offline.sh --variant` | yes | yes | yes | yes |
| Runtime matrix via mise | `test-runtime-matrix.sh` | no | no | yes | yes |
| Image inventory | `test-image-inventory.sh --variant` | yes | yes | yes | yes |
| Smoke (`--variant`, exact reference) | `smoke-test.sh` | yes | yes | yes | yes |
| Measurement | `measure-image.sh` | yes | yes | yes | yes |

Rationale for the gaps:

- **Harness lifecycle on `core`/`browser`.** The existing suite asserts the
  *transitional* contract (a baked harness fallback is present) and installs
  exact harness versions from mise. The final targets do not bake a harness, so
  the manager reports `bakedFallback.present: false`; asserting the
  transitional value would be wrong. Managed install/launch on the final
  targets is TM-12's E2E, wired into this workflow through the hook below.
- **Offline on all four.** `test-offline.sh` is variant-aware since this
  ticket: `slim`/`full` assert the baked fallback, `core`/`browser` assert its
  absence, and every other offline assertion is unchanged. That closes the
  earlier gap where only the transitional targets ran it.
- **Runtime matrix on `core`/`browser`.** The matrix proves the final images
  can provide the runtimes the transitional `full` used to bake. `slim`/`full`
  do not run it: the transitional targets keep the baked toolchains this
  effort is replacing.
- **Measurement on all four.** Measured locally from the pulled digest so the
  startup timing belongs to the artifact under test.

### E2E Hook (TM-12)

The `test` job runs `scripts/test-toolchain-e2e.sh` for `core` and `browser`
when that script exists and `run_e2e` is true. The interface is deliberately
the same shape as the other checks:

```sh
scripts/test-toolchain-e2e.sh --variant "$T3C_VARIANT" "$T3C_IMAGE"
```

with `T3C_VARIANT`, `T3C_IMAGE`, `T3C_PLATFORM=linux/amd64`, and - when the
rehearsal included `browser` - `T3C_BROWSER_IMAGE` exported. Until the script
lands the step is inert, so this workflow needs no change for TM-12.

## Evidence Artifacts

All artifacts are attached to the workflow run; the promoting jobs also write a
Markdown summary to the run page.

| Artifact | Written by | Contents |
| --- | --- | --- |
| `build-evidence-<target>-<platform>` (build.yml, tags) | build job, after the amd64 smoke test | `build-<target>-<platform>.json` |
| `candidate-build-<target>-<platform>` | candidate build job | `build-<target>-<platform>.json` |
| `candidate-tested-<target>` | candidate test job, after every check passed | `tested-<target>.json` |
| `candidate-evidence` | candidate promote job | one JSON array: the promoted manifest, its members, and the promotion rule |

Evidence record shape:

```json
{
  "target": "core",
  "platform": "linux/amd64",
  "digest": "sha256:...",
  "indexDigest": "sha256:...",
  "ref": "ghcr.io/you/t3code@sha256:...",
  "indexRef": "ghcr.io/you/t3code@sha256:...",
  "tested": true,
  "checks": ["infrastructure", "mise", "ownership", "runtime", "inventory", "smoke", "measure"],
  "size": [{ "compressed_bytes": 0, "unpacked_bytes": 0, "startup_seconds": 0.0 }],
  "pinFreshness": "waived",
  "sourceSha": "...",
  "runUrl": "https://github.com/.../actions/runs/..."
}
```

`digest` is the platform manifest (the promoted member and, for amd64, the
artifact the checks ran against); `indexDigest` is the pushed index buildx
returned, which is what promotion copies. In the candidate path, `tested` is
`true` only in the test job's artifact, and only when every check step passed;
the release path marks its amd64 record `tested: true` after its own smoke step,
so `merge` can apply the same gate. The promotion job reads the amd64 platform
digest *only* from the tested artifact, so a build that was never tested cannot
be promoted even if its build artifact exists.

## Failure Rehearsal

The gate is exercised by a rehearsal run on a scratch ref where the amd64
checks fail: the test job fails at the smoke step and writes no
`tested-<target>.json`, so `promote` is skipped (it needs every test job) and no
candidate manifest or `candidate-evidence` artifact is created. The recorded
run is linked in the issue's handoff.

The script-level gate is exercised the same way in CI and locally:

```sh
# A wrong digest fails:
scripts/verify-promoted-manifest.sh \
  --expect linux/amd64=sha256:0000... ghcr.io/you/t3code:core-candidate
# Promotion verification failed (exit 1)

# A missing platform fails:
scripts/verify-promoted-manifest.sh --platforms linux/amd64 ghcr.io/you/t3code:core-candidate
```

## Current Evidence

Final rehearsal, 2026-09-17, source `2fec568`
(run [35256458619](https://github.com/Baz00k/t3code-docker/actions/runs/35256458619)):
all four targets built for amd64 and arm64, all four native amd64 test jobs
passed, and all four candidate manifests were promoted and member-verified
inside the run. `scripts/verify-promoted-manifest.sh` was re-run from a checkout
against the same tags and passed independently. Candidate tags get overwritten
by later rehearsals; the digests below are the record.

| Target | amd64 member (tested) | arm64 member (built) | Promoted index digest |
| --- | --- | --- | --- |
| `slim` | `sha256:3a2ac5c41daa64d3d388b0bdd378ce3960bac1f7f44bd692fe34e8d939134599` | `sha256:87b251626dfa00338ff52161f4d6692bab22073a5a7e099329e318c32f8d4c5a` | `sha256:d3323ebe43eedb1670b6a21558f736e25e25f913adb5d58f9cf7fdbc60dd6b67` |
| `full` | `sha256:74f7109e6aa45ad24dc589a32dc16619300e165d7b435e4b04123b93d7b93d67` | `sha256:1ec6a15f85e0fb94b6679f4722a90e4d3eecf2c09d289632038d127e99f5e332` | `sha256:9ae6fad2dedb85cfd0f56692c8934a5feecaccbf9caed35de86f66c761e6b855` |
| `core` | `sha256:3461c61cee24ceebf5947c332deb8068b4231a05a2693a60880da4f497b2cd59` | `sha256:6c9d957c4bd9d1219b565a2a63a9704114b1fa30357c91e36ab8d422a0aa8289` | `sha256:736b714b5768f7a669e3bd73a2a791313ad1c7bc35c8819d0e32de6b9eaf9a8c` |
| `browser` | `sha256:cf1f277702111d95f3b0ae805f8fd17aaf9ba137d3992f155bd76fcd700710c3` | `sha256:42310feb4bfba30a521e470c25c1d33b5fc421ed1d7554897eb6a9d9102ed8fa` | `sha256:3221a20b2b8ebf34487bd0af987c08c8c18394e2e9a77508569e55c3134acf06` |

Measured from the pulled amd64 digests (startup is the first healthy response):

| Target | Compressed | Unpacked | Startup | Checks |
| --- | ---: | ---: | ---: | --- |
| `slim` | 1.14 GiB | 3.17 GiB | 3.64 s | infrastructure, mise, ownership, harness, offline, inventory, smoke, measure |
| `full` | 1.99 GiB | 5.44 GiB | 3.40 s | infrastructure, mise, ownership, harness, offline, inventory, smoke, measure |
| `core` | 0.69 GiB | 2.03 GiB | 3.64 s | infrastructure, mise, ownership, offline, runtime, inventory, smoke, measure |
| `browser` | 0.97 GiB | 2.63 GiB | 3.65 s | infrastructure, mise, ownership, offline, runtime, inventory, smoke, measure |

Failing-candidate rehearsal, 2026-09-17
(run [35256467044](https://github.com/Baz00k/t3code-docker/actions/runs/35256467044),
scratch branch `tm/11-failure-rehearsal` at `de6aadf`): `core` built for both architectures,
the amd64 smoke step failed on the injected defect, `promote` was skipped
because a test job failed, and the run produced build evidence only - no
`candidate-tested-core`, no `candidate-evidence`, no candidate manifest.

## Known Blocker: T3 0.0.42 Binary Distribution

Discovered while preparing this ticket's first rehearsal. T3 0.0.42 replaces the
patchable npm bundle with a per-platform executable:

- `t3@0.0.42` is a 1.5 KB launcher that resolves `@t3code/t3-<platform>-<arch>`;
- `@t3code/t3-linux-x64@0.0.42` is a 64 MB tarball containing a 161 MB ELF
  executable plus `client/` assets and native `node_modules`;
- `/opt/t3/lib/node_modules/t3/dist/client/index.html` no longer exists, so
  `docker/t3-client/patch.mjs` fails the build for every target.

Migrating means reworking the immutable launch path (`node <entry>` becomes the
binary), the setup-pill injection, and re-verifying the provider seams audited
in [`provider-audit.md`](./provider-audit.md). That is an infrastructure
migration, not a pin refresh, and it is not part of TM-11: the pins are
refreshed for the harnesses and MCP servers, T3 stays at 0.0.40, and rehearsals
waive the freshness assertion until the migration lands. Tracked as
[TM-16](https://github.com/Baz00k/t3code-docker/issues/18), which blocks TM-13's
release path while the strict pin check is in place.

## Corrections Returned To Owners

Wiring the full matrix in CI surfaced five defects that predate TM-11. They
were fixed on the TM-11 branch because they block every candidate run, and are
called out here so the originating work can review them:

| Defect | Owner | Fix |
| --- | --- | --- |
| `test-runtime-matrix.sh` copied a `mktemp` (0600) `mise.toml` into the container; on a runner whose uid is not the container's `t3` uid, mise could not read it and every runtime check failed. | TM-10 | `chmod 644` before `docker cp`. |
| The setup server kept serving an authenticated harness snapshot from before a credential write: storing a Codex key left the panel on "not signed in" until the 15s refresh window elapsed. | TM-08/TM-09 | An explicit credential write bumps a cache generation, waits out any refresh that began before it, and refreshes through the same bounded read before returning (`cache.mjs` `invalidate()`, `server.mjs` `refreshSignInState`); sign-in completion and child exits keep the manager-only verdict flush. Covered by three new unit tests, including the pre-write-refresh race. |
| The console audit compared button tops across an action group that is designed to wrap on phone widths, flagging the intended second line on `full`. | TM-10 | The audit compares buttons that share a visual line for groups that opt into wrapping; the strict single-line check stays everywhere else. |
| `measure-image.sh` reported 0 unpacked bytes when `docker save` stored uncompressed blobs: gunzip closed the pipe and tar counted a truncated extract. | TM-01 | Fall back to the size in the tar header when the blob is not gzip. |
| `test-offline.sh` asserted the transitional baked harness fallback unconditionally, so the final targets could not run it. | TM-09 | The check takes `--variant` and asserts the fallback the variant actually ships. |

All five reproduce on the pre-refresh pin set; none is a TM-11 regression.
`smoke-test.sh`'s "a stored key flips the panel without waiting for a cache"
and "the console has no layout defects", `test-runtime-matrix.sh`'s install
step, and `measure-image.sh`'s unpacked column are what caught them.

## Unavailable Checks

- **Credentialed harness sign-ins.** No provider accounts are used in CI;
  harness facts remain `signedIn: null` where no executable can be probed.
  TM-12 records credentialed checks separately from executable-launch checks.
- **arm64 smoke tests.** Built and digest-mapped only, by policy.
- **Startup timing through the registry.** `measure-image.sh` registry mode
  cannot time a boot; CI stores compressed/unpacked sizes and the local
  measurement in the test job records startup from the pulled digest.
- **Registry-mode measurement of a private fork package.** `measure-image.sh
  --registry` authenticates anonymously. The candidate rehearsal measures
  locally instead; the registry path stays for public references.

## Reproducing Locally

```sh
# Build and prove one target exactly like the candidate workflow's amd64 leg:
scripts/build.sh --target core --tag t3code:core
scripts/test-image-inventory.sh --variant core t3code:core
scripts/smoke-test.sh --variant core t3code:core

# Verify a promoted (or candidate) manifest against known digests:
scripts/verify-promoted-manifest.sh \
  --expect linux/amd64=sha256:... --expect linux/arm64=sha256:... \
  ghcr.io/you/t3code:core-candidate

# Rehearse promotion locally from two pushed indexes (provenance included):
docker run -d -p 127.0.0.1:5005:5000 registry:2
docker buildx imagetools create -t localhost:5005/t3code:core-candidate \
  ghcr.io/you/t3code@sha256:<amd64-index> ghcr.io/you/t3code@sha256:<arm64-index>
scripts/verify-promoted-manifest.sh \
  --expect linux/amd64=<amd64-platform-manifest> \
  --expect linux/arm64=<arm64-platform-manifest> \
  localhost:5005/t3code:core-candidate
```

`actionlint` and `docker compose config` are the workflow linters used to
verify this ticket. CI's `lint` job runs `bash -n`, shellcheck, and
`docker compose config`; actionlint is run manually with the same image:

```sh
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest
docker compose config >/dev/null
```

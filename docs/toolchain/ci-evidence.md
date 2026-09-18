# Native CI And Tested-Digest Promotion

TM-11 deliverable, switched to the final product by TM-13. `core` and
`browser` are built for `linux/amd64` and `linux/arm64` on native runners, the
amd64 members are proven by the capability checks (including the final-target
E2E), and a release tag can only be promoted from the exact digests that were
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
  test, the E2E and the measurement run against the exact member
  (`registry/repo@sha256:<platform>`). The digest-only evidence artifact is
  written *after* those steps, so a failed check leaves nothing to promote.
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
source-hygiene check, not an artifact property, and the release `versions` job
reports drift informationally. Both the candidate rehearsal and the release
path run smoke without a waiver, so their evidence records
`pinFreshness: "asserted"`. T3 0.0.42's platform-package migration restored a
clean pin and removed the temporary rehearsal exception.

## Workflows

### `build.yml` - the official path

| Event | Behaviour |
| --- | --- |
| pull request, `main`, dispatch | Both final targets build for both architectures. `linux/amd64` runs `smoke-test.sh` against the locally loaded image. arm64 builds without smoke testing. |
| tag `v*` | `core`/`browser` push by digest; the exact pushed amd64 digest is smoke-tested, E2E-tested, and measured; `merge` assembles the release tags from the tested digests. |

`merge` creates the tag list with `docker/metadata-action`:

- `core` -> `:core`, `:latest`, `:1.2.3`, `:1.2`, `:1.2.3-core`, `:1.2-core`;
- `browser` -> `:browser`, `:1.2.3-browser`, `:1.2-browser`.

Historical `slim`/`full` tags keep their existing artifacts and stop receiving
updates. Then `merge`:

1. requires one digest per platform from the evidence artifacts, with the amd64
   member marked `tested: true`;
2. calls `docker buildx imagetools create` with the recorded digests - a
   registry-side manifest copy, never a rebuild;
3. calls `scripts/verify-promoted-manifest.sh` with the expected digests and
   fails the job on any mismatch.

The tag path additionally gates on the assembled product and reports size:

- **Final-target E2E** (`scripts/test-toolchain-e2e.sh`) runs on the exact amd64
  digest for both targets: fresh installs of all five harnesses, T3 provider
  launches, recreation (including `--network none`), project toolchain vs image
  infrastructure, and, on `browser`, managed MCP registration driving real
  pages. A failure prevents the evidence artifact `merge` needs.
- **Measurement** (`scripts/measure-image.sh --no-build`) records compressed
  size, unpacked size and startup from the pulled digest, and the run summary
  reports each final target against the published transitional baseline
  (`core` vs `slim`, `browser` vs `full`). Reporting is informational; the E2E
  and smoke are the gates.

`lint` (shellcheck + `docker compose config`) and `versions`
(`bump-versions.sh --check`, informational) are unchanged.

### `toolchain-candidate.yml` - the fork rehearsal

```sh
gh workflow run toolchain-candidate.yml --ref <branch> \
  -f targets="core browser" -f run_e2e=true
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
tag. `--variant` is passed explicitly for the scripts that select profiles.

| Capability | Script | `core` | `browser` |
| --- | --- | :---: | :---: |
| Infrastructure isolation | `test-infrastructure.sh` | yes | yes |
| Mise contract | `test-mise.sh` | yes | yes |
| Ownership migration | `test-ownership.sh` | yes | yes |
| Harness lifecycle | `test-harness-manager.sh`, `test-harness-surfaces.sh` | yes | yes |
| Offline setup status | `test-offline.sh --variant` | yes | yes |
| Runtime matrix via mise | `test-runtime-matrix.sh` | yes | yes |
| Image inventory | `test-image-inventory.sh --variant` | yes | yes |
| Smoke (`--variant`, exact reference) | `smoke-test.sh` | yes | yes |
| Final-target E2E | `test-toolchain-e2e.sh --variant` | yes | yes |
| Measurement | `measure-image.sh` | yes | yes |

Notes:

- **The E2E is a named capability**, so `candidate-tested-<target>.json` records
  that the promoted digest passed it. A failure prevents the tested artifact
  from being written, which prevents promotion.
- **Harness lifecycle checks run on both targets.** They install exact versions
  through the manager and assert the managed contract; the E2E adds T3's own
  provider launches and recreation on top.
- **The runtime matrix** proves the images can provide the toolchains the old
  `full` target used to bake: Node, Python, Go, Rust (with `clippy` and
  `rustfmt`), Bun, Deno, and uv.

## Evidence Artifacts

All artifacts are attached to the workflow run; the promoting jobs also write a
Markdown summary to the run page.

| Artifact | Written by | Contents |
| --- | --- | --- |
| `build-evidence-<target>-<platform>` (build.yml, tags) | build job, after smoke, E2E and measurement passed on amd64 | `build-<target>-<platform>.json` |
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
  "checks": ["infrastructure", "mise", "ownership", "harness", "offline", "runtime", "inventory", "smoke", "measure", "e2e"],
  "size": { "compressed_bytes": 0, "unpacked_bytes": 0, "startup_seconds": 0.0 },
  "pinFreshness": "waived",
  "sourceSha": "...",
  "runUrl": "https://github.com/.../actions/runs/..."
}
```

`digest` is the platform manifest (the promoted member and, for amd64, the
artifact the checks ran against); `indexDigest` is the pushed index buildx
returned, which is what promotion copies. In the candidate path, `tested` is
`true` only in the test job's artifact, and only when every check step passed;
the release path marks its amd64 record `tested: true` after smoke, E2E and
measurement, so `merge` can apply the same gate. The promotion job reads the
amd64 platform digest *only* from the tested artifact, so a build that was never
tested cannot be promoted even if its build artifact exists.

## Failure Rehearsal

The gate is exercised by a rehearsal run on a scratch ref where the amd64
checks fail: the test job fails at the smoke step and writes no
`tested-<target>.json`, so `promote` is skipped (it needs every test job) and no
candidate manifest or `candidate-evidence` artifact is created.

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

Final-target rehearsal, 2026-09-18, source
`d371bf6ade0f1f8b45c8e4d94bca82859701462e`
(run [35321725906](https://github.com/Baz00k/t3code-docker/actions/runs/35321725906)):
`core` and `browser` built for amd64 and arm64, both native amd64 test jobs
passed every capability (including the harness lifecycle checks and the E2E),
and both candidate manifests were promoted from the tested digests and
member-verified inside the run. `scripts/verify-promoted-manifest.sh` was
re-run independently from a checkout against the same tags and passed.
Candidate tags get overwritten by later rehearsals; the digests below are the
record.

| Target | amd64 member (tested, E2E) | arm64 member (built) | Promoted candidate index digest |
| --- | --- | --- | --- |
| `core` | `sha256:25671a93dce56f1f911efc760919ad77d112a62dc5f49ca4ad97825606bd8d72` | `sha256:91f55d912a22f1433500e17c9657aaf223d73ca4ff507338ec678825a0ad8cb2` | `sha256:5f2142b7ea97d42f11aae3206088016d2eb4f918f29d2f126fbc989ac2480e60` |
| `browser` | `sha256:681f27401c4040570ce5b88f75d853f8b6c1d2fbe2e587e1e64a816715ea9c1f` | `sha256:e718b2bb6067ec2014b59441b8ca91c26f3309614afc79f742f27587b65eb088` | `sha256:0a2d6f05e84555902dd9e2eae0f416fcb86dffbbed3dd60152b8a6397c08969f` |

Measured from the pulled amd64 digests (startup is the first healthy response):

| Target | Compressed | Unpacked | Startup | Checks |
| --- | ---: | ---: | ---: | --- |
| `core` | 0.69 GiB (745,217,028 B) | 2.03 GiB (2,179,749,376 B) | 3.66 s | infrastructure, mise, ownership, harness, offline, runtime, inventory, smoke, measure, e2e |
| `browser` | 0.97 GiB (1,043,181,614 B) | 2.63 GiB (2,825,801,216 B) | 3.65 s | infrastructure, mise, ownership, harness, offline, runtime, inventory, smoke, measure, e2e |

Both records are `tested: true` with `pinFreshness: "waived"` (TM-16). The
local dry runs at the same source passed 147/0 checks on `core` and 156/0 on
`browser`.

Historical transitional rehearsal (TM-11), 2026-09-17, source `2fec568`
(run [35256458619](https://github.com/Baz00k/t3code-docker/actions/runs/35256458619)):
all four targets built for amd64 and arm64 and passed their capability checks;
the `slim`/`full` digests below are the last transitional artifacts this
repository built and promoted, and remain useful as rollback references.

| Target | amd64 member | arm64 member | Promoted index digest |
| --- | --- | --- | --- |
| `slim` | `sha256:3a2ac5c41daa64d3d388b0bdd378ce3960bac1f7f44bd692fe34e8d939134599` | `sha256:87b251626dfa00338ff52161f4d6692bab22073a5a7e099329e318c32f8d4c5a` | `sha256:d3323ebe43eedb1670b6a21558f736e25e25f913adb5d58f9cf7fdbc60dd6b67` |
| `full` | `sha256:74f7109e6aa45ad24dc589a32dc16619300e165d7b435e4b04123b93d7b93d67` | `sha256:1ec6a15f85e0fb94b6679f4722a90e4d3eecf2c09d289632038d127e99f5e332` | `sha256:9ae6fad2dedb85cfd0f56692c8934a5feecaccbf9caed35de86f66c761e6b855` |

Failing-candidate rehearsal, 2026-09-17
(run [35256467044](https://github.com/Baz00k/t3code-docker/actions/runs/35256467044),
scratch branch `tm/11-failure-rehearsal` at `de6aadf`): `core` built for both
architectures, the amd64 smoke step failed on the injected defect, `promote` was
skipped because a test job failed, and the run produced build evidence only - no
`candidate-tested-core`, no `candidate-evidence`, no candidate manifest.

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
scripts/test-toolchain-e2e.sh --variant core t3code:core

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

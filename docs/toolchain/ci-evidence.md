# Native CI And Tested-Digest Promotion

`core` and
`browser` are built for `linux/amd64` and `linux/arm64` on native runners, the
amd64 members are proven by the capability checks (including the final-target
E2E), and a release tag can only be promoted from the exact digests that were
built and tested. Nothing is rebuilt between testing and tagging.

Target profiles and measured sizes are in
[`image-contract.md`](./image-contract.md).

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

### Pin Freshness

Smoke's final assertion is that the pins were current at build time. That is a
source-hygiene check, not an artifact property, and the release `versions` job
reports drift informationally. The release path runs the strict smoke check and
cannot publish while it fails.

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
  size, unpacked size and startup from the pulled digest in the run summary.
  Reporting is informational; the E2E and smoke are the gates.

`lint` (shellcheck + `docker compose config`) and `versions`
(`bump-versions.sh --check`, informational) are unchanged.

## Capability Matrix

The repository provides the following verification coverage. Release CI runs
smoke, the final-target E2E, and measurement against the exact amd64 digest;
the focused scripts remain available for local diagnosis and targeted changes.
`--variant` is passed explicitly wherever a script selects a profile.

| Capability | Script | Release CI |
| --- | --- | :---: |
| Infrastructure isolation | `test-infrastructure.sh` | focused local check |
| Mise contract | `test-mise.sh` | focused local check |
| Ownership migration | `test-ownership.sh` | focused local check |
| Harness lifecycle | `test-harness-manager.sh`, `test-harness-surfaces.sh` | via E2E |
| Offline setup status | `test-offline.sh --variant` | via E2E |
| Runtime matrix via mise | `test-runtime-matrix.sh` | via E2E |
| Image inventory | `test-image-inventory.sh --variant` | via smoke |
| Smoke (`--variant`, exact reference) | `smoke-test.sh` | yes |
| Final-target E2E | `test-toolchain-e2e.sh --variant` | release tags |
| Measurement | `measure-image.sh` | release tags |

Notes:

- **The E2E is a release capability.** A failure prevents the tested build
  evidence from being written, which prevents promotion.
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
  "size": { "compressed_bytes": 0, "unpacked_bytes": 0, "startup_seconds": 0.0 },
  "sourceSha": "...",
  "runUrl": "https://github.com/.../actions/runs/..."
}
```

`digest` is the platform manifest (the promoted member and, for amd64, the
artifact the checks ran against); `indexDigest` is the pushed index buildx
returned, which is what promotion copies. The release path marks its amd64
record `tested: true` only after smoke, E2E and measurement, so `merge` can apply
the gate. A build that was never tested cannot be promoted even if its build
artifact exists.

## Promotion Gate Verification

The workflow structure makes promotion depend on tested evidence: a failed
amd64 check leaves no promotable record, so the merge job cannot assign release
tags.

The script-level gate is exercised the same way in CI and locally:

```sh
# A wrong digest fails:
scripts/verify-promoted-manifest.sh \
  --expect linux/amd64=sha256:0000... ghcr.io/you/t3code:core-staging
# Promotion verification failed (exit 1)

# A missing platform fails:
scripts/verify-promoted-manifest.sh --platforms linux/amd64 ghcr.io/you/t3code:core-staging
```

## Unavailable Checks

- **Credentialed harness sign-ins.** No provider accounts are used in CI;
  harness facts remain `signedIn: null` where no executable can be probed.
  Credentialed checks are recorded separately from executable-launch checks.
- **arm64 smoke tests.** Built and digest-mapped only, by policy.
- **Startup timing through the registry.** `measure-image.sh` registry mode
  cannot time a boot; CI stores compressed/unpacked sizes and the local
  measurement in the test job records startup from the pulled digest.
- **Registry-mode measurement of a private package.** `measure-image.sh
  --registry` authenticates anonymously; the registry path is intended for
  public references.

## Reproducing Locally

```sh
# Build and prove one target locally:
scripts/build.sh --target core --tag t3code:core
scripts/test-image-inventory.sh --variant core t3code:core
scripts/smoke-test.sh --variant core t3code:core
scripts/test-toolchain-e2e.sh --variant core t3code:core

# Verify a staged manifest against known digests:
scripts/verify-promoted-manifest.sh \
  --expect linux/amd64=sha256:... --expect linux/arm64=sha256:... \
  ghcr.io/you/t3code:core-staging

# Rehearse promotion locally from two pushed indexes (provenance included):
docker run -d -p 127.0.0.1:5005:5000 registry:2
docker buildx imagetools create -t localhost:5005/t3code:core-staging \
  ghcr.io/you/t3code@sha256:<amd64-index> ghcr.io/you/t3code@sha256:<arm64-index>
scripts/verify-promoted-manifest.sh \
  --expect linux/amd64=<amd64-platform-manifest> \
  --expect linux/arm64=<arm64-platform-manifest> \
  localhost:5005/t3code:core-staging
```

CI's lint job runs shell parsing, ShellCheck, the Node unit suites, the harness
surface audit, the generated mise configuration check, and
`docker compose config`.

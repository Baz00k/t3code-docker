# Tested-digest and provenance constraints

**October 1, 2026 — issue #20; static research, not an accepted publishing contract.** No builds, registry writes, or workflow runs were performed. Facts below constrain the contributor's options; recommendations do not settle issue #21.

## Snapshot comparison

- **Upstream [`16e59c7`][U]:** `slim/full × amd64/arm64` builds load locally and smoke-test; tag-only `publish` builds again, then `merge` combines its digests. Cache reuse does not establish identity with the tested image. The two build invocations also have different labeling inputs. Architecture-name grep verifies presence, not tested-member equality.
- **Donor [`0fd91c7`][D]:** release-path builds push by digest, resolve a runnable member, test that member, then upload member/index evidence. Merge consumes the **indices**, preserving the route to provenance, and checks exactly one record per architecture. However, member selection uses `head -1`; evidence consumption does not validate target/source/run fields. Build-side publication uses only `ref_type == 'tag'`, unlike merge's push-and-tag gate. It also substitutes `core/browser`, removes disk reclamation, and adds E2E/size/verifier scope. Those are not prerequisites for this slice.

## Artifact identities: what must remain distinct

1. **Build result digest:** the action exposes `digest` separately from `imageid`. `load: true` uses the Docker exporter; a release registry export can use `type=image,...,push-by-digest=true,name-canonical=true,push=true`, publishing without assigning release aliases. [1], [2]
2. **Pushed index digest:** with attestations, an index contains runnable image manifests plus attestation manifests. A single-platform build can therefore return an index digest, not its runnable child's digest. [4]
3. **Runnable platform digest:** select exactly one `linux/amd64` or `linux/arm64` descriptor from that index, excluding attestations; do not silently choose the first duplicate. Run the smoke script against `repository@memberDigest` on the corresponding native runner. Upstream's existing script already accepts that positional image reference. [4], [S]
4. **Attestation identity:** BuildKit's attestation descriptors use `unknown/unknown`, with reference annotations identifying their target; OCI artifact manifests additionally have a `subject`. They are not extra runnable architectures. Keep their descriptors, linkage, and reachable blobs. [4]
5. **Release aliases:** `imagetools create` assembles registry manifests, not a new Dockerfile build. Multiple source indices produce an assembled index; its digest need not equal either source index. One unmodified source index permits a carbon copy. Tags must resolve to the recorded assembled index. [5]

**Proof boundary:** a successful smoke test supports only “these checks passed for this runnable digest on this runner.” It does not test the parent index's architecture completeness, validate provenance claims/signatures, establish reproducibility, or prove every alias resolves correctly. This follows from the separation above, not from an attestation promising test success. [3], [4], [5]

**Provenance constraint:** Docker documents public-repository action defaults as `mode=max`, private as `mode=min`, and no attestations for `load: true`/Docker export. Max provenance exposes build arguments. Thus local load → re-export is not evidence of retained provenance; publish the attested build directly, keep its index, and make the intended provenance mode explicit. GitHub artifact-attestation signing is a separate mechanism, not required merely to retain BuildKit provenance. [3], [6]

## Actions gates and minimal evidence

**Required release boundary:** use `github.event_name == 'push' && github.ref_type == 'tag'` consistently for login, push, digest resolution, release evidence, and promotion, retaining the existing `v*` trigger. A dispatch against a tag must not accidentally become a publishing path. [U], [D], [6]

**Permissions:** PR/non-release checks need read-only checkout access and no registry write path. Fork PR tokens are normally downgraded to read-only, with an administrative exception; do not depend on that downgrade to protect same-repository PRs. Release publishing needs `contents: read`, `packages: write`, subject to repository/package access. Permissions apply to the whole job, not conditionally to its publishing steps. Prefer separately gated release jobs if PR jobs must never receive package-write permission; a combined matrix needs that tradeoff acknowledged. [6]

**Failure boundary:** promotion must depend on successful required build/test jobs; retain `fail-fast: false` for diagnostic coverage, not as permission to publish partial success. Failed/skipped dependencies normally skip downstream jobs. Do not bypass with `always()` or mark required tests `continue-on-error`. [6]

**Derived validation minimum, not a finalized schema:** [D], [4], [5]

- Record only after successful smoke checks: variant, platform, canonical repository, source SHA, run ID/URL and attempt, index digest, member digest, and success/check identity. Preserve logs; a self-declared `tested: true` alone is not independent proof.
- Consume this release run's evidence, rejecting missing, duplicate, malformed, unexpected-platform, wrong-target/repository/source/run records. Require precisely amd64 and arm64 for each variant; validate both digests and membership against registry JSON. Require successful evidence upload; no wildcard-only completeness assumption.
- Before assigning aliases, inspect the proposed assembled index: its runnable set must equal the tested pair, and its provenance descriptors/linkages must match the source indices. After promotion, verify every alias resolves to the recorded final index and retained provenance remains retrievable. This can be focused inline checking, not the donor's large standalone verifier.

## Minimal options and recommendation

**A — digest-first per native tuple:** build/push once without release aliases; test the resolved member; merge the two **parent indices**, without platform filtering that could discard attestations. Preserving sibling attestations follows from index composition, but must be checked, not assumed. [2], [4], [5]

**B — staged aggregate:** assemble an untagged/staging two-platform index first, test its two members natively, then carbon-copy that unchanged index to release aliases after both gates. This adds orchestration but gives promotion one frozen index identity. [5]

**Recommendation, not accepted choice:** prefer A as the smaller adaptation of upstream/donor; retain upstream smoke checks, native runners, and disk reclamation. Keep existing aliases: full → `full/latest/version/major.minor/version-full/major.minor-full`; slim → `slim/version-slim/major.minor-slim`. Do not import donor variant renames, change `latest`, add size measurement, or require the standalone verifier. [U], [S], [D]

## Untested / remaining choices

GHCR package permissions, actual action/Buildx versions, attestation format and preservation during multi-index merging, native pull/smoke behavior, disk headroom, malformed/missing evidence, and failure/cancellation gates need release rehearsal. Concurrent runs/retries, multi-tag update failure/rollback, digest-only retention, evidence retention, provenance mode/signing policy, and option A/B remain contributor decisions. Documentation establishes feasibility and necessary identity checks, not an executed guarantee.

## Primary references

- [1 — Docker build-push-action v6 API][1]
- [2 — Docker image/registry exporter][2]
- [3 — Docker Actions provenance defaults][3]
- [4 — Docker attestation storage/linkage][4]
- [5 — Docker Buildx imagetools create][5]
- [6 — GitHub Actions gates/permissions][6]

[1]: https://raw.githubusercontent.com/docker/build-push-action/v6/README.md
[2]: https://docs.docker.com/build/exporters/image-registry/
[3]: https://docs.docker.com/build/ci/github-actions/attestations/
[4]: https://docs.docker.com/build/metadata/attestations/attestation-storage/
[5]: https://docs.docker.com/reference/cli/docker/buildx/imagetools/create/
[6]: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
[U]: https://github.com/dizys/t3code-docker/blob/16e59c7f21e43698ee9efbdcc2827b619c97e64d/.github/workflows/build.yml
[D]: https://github.com/dizys/t3code-docker/blob/0fd91c73a06e8bbef459f88d22ec03df2b279b2d/.github/workflows/build.yml
[S]: https://github.com/dizys/t3code-docker/blob/16e59c7f21e43698ee9efbdcc2827b619c97e64d/scripts/smoke-test.sh

Official external references [1]–[6] were read October 1, 2026. [U]/[D]/[S] are immutable repository snapshots inspected locally; current documentation is not a proposal to upgrade their action versions.

# Review-driven planning context

Captured October 1, 2026. These documents are historical planning inputs and static observations, not an approved implementation specification.

- Upstream main: `16e59c7f21e43698ee9efbdcc2827b619c97e64d` (T3 0.0.44).
- Donor PR head: `0fd91c73a06e8bbef459f88d22ec03df2b279b2d`.
- Original review: https://github.com/dizys/t3code-docker/pull/1#issuecomment-5901107438.
- Latest maintainer reply: https://github.com/dizys/t3code-docker/pull/1#issuecomment-5917472097.
- Prior split proposal: [PR split plan](pr-1-split-plan.md).
- Static UI audit: [Phone install readiness](pr-1-phone-install-readiness.md).
- Contributor-confirmed vocabulary: [Phone-ready](../../GLOSSARY.md).

The contributor confirmed that this effort ends at an implementation-ready specification, not executed code or delivered PRs. The phone-ready boundary covers fresh install through authentication and a usable provider, without commands. The three suggested delivery slices remain a hypothesis to examine, not decisions to close without the contributor.

The new Wayfinder issue map is canonical for decisions and their dependencies. Keep the old completed implementation map and architecture contract as historical evidence; do not inherit their atomic default switch or stop updating slim/full. Initial default compatibility remains a constraint; a future latest switch is outside this planning effort.

Research branches contain evidence only. Production source and CI behavior are unchanged.

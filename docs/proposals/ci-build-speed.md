# CI build speed follow-up

Status: proposal, owned by UX. The toolkit floor is accepted in [ADR 0021](../decisions/0021-toolkit-floor.md). This page records current configuration and a measurement-gated candidate; it does not set release scope.

## Current configuration

- `scripts/gtk-test-binary.sh` builds GTK scenario binaries with the Cargo `ci` profile by default. `TABLEPRO_GTK_BUILD_PROFILE=release` remains available for profiling.
- The installed GTK scenario job runs three shards, with coverage assigned by `TABLEPRO_GTK_SHARD`.
- The distro-floor job uses Debian testing and runs package build, installation checks and the distro-floor scenarios in one job. It is not sharded.

These behaviors are confirmed in the current script, workflow and Cargo profile. Older timing records predate the accepted toolkit floor and these changes, so they do not establish current job duration or a current bottleneck.

## Candidate: measure before sharding distro-floor scenarios

Keep the current single-job layout unless fresh, source-pinned runs show that the distro-floor scenarios are on the critical path. If they are, compare the existing job with a split scenario run under the same source, package and environment.

Before proposing a workflow change:

1. Record repeated isolated runs and separate package build, installation and scenario time.
2. Confirm every scenario runs exactly once across the proposed shards and that package checks remain intact.
3. Measure total elapsed time and executor load, including any duplicated build or setup work.
4. Keep the original job as the fallback until the split passes the normal acceptance gate.

Relevant entry points are [`scripts/test-distro-floor.sh`](../../scripts/test-distro-floor.sh), [`scripts/distro-floor-package.sh`](../../scripts/distro-floor-package.sh) and the `distro-floor` job in [the Forgejo workflow](../../.forgejo/workflows/ci.yml). No split should be selected from historical timing alone.

# CI build speed follow-up

Status: proposal, owned by UX. The toolkit floor is accepted in [ADR 0021](../decisions/0021-toolkit-floor.md). This page records current configuration and a measurement-gated candidate; it does not set release scope.

The immediate target is a complete acceptance run around 20 minutes, with 15 minutes as the longer-term aim, without dropping tests. Issue [#573](https://github.com/cozyGarage/BookiE/issues/573) owns the runner capacity work.

## Measured baseline

Forgejo run #938 at `8ecfab2f2e7fb79d9b7087efe2ed6339c32f9b93` completed successfully in 31 minutes 17 seconds. Its job logs account for 84.7 execution minutes. The distro-floor job took 14 minutes 46 seconds. Eight native GTK jobs separately built the same CI-profile application, spending 12 minutes 40 seconds on those builds in total. These measurements describe that run, not a guarantee for a different source or cold caches.

## Current configuration

- `scripts/gtk-test-binary.sh` builds GTK scenario binaries with the Cargo `ci` profile by default. `TABLEPRO_GTK_BUILD_PROFILE=release` remains available for profiling.
- The installed GTK scenario job runs three shards, with coverage assigned by `TABLEPRO_GTK_SHARD`.
- The distro-floor job uses Debian testing and runs package build, installation checks and the distro-floor scenarios in one job. It is not sharded.
- Native GTK scenario jobs share one CI-profile application artifact per workflow run. The producer and consumers require a clean checkout and validate the source commit, binary digest, architecture and profile. Artifact transfer restores executable permissions only after verification. Local scripts still build when no binary is supplied.

The artifact actions are immutable commit pins from Forgejo's official mirrors. A checksum-pinned Node runtime is installed into the existing tools cache before each action job; this replaces the historical assumption that host workers have no Node runtime. This workflow change still needs acceptance on the actual runner fleet. The separate Debian release-package build retains its own profile and installation coverage.

Artifact actions transfer only the workspace packet, outside the generated Cargo cache. Every shell step that can use that cache retains the existing cache-lock wrapper. Native GTK consumers use the shared target marker, so they do not refresh the last-use timestamps of their retired per-job build caches.

These behaviors are confirmed in the current script, workflow and Cargo profile. Timing records that predate the accepted toolkit floor are not used as a baseline for this change.

Sharing the GTK application would remove seven of the eight measured builds, about 11 execution minutes at this baseline. That alone does not establish the 15-minute target. Measure total execution demand and runner availability as well as the longest job; shortening one job cannot remove a capacity bottleneck elsewhere.

## Candidate: measure before sharding distro-floor scenarios

Keep the current single-job layout unless fresh, source-pinned runs show that the distro-floor scenarios are on the critical path. If they are, compare the existing job with a split scenario run under the same source, package and environment.

Before proposing a workflow change:

1. Record repeated isolated runs and separate package build, installation and scenario time.
2. Confirm every scenario runs exactly once across the proposed shards and that package checks remain intact.
3. Measure total elapsed time and executor load, including any duplicated build or setup work.
4. Keep the original job as the fallback until the split passes the normal acceptance gate.

Relevant entry points are [`scripts/test-distro-floor.sh`](../../scripts/test-distro-floor.sh), [`scripts/distro-floor-package.sh`](../../scripts/distro-floor-package.sh) and the `distro-floor` job in [the Forgejo workflow](../../.forgejo/workflows/ci.yml). No split should be selected from historical timing alone.

The scenario harness already partitions its scenario list with `TABLEPRO_GTK_SHARD`, but the distro-floor Docker wrapper does not forward that variable. Setting it only on a workflow step would therefore repeat the full suite on every shard. A split must forward it explicitly, test that boundary and verify the union and disjointness of scenario assignments. The package cache is local to each worker, so adding matrix jobs alone would also rebuild the package on workers without that source cached. Produce and verify one package before distributing scenario jobs, and retain the package lifecycle checks once against that package.

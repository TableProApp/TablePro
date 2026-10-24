# CI build speed follow-up

Status: proposal, owned by UX. The toolkit floor is accepted in [ADR 0021](../decisions/0021-toolkit-floor.md). This page records current configuration and a measurement-gated candidate; it does not set release scope.

The immediate target is a complete acceptance run around 20 minutes, with 15 minutes as the longer-term aim, without dropping tests. Issue [#573](https://github.com/cozyGarage/BookiE/issues/573) owns the runner capacity work.

## Measured baseline

Forgejo run #938 at `8ecfab2f2e7fb79d9b7087efe2ed6339c32f9b93` completed successfully in 31 minutes 17 seconds. Its job logs account for 84.7 execution minutes. The distro-floor job took 14 minutes 46 seconds. Eight native GTK jobs separately built the same CI-profile application, spending 12 minutes 40 seconds on those builds in total. These measurements describe that run, not a guarantee for a different source or cold caches.

## Current configuration

- `scripts/gtk-test-binary.sh` builds GTK scenario binaries with the Cargo `ci` profile by default. `TABLEPRO_GTK_BUILD_PROFILE=release` remains available for profiling.
- The installed GTK scenario job runs three shards, with coverage assigned by `TABLEPRO_GTK_SHARD`.
- The distro-floor producer builds one Debian testing release package and retains installation, upgrade and purge checks. Three scenario jobs consume that same verified package and partition the installed GTK scenarios with `TABLEPRO_GTK_SHARD`. This split still needs fleet acceptance.
- Native GTK scenario jobs share one CI-profile application artifact per workflow run. The producer and consumers require a clean checkout and validate the source commit, binary digest, architecture and profile. Artifact transfer restores executable permissions only after verification. Local scripts still build when no binary is supplied.

The artifact actions are immutable commit pins from Forgejo's official mirrors. A checksum-pinned Node runtime is installed into the existing tools cache before each action job; this replaces the historical assumption that host workers have no Node runtime. This workflow change still needs acceptance on the actual runner fleet. The separate Debian release-package build retains its own profile and installation coverage.

Artifact actions transfer only the workspace packet, outside the generated Cargo cache. Every shell step that can use that cache retains the existing cache-lock wrapper. Native GTK consumers use the shared target marker, so they do not refresh the last-use timestamps of their retired per-job build caches.

These behaviors are confirmed in the current script, workflow and Cargo profile. Timing records that predate the accepted toolkit floor are not used as a baseline for this change.

Sharing the GTK application would remove seven of the eight measured builds, about 11 execution minutes at this baseline. That alone does not establish the 15-minute target. Measure total execution demand and runner availability as well as the longest job; shortening one job cannot remove a capacity bottleneck elsewhere.

## Distro-floor scenario qualification

The package producer publishes one source-pinned packet through the same artifact helper used for native GTK builds. Package packets have a separate profile and filename; consumers check source, architecture and digest before installation. A package cannot substitute for a native CI binary. Local unsharded commands retain their existing behavior.

The Docker wrapper explicitly forwards `TABLEPRO_GTK_SHARD` for both source and installed-package runs. The three workflow shards use disjoint run-scoped MCP ports. The existing scenario partitioner assigns every input scenario exactly once across the shards. Package lifecycle checks run once on the producer, and consumers do not invoke the package builder.

Before accepting the split:

1. Record source-pinned runs and separate package build, transfer, installation and scenario time.
2. Compare the union of executed scenario names against an unsharded run on the same source and require no duplicates or omissions.
3. Measure total elapsed time and executor load, including duplicated image and installation setup. More jobs alone do not increase physical capacity.
4. Require all package lifecycle and scenario jobs to pass. Keep the preceding single-job workflow available in Git as the rollback until qualification succeeds.

Relevant entry points are [`scripts/test-distro-floor.sh`](../../scripts/test-distro-floor.sh), [`scripts/distro-floor-package.sh`](../../scripts/distro-floor-package.sh) and the `distro-floor` and `distro-floor-scenarios` jobs in [the Forgejo workflow](../../.forgejo/workflows/ci.yml). No 20-minute or 15-minute result is claimed until complete runs demonstrate it.

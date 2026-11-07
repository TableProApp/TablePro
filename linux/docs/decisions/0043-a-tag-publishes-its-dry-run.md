# 0043: A tag publishes what its commit's dry run built

- **Status**: Accepted
- **Date**: 2026-11-07

## Context

`release-linux.yml` built every package twice for one release: in the dry
run [releasing.md](../releasing.md#a-dry-run) requires on the release
commit, and again in the tag's run. Measured on 2026-11-07:

- The dry run 42369487348 and the beta.1 tag run 42344474857 each spent
  about 2.5 hours in the package jobs. The jobs after them took about 20
  minutes.
- The beta.1 dry run 42332344555 and tag run 42344474857, both on
  38184ff51, made byte-identical source and vendor tarballs and translation
  templates. Every .deb, .rpm and Flatpak bundle differed: the builds are
  not reproducible, and a bundle carries the key that signed it.

## Decision

A tag builds no package. Its run takes the tarballs, the translation
template, the Debian source packages, the .deb and .rpm packages and the
unsigned Flatpak repositories from the newest green dry run of its commit,
and publishes them after its own tag, version and date checks.

## Rationale

- **What ships is what was tested.** The dry run installed and started
  these files. A rebuild ships other bytes than the ones it checked.
- **Nothing in them depends on the tag.** Versions, file names, the Flatpak
  branch and the release-notes link in the Debian changelog come from the
  version in `meson.build`, which the commit fixes. The release notes, the
  Flatpak signatures, the PPA upload's signature and the attestations are
  made in the tag's run, as before.
- **About 2.5 hours less per release.**

## Consequences

- A tag with no green dry run of its commit fails before it publishes
  anything. Its error names the dry run to start on the tag and the rerun.
- A dry run made green by a rerun counts. The run keeps the failed
  attempt's artifacts too and the API names no attempt, so the tag takes the
  newest of each name. This trusts those with Actions write, only
  maintainers, not to delete the passing attempt's: the Flatpak a failed
  attempt left would come back, and the `SHA256SUMS` comparison does not
  cover it. Checking the Flatpak's OSTree tree against the dry run's bundles
  would remove that trust.
- What a tag takes from a dry run has an explicit retention
  (`release-linux.yml`, header). A tag after that needs a new dry run.
- The tag's run still signs the Flatpak commits with the release key into
  the published repository and makes the bundles from it. Only the bundles
  and their `SHA256SUMS` lines differ from the dry run's; every other line
  must match.
- The tag's run copies each artifact it takes under the same name, so the
  jobs after it and a [partial publish](../releasing.md#a-partial-publish)
  read that run's artifacts.
- The attestations name the tag's run. Its summary links the dry run that
  built the files.
- Dates stamped at build time, such as the Debian changelog's, are the dry
  run's.
- A packaging fix still builds from the release's tarballs in its own run.

## Alternatives considered

- **Build again in the tag's run**: 2.5 hours more per release, and the
  published packages are a rebuild the dry run never installed.
- **Each publishing job downloads from the dry run**: the jobs that hold the
  release secrets would need `actions: read`, and a partial-publish recovery
  would read two runs.
- **Publish the dry run's `linux-release` as it is**: its bundles carry the
  dry run's throwaway key and name an empty repository.
- **Reproducible builds, compared after a rebuild**: still the 2.5 hours,
  and the builds are not reproducible today.

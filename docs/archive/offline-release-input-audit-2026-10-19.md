# Offline release input audit, 2026-10-19

## Current evidence

`scripts/build-arch-rc.sh` refuses a dirty tree, requires the candidate to resolve to `HEAD`, creates a Git archive from that immutable commit, computes its SHA-256, and passes both into the Arch recipe. `scripts/tests/test_arch_candidate.py` verifies those properties and rejects a non-SHA candidate, conflicting tag/SHA inputs, an unsafe version and a dirty tree. `validate-arch-package.sh` checks installed executables, schemas, desktop metadata and the BookiE license.

The Arch recipe still runs `cargo fetch --locked` in `prepare()` and invokes Cargo builds without `--offline`. The captured input is therefore the project source archive, not a source-plus-dependency archive. This does not prove a build can finish after registry access is removed. Native package dependencies are resolved separately by makepkg and are also not captured by the Cargo archive.

The app manifest reports `0.1.6-dev`, while candidate package version is an explicit environment input to the RC helper. The helper validates version syntax but does not compare it with the app manifest or a release date. This is useful for unpublished candidates, but it leaves consistency checks to the maintainer.

## Implementation

`scripts/build-arch-rc.sh` now requires an ISO release date, checks that `TABLEPRO_RC_VERSION` equals both the app and agentd package versions, and writes three retained inputs under `target/arch-release-inputs/`: the immutable Git source archive, a Cargo vendor archive, and a JSON build-input manifest. The manifest records the commit and optional verified tag, source/package version, date, target, Cargo and Rust versions, both archive checksums, the Arch recipe checksum, selected package roots/features, and the exact native runtime, build and check dependency constraints parsed from the Arch recipe.

The helper fetches the selected Cargo graphs and vendors them with checksums. The Arch recipe verifies the manifest checksum, builds and tests with `--offline`, and installs the manifest under `/usr/share/doc/bookie/BUILD_INPUTS.json`. The package validator checks that its recorded source/package version matches the package filename and validates the commit, date, target and checksums. Native GTK, database and packaging packages remain external Arch inputs with declared version constraints; the manifest and its recipe checksum do not claim to capture the installed native package versions or prove a fully offline operating-system build. They also do not claim byte-for-byte reproducible binaries.

The app and agentd source versions are now `0.2.0`, matching the completed delivery milestone. This changes package metadata only; it creates no tag and publishes no artifact or release. `scripts/tests/test_arch_candidate.py` covers source and vendor archive checksums, provenance fields, bad version/date inputs, immutable commit checks and dirty-tree rejection.

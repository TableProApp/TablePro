# Arch wrapper release date, October 22, 2026

Status: implementation, local validation and isolated artifact lifecycle acceptance complete. Hosted acceptance remains on [#1297](https://github.com/cozyGarage/BookiE/issues/1297).

## Cause and change

The standalone/nightly wrapper called the Arch candidate helper without its mandatory release date. A date exported on the host also did not cross Docker and sudo. The wrapper now resolves `ARCH_CANDIDATE_DATE`, then `TABLEPRO_RC_DATE`, then the current UTC date, matching the release workflow default. Calendar dates and source-version matches are checked before Docker starts. Quoted container/builder heredocs and explicit environment arguments keep input values as data. The build helper and package lifecycle checker are unchanged.

Ten unit cases execute the wrapper with a fake Docker command and check default/overridden/inherited dates, changing UTC days, workspace-version defaults, calendar failures and version refusal. The builder-stage case models sudo environment reset, observes the actual inputs reaching the helper, and verifies hostile-looking URL text stays literal. These tests require no downloads or package builds. The first six boundary tests failed before the fix; [before.log.gz](before.log.gz) retains the failures. The source-version default case pins existing behavior.

The [packaging guide](../../../apps/linux/packaging/README.md) now supplies the required date in its direct-build command and documents wrapper defaults and overrides.

## Real artifact lifecycle acceptance

A disposable Arch container ran the unchanged package validator and lifecycle checker on actual BookiE artifacts: published 0.1.5 and the existing draft 0.2.0 package. The candidate checksum matched the draft SHA256SUMS. Its recorded source commit is `bd31a1d8b3dc83200c324b9f37fa83f3660d8aab`, not the current Linux source. Downloading it did not modify or publish the draft.

- Existing configuration data was refused before any package installation; its bytes were unchanged.
- Existing history data was independently refused and preserved.
- Package validation passed.
- Upgrade from `bookie 0.1.5-1` to `bookie 0.2.0-1` and removal preserved the data sentinels.
- Final package removal and fixture cleanup were verified. The owned container exited zero and was removed; all host mounts were read-only.

[packages.json](packages.json) records artifact SHA-256 values and candidate provenance; [container.json](container.json) records the immutable image ID; [container-exit.json](container-exit.json) records exit status. The [acceptance script](acceptance.sh) and [complete lifecycle log](package-lifecycle.log.gz) retain the checks. The container used GTK 4.24.1, GLib 2.90.1, libadwaita 1.10.0 and GtkSourceView 5.22.0. No GUI was launched.

This proves the lifecycle checker on those recorded artifacts. It does not rebuild the new wrapper's entire candidate, qualify current Linux Rust code, or establish native desktop acceptance. Full wrapper rebuild/nightly and maintainer Forgejo remain separate. No Forgejo run or merge was started.

## Reproduction

```bash
python3 -m unittest discover -s scripts/tests -p test_arch_package_container.py
shellcheck scripts/test-arch-package-container.sh
bash -n scripts/test-arch-package-container.sh
```

Run `bash scripts/test-arch-package-container.sh` for the full isolated source build and upgrade check. Pin `ARCH_CANDIDATE_DATE` to repeat a dated candidate. Run the recorded acceptance script only inside its disposable Arch container. [manifest.json](manifest.json) records final source/check evidence. The separate source and shell-input review was a self-review, not independent review.

## Completed local checks

Final preflight passed: 355 harness tests, 2,056 unit tests, 2,059 sandbox tests and one Redis cancellation test. All ten wrapper tests, ShellCheck, Bash syntax, documentation links, issue ledger and ignored-test registrations passed. No existing test was removed or weakened. Local Debian archive validation was unavailable because `dpkg-deb` is absent; this change does not modify Debian packaging.

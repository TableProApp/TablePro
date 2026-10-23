# CI profile cache cleanup, October 23, 2026

Follow-up to [#1423](https://github.com/cozyGarage/BookiE/issues/1423). The `ci` Cargo profile is used by native GUI scenario builds, but generated-cache cleanup originally considered only `debug` and `release`. Old `ci` directories were never selected by that loop.

The existing stale-generated-artifact regression was extended to create a `ci` directory with Cargo lock and dependency markers. It failed before the fix because that directory remained. Adding `ci` to the existing guarded profile loop makes all 11 cache tests pass. The symlink regression now also covers a `ci` profile pointing outside the cache. Evidence siblings, unmarked/active caches and the exclusive cleanup lock retain their existing protection.

This changes cache maintenance, not test coverage or job placement. The helper is deployed to runners from a pinned source revision by the lab provisioning scripts. Repository validation is not proof of deployed behavior: after merge, update the pin/checksum and qualify the installed helper on drained runners. Do not clear shared caches while another job owns the build lock.

The full script/workflow harness passed. Its Debian archive validation was skipped locally because `dpkg-deb` is unavailable; no local package-validation pass is claimed. Full preflight passed. The deployment pin update and exact-head Forgejo acceptance remain pending.

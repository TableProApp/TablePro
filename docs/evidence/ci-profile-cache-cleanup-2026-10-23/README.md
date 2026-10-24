# CI profile cache cleanup, October 23, 2026

Follow-up to [#1423](https://github.com/cozyGarage/BookiE/issues/1423). The `ci` Cargo profile is used by native GUI scenario builds, but generated-cache cleanup originally considered only `debug` and `release`. Old `ci` directories were never selected by that loop.

This packet records [#1497](https://github.com/cozyGarage/BookiE/pull/1497), merged at `742491a5599a9c7ab1c9b8cec231bb6c62eb9ce4`. The local checks below apply to that source. The later least-recently-used pressure-recovery change is [#1586](https://github.com/cozyGarage/BookiE/pull/1586) and is not covered by this packet.

The existing stale-generated-artifact regression was extended to create a `ci` directory with Cargo lock and dependency markers. It failed before the fix because that directory remained. Adding `ci` to the existing guarded profile loop makes all 11 cache tests pass. The symlink regression now also covers a `ci` profile pointing outside the cache. Evidence siblings, unmarked/active caches and the exclusive cleanup lock retain their existing protection.

This changes cache maintenance, not test coverage or job placement. Repository code and workflow configuration do not prove deployment on a live runner. The [runner maintenance proposal](../../proposals/runner-maintenance-and-isolation.md) records that deployment and isolated-runner acceptance remain unverified. Do not clear shared caches while another job owns the build lock.

A one-time runner health capture is not acceptance evidence. Its operator-specific details were removed; see the [replacement note](runner-health.md) and [redaction record](../redaction-record-2026-10-24.json).

The full script/workflow harness passed. Its Debian archive validation was skipped locally because `dpkg-deb` is unavailable; no local package-validation pass is claimed. Full preflight passed. The deployment pin update and exact-head Forgejo acceptance remain pending.

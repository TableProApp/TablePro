# Newest-code review evidence, October 20

The [review](../../archive/upstream-next-slices-2026-10-20.md) explains findings, confidence, owners and proposed slices. These artifacts prove only their described scope.

- [Source pins](source-pins.json) record the BookiE, upstream and mirror revisions plus the native oracle image ID.
- [Upstream commits](upstream-commits.tsv) records all 18 commits after the previous review pin. A path-limited Git history/diff over that range found no changes under upstream `linux/`.
- [Existing issue snapshot](existing-issues.json) records selected open issues before creating #1186, #1187 and #1188. It is dated evidence, not current status.
- [Native SQL](transaction-oracle.sql) and [psql output](transaction-oracle.txt) distinguish an aborted COMMIT from savepoint recovery. They ran on `postgres:16-alpine` in an isolated, unpublished container with networking disabled. The container was removed by the command's exit trap. Expected division errors were allowed so both terminal outcomes could be observed. Case 1 returns ROLLBACK and zero rows; case 2 returns COMMIT and IDs `{2,3}`.
- [GTK report reproduction](gtk-report-repro.json) records a focused invocation of the existing shell failure reporter. An early assertion followed by 40 passes loses its diagnostic text while preserving exit status 1 and the failure summary. The generated input was removed after the invocation.
- [Forgejo #800 job spans](forgejo-800-timings.json) measure first to last timestamps in selected job logs for BookiE `d291ee6`. They exclude queue time and do not identify which internal phase consumed the time. No new gate was launched to collect them.

The SQL oracle ran directly through psql. It did not run through PolicyGuard or the GTK editor. The audit and UI conclusions combine those native semantics with source tracing and inspected existing tests. The corresponding issues require failing-before regressions and real consumer acceptance before a fix can be claimed.

Documentation validation commands for this review are `python3 scripts/check-doc-links.py`, `python3 scripts/check-known-issues.py` and `python3 scripts/inventory-ignored-tests.py --check`. This review changes no production code, dependency, test registration or workflow.

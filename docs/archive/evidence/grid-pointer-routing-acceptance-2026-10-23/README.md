# Pointer menu routing acceptance

[PR #1520](https://github.com/cozyGarage/BookiE/pull/1520) merged as `4a0c3dda73bd180939bed546abe94f82139213bf`. Forgejo browser run 927, API ID 928, passed all 28 jobs for exact head `12519fa76c0d9bda3f8fb1680faa5fc10b205d1e`. Applicable GitHub checks passed at that tested head; scheduled and Forgejo-owned jobs skipped on GitHub are not counted as passes.

The maintainer merged the documentation-refreshed PR head `791c7a847a0da7bdd0bce1ff735cf3b75b5e0fae`. Runtime, tests, scripts and CI at that head and the merged commit are identical to the tested head. This uses the explicit docs-only freshness exception. Full-tree equality and new passes for the refreshed head are not claimed. [Acceptance data](acceptance.json) records both identifiers and the comparisons.

The [paired measurement](../../../evidence/grid-pointer-routing-2026-10-23/README.md) remains a development-build SQLite result. The [optimized PostgreSQL investigation](../../../evidence/postgres-optimized-stream-2026-10-23/README.md) records a separate unresolved throughput gap; #1315 and #1523 remain open.

# Proposal: maintain local dependency patches

BookiE carries patches for selected database-driver dependencies under `vendor/`. Each patch addresses a boundary needed by the application, such as hostile-server resource limits, TLS identity, or exact native-value preservation. Patch files are checked by `scripts/vendor-patches.py check`.

## Removal rule

Keep a local patch until a released dependency version contains the required behavior and the replacement passes BookiE's contract tests. Before removing it:

1. Verify the exact released version and source change.
2. Compare edge-case behavior with the local patch, including failure handling.
3. Update the dependency and lockfile.
4. Run the focused unit and real-engine layers that exercise the contract.
5. Remove only the patch and vendor override that are no longer required.

An external issue or pull request is provenance, not evidence that the behavior has shipped in a release. Recheck its current status before acting.

## Patch inventory

| Behavior | Dependency | Reference or local contract |
|---|---|---|
| Bound SCRAM iteration cost and validate server nonces | PostgreSQL and MongoDB drivers | [SQLx report](https://github.com/transact-rs/sqlx/issues/4451), [MongoDB driver report](https://github.com/mongodb/mongo-rust-driver/issues/1819), [RUSTSEC-2026-0179](https://rustsec.org/advisories/RUSTSEC-2026-0179.html) |
| Preserve database service identity separately from a tunnel's dial address | MongoDB and Redis drivers | Local transport contract and TLS regression fixtures |
| Preserve quoted text `NULL` separately from SQL NULL in PostgreSQL arrays | PostgreSQL driver | [SQLx report](https://github.com/transact-rs/sqlx/issues/4452); ADR 0007 |
| Decode PostgreSQL multirange type codes | PostgreSQL driver | Local value contract and PostgreSQL oracle |
| Resolve deeply nested PostgreSQL domains and enum types | PostgreSQL driver | Local decoder regression cases |
| Preserve MySQL `ENUM` and `SET` text under binary collation | MySQL driver | [SQLx report](https://github.com/launchbadge/sqlx/issues/4453); ADR 0007 |

The MongoDB SCRAM change merged upstream as [#1833](https://github.com/mongodb/mongo-rust-driver/pull/1833) on 2026-10-21, after release 3.9.1; drop that hunk when a release contains it. SQLx [#4451](https://github.com/transact-rs/sqlx/issues/4451), [#4452](https://github.com/transact-rs/sqlx/issues/4452) and [#4453](https://github.com/transact-rs/sqlx/issues/4453) were open on 2026-10-22 with no sqlx release since 0.9.0.

The links preserve issue provenance only. Current release status, patch contents, dependency versions and test selectors must be checked before changing `vendor/`.

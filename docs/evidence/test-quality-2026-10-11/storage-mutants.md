# Storage crate mutation run, 2026-10-11

`cargo mutants -p tablepro-storage --jobs 3 --timeout 180` on `linux` at `4120696f9`'s parent line (run started 2026-10-11 00:25 CEST, source of `crates/storage`).

| Outcome | Count |
|---|---|
| Mutants generated | 776 |
| Caught | 462 |
| Missed | 231 |
| Timeouts | 4 |
| Unviable | 79 |

About 66 percent of the 697 viable mutants are caught. Every missed mutant is listed in [storage-missed-mutants.txt](storage-missed-mutants.txt).

## Missed mutants by file

| File | Missed |
|---|---|
| `query_history.rs` | 40 |
| `connection_bundle.rs` | 35 |
| `secrets.rs` | 34 |
| `audit_journal.rs` | 28 |
| `connection_organization.rs` | 22 |
| `favorites.rs` | 20 |
| `connections.rs` | 19 |
| `file_access.rs` | 13 |
| `connection_url.rs` | 12 |
| `connection_bundle_secret_transaction.rs` | 5 |
| `paths.rs` | 2 |
| `connection_bundle_crypto.rs` | 1 |

## What matters most

- **`secrets.rs` (secret storage) and `connection_bundle.rs` (bundle export and import):** security-relevant, and bundle v2 just landed (#494). Triage first.
- **`audit_journal.rs`:** the file-lock functions (`acquire_shared_lock` replaced by `Ok(())`, `try_exclusive_lock`'s flag combination, `open_file_with_options`), `AuditJournal::recent` ordering and limit arithmetic, and `sync_created_file_and_parent`. No test fails when any of these change.
- **`query_history.rs`, `favorites.rs`, `connection_organization.rs`:** lower risk, but the counts are high.

A survivor is not automatically a bug. Some are equivalent mutants (the changed code behaves the same). Triage each before writing a test, as for the policy and core runs. The same method and caveats are in [the policy summary](policy-mutants.md).

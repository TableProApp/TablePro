# Transport crate mutation run, 2026-10-11

`cargo mutants -p tablepro-transport --jobs 3 --timeout 180` on the `linux` tree at `origin/linux` after #534.

| Outcome | Count |
|---|---|
| Mutants generated | 144 |
| Caught | 73 |
| Missed | 40 |
| Timeouts | 0 |
| Unviable | 31 |

About 65 percent of the 113 viable mutants are caught. Every missed mutant is in [transport-missed-mutants.txt](transport-missed-mutants.txt).

## Missed mutants by file

| File | Missed |
|---|---|
| `lib.rs` | 29 |
| `route.rs` | 8 |
| `session_material.rs` | 3 |

The crate carries the per-hop SSH secret handling that #492 added, so the survivors in `session_material.rs` come first. A survivor is not automatically a bug: some are equivalent mutants. Triage each one before writing a test, as in the [storage summary](storage-mutants.md).

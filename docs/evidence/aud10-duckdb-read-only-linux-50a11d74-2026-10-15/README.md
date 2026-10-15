# AUD-10 DuckDB read-only recheck at `50a11d74`

Date: 2026-10-15

Source: `50a11d74858e3ee3c39ea861881fd85c8561027a` (`docs(b4): record AUD-2 unit check`). The code under test was already present in this Linux tree.

Environment: rustc 1.98.1; bundled DuckDB.

Command:

```bash
cargo test --locked -p tablepro-driver-duckdb --test read_only -- --test-threads=1
```

Result: 6 passed, 0 failed.

The selected-file tests cover reading the chosen CSV while rejecting sibling and unrelated files, direct reader access after setup, pathname replacement, FIFO refusal without blocking, symlink selection, locked external-access settings, and mutation refusal. The database-file test confirms read-only open and external-file denial; the in-memory read-only connection is refused.

This is a focused local test on the current Linux tree. The historical [AUD-10 implementation record](../../archive/duckdb-read-only-aud10-2026-10-10.md) records the broader suite and Forgejo acceptance for PR #486. Neither record makes DuckDB path controls an operating-system sandbox.

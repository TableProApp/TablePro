# AUD-10: DuckDB read-only file access

This record summarizes the completed implementation in [#463](https://github.com/cozyGarage/BookiE/pull/463) and [#486](https://github.com/cozyGarage/BookiE/pull/486). It is historical evidence, not a separate current policy. Current limitations are in [known limitations](../known-limitations.md).

## Required behavior

A read-only DuckDB connection must not read arbitrary local files through functions such as `read_text`. The driver also supports opening a user-selected CSV, TSV, Parquet or JSON file as a view in an in-memory DuckDB connection. That path remains available while unrelated external paths are denied.

## Implementation

For a flat-file connection, the driver validates and pins the selected regular file before DuckDB opens it. It creates a private same-filesystem hard link to the checked inode and configures DuckDB to allow only that alias. The session retains the file and alias directory for its lifetime. Direct reads through the selected pathname, sibling paths and unrelated paths are refused, including after the selected path is replaced. If pinning or another restriction cannot be applied, connection setup fails closed.

For a `.duckdb` or `.db` connection, the driver opens the selected database in read-only mode and disables external access before user SQL. The read-only policy also rejects SQL writes. This DuckDB-level path restriction is not an operating-system sandbox.

The selected file is opened with `O_PATH` and `O_NOFOLLOW`, checked for identity, then reopened through the descriptor with `O_NONBLOCK`. This prevents a replaced FIFO from hanging setup. DuckDB's path allowlist is initialized with trusted SQL using a tested literal encoder.

## Verification

Coverage includes selected-file reads, refusal of direct reader access after pathname replacement, sibling and unrelated path refusal, quoted and Unicode paths, symlink and FIFO handling, configuration locking, and write refusal against a read-only database. [#486](https://github.com/cozyGarage/BookiE/pull/486) added the pathname-replacement regression and passed 64 DuckDB crate tests, Clippy, `cargo deny`, and workspace preflight. The historical ledger records the Forgejo acceptance run.

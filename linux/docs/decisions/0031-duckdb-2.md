# 0031: DuckDB 2.0, writing files DuckDB 1.x reads

- **Status**: Accepted
- **Date**: 2026-10-31

## Context

[0025](0025-bundled-duckdb.md) kept the driver on duckdb `~1.10506`, DuckDB 1.5.6, because duckdb 1.20000.0 bundled a `v2.0.0-dev` snapshot whose static build failed to link. duckdb 1.20000.1 bundles the v2.0.0 release, reports itself as `v2.0.0`, and links its static extensions with GNU ld.

DuckDB 2.0 creates a new database file in its v2.0.0 storage format, which DuckDB 1.x cannot open: `ATTACH` of a new file too. A file that already exists keeps its storage version when 2.0 writes to it. Measured on 2026-10-31 against libduckdb v2.0.0 and read back with v1.5.2:

| What 2.0 wrote | Default | `storage_compatibility_version = 'v0.10.2'` |
|---|---|---|
| A new file | `v2.0.0+`, 1.x refuses it | `v1.0.0+`, 1.x reads it |
| A new file through `ATTACH` | `v2.0.0+` | `v1.0.0+` |
| A file 1.5.2 created, after a write and a checkpoint | `v1.0.0+` | `v1.0.0+` |

## Decision

The driver uses duckdb `~1.20000.1` with `bundled`, `json` and `parquet`, and opens every database with `storage_compatibility_version` set to `v0.10.2`; this supersedes 0025's crate version, and the rest of 0025 stands.

## Rationale

- **A release, not a snapshot**, as in 0025.
- **The files of earlier releases.** `v0.10.2` is DuckDB 1.x's own default, so a file the app creates, replaces or attaches is what TablePro 0.84 wrote, and DuckDB 1.x, the 1.5 packages in Ubuntu 26.10 and Debian sid among them, opens it.
- **The setting is on the database, not a statement.** It reaches the file `CreateNew` builds, every `ATTACH` and the write-ahead log.

## Consequences

- A new file cannot hold what needs a later storage version, `VARIANT` columns among them, as under 1.5.
- SQL DuckDB 2.0 reads differently reaches the editor: single-arrow lambdas are refused, `~` matches part of a string, integer division by zero fails, and `X'..'` is a `BLOB` (DuckDB's migration guide, Breaking Changes).
- duckdb 1.20000.1 depends on arrow 60, which builds num-bigint 0.5 beside the 0.4 that oo7 and bollard need.

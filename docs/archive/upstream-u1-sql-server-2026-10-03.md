# U1 handoff: SQL Server server-owned columns

Date: 2026-10-03. Branch: `linux`. Upstream reference:
[#3231 / ff80b43a9d](https://github.com/TableProApp/TablePro/commit/ff80b43a9d).
Parent code baseline: `7b08dd4786db22ac38bc341f29d0f350412af82d`.
Review documentation commit: `5cdb2eeadaa747b3b8d7724a20205862d945d6a0`.

## What changed and why

The SQL Server column catalog now reports a column as generated when it is
computed, has the rowversion system type (189), or has a positive
`GeneratedAlwaysType` property. Previously only `is_computed` set that flag.
As a result, rowversion and temporal period columns appeared writable and
could be included in generated INSERT statements that SQL Server refuses.

This changes the existing catalog projection in
`crates/drivers/mssql/src/lib.rs::fetch_columns`. It retains the same column
positions and `ColumnInfo` contract. It uses the base system type so aliases
do not rely on the displayed type spelling. The property check avoids naming
a newer `sys.columns` field in production SQL; a missing property is NULL and
does not meet `> 0`. Schema and table remain bound parameters, and the query
continues to resolve columns through object-ID joins.

The grid already makes `is_generated` columns read-only. Literal INSERT export
and parameterized draft insert already omit them. Fixing their shared metadata
supplies the missing information without duplicating predicates in each UI or
writer. This is a manual Rust behavior adaptation; no Apple code was imported.

## Regression and evidence

Permanent driver-tier regression:
`server_owned_columns::server_owned_columns_are_generated_and_omitted_from_insert_consumers`,
in `crates/drivers/mssql/tests/support/server_owned_columns.rs`.
The integration root registers the module and `docs/ignored-tests.md` records
the Docker ownership.

The native fixture uses a schema and table containing periods, a normal primary
key and text column, a computed column, rowversion, and hidden temporal ROW
START/END columns with system versioning enabled. It compares metadata with an
independent native catalog query, checks ordinary type/default positions, then
executes both Copy as SQL's literal builder and the parameterized draft builder.
Three resulting rows preserve the ordinary data; computed values are recalculated
and rowversion values retain their native eight-byte size.

Before the production fix, the regression failed:

```text
left: ["calculated"]
right: ["calculated", "version", "starts", "ends"]
test result: FAILED. 0 passed; 1 failed
```

After the fix, the same selector passed one test with no ignored tests.
Run from the repository root:

```bash
rtk cargo test --manifest-path linux/Cargo.toml -p tablepro-driver-mssql \
  --test integration \
  server_owned_columns::server_owned_columns_are_generated_and_omitted_from_insert_consumers \
  -- --include-ignored --exact --test-threads=1
```

Validation passed on the changed production source:

- Full local gate: guards, formatting, Clippy, workspace unit/bin and sandbox
  tests; 2,839 passing executions across 63 summaries, including subprocess
  and repeated executions, not a unique test count.
- Change-contract layer: passed.
- Entire SQL Server integration suite: 34 passed, zero failed or ignored,
  including the new regression. The first raw-cargo attempt inside the sandbox
  could not access Docker; the outside-sandbox rerun passed.
- Ignored-test inventory, file/function-size guards and whitespace: passed.

Local layer report:
`target/quality/20261002T222123464575Z-layers/report.json`.
The checked-in [validation manifest](evidence/upstream-u1-2026-10-03/validation.json)
retains source/log hashes and results. The
[failing-before log](evidence/upstream-u1-2026-10-03/native-before.txt) and
[passing native suite log](evidence/upstream-u1-2026-10-03/native-after.txt)
remain available after build-cache deletion. Validation ran on the dirty source
over documentation commit `5cdb2ee`; the manifest identifies the tested Rust
files, including the new test module. The original review did not run these
tests; this follow-up did. Hosted CI is a separate post-push check.

## Remaining work and ownership

- U1 is partially implemented. The shared metadata and two INSERT consumers have
  native evidence. Installed GTK editing, duplicate-row/CSV-import flows and
  ledger-specific fixtures remain acceptance work. SQL Server versions older
  than the fixture are not runtime-qualified here.
- U2 stays open: identity INSERT semantics are distinct from generated columns.
  Do not mark an IDENTITY column generated to solve identity-copy handling.
- U3–U6 are unchanged. This patch does not alter autocomplete, reconnect, client
  certificate configuration or MongoDB export scope.
- The fixture exposed that the existing formatter spells `datetime2(7)` metadata
  as `datetime2`. This patch does not repair temporal declared-type precision;
  keep that as a separate B3 metadata contract, with its own native regression.
- B3/B4, package promotion, native Wayland acceptance and release approval remain
  open. Hosted results must be recorded separately from local tests.

For the next agent: recheck the branch tip and ownership of the SQL Server
catalog/test module, reuse this fixture for the remaining U1 consumer contracts,
and choose U2 as a separate packet if identity copying is the next priority.

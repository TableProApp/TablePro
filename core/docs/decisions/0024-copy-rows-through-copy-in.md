# 0024: An imported COPY block loads through PostgreSQL's copy-in

- **Status**: Accepted
- **Date**: 2026-11-13

## Context

[0011](0011-sql-dump-and-import-in-process.md) has Import SQL File turn the rows of pg_dump's `COPY ... FROM stdin` blocks into INSERTs, and refuse a COPY with any option. A file in CSV, or with `NULL`, `DELIMITER` or `HEADER`, does not load, and a large block loads as many INSERTs instead of one COPY. The macOS app now loads such blocks through libpq's copy-in.

## Decision

On PostgreSQL the `ScriptReader` gives a COPY from stdin as a unit of its own, then its rows as the file holds them in pieces of at most 256 KiB, then their end; `run_sql_import` sends them with `EditorSession::copy_in`, which the PostgreSQL driver runs with tokio-postgres's copy-in on the session's own connection.

## Rationale

- It is what psql does. The rows reach the server unchanged, so text and CSV with any option load as the server reads them, and the server names the line of a bad row, which the import shows with the failure.
- The file is still never held whole: the pieces go through the import's bounded queue, and the import's progress and Stop work during the rows.
- One COPY loads a block much faster than INSERTs of 1,000 rows each.

## Consequences

- The rows end at a line that is exactly `\.`, with LF or CRLF, or at the end of the file. The `\.` is never sent, as psql 18 does, since PostgreSQL 18 reads it as data in CSV. What follows the COPY on its own line runs once the rows end, as in psql. A `\.` line inside a CSV quoted field ends the rows too, as in psql.
- The binary format is refused and its rows passed over, since a script cannot hold it. Binary rows are almost never UTF-8, so such a block usually stops the import at its first row, as the next point says.
- The reader takes the whole file as UTF-8 before it splits it, so a row that is not UTF-8 stops the import at its line, and the rows reach the session's UTF8 `client_encoding` as written.
- A COPY counts as one statement. One the server refuses loses its whole block, as in psql, and the import's error policy decides whether the rest runs. Stop, or a read of the file that fails, fails the copy with CopyFail, and the import reports the stop or the read, not the server's answer to the CopyFail.
- A COPY runs in the import's transaction when there is one, and otherwise in one of the driver's own, so the statement tokio-postgres prepares under a name and the Bind after it reach one server connection behind a transaction pooler. A COPY on its own is atomic, so the wrap changes nothing else.
- A read-only session starts that transaction READ ONLY, and the server refuses the COPY as it refuses any other write.
- tokio-postgres 0.7.18 sends a Sync with the COPY's Execute and another with its CopyDone or CopyFail. A COPY the server refuses before copy-in mode (a missing table or column, a permission error, a Stop while it waits on a lock) then gets two ReadyForQuery, and the next request reads the second. The workspace takes tokio-postgres, postgres-types and postgres-protocol from `TableProApp/rust-postgres` (root `Cargo.toml`, `[patch.crates-io]`): the 0.7.18 tag plus [rust-postgres#1402](https://github.com/rust-postgres/rust-postgres/pull/1402), which sends Flush in place of the first Sync. Such a COPY fails like any statement, and the session goes on. The pin goes once a release has the fix; the integration test `tokio_postgres_answers_the_request_after_a_copy_refused_at_its_start` fails if it goes earlier.
- The query editor still refuses `COPY ... FROM STDIN`, and Export Database still writes INSERTs, which every client loads.
- A session without copy-in fails the COPY with `UnsupportedFeature::CopyFromStdin`.

## Alternatives considered

- **Keep the INSERTs and read CSV and the options too.** A second reader of every format and option the server already reads, and still slower.
- **Read a block into memory and send it in one call.** A block can be larger than memory.
- **Give the session up after a COPY refused at its start.** A missing table, a permission error or a Stop while the COPY waits on a lock would each lose the session, and under Continue end the import.
- **Skip the CopyFail when no CopyInResponse came, in tokio-postgres.** A Stop drops the copy while it waits on a lock; once the lock frees, the server enters copy-in mode and waits for rows that never come.

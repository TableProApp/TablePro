# 0019: A run keeps a byte limit of rows

- **Status**: Accepted
- **Date**: 2026-11-11

## Context

[ADR 0003](0003-result-windows-for-native-grids.md) has the row limit bound what an editor run holds. A row has no size bound, so 10,000 rows of 2 MB values are 20 GB, and the FFI's store holds a batch about three times while it appends it. Every driver sent 256 rows per `Rows` event, whatever their size. MongoDB held every document up to the row limit before its first event, so no sink could stop it.

## Decision

`RunOptions::byte_limit` bounds the bytes of rows one editor run keeps, 256,000,000 by default, measured by `Value::retained_bytes`. `ByteLimitSink` in `tablepro-core` enforces it, and `Session::open_editor_session` wraps every editor session it opens, so each run goes through that sink.

## Rationale

- **Per run, not per value.** A kept row stays exact: a query result has no row identity to read the rest of a cut value by. The row that crosses the limit is kept whole, so a run shows at least one row.
- **Not a stop.** The sink drops rows past the limit and answers `Continue`, never `ConsumerGone`. A stop cancels the statement, and on PostgreSQL a cancelled statement aborts the user's transaction. Rows past the cut are still read up to the row limit, as rows past the row limit are.
- **Once, in the session.** One sink sees every engine's events, and the Linux app, the FFI and MCP only set `RunOptions`, so a later app cannot leave it out. A driver that holds a set before its first event stops on its own: MongoDB stops taking documents once their BSON bytes reach the limit, closes the cursor and sends `ByteLimitReached` itself.
- **The measure.** `retained_bytes` is the value's 32 bytes plus the length of its text, bytes or digits. It counts lengths, not capacities, so the same rows measure the same on every platform. The 10,000-row default reaches 256 MB only past about 25.6 KB a row, and a million rows of three short columns, about 107 MB, stays under it.
- **Its own words.** `Truncation::ByteLimit`, and `ResultEvent::ByteLimitReached { retained }` once per set at the cut. `ServerStopped` says the server stopped the statement, and `ReadPastLimit` names the row limit.

## Consequences

- A set the sink cut finishes `ByteLimit` with the driver's total: exact where the driver read to the end, `None` where it stopped at the row limit. A set the server also stopped finishes `ServerStopped`, since the user has to know the statement did not run to its end; `ByteLimitReached` has already said the size cut it. A set after the limit is used up keeps no rows, and an empty one stays `Complete`.
- A batch goes at 256 rows or 4 MiB of `retained_bytes` (`RowBatch`), so a batch of wide rows is not held several times over while a sink copies it.
- The FFI's `RunSettings.byte_limit` sets the limit per run, and `RunEvent::ByteLimitReached` carries it. The Linux editor gives each statement the bytes its run has left, as it does rows.
- Table pages are exempt. Linux reads a page through `read_page`, not a sink, and Windows pages pass the largest limit, because both pagers read a short page as the last. A page of wide rows is bounded by its row count alone until a page reads a prefix and the length of a long value, with the whole value read by row identity.
- Cassandra's page and Redis's reply are still decoded whole before the sink sees them; the sink bounds what is kept, not that.
- What crosses the wire does not change.

## Alternatives considered

- **A cap per value.** Each long value cut to a prefix. A query result cannot read the rest by key, so copy, the detail pane and an edit would act on the prefix.
- **The limit in each driver.** Nine copies of one rule and its words, and one more to remember for each engine added.
- **Stop the statement at the cut.** The read ends sooner, but an open PostgreSQL transaction is aborted, and each engine needs its own stop, such as a chunked FETCH for PostgreSQL's cursor.

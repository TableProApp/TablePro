# 0033: A query tab edits one result at a time, through the table tab's save

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

[Core ADR 0011](../../../core/docs/decisions/0011-editing-a-query-result.md) decides when a query result's rows are one table's. A query tab runs on its own connection ([0030](0030-a-database-is-a-session-of-its-own.md)), shows every result of a run, keeps at most eight result pages built, and builds them again from the run's rows. A table tab saves its changes through the window's connection, with Confirm Writes, the Read-Only level, the row guards, query history and the close prompts keyed by its tab id.

## Decision

- A query tab holds one change tracker, registered under its tab id as a table tab's is, so Save, Confirm Writes, history, the ledger and the close prompts treat it as they treat a table tab.
- The result on screen takes the tracker when no other result holds changes; another result then shows read-only and says to save or discard first.
- After a run, each result that `result_source` accepts reads its table's columns on the window's connection and becomes editable once `result_target` maps them. A Read-Only connection, a run that leaves a transaction open, a run that may change database, and a tab in another database than the connection's keep every result read-only.
- The pending changes bar of a table tab sits under the results. Ctrl+S saves changed rows while the results have the focus, and the file otherwise; Ctrl+Z and Ctrl+Shift+Z undo and redo the rows there.
- After a save the statement behind the result runs again on the tab's connection, and its rows replace the result's. When it now reads another table or other columns, the tracker follows while it holds nothing, and the result turns read-only while it holds changes made on the rows read before.
- A run, Commit or Roll Back with changes pending asks to discard them first, and waits while a save runs.
- Why a result or a column is read-only shows where an edit would open, in the row details, as for a table tab's locked cell.

## Rationale

- One tracker per tab keeps the window's save, close and history paths as they are; changes in two results would need two saves under one tab id.
- The window's connection is where the table tab's guards, Safe Mode and outcome handling already live. Saving on the tab's connection would commit or roll back the user's own transaction.
- The row details already explain a locked cell; a banner over every read-only result, most of them joins and aggregates, would be noise (HIG, Banners).

## Consequences

- A result read in a transaction is read-only until it is committed or rolled back and run again.
- Switching between two editable results with nothing pending builds each page again, which resets its scroll position.
- MongoDB and Redis results stay read-only; a collection's documents edit in its table tab ([0026](0026-documents-in-the-table-tab.md)).

## Alternatives considered

- **A tracker per result.** The window saves and closes by tab id; several dirty results would need several saves, prompts and outcomes per tab.
- **Saving on the tab's connection.** It would join the user's transaction, and the table tab's guards and outcome handling would need a second home.

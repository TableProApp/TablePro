# 0033: A query tab edits the one result of its run, through the table tab's save

- **Status**: Accepted
- **Date**: 2026-11-05

## Context

[Core ADR 0011](../../../core/docs/decisions/0011-editing-a-query-result.md) decides when a query result's rows are one table's. A query tab runs on its own connection ([0030](0030-a-database-is-a-session-of-its-own.md)), shows every result of a run, keeps at most eight result pages built, and builds them again from the run's rows. A table tab saves its changes through the window's connection, with Confirm Writes, the Read-Only level, the row guards, query history and the close prompts keyed by its tab id.

## Decision

- A query tab holds one change tracker, registered under its tab id as a table tab's is, so Save, Confirm Writes, history, the ledger and the close prompts treat it as they treat a table tab.
- After a run that returns one result, a result that `result_source` accepts reads its table's columns on the window's connection, becomes editable once `result_target` maps them, and takes the tracker. A run of several results, a Read-Only connection, a run that leaves a transaction open or does not say whether one is, a run that may change database, and a tab in another database than the connection's keep every result read-only.
- The pending changes bar of a table tab sits under the results. Its Save, and Ctrl+S while the results have the focus, save the rows and never the SQL file; Ctrl+S elsewhere saves the file. The close prompt lists a tab's changed rows and its file as one choice, which saves or discards both. Ctrl+Z and Ctrl+Shift+Z undo and redo the rows in the results.
- After a save the statement behind the result runs again as a run of the tab, with its Stop, and its result is checked from the start; history leaves that run out. Changes made while the save ran keep the rows they were made on until they are saved too.
- A run, Commit or Roll Back with changes pending asks to discard them first, and waits while a save runs.
- Why a result or a column is read-only shows where an edit would open, in the row details, as for a table tab's locked cell.

## Rationale

- One tracker per tab keeps the window's save, close and history paths as they are; changes in two results would need two saves under one tab id, and handing one tracker between results drew a new race in each review round.
- Reading the result again as an ordinary run reuses its Stop, its busy state and its checks, rather than a second path that has to keep them in step.
- The window's connection is where the table tab's guards, Safe Mode and outcome handling already live. Saving on the tab's connection would commit or roll back the user's own transaction.
- The row details already explain a locked cell; a banner over every read-only result, most of them joins and aggregates, would be noise (HIG, Banners).

## Consequences

- A result read in a transaction is read-only until it is committed or rolled back and run again.
- A script that returns several results is read-only; running its one statement makes that result editable.
- The read after a save starts the result over, scrolled to the top.
- MongoDB and Redis results stay read-only; a collection's documents edit in its table tab ([0026](0026-documents-in-the-table-tab.md)).

## Alternatives considered

- **A tracker per result.** The window saves and closes by tab id; several dirty results would need several saves, prompts and outcomes per tab.
- **Saving on the tab's connection.** It would join the user's transaction, and the table tab's guards and outcome handling would need a second home.

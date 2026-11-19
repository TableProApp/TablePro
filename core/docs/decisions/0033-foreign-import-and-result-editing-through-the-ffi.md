# 0033: Importing from other apps and editing a query result cross the FFI

- **Status**: Accepted
- **Date**: 2026-11-18

## Context

The importers ([0008](0008-importers-from-other-apps.md)) and the rules for editing a query result ([0015](0015-editing-a-query-result.md)) were core code the FFI did not expose, so the Windows app could import only TablePro's own file and edit only a table tab ([0019](0019-row-edits-through-the-ffi.md)). DataGrip on Windows keeps its passwords in a KeePass file whose main key is sealed with DPAPI (`CRYPT_32`), which the core read as locked.

## Decision

### Importing

- `ForeignHost::data_protection` hands the importers the platform's data protection. The JetBrains store unseals a `CRYPT_32` main key through it, then reads it as `BUILT_IN`; with none, or a blob another user sealed, the lookups stop and the review says so (`PasswordOutcome::Stopped`).
- The FFI's Windows host passes `CryptUnprotectData` with no entropy and no prompt, as IntelliJ seals the key. It reads no other app's Credential Manager items and reports no installed apps.
- `Core::foreign_sources` lists the platform's apps with their counts, read from files only. `Core::read_foreign` reads one app, or a Navicat export the user picked, and analyzes it against the library as it is then. The app passes the home, config and data folders (`ForeignAppDirsArg`).
- `ForeignImportReview` holds the review and the user's checks. `choices()` works the plan out again after each `set_selected`, `resolve` or `set_included`, so a Replace another row took is withdrawn and a query follows its connection.
- `apply()` runs once, under the library's write lock: `apply_blocking`, each imported password into the core's secret store under the new id, then the saved queries into the history's store, leaving a name the connection already holds alone. A library changed since the read refuses with `storage.import_outdated` and writes nothing, and the review can apply again after a refusal.

### Editing a query result

- `DatabaseSession::result_editor(sql, rows)` gives a `TableEditor` over a run's result set. A read-only connection, a statement `edit::result_source` refuses and a result `edit::result_target` refuses each give an editor locked with the reason, as new `EditLock` variants: `NotOneSelect`, `MoreThanOneTable`, `Collapsed`, `Untraced`, `KeyNotShown`, and `NoPrimaryKey` and `ColumnsChanged` as before.
- The table's columns are read again from the server first, so a result read before the table changed locks rather than writes by an old place.
- The editor has one column per result column. A traced column is the catalog's; a second copy of a column and an untraced one are generated columns with a name no statement can hold, so they are locked to typing, left out of an insert and never named by an update. The key is read from the result's own columns, through `value_for_column`.
- `copies_exactly(rows, row)` says whether a row's copied values read back as the catalog's types, so an app refuses a duplicate that would write PostgreSQL's server text for a float, a time or money, as 0015 asks. A table page's values are typed, so its rows always copy.
- Planning, the Safe Mode gate and the save are the table tab's: `plan_save` over the traced table, planned again on the writing lease. Edits name rows of the editor's own result set, sorted or not: rows of any other set, the same statement run again included, refuse with `edit.columns_changed`.

## Rationale

- One editor type keeps one save path: a query result writes nothing a table tab would not, as 0015 asks.
- The app keeps what only it knows: a run with several results, a transaction left open, a tab in another database than the session's. It refuses those before it asks the core.

## Consequences

- DBX keeps its key in the system keyring on Windows as well, under its own scheme; its passwords stay behind until an importer reads that scheme on every platform.
- An insert from a query result leaves out every column the result does not show, so the server fills them.

## Alternatives considered

- **A separate result editor type.** A second copy of the key reading, the plan and the save.
- **Reading other apps' Credential Manager items.** No importer keeps a password there that the core could decrypt today.

# Exact database-name preservation

Issue: [#1436](https://github.com/cozyGarage/BookiE/issues/1436).
Source base: `83bf13682c5534a81f411818f32c730adde54604`.

The connection form trimmed server database names before creating connection
options. A whitespace-bearing identifier can differ from its trimmed name.
Test Connection and Connect both use the same option collector.

The replacement regression covers ordinary names, leading and trailing spaces,
newline, empty input and file paths. An extracted copy of the production helper
and its test compiled with `rustc --edition=2024 --test` failed before the fix:
actual `shop`, expected ` shop`. With exact conversion, the same regression
passed. This extraction checks the pure helper only, not widget wiring.

The implementation preserves the database field verbatim and removes the
unneeded file/server normalization branch. Host trimming remains. The exact Cargo app regression also passed (one selected test, no display).
Complete preflight and a real PostgreSQL fixture remain pending.
No live database misconnection was observed.

## PostgreSQL identifier probe

An isolated `postgres:17-alpine` container with no network created `shop`,
` shop` and `shop ` as three distinct databases. Connecting with each exact
name and selecting `current_database()` returned the corresponding spelling.
The owned container was removed in a finally block. This proves database-name
distinction, not the GUI connection path. No existing database was touched.

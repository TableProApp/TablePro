# Export cleanup diagnostic privacy

Issue: [#1502](https://github.com/cozyGarage/BookiE/issues/1502).
Source before correction: Linux `e6f73eca9`.

Two cleanup warnings formatted full ExportError values. Cursor finalization maps database errors through driver_message into ExportError::Source, so these warnings could persist database-controlled text. The primary error remains available to the caller; diagnostics must not record arbitrary payloads.

The regression cleanup_warning_keeps_source_payloads_out_of_logs_and_preserves_the_primary_error failed before the correction because the captured warning contained a synthetic private marker. Both call sites now use a shared diagnostic helper with exhaustive static variant codes and operation names. Error propagation and cleanup behavior are unchanged.

The regression passes after the correction. On the integrated branch, all 786 non-display app tests and full scripts/preflight.sh pass. Display tests were not rerun for this logging-only correction. Adjacent export warning and source paths were reviewed; the remaining export-dialog warning concerns preference persistence. Independent review and Forgejo acceptance were pending at this local evidence checkpoint.

## Subsequent status

GitHub PR [#1503](https://github.com/cozyGarage/BookiE/pull/1503) merged on 2026-10-23 at head `061a9d127b9ec040440afdf6f865bf334ce8dd3d`, and issue [#1502](https://github.com/cozyGarage/BookiE/issues/1502) closed. The PR's GitHub checks succeeded and the merge commit is in the current Linux tree. This packet does not record the exact-head Forgejo run, so it does not independently establish Forgejo acceptance.

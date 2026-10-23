# Cursor cleanup diagnostic codes, October 23, 2026

Issue: [#1477](https://github.com/cozyGarage/BookiE/issues/1477). Base: `662ed2f76`.

Three editor cursor cleanup warnings previously formatted arbitrary driver errors: stream finish, setup rollback, and setup session close. Query errors and nested errors can contain server-provided values. No real sensitive-data exposure was observed.

The shared diagnostic boundary now logs an exhaustive static error code and the cleanup operation. It does not format driver payloads or recursively format sources. Cleanup execution and user-facing errors are unchanged.

The warning-capture regression failed before the repair because a synthetic private marker appeared in captured output. It passed after the repair for query, internal, unknown-outcome and rollback-failure errors across all three operations. Local logs: `target/quality/cursor-log-regression-before.log` and `target/quality/cursor-log-regression-after.log`.

Strict app Clippy and the app library suite passed (776 tests; 182 ignored for external prerequisites). Documentation links and the ledger format passed. Full preflight passed. Forgejo acceptance has not run. This is a scoped cleanup logging repair, not a repository-wide privacy audit.

# Detached session cleanup diagnostics

Source base: `f7a985ef2fe9c65e4ac5307d52e0d0185978631d`. Issue: [#1516](https://github.com/cozyGarage/BookiE/issues/1516).

The detached dedicated-session close path formatted the complete driver error into a warning. Driver messages are untrusted and may contain private SQL or server details. The fix reuses the existing exhaustive static category mapper for driver cleanup and includes a static operation field. Cursor cleanup uses the same mapper. Session ownership and completion behavior are unchanged.

The regression `detached_cleanup_logs_category_without_server_payload` runs the real asynchronous cleanup body with a synthetic query failure and captures its warning. Before the fix it failed because the private marker appeared in the log. After the fix it passed and retained the query category. The cleanup future is separate from its spawn wrapper so this check does not need a display or timing sleeps.

Run the regression with `cargo test -p tablepro-app --lib detached_cleanup_logs_category_without_server_payload`. This is a diagnostic privacy repair, not a complete application logging audit. Full preflight passed. All 788 non-display application tests passed, with 191 display or fixture tests ignored by that command. Isolated GTK results are recorded on the pull request when complete; Forgejo acceptance remains required.

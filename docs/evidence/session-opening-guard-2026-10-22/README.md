# Dedicated-session opening guard

Base: Linux `f22a4905ddfe4cff74fd37247d4d028ac9c534e3`. Owning issue: [#1403](https://github.com/cozyGarage/BookiE/issues/1403).

## Change

SQL execution waits while a dedicated session is opening. Initial dispatch, delayed planning, parameter responses and Run sensitivity share one readiness check. Session-open outcomes and teardown refresh the button. This is the standalone version of the gate repair on [#1390](https://github.com/cozyGarage/BookiE/pull/1390), with a small fixture independent of that feature stack.

## Regression

`ui::editor::dispatch_tests::editor_waits_for_its_session_before_accepting_any_run_input` holds opening behind a controlled response. On the unfixed Linux source, it fails because Run remains sensitive. After the fix, shortcuts from both editor views and a parameter response cannot dispatch while opening. Releasing the session permits a query, and the fixture verifies that its dedicated-session path receives it.

The adjacent text files contain focused excerpts from the observed before/after test results. They are not complete command logs. The regression does not modify a real database.

## Local checks

- `scripts/preflight.sh` passed.
- All 107 registered isolated GTK tests passed through `scripts/test-gtk-widgets.sh` using private Xvfb, Cairo and fatal criticals.
- `cargo clippy --locked -p tablepro-app --all-targets -- -D warnings` passed.
- The focused regression failed before the production fix and passed afterward.

The source checks do not qualify an installed package or native Wayland. GitHub checks and the exact-head Forgejo gate remain required before merge.

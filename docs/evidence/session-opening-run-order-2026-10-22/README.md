# Session opening and SQL execution ordering

## Source and defect

Base: `9583641a781dda82430b505a49b0176c8fc98651`, the #1390 head tested by Forgejo run 883. Its PostgreSQL editor and tunnel-loss scenarios observed `Session` instead of an open transaction after immediately requesting `BEGIN`.

Source inspection found that asynchronous session opening left Run enabled. Execution guards checked active queries and session teardown, but did not check session opening. An immediate request could therefore reach the ordinary connection before the dedicated session became available.

## Regression

`ui::editor::dispatch_tests::editor_waits_for_its_session_before_accepting_any_run_input` holds session opening behind a controlled response. On the unfixed source it fails because Run remains sensitive. With the fix, both editor shortcut paths and a parameter response cannot dispatch while opening. After release, the first accepted query reaches the dedicated session, and completes normally.

The shared readiness check covers initial dispatch, delayed statement planning, parameter responses and button sensitivity. Session success, failure and teardown refresh the button state. PostgreSQL accessibility scenarios wait for Run to become sensitive before issuing their statement.

## Local verification

- The new isolated GTK regression failed on the unfixed source and passed after the fix.
- `scripts/preflight.sh` passed on the corrected source.
- All 129 registered isolated GTK tests passed through `scripts/test-gtk-widgets.sh` with a private Xvfb display and fatal criticals.
- `cargo clippy --locked -p tablepro-app --all-targets -- -D warnings` passed.

This qualifies local source behavior. The updated PR still requires GitHub checks and an exact-head Forgejo gate. The older PostgreSQL scenario runs recorded before this change do not qualify the new head. Native Wayland and installed-package behavior were not tested by this local run.

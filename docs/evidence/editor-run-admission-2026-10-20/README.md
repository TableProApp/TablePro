# Editor run admission

Issue: [#1171](https://github.com/cozyGarage/BookiE/issues/1171).

The editor previously started another generation and cancelled the prior token when Run or RunAtCursor arrived during execution. Parameter-dialog callbacks also reached execution directly.

The editor-state regression `an_active_run_refuses_new_execution_until_its_terminal_outcome` failed before the admission check because a second run was admitted. After the fix it passes through the GTK application's unit target. It verifies that refusal preserves the active generation and that completing a run allows another run. Existing stale-generation tests remain unchanged.

Run and RunAtCursor share an early active-run check. Execution also checks admission so a delayed parameter response cannot supersede an active run. Cancellation does not release admission until the run reports its terminal outcome. Success, cancellation and timeout use the existing terminal cleanup.

Validation: focused app unit test passed. Seven existing editor unit tests, full preflight and all 76 GTK widget tests passed. Forgejo acceptance is pending. Self-review traced all begin_run and execute_sql callers; no independent review has been performed. This record does not claim an installed keyboard scenario passed.

Work used the main checkout at the maintainer's explicit request; no worktree or parallel agent was created.

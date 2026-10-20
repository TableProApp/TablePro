# Editor run admission

Issue: [#1171](https://github.com/cozyGarage/BookiE/issues/1171).

The editor previously started another generation and cancelled the prior token when Run or RunAtCursor arrived during execution. Parameter-dialog callbacks also reached execution directly.

The editor-state regression `an_active_run_refuses_new_execution_until_its_terminal_outcome` failed before the admission check because a second run was admitted. After the fix it passes through the GTK application's unit target. It verifies that refusal preserves the active generation and that completing a run allows another run. Existing stale-generation tests remain unchanged.

Run and RunAtCursor share an early active-run check. Execution also checks admission so a delayed parameter response cannot supersede an active run. Cancellation does not release admission until the run reports its terminal outcome. Success, cancellation and timeout use the existing terminal cleanup.

Validation: focused app unit test passed. Seven existing editor unit tests, full preflight and all 76 GTK widget tests passed. Forgejo [run 809](http://192.168.1.246:3000/trung/bookie/actions/runs/809) passed all 29 jobs. [PR #1193](https://github.com/cozyGarage/BookiE/pull/1193) merged as `afe3b688c82012072172caaab4a05e713f55eb51`; issue #1171 is closed. Self-review traced all begin_run and execute_sql callers; no independent review has been performed. This record does not claim an installed keyboard scenario passed.

Work used the main checkout at the maintainer's explicit request; no worktree or parallel agent was created.

## Component regression follow-up

[PR #1200](https://github.com/cozyGarage/BookiE/pull/1200) added component and guarded-driver coverage for toolbar actions, Run and RunAtCursor shortcut actions in both panes, and delayed parameter responses. Bypassing production admission made the regression fail; restoring admission passed. Success, confirmed cancellation and timeout permit another dispatch only after the terminal outcome. All 78 isolated GTK tests passed locally; Forgejo [run 813](http://192.168.1.246:3000/trung/bookie/actions/runs/813) passed all 29 jobs. The follow-up merged as `e8c7e03dc477de62c8680fb665fa1f429e24ecf0`. These component tests do not establish installed keyboard event delivery or real database cancellation.

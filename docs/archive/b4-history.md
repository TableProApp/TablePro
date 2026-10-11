# B4 historical implementation packets

Archived from `aeac107a4` on 2026-10-03. All status, ownership, worktree and
next-task wording below belongs to its recorded checkpoint. Current tasks and
acceptance are owned by [the B4 board](../b4-task-board.md); use the shared checkout
and cache for the current single-agent session. Historical results are retained
as evidence, including reports that are unavailable locally.

# Original B4 task board

Surveyed on 2026-09-27 at `5fac54059` (source version 0.1.5). This board splits
the open B4 work in [the 0.2 sprint](../bookie-0.2-sprint.md) into small tasks that
separate agents can take in parallel.

## B4 continuation status (October 3)

Latest integrated base: `d1434438e` on `linux`. These B4 reports originated in
isolated worktrees while B3 work was concurrent. Recheck current checkout
status; that observation does not assert a dirty tree in later sessions. Keep B4 open until the remaining tasks and installed Arch/Debian
acceptance are complete.

| Task | Current state | Evidence / next step |
| --- | --- | --- |
| E1, E2, G3, F1, F2, F3 | Merged to `linux` in PRs #16–#18 | Hosted required checks passed; see the linked PRs for packet details. |
| F5 | Merged to `linux` by [PR #19](https://github.com/cozyGarage/BookiE/pull/19) as `4b7814f5e` | Local focused tests and `full` passed; hosted Build Linux, Linux Security, and both Flatpak jobs passed. Scheduled current-stable Clippy was skipped by workflow schedule. |
| F4 + F9 | Merged in [PR #20](https://github.com/cozyGarage/BookiE/pull/20) as `573435766`; implementation commit `ecadbe204` | Local `full`, `ssh`, and `postgres-release` passed in `/tmp/tablepro-b4-f5/linux/linux/target/quality/20261002T225224078495Z-layers/report.json`, including `ssh_reconnect_replaces_the_tunnel_and_the_session`. Build Linux and Flatpak checks were still running at this update; Linux Security had passed. |
| F6 | Merged in PR #22 as `d1434438e`; 86 SSH unit tests, 2 prompt UI tests, affected-crate Clippy and ignored-test inventory passed | Hosted check results were not verified in this session. Docker-backed trust and multi-hop tests are registered in the SSH CI layer. |
| F8 | Implemented on `codex-b4-f8` at `5b69480d`; connection-generation uncertainty is isolated while journal failures remain shared | `full`, `security-policy`, and `postgres-release` passed in `/tmp/tablepro-b4-f8/linux/target/quality/20261002T234851138407Z-layers/report.json`; affected-crate Clippy and focused connection/isolation tests passed. Push completed locally; hosted checks and merge pending. |
| Remaining | C6 MySQL/SQL Server, G5, I2, I5, F7, I3, native Arch acceptance, I1/Debian | Follow the dependencies and evidence requirements in the packets below. B3 completion remains the sprint prerequisite. |

## October 3 integration checkpoint

Historical checkpoint at `4b7814f5e`; the continuation status above supersedes
its F4/F9 open-state wording after PR #20 merged. Retain its recorded evidence scope.

Reviewed `linux` at `4b7814f5e1f586c3761c1454e66d3394ad2c9609`. The isolated-worktree progress below is historical; do not reapply those patches as unmerged work. Main-branch history now includes F1/F3 (`7054a7867`, #13), daemon cache refusal (`d80bade4c` / `768188734`, #14/#17), shared transaction policy (`ad807c61b`, #18), awaited editor cleanup (`7b08dd478`, #16), and editor retirement (`4b7814f5e`, #19). The current retirement path refuses further session dispatch and requires reopening Session. This checkpoint traces source integration; it does not rerun the older branch reports or certify hosted/installed acceptance. F4/F9, F8 and wider B4 acceptance stay open.

The [consistency review](architecture-consistency-review-2026-10-03.md) records remaining panic/headless-retirement risks. The [older-release review](upstream-older-releases-review-2026-10-03.md) adds transition and result-contract reproducers under existing owners, avoiding a second lifecycle engine.

## October 2 review and dispatch plan

Reviewed source checkpoint: `e6e5c34d0ba918aef8cb937b3cbc2741b3f27d64` on
`linux`, source version 0.1.5, target 0.2.0. This is a source/document review;
no new runtime, hosted or installed acceptance results were produced. B3 is
still being worked on in this checkout. At review start another agent had an
uncommitted `crates/app/tests/gtk_safety.py` change; later the dirty source path
was `crates/app/src/services/connection_monitor.rs`. These are concurrent work,
not part of this documentation patch. Recheck ownership and status at dispatch.

**B4 remains open.** The execution plan below supersedes the September 28
waves. Original IDs, decisions and completed evidence are retained below so
agents can continue without rebuilding delivered work. Paths below are relative
to `linux/` unless stated otherwise.

### Findings from the current source

| Scope | Observed source | Planning consequence |
| --- | --- | --- |
| E1/E2 | `policy/src/transaction_control.rs` recognizes explicit single transaction statements; `rules.rs::shared_connection_decision` exempts multi-statement batches. | Trace classification and every shared dispatch caller before implementing implicit/batch refusal. |
| F1 | `app/src/ui/editor/mod.rs::set_running` shows Stop whenever a run is active. | Read the connection capability, including session execution; do not maintain an engine-name list. |
| F3/F5 | `SqlEditorInput::SessionState(bool)` carries neither session identity nor usability; `session_mode.rs::on_session_state` changes whichever session is current. | Protect every session callback, including open and commit completion, against replacement. |
| F2 | `session_mode.rs::close_detached` spawns close; `workspace_close.rs` has a tab transaction prompt; Disconnect tears down tabs before closing the connection. | Preserve the existing tab prompt, then prove awaited cleanup for tab/window/disconnect/switch routes. |
| F4/F9 | B3 commits `111c0f5af` and `b47e2b1d3` prove that reported reconnect faults reattach after swap and trigger before the next ping. B3 commit `1cf609c5d` also checks native SQL Server temporal values through a dedicated session. Transport `Tunnel` still exposes only `socket_dir`; built-in `SshTunnel::is_closed()` has no monitor consumer. | Keep the proven monitor behavior and reuse real session fixtures for editor lifecycle coverage. F9 must connect SSH tunnel closure to its existing fault signal even when driver ping succeeds; F4 must invalidate the dedicated editor session on the resulting connection swap. |
| F6 | `DatabaseService::new` selects `UnknownHostKey::Learn`; `ui/ssh_prompt.rs` already implements the OpenSSH GTK confirmation dialog. | Extend the existing prompt path to built-in SSH, with explicit trust before persistence. |
| F8 | `policy/src/audit.rs::AuditState` contains a shared disabling flag; guard/session/bulk paths all set it. | Split connection uncertainty from journal-wide failure without relaxing fail-closed behavior. |
| G3 | `agentd/src/lib.rs::connection_for` returns a cached connection on initial digest failure and retains the old digest on post-connect failure. | Cover both fallbacks and dispose of unverified new handles. |
| C6/G5 | TLS engine fixtures, PostgreSQL SSH/release fixtures and unattended OpenSSH setup already exist. | Reuse fixtures; transport success alone cannot certify engine TLS or actual daemon wiring. |
| I1/I3 | Debian rules build/install app and agentd only; `upstream-sync.md` contains both adopted OpenSSH evidence and an older no-askpass claim. | Fix Debian in the required later phase; reconcile historical wording without deleting its dated evidence. |

Source entries abbreviate `crates/` for readability. These observations are
not failing runtime reproductions. Every implementer must recheck the current
SHA and determine whether a case is already fixed before editing.

### Ownership and safe execution

Use four logical owners; an owner can be a different agent on successive
handoffs. Hand off one task ID or subtask at a time. This document schedules
future work; it does not start implementation agents.

| Owner | Reserved scope | Sequential queue |
| --- | --- | --- |
| Policy | `crates/policy`; coordinated audit API changes | E1 → E2; later F8 policy portion and I5 audit contract |
| Editor | `crates/app/src/ui/editor`, affected `ui/app` lifecycle/messages | F1 → F3 → F5 → F2 → F4 integration → F8 UI → F7 |
| Transport / daemon | `crates/transport`, `crates/ssh`, `crates/agentd`, app connection services and SSH prompt | G3 → F9 with editor F4 → F6 → I2 → I5 composition |
| Fixture / qualification | `crates/driver-tls-tests`, `crates/release-tests`, owning fixture scripts, later packaging | C6-MySQL → C6-SQLServer → G5 → I3 → Arch acceptance → I1/Debian |

The table is a file reservation, not permission for overlapping edits. F4/F9,
F6, F8 and I5 cross ownership boundaries: agree on one API and integrate in
serial commits. Reserve shared ledgers (`CHANGELOG.md`, this board,
`isolated-tests.json`, `ignored-tests.md`) through one integration owner.

While B3 is active, use a separately agreed worktree/branch or take turns on
this checkout. Never checkout, stash, reset or commit the B3 agent's changes.
Do not run concurrent Cargo jobs against the same target or concurrent fixture
scripts with the same Compose project/ports. Reserve Docker and build windows;
do not prune the existing target or stop another agent's containers. Follow the
[playbook concurrency guidance](../validation-playbook.md#agent-task-template)
and record the actual worktree, base SHA and reservations in each handoff.

### Dispatch waves and dependencies

| Wave | Ready tasks | Exit condition |
| --- | --- | --- |
| 1 | Policy E1 → E2; daemon G3; editor F1 → F3 → F5 → F2; fixture C6 split by engine | Shared transaction refusal and cache refusal proven; session callbacks/retirement/close safe. Independent work may overlap only with reserved files and fixtures. |
| 2 | F4 + F9 after F3/F5; F6 after tunnel ownership integration; G5 after G3; I2 after F6 transport changes | Reconnect invalidates old sessions, built-in host trust is explicit, unattended daemon behavior and Flatpak refusal are proven. |
| 3 | F8 after E/F4 lifecycle integration; I5 after F6/G5 and F8 audit contract; I3 after C6/G5/I2; F7 after F2/F3/F4/F5/F8 | Audit scope and transport events verified; GTK flow registered and executed; docs match integrated behavior. |
| 4 | Integrated affected layers, then installed Arch/Omarchy/Hyprland native Wayland acceptance | Candidate SHA and native workflow evidence recorded, including package upgrade/rollback. |
| 5 | I1, then required installed Debian/GNOME native Wayland acceptance | Debian recipe/helper, installed workflows and upgrade/rollback proven. |

B3 completion remains the sprint prerequisite for closing B4 acceptance. Review
and isolated preparation can proceed now; integration must use the latest
accepted B3 baseline. Installed qualification and B7 release approval stay
separate decisions. A green task or layer does not close B4.

### Detailed agent packets

Unless progress below says otherwise, implementation or runtime acceptance is
pending. Common handoff and validation rules follow the packets.

### Isolated implementation progress (October 2)

Three B4 packets have implementation commits on clean worktrees rebased onto
the current B3 tip `1cf609c5daf508a979708dbaf892bd6975031193`. They are not merged
into `linux`; leave their lane status open until integration and affected-layer
validation finish. B3 remains active in the main checkout.

| Task | Worktree / branch / commit | Evidence on current rebased branch |
| --- | --- | --- |
| F1 | `/tmp/tablepro-b4-f1`, `codex-b4-f1`, `95bb1a7c1` | Stop visibility and Escape/click handling use the active guarded connection's `supports_server_cancellation`. The regression covers running/cancellable, running/unsupported and idle states. App library: 420 passed, 15 ignored; app Clippy with `-D warnings`, fmt, and file/function/bounded-operation/panic guards pass. |
| F3 | Same worktree, `417ad1975` | Session open, state, confirmation and commit callbacks carry a per-session UUID; stale success handles are closed and stale state/error/completion callbacks are ignored. Five session-mode tests pass, including old transaction state not changing the replacement; full app library result is above. |
| G3 | `/tmp/tablepro-b4-g3`, `codex-b4-g3`, `236e35220` | Digest failures before cache lookup refuse reuse; post-connect failure drops the new handle. Tests prove zero query dispatch, cleanup, verified cache reuse and retained key-rotation behavior. Agentd library: 14 passed; agentd Clippy with `-D warnings` passes. Both new failure tests were observed failing before the fix on the initial base. |

F1/F3 use the app test target in `/tmp/tablepro-b4-f1-target`; G3 uses
`/tmp/tablepro-b4-g3-target`. Rebase and rerun affected tests whenever `linux`
advances before integration. The B3 reconnect tests added useful F9 context and
did not conflict with the B4 editor or agentd files. These narrow results do
not replace the final combined layers or installed Arch/Debian acceptance.

#### Follow-up implementation packets (October 2)

The current `linux` tip has advanced to `d7007a6a6`. E1 and F2 were implemented
in isolated worktrees, rebased onto that tip, and pushed as separate review
branches. A temporary integration tree passed the combined affected layers;
the packets remain open until integrated into `linux` and hosted review checks
finish. Direct pushes to these feature branches do not trigger the Linux
workflows; PRs targeting `linux` or manual dispatch by ref do.

| Task | Worktree / branch / commit | Evidence and remaining acceptance |
| --- | --- | --- |
| E1 | `/tmp/tablepro-b4-e1/linux`, `codex-b4-e1`, `3c165a0d7` | The dialect-aware shared policy gate refuses MySQL XA start and autocommit-off and SQL Server implicit transactions before approval/dispatch; tokens in comments/literals are ignored and safe neighboring statements remain allowed. Exact-tip report `target/quality/20261002T202739203539Z-layers/report.json`: `quick` and `security-policy` passed; policy lib: 165 passed. E2 is the next policy packet but depends on E1 review/integration. |
| F2 | `/tmp/tablepro-b4-f1`, `codex-b4-f2`, `495c39931` | Editor teardown cancels/drains runs, joins opens, and awaits one close before tab/window/connection destruction; rollback failures stay visible and audited as unknown. Exact-tip report `target/quality/20261002T202523816125Z-layers/report.json`: `full`, `widgets`, `postgres-release` passed; app lib: 425 passed, 15 ignored. Real PostgreSQL selector `closing_a_session_with_an_open_transaction_rolls_it_back_on_real_postgres` passed (1/1), verifying fresh-connection row state and rollback audit. Route order ensures pending saves/discards precede a tab's rollback prompt. |

Combined validation: temporary worktree `/tmp/tablepro-b4-integration`, merge
commit `b9e75ac26` (base `d7007a6a6`), report
`target/quality/20261002T203352934307Z-layers/report.json`. `quick`,
`security-policy`, `full`, `widgets` and `postgres-release` all passed on the
combined E1+F2 tree. The real PostgreSQL rollback/audit selector also passed on
that tree (1/1).

F2 route trace at the pushed branch:

| Route | Guard and continuation | Evidence / remaining limit |
| --- | --- | --- |
| Single or bulk tab close | Pending save/discard resolves first; then transaction prompt. Cancel leaves the tab/session; confirm awaits that editor before removing it. Bulk actions use the same page-close hook per tab. | `workspace_tabs.rs`, `workspace_close.rs`; app unit and widget layers pass. No installed Wayland route run yet. |
| Window close / quit | Existing dirty-save prompt and workspace flush finish first; transaction prompt follows. All editor replies must succeed before the close is retried. | `init_window.rs`, `session_teardown.rs`; window remains open on cleanup error/timeout. Installed acceptance pending. |
| Disconnect | Existing pending-change prompt then transaction prompt; await every editor before tabs or DB connection are closed. | `connection.rs`, `session_teardown.rs`; unknown/error prevents disconnect completion. |
| Connection switch | Existing running-query and dirty-change decisions precede transaction confirmation; await all editors before replacing the old connection. | `connection.rs`, `session_teardown.rs`; error resets transition and retains the current connection. |
| Editor shutdown | Normal user teardown routes above intercept and await; component shutdown keeps detached close only as a final fallback for unexpected shutdown. | `editor/mod.rs`, `session_mode.rs`; close helper is idempotent and the underlying handle closes once. |

Focused F2 regressions cover delayed close, close error and duplicate close, active-query/open gating, multiple editor replies and stale session callbacks. The report artifacts above are local; hosted workflow checks remain pending because direct pushes to the feature branches do not trigger workflows.

The `Build Linux` workflow covers `linux/**` pushes/PRs and runs `full` and
`widgets`, so it will exercise the app changes on a PR to `linux`. The separate
`Linux test quality` workflow covers policy mutation/coverage but intentionally
does not measure the GTK app crate. `Linux Security` includes `security-policy`
and triggers for Linux PRs. No workflow run has yet validated these two pushed
branches.

#### E1: refuse implicit transaction starters on shared connections

- Inspect `crates/policy/src/{classify.rs,rules.rs,transaction_control.rs,guard.rs}`
  and all callers of `shared_connection_decision`; inspect controlled, parameter,
  batch and MCP paths. Keep dedicated-session behavior as decision 4 specifies.
- Reproduce MySQL `SET autocommit=0`, SQL Server `SET IMPLICIT_TRANSACTIONS ON`
  and MySQL `XA START`. Include case/whitespace/comments and dialect-valid
  variants, both standalone and inside a script. Check parser failure paths so
  human approval cannot bypass shared-connection refusal.
- Implement at the shared policy boundary. Tests assert denial before dispatch,
  the required denial audit, and allowed ordinary SET/read/complete explicit
  transaction behavior. Distinguish SQL tokens from strings/comments; avoid a
  new independent SQL parser or broad denial of every SET statement.
- Finish with focused policy tests and `quick security-policy`. Return exact
  selectors and initial behavior for each starter; document unsupported syntax.

#### E2: refuse unterminated shared transaction batches

- Depends on E1. Inspect existing SQL splitting/classification and guarded batch
  dispatch, plus MySQL/SQL Server policy integration fixtures. Reuse statement
  order and transaction-control helpers; do not infer balance from substrings.
- Reproduce `BEGIN; UPDATE ...` without a terminal COMMIT/ROLLBACK on both real
  engines. Assert refusal occurs before BEGIN or UPDATE is sent and that an
  independent connection sees unchanged data with no leaked transaction/lock.
- Cover completed COMMIT and ROLLBACK batches, BEGIN-only/BEGIN+SELECT scripts,
  comments/quoted transaction words, nested starts, stray endings and chained
  endings that reopen a transaction. Define engine-specific DDL/implicit-commit
  cases explicitly; do not claim general balance from a simple counter.
- Retain session behavior and existing policy/approval rules. Run
  `quick security-policy drivers`; register any new live regression in its
  owning runner and ignored-test ledger. A mock is supplemental to engine evidence.

#### G3: refuse unverifiable cached or freshly connected daemon handles

- Inspect `crates/agentd/src/lib.rs::{connection_for,cached_connection,connect_session}`
  and `crates/transport/src/session_material.rs`. Preserve G2's successful
  key-rotation re-digest behavior.
- Seed a healthy cached connection, then make required key/CA material unreadable
  or missing. Assert the first digest error refuses before cache reuse or SQL
  dispatch. Add a deterministic connect-time change causing the second digest
  to fail; do not depend on timing sleeps.
- Remove both weaker fallbacks. A handle created before verification fails must
  not enter the cache or remain usable through another caller; assert cleanup
  and a sanitized error. Test verified cache reuse and successful key rotation.
- Run focused agentd/transport checks and `quick security-policy`; retain G1/G2.
  Return which verification failed and evidence that no query reached the handle.

#### F1: show Stop only when cancellation is supported

- Inspect `editor/mod.rs::{set_running,on_run}` and every Cancel input/shortcut,
  `StatementTarget`, and capability forwarding through guarded connections.
- Capture the active execution capability. Show/enable Stop only when
  `supports_server_cancellation` allows it; enforce the same rule on keyboard
  actions. Derive actual engine expectations from current implementations.
- Cover supported/unsupported connections, session execution, switching or
  reconnect during a run, and normal timeout/result completion. Hidden Stop
  must not hide timeout or uncertain-outcome feedback.
- Run focused app units and `full`; retain an installed supported/unsupported
  engine check for the Arch acceptance packet.

#### F3: reject stale session callbacks

- Inspect `editor/{mod.rs,session_mode.rs}` and every session open/state/end/commit
  message. Reuse run generation and shared-session identity where suitable;
  connection UUID alone cannot distinguish two sessions on the same connection.
- Start session A, replace it with B, then deliver A's state and commit/open
  completions. Assert B's label, toggle, handle and pending state remain unchanged.
  Include a cancelled open followed by a new open against the same saved UUID.
- Match callbacks to their initiating session/open attempt and underlying
  connection. Close discarded opened handles safely; a stale error must not
  turn off the new session. Do not build a general event framework.
- Run focused app units and `full`. Return the identities carried by each
  callback and exact stale-success/stale-error selectors. F5/F2 build on this.

#### F5: reflect retired sessions without pool fallback

- Depends on F3; D3 is delivered. Inspect `StatementTarget`, session completion
  reporting and `Session::is_usable`, including B3's newer driver retirement fixes.
- Reproduce a session becoming unusable after disconnect/timeout. Report
  usability together with transaction state and the matching identity; turn
  Session off and display actionable retirement/uncertainty feedback.
- Assert a retired handle refuses subsequent dispatch, other editors remain
  unaffected, and no statement silently falls back to the shared pool. Cover
  usable sessions after ordinary errors and stale retired-session callbacks.
- Run focused app checks, `full`, and the relevant existing driver retirement
  regression when driver integration is implicated. Do not redo D3/H4.

#### F2: await session cleanup before close or connection teardown

- Depends on F3/F5. Trace tab close, bulk tab close, window close/quit,
  Disconnect, connection switch and editor shutdown through
  `ui/app/{workspace_close.rs,workspace_tabs.rs,connection.rs,init_window.rs}`
  and `editor/session_mode.rs`. Preserve file-save and pending-grid-change prompts.
- Reproduce Session → BEGIN → UPDATE → each teardown route. Cancel leaves
  the original session available. Confirmed rollback must complete before the
  component/connection/runtime is destroyed, with exactly one close per handle.
- Replace detached cleanup on awaited user teardown routes with explicit
  completion messages. Test delayed close, close error, running query,
  duplicate requests, multiple editor sessions and stale completion. Bound
  cleanup; failure/unknown outcome must remain visible and audited, never be
  reported as successful rollback. Ensure app lifetime survives pending cleanup.
- Run focused app tests and `full widgets`; supplement with real PostgreSQL
  state/audit evidence in `postgres-release` where needed. Return the route
  coverage table and show unchanged server data after successful rollback.

#### F4 + F9: tunnel loss, reconnect and dedicated-session invalidation

- One coordinated packet, split into F9 transport and F4 editor commits.
  Depends on F3/F5. Inspect `transport/src/route.rs::Tunnel`,
  `ssh/src/lib.rs::SshTunnel::is_closed`, `services/{connection_monitor.rs,database_service.rs}`
  and `ui/app/connection.rs::on_poll_health`.
- F9: consume built-in closed state through existing tunnel/monitor ownership.
  Detect dead transport even when the driver's pooled ping can still succeed;
  retain bounded backoff, cancel-on-disconnect and one reconnect loop. Define
  and assert a detection bound; merely exposing another accessor is incomplete.
- F4: reuse `DatabaseService::identity/get_with_identity` to detect replacement
  of the underlying connection, including same saved UUID. Retire old editor
  sessions and invalidate pending callbacks; never replay BEGIN/writes or pretend
  an old transaction survived reconnect. Preserve other windows/connections.
- Unit-test loss notification, successful swap, unsuccessful retry, cancellation
  and old-session refusal. Reproduce real bastion loss/restart with existing SSH
  or PostgreSQL release fixtures; verify a new query works through a new tunnel
  and the old session cannot write. Run `full ssh postgres-release` using reserved
  fixture slots. Cross-link evidence under both F4 and F9 before closing A5.

#### F6: explicit built-in SSH host-key trust

- Inspect `ssh` host-key callback/known-hosts code, `SshEnvironment`, GUI initial
  connection/reconnect environments, and `ui/ssh_prompt.rs::GtkPrompter`.
  Reuse its host/algorithm/fingerprint question and main-context dispatch.
- Unknown key: prompt before learning, persist only after acceptance. Decline,
  cancelled connection, dialog close/window close and failed persistence must
  refuse. Known matching key connects; changed key refuses without silently
  overwriting trust. Cover each jump hop and reconnect to a changed host.
- Pass a headless refusal path for agentd; avoid introducing GTK into SSH or
  transport. Cancellation must dismiss/resolve pending prompts and release
  resources. Do not learn first and ask afterward.
- Run focused trust tests, isolated prompt widgets and `full ssh widgets`.
  Record known-hosts contents before/after accept/decline/mismatch. I5 uses
  these same outcomes for audit evidence.

#### F8: scope unknown-write blocking to the connection

- Coordinate policy and app owners after lifecycle integration. Inspect all
  `AuditState` construction/disable/drop paths, guarded session and bulk-import
  ownership, app transition checks and agentd/MCP consumers before changing APIs.
- Reproduce uncertain write on A while B remains healthy. Block subsequent
  governed writes on A only; a verified new connection generation restores A,
  while old-generation late failures cannot poison the replacement.
- Keep journal unavailable/unpersistable and recovered unresolved-intent safety
  separate from connection uncertainty. A reconnect must not clear a journal-wide
  failure or invent a terminal audit record for an unknown old write. Cover
  session/bulk drop, simultaneous connections, reads and failed reconnect.
- Policy assertions must cover allow/deny and terminal audit states; app tests
  prove the connection-specific transition UI. Run `full security-policy
  postgres-release`, update manual checklist decision 3, and require security
  review of the shared state API before marking F8 done.

#### C6-MySQL and C6-SQLServer: TLS identity through actual SSH

- Two serial handoffs with the same fixture owner. Inspect
  `crates/driver-tls-tests/{src/lib.rs,tests/mysql_tls.rs,tests/mssql_tls.rs}`,
  `tests/fixtures/driver-tls`, transport connection assembly and the existing
  PostgreSQL bastion fixture. Reuse C4/C5 and certificate-generation helpers.
- C6-MySQL: actual socket forwarding through SSH, TLS verified against the
  original service name. C6-SQLServer: actual TCP forwarding with the original
  service identity preserved. The endpoint must be reachable only through the
  bastion for the tested route; direct access cannot satisfy the assertion.
- Per engine prove valid CA/name success with a native query, wrong CA failure,
  wrong hostname failure, refusal of the local dial address as identity and no
  plaintext fallback. Check tunnel cleanup on rejection; cover built-in versus
  OpenSSH routes explicitly or leave the untested backend pending by name.
- Add ignored cases to the existing TLS runner/inventory and run `tls` plus
  `ssh` if shared fixture code changes. Record exact executed tests and engine/
  backend matrix. Close C6 only when both engine subtasks have evidence.

#### G5: agentd system OpenSSH without interactive approval

- Depends on G3; coordinate shared route changes with F6/I2. Inspect
  `agentd/src/main.rs` unattended environment setup and the daemon's actual
  saved-connection path, not only `OpenSshSession` in isolation.
- Use a real bastion and daemon-owned request: an unknown host requiring trust
  must decline with no known-hosts update or cached DB handle. A pretrusted host
  with unattended credentials must connect and return a policy-guarded result.
- Cover changed host key, cancellation/timeout and master/forward cleanup.
  Prove token scope, connection allowlist and policy denial remain enforced
  after transport success. No automatic learning or GUI prompt in agentd.
- Place evidence in the existing SSH/release ownership and wire its runner.
  Run `quick ssh postgres-release security-policy` as affected. Report actual
  daemon entry path exercised; a constant assertion cannot close this packet.

#### I2: explicit system OpenSSH refusal in Flatpak

- Inspect `transport/src/route.rs::system_openssh/open_openssh`, GUI/agentd setup
  and existing sandbox tests. Detect the real sandbox through a testable boundary
  without process-global environment races in parallel tests.
- Saved system-OpenSSH choice inside Flatpak must refuse clearly, before any
  host helper launch or automatic built-in fallback. Built-in SSH remains usable;
  native system OpenSSH remains supported. Missing native helpers have their own
  actionable error, not a false Flatpak diagnosis.
- Retain decision 2 in `connections.md` and every current sprint description;
  annotate obsolete historical fallback text. Run focused transport tests and
  `quick`; record Flatpak runtime acceptance separately from simulated tests.

#### I5: transport setup and host-key refusal audit records

- Depends on F6/G5 and F8's state contract. Inspect existing `AuditEvent`,
  `AuditJournal` and composition hooks in GUI/agentd. Define the smallest event
  representation consistent with the persisted audit format and compatibility.
- Record connect/reconnect tunnel setup success/failure and host-key refusal
  for built-in and system SSH, GUI and daemon. Include connection/attempt identity
  and safe outcome metadata; exclude secrets, private-key contents and SQL values.
- Assert ordering, one terminal event per attempt, decline/mismatch/cancel and
  journal-write failure behavior. Do not duplicate events at every hop/caller or
  swallow persistence errors. Decide and document handling before changing it.
- Run `full security-policy ssh postgres-release` as affected. Return event
  examples with sensitive data removed and the backend/consumer coverage matrix.

#### F7: isolated Session GTK workflow regression

- Depends on F2/F3/F4/F5/F8. Use existing widget harness and session fixtures;
  reserve `gtk_safety.py` until its B3 owner releases it. GTK code stays on the
  main context and database work remains asynchronous.
- Session on → BEGIN → transaction-open label → Session off opens the dialog.
  Cancel preserves session; rollback clears it only after completion. Add stale
  callback/retirement assertions to the lowest existing tier that can prove them,
  with engine persistence proven by a real-server test rather than a widget fake.
- Register each ignored widget selector in `scripts/isolated-tests.json`,
  regenerate `docs/ignored-tests.md`, and prove it executes exactly once. Run
  `widgets` and `ui` if the installed safety flow changes. Xvfb results do not
  qualify native Wayland acceptance.

#### I3: reconcile transport documentation and evidence ownership

- Depends on C6/G5/I2 outcomes. Update `docs/{upstream-sync.md,connections.md,testing.md,validation-playbook.md}`
  only where evidence changes. Describe the older no-askpass passage as its dated
  baseline; keep adoption history and current helper behavior unambiguous.
- Publish engine × backend × TLS/auth/reconnect evidence with exact selectors,
  tested SHA and owning tier. Keep unknown combinations pending. A drivers-layer
  SSH runner pass proves its SSH cases, not every engine's TLS through SSH.
- Reconcile this board and the sprint B4 summary, verify relative links and task
  IDs, and preserve I4's unchecked runtime boxes. Documentation review requires
  no unrelated full Rust rebuild.

#### Arch acceptance, I1 and required Debian/GNOME follow-up

- Integration owner freezes an accepted B3+B4 SHA and runs the affected layers
  listed below before packaging. Use `manual-verification-0.2-features.md` for
  installed Arch/Omarchy/Hyprland native Wayland flows: Stop/timeouts, failed
  COMMIT, every close route, stale/retired sessions, reconnect/bastion loss, host
  trust, per-connection blocking, keyring/MCP and askpass launch.
- Record artifact/hash, package version, desktop/library versions, exact steps,
  expected/observed result and screenshots where needed. Upgrade/rollback must
  preserve saved connections, secrets, workspace and audit data. I4 supplied
  instructions only; tick runtime boxes only after executing these checks.
- After Arch, I1 owns `packaging/debian/rules`,
  `scripts/validate-deb-package.sh` and `scripts/tests/test_deb_package.py`.
  Build/install `tablepro-askpass` consistently with `scripts/build-deb.sh`;
  validator must reject missing/non-executable helpers. Prove the rules recipe,
  not just the standalone build script, yields a usable package. Avoid the
  recipe's clean target against another agent's shared build cache.
- Run `packaging-contracts`, inspect the produced Debian archive and perform
  installed Debian/GNOME native Wayland workflows plus upgrade/rollback.
  Full Flatpak release qualification and B7 soak/release approval remain later
  acceptance work; simulated Flatpak refusal closes only I2's automated scope.

### Agent handoff and completion evidence

Use the [existing handoff template](../validation-playbook.md#agent-task-template).
For each packet fill the absolute worktree, current full SHA, allowed files,
other owners, exact reproducer, selected layers, available tools, build/fixture
reservation and authorization. Do not assume push permission from this plan.
The first bounded handoffs **F1**, **F3** and **G3** have isolated commits
listed above. The next ready handoffs are **E1** and **C6-MySQL**, after current
source/status and shared resources are rechecked; F5 follows F3 in the editor
lane. No implementation agent is launched by this documentation update.

Each returned packet must include:

1. Source trace and initial failure, or an already-covered result with an exact
   passing selector and no unnecessary implementation change.
2. Smallest root-cause patch, permanent regression, valid/invalid neighbors and
   real engine/UI evidence where named above. Record every added selector.
3. Exact commands, exit results, selected/executed counts, commit SHA and retained
   reports under `target/quality/`; label blocked/not-run/local/hosted/installed
   evidence separately. Missing prerequisites are not passes.
4. One task status/evidence update under the original ID, caller compatibility,
   user-facing changelog only if required, unresolved risks and handoff to the
   dependent owner. Shared ledgers are merged by the integration owner.

Rust changes use the existing format, Clippy and size/panic/bounded-operation
guards via `quick` or `full`; GTK code needs `full`. Select additional catalog
layers by affected behavior, without repeating overlapping suites gratuitously.
Run commands from `linux/` with `rtk proxy`, for example:

```bash
rtk proxy python3 scripts/run-test-layer.py quick security-policy
rtk proxy python3 scripts/run-test-layer.py full widgets
rtk proxy python3 scripts/run-test-layer.py tls
rtk proxy python3 scripts/run-test-layer.py ssh postgres-release
```

These are future implementation checks, not results of this review. At final
integration run `full security-policy drivers tls postgres-release widgets ui
packaging-contracts` and add `keyring`/other affected layers if their contracts
changed. Preserve hosted ownership for added tests; a filtered command returning
zero executed tests is incomplete. Installed acceptance uses the same frozen
candidate, followed by the required Debian phase and the existing B7 process.

### B4 completion checklist

- [ ] E1/E2 and G3 refuse unsafe shared/cache behavior with no pre-denial dispatch.
- [ ] F1–F5 and F9 prove capability, identity, retirement, awaited cleanup and reconnect.
- [ ] F6/G5 prove explicit GUI trust and unattended daemon refusal/success.
- [ ] F8/I5 prove correctly scoped write blocking and transport audit outcomes.
- [ ] C6 proves MySQL and SQL Server TLS through real SSH with negative identity cases.
- [ ] F7 is registered/executed; I2/I3 agree with runtime behavior and evidence.
- [ ] Integrated affected gates pass on the recorded candidate; completed A/B/C/D/G/H regressions remain retained.
- [ ] Installed Arch native Wayland qualification and upgrade/rollback recorded.
- [ ] I1 and required Debian/GNOME qualification and upgrade/rollback recorded.

## September 28 continuation (historical evidence)

Reviewed at `85fecbe0b`. See the [commit archive](sprint-review-2026-09-28.md)
and [active B4 acceptance work](../b4-task-board.md#next-b4-acceptance-run).
A/B, C1–C5, D, G1/G2/G4 and H have recorded implementation/regression evidence;
B4 remains open for C6, E, F, G3/G5 and active I tasks. A5's monitor follow-up is F9.
Existing results apply to their recorded revisions; this review reran no tests.

Current UI target: Arch/Omarchy/Hyprland native Wayland. GNOME desktop and Debian
installed acceptance, including I1, are the required next phase after Arch. The GTK/libadwaita build stack
remains. Use one bounded task per Luna handoff and serialize shared editor files.

## Rules for every task

1. Audit the named behavior and cite the code.
2. Write the failing reproducer first, in the lowest tier that can show it.
   Record the failure message.
3. Fix the root cause with the smallest change. Keep the reproducer as a
   permanent regression test.
4. Run the affected crate tests, Clippy with `-D warnings`, `cargo fmt`, and the
   file-size and function-size guards. Regenerate `ignored-tests.md` when an
   `#[ignore]` test is added.
5. Add a changelog line only for user-visible behavior. Commit one fix per
   commit.
6. Stay inside the lane's files. Tasks in the same lane run in order.

A task that names a decision follows the recorded decision.

## Decisions

The seven September 27 decisions are now recorded in
[ADR 0008](../decisions/0008-connection-and-session-ownership.md). The stable numbers
below preserve task references; the ADR owns the rules and this board owns
implementation/acceptance. Accepted architecture is not a runtime pass.

| Legacy decision | ADR section | Owning implementation |
| --- | --- | --- |
| 1: built-in host-key consent | [Trust and route selection](../decisions/0008-connection-and-session-ownership.md#trust-and-route-selection) | F6 |
| 2: unavailable Flatpak OpenSSH route | [Trust and route selection](../decisions/0008-connection-and-session-ownership.md#trust-and-route-selection) | I2 |
| 3: connection uncertainty scope | [Uncertainty scope](../decisions/0008-connection-and-session-ownership.md#uncertainty-scope) | F8; journal-wide failures remain fail-closed |
| 4: implicit shared transaction starters | [Identity and transaction ownership](../decisions/0008-connection-and-session-ownership.md#identity-and-transaction-ownership) | E1 |
| 5: unterminated shared transaction batches | [Identity and transaction ownership](../decisions/0008-connection-and-session-ownership.md#identity-and-transaction-ownership) | E2 |
| 6: transport/trust audit records | [Trust and route selection](../decisions/0008-connection-and-session-ownership.md#trust-and-route-selection) | I5 |
| 7: verified daemon cache reuse | [Trust and route selection](../decisions/0008-connection-and-session-ownership.md#trust-and-route-selection) | G3/G5 |

## Lane A: built-in SSH — implementation delivered; A5 monitor follow-up open

Files: `crates/ssh/src/lib.rs`, `crates/ssh/tests/agent_auth.rs`.

| # | Task | Tier | Status |
|---|---|---|---|
| A1 | The unknown-key error advises connecting once with `ssh`, which writes `~/.ssh/known_hosts`. The built-in client reads only its own `known_hosts`. Correct the message. | unit | done, `d8e3479fc` |
| A2 | Real-server tests for password, wrong password, rejected key and an encrypted key with passphrase. | ssh | done, `543bed77d` |
| A3 | A real two-hop chain succeeds, and a changed key on the second hop returns a host-key mismatch. | ssh | done, `543bed77d` |
| A4 | Keyboard-interactive login is not supported. Return a clear error and test it. | unit | done, `12bd158de` |
| A5 | Add keepalive and expose tunnel loss, so a dead bastion triggers reconnect instead of driver timeouts. | unit, then release | done, `6fca02c24`. Keepalive and `SshTunnel::is_closed()` land in `crates/ssh`; wiring a reconnect from the transport layer on `is_closed()` remains open as F9. This does not yet prove the complete reconnect behavior in A5. |

## Lane B: system OpenSSH — done (2026-09-27)

Files: `crates/ssh/src/openssh/*`, `crates/ssh/tests/openssh_*.rs`, `crates/transport/src/route.rs`.

| # | Task | Tier | Status |
|---|---|---|---|
| B1 | `route.rs:105` passes a new `CancellationToken`, so a caller's cancel never reaches the connect. Pass the caller's token. Test that cancelling during a prompt stops the master and removes its directory. | unit (fake ssh) | done, `9746d9a05` |
| B2 | If the app is killed, the `ssh -M` master keeps running until the next launch. Set a parent-death signal when spawning it. Test by killing the parent. | unit | done, `9746d9a05` |
| B3 | A `ProxyJump` line in the SSH config reaches the target. The current jump test only asserts failure. | ssh | done, `bfa4be264` |
| B4 | Real tests for a changed host key, key auth, agent auth and passphrase auth. | ssh | done, `528f5b3ad` |
| B5 | `OpenSshAuth::KeyboardInteractive` cannot be selected (`route.rs:73-82`). Remove it or make it saveable. | unit | done, `f248ec6d9`. Removed: nothing in transport/storage/app could ever construct it, and wiring it end to end was disproportionate to a mode nothing exposes. |

## Lane C: TLS through the tunnel — C1-C5 done (2026-09-27), C6 open

Files: `crates/drivers/{clickhouse,mongodb,redis,mssql}`, `crates/driver-tls-tests`, `scripts/test-driver-tls.sh`.

| # | Task | Tier | Status |
|---|---|---|---|
| C1 | ClickHouse checks the certificate against the tunnel's 127.0.0.1, so Verify CA and Verify Full fail through SSH. Use the service hostname. | unit | done, `608525079` |
| C2 | The same for MongoDB. | unit | done, `b83e62618` |
| C3 | The same for Redis. | unit | done, `8fd527f2f` |
| C4 | SQL Server has no TLS test. Add it to the TLS fixture with verify, wrong CA and wrong hostname cases. | driver-tls | done, `cb84d0ec3` |
| C5 | Add no-plaintext-fallback tests for MySQL, ClickHouse and SQL Server. | driver-tls | done, `cb84d0ec3` |
| C6 | Prove TLS through SSH for MySQL's socket forward and SQL Server's identity. Needs C4 and a bastion in the fixture. | driver-tls | open, C4 is now available |

## Lane D: policy sessions — D1-D8 done (2026-09-28)

Files: `crates/policy/src/guard/session.rs`, `crates/policy/src/guard_tests_session.rs`. One agent, in order.

| # | Task | Tier | Status |
|---|---|---|---|
| D1 | A PostgreSQL COMMIT on an aborted transaction is audited as committed, although the server rolled back. | driver | fixed, `6ae98c0ed`; the real-Postgres gap is closed by `01f892ac2`, which confirms it unmodified. |
| D2 | A failed COMMIT keeps a batch open after the engine has already ended the transaction, for example a deferred foreign key failure. | driver | fixed, `29b0a6b02`; the real-Postgres gap is closed by `01f892ac2`, which confirms it unmodified. |
| D3 | A statement on a retired session is sent and fails as an ambiguous error, which turns off governed writes. Refuse it before dispatch. | unit | done, `8428263d3` |
| D4 | A `Disconnected` error retires the session and marks its transaction uncertain. | unit | done, `8428263d3` |
| D5 | Audit or refuse COMMIT without BEGIN and a nested BEGIN. | unit | done, `8428263d3` |
| D6 | Cover a denied, cancelled or timed-out statement inside a transaction followed by COMMIT, and ROLLBACK AND CHAIN. | unit | done, `6ae98c0ed` |
| D7 | Cancelled, timed-out and unknown outcomes on the session path write the required audit state. | unit | done, `29b0a6b02` |
| D8 | A guarded session on real PostgreSQL: BEGIN, UPDATE and close write an audited ROLLBACK and leave the row unchanged. | driver | done; the mocked-driver unit test (`closing_a_session_with_an_open_transaction_rolls_it_back_and_audits_it`) is now backed by a real-Postgres reproduction in `01f892ac2`. |

## Lane E: policy rules

Files: `crates/policy/src/rules.rs`, `crates/policy/src/transaction_control.rs`.

| # | Task | Tier |
|---|---|---|
| E1 | Implicit transaction starters. Decision 4. | unit |
| E2 | Unterminated batches on shared connections, with MySQL and SQL Server reproducers. Decision 5. | driver |

## Lane F: GUI

Files: `crates/app/src/ui/editor/*`, `crates/app/src/ui/app/*`, `crates/app/src/services/*`.

| # | Task | Tier |
|---|---|---|
| F1 | Stop is shown for engines that cannot stop a query (SQL Server, DuckDB, MongoDB, Redis). Gate it on `supports_server_cancellation`. | unit |
| F2 | Window close and Disconnect ignore an open session transaction, and the ROLLBACK may not finish before exit. | unit |
| F3 | The session state message has no session identity, so a late message can relabel a newer session. | unit |
| F4 | After an automatic reconnect, end or mark the editor sessions on that connection. | unit |
| F5 | A retired session turns its toggle off. Needs D3. | unit |
| F6 | Host-key prompt for built-in SSH. Decision 1. | unit, gtk-widgets |
| F7 | An isolated GTK test: Session on, BEGIN, "transaction open" label, toggle off shows the dialog. | gtk-widgets |
| F8 | Governed writes turn off only for the connection with the unknown outcome and return when that connection restarts. Decision 3. Document it in the manual checklist. | unit |
| F9 | Consume the built-in `SshTunnel::is_closed()` state through transport/connection-monitor ownership, then retire old editor sessions and reconnect. A5 added the API but no consumer. Coordinate with F4; reproduce bastion loss against a real SSH fixture. | unit, ssh/release |

F2, F3 and F5 share editor files and go to one agent in order.

## Lane G: agentd and MCP — G1/G2/G4 done (2026-09-27), G3/G5 open (need decision 7 / wave 2)

Files: `crates/agentd`, `crates/mcp`, `crates/release-tests`.

| # | Task | Tier | Status |
|---|---|---|---|
| G1 | "agentd refuses unknown host keys" is backed only by a constant assert, and the release test uses `Learn`. Test with an empty `known_hosts`: refused, and no file written. | release | done, `96cd2f8f7` |
| G2 | Race test for key material rotated between the digest and the connection, pending since the 2026-09-17 baseline review. | unit | done, `256bf0572`. Fixed by recomputing the session-material digest after `establish()` succeeds and caching under that key. |
| G3 | Refuse reuse of a cached connection with unverifiable key material. Cover digest failure before cache lookup and after connect; the latter still retains the old digest. Decision 7. | unit | open |
| G4 | MCP shutdown during a write records a Cancelled or Unknown audit outcome. | mcp tests | done, `eb3682068`. Force-shutdown deadline now derives from `query_timeout_secs + 5s` instead of a hardcoded 5s. |
| G5 | agentd through OpenSSH: an unattended decline and a successful connect. | ssh | open |

## Lane H: driver cancellation and refusal — H1-H4 done (2026-09-27/28)

Files: driver `src/lib.rs` and tests for the engines named.

| # | Task | Tier | Status |
|---|---|---|---|
| H1 | ClickHouse, DuckDB, MongoDB and Redis refuse `open_session`, one test each. | unit | done, `1059edfb6`. Behavior was already correct; added regression tests only. |
| H2 | A MySQL session cancel returns Cancelled and leaves the session usable. | driver | done, `2c7321638`. Behavior was already correct; added a real-MySQL regression test. |
| H3 | DuckDB and MongoDB timeouts return an unknown outcome. | unit | done, `33ed55080`. Behavior was already correct; added regression tests only. |
| H4 | SQL Server retirement reports to the connection monitor instead of waiting for the next 30 second ping. | unit | done, `0aef65e82`. `PolicyGuard::caught_read`/`caught_write` (`crates/policy/src/guard/panic_boundary.rs`) now report a `DriverError::Disconnected` result to `ConnectionFaultSink::connection_became_unusable`, the same fast-path hook that already fired on a caught panic. This reaches the app's `Arc<Notify>`-based connection monitor fast path (`crates/app/src/services/connection_monitor.rs`) for any driver, including SQL Server after `retire()`, without a `crates/drivers/mssql` change. |

## Lane I: packaging and docs

| # | Task | Tier |
|---|---|---|
| I1 | `packaging/debian/rules` does not build/install `tablepro-askpass`, although `scripts/build-deb.sh` already does. Fix the rules recipe and validator check in the required GNOME/Debian phase after Arch. | packaging |
| I2 | Flatpak OpenSSH behavior, and reconcile `connections.md` with the sprint doc. Decision 2. | unit, docs |
| I3 | Update the dated no-askpass claim in `upstream-sync.md`; distinguish SSH transport/auth fixtures from per-driver TLS-through-SSH evidence in the tier docs. The drivers layer invokes the SSH runner; this does not prove every driver uses a tunnel. | docs |
| I4 | Done in the September 28 documentation review: manual checks now cover Stop/timeout, failed COMMIT retry, close/Disconnect, retired sessions and connection-specific write blocking. Runtime boxes remain unchecked. | docs |
| I5 | Audit record for tunnel setup and host-key refusal. Decision 6. | unit |

## Remaining waves (September 28, superseded)

1. E1/E2 and G3; F1 and F3/F5/F2 in one editor stream. Keep recorded decisions.
2. F4/F9, F6/F8, C6/G5, then I2/I3/I5 and F7 after the lifecycle work.
3. Installed manual checks on Arch/Omarchy native Wayland. Automated tiers do not
   tick these boxes. Then complete the required GNOME desktop on Debian phase,
   including recipe I1 and installed Debian checks.

Completed lane tasks are archived evidence, not a request to reimplement them.
Review current callers and record a failure before changing behavior. Preserve
one regression and the existing tier ownership for every confirmed fix.


---

# Archived B4 dated checkpoints (2026-10-09 consolidation)

Moved from [b4-task-board.md](../b4-task-board.md). These snapshots are source-pinned evidence. Failed or incomplete hosted runs remain retest indicators; open rows stay on the live board and ledger.

## B4 continuation checkpoint (October 3; historical integration snapshot)

| Task | Integrated source | Remaining acceptance |
| --- | --- | --- |
| A1–A5, B1–B5, C1–C5, D1–D8, G1/G2/G4, H1–H4 | Prior implementation and regressions retained | Recheck affected cases on the frozen candidate; A5's consumer is F9 |
| E1/E2, G3, F1/F2/F3 | Merged in #13–#18 | No reimplementation; native/shared policy, verified cache and close-route acceptance at candidate SHA |
| F5 | Merged as `4b7814f5e` (#19) | Installed retirement/toggle flow |
| F4/F9 | Merged as `573435766` (#20) | Monitor consumes tunnel closure and swaps live identity; native reconnect and [release-binary GTK stale-session evidence](../evidence/ssh-reconnect-session-gtk-2026-10-07/manifest.json) passed; distribution-package/native Wayland acceptance remains |
| F6 | Merged as `d1434438e` and follow-up `6e2c5687a` (#22/#23) | GUI defaults to refusal and installs the built-in prompter. Native two-hop success, second-hop key-change refusal, and in-flight cancellation while the second-hop trust prompt is pending passed locally on `f3a1765` via `bash scripts/test-ssh.sh`; the [combined release-binary GTK run](../evidence/ssh-gtk-multihop-2026-10-07/manifest.json) passes all five default PostgreSQL release GTK scenarios, including two-hop success, second-hop decline, changed-key refusal, audit refusal, and saved mTLS. The current [relay image rerun](../evidence/postgres-release-relay-no-expose-2026-10-07/manifest.json) also passed after removing unnecessary EXPOSE metadata. The two-hop success, decline and changed-key flows each record exactly one terminal audit outcome. Frozen-candidate native cancellation and package-installed/native Wayland trust acceptance remain; all seven hosted release-binary PostgreSQL SSH GTK scenarios passed in [run #37708183936](https://github.com/cozyGarage/BookiE/actions/runs/37708183936) at PR #286 head `a056bf1` |
| F8 | GUI generation split merged as `6346a431c` (#24); daemon generations merged as `09c5351a3` | Policy, GUI and daemon scope uncertainty per connection generation while sharing journal failure. Agentd regressions cover isolation, replacement, late cancellation and shared journal failure; frozen-candidate and installed restart acceptance remain |

This table is the October 3 integration snapshot with later evidence links added
where useful. The current merged state is summarized below; merges do not imply
fresh hosted results. Historical reports and original packets are preserved in
[B4 history](b4-history.md); missing worktree/cache paths remain
unavailable evidence. The broad release audit is dated
[October 3](release-audit-2026-10-03.md).

## Latest merged slices (checked 2026-10-07)

| Task | Merge | Local evidence | Hosted state at last check |
| --- | --- | --- | --- |
| C6 | PR #150, merge commit `8f2df09ee` | MySQL and SQL Server tunneled TLS focused suite passed locally (43 tests) | Preflight, regression gate and SonarCloud failed; integration tests were skipped; Flatpak and supply-chain checks were queued or in progress |
| G5 | PR #151, merge commit `11672cbe6` | Actual system OpenSSH trust flow and PostgreSQL release suite passed locally; `audit_isolation_tests` passed separately (4 tests) | SonarCloud and resolve-ref passed; other checks were queued |

The current `linux` branch tip fetched on 2026-10-07 is `c8c06edd` (PR #201).
Recent B4 merges include #159 (SSH audit, rollback and Kerberos), #161/#162
(PostgreSQL GTK fixture setup), #163/#170/#173/#175 (SSH trust-prompt timeout
and dismissal), #165 (GTK SSH fixture hardening), and #178 (file-chooser
accessibility wait). PR #181 records fresh merged-linux plaintext bundle-audit
GTK runs; #182 adds a fresh encrypted-bundle run and corrects the stale I5 GTK
coverage row. PR #183 adds B3 UI and MSSQL coverage; #184 reconciles the sprint
baseline. PR #185 fixes bundle chooser interaction and connection-list rebuild
after its GTK run exposed a fatal-critical regression. The export, plaintext
import and encrypted retry/credential round-trip GTK scenarios were rerun on
`3a3d742fe` via `TABLEPRO_GTK_SCENARIO=bundle_export_records_sanitized_audit_outcome,bundle_import_records_sanitized_audit_outcome,encrypted_bundle_round_trip_restores_credentials bash scripts/test-gtk-safety.sh`;
all three passed on the local host under isolated D-Bus/Xvfb. The harness sets
`G_DEBUG=fatal-criticals`. The [PR #185 discussion](https://github.com/cozyGarage/BookiE/pull/185)
records the original failure and fix. Required pull-request checks on #185
completed successfully; Docker-backed suites and installed GTK safety were
skipped on the pull-request event. The later push run on #194's merge commit
([run 37641533809](https://github.com/cozyGarage/BookiE/actions/runs/37641533809))
was superseded by the #195 push: its installed GTK and driver integration jobs
were cancelled, and the Linux regression gate reported those cancelled lanes
as incomplete. This does not establish hosted installed-flow acceptance. The
[October 7 candidate
checkpoint](../evidence/b4-candidate-acceptance-2026-10-07/manifest.json) retains
the earlier candidate evidence. These runs do not establish frozen-candidate
or installed acceptance; those gates remain open.

## Previous merged-tip B4 checkpoint (2026-10-09; source `97e5f55`)

`fork/linux` is `97e5f55bddacdfef427c51f162917fedcace3a9f` after PR #451.
PR #451 makes the SSH cancellation fixture deterministic; its rebased focused
test passed 10/10 locally. On the merged tip, the per-user source build passed
the 54-scenario GTK safety suite, the MySQL approval-dialog regression, the
seven PostgreSQL SSH/mTLS GTK scenarios, and the 18-test `mysql_atomic`
selector. The PostgreSQL release fixture also passed one system OpenSSH test,
three mTLS tests, and 59 release integration tests. Logs, hashes, exact
selectors, and scope limits are in the [current-tip evidence](../evidence/b4-current-linux-tip-2026-10-09/manifest.json).

This evidence is from a user-local package-layout install, not a package built
and installed by pacman. The post-merge hosted Build Linux run was still in
progress when the evidence was captured. Distribution-package and native
Wayland acceptance and Windows AD interoperability remain open. A separate
manual launch on the earlier source `3b903b8` produced a GTK/Wayland
SIGSEGV. An isolated eight-second Wayland smoke on `97e5f55` showed no
SIGSEGV but did not reach workspace readiness because its D-Bus session could
not activate AT-SPI; this is incomplete, not acceptance. The headless Wayland
runner could not start because `gnome-shell` is unavailable on the test host.
See the [run notes](../evidence/b4-current-linux-tip-2026-10-09/README.md).

On exact `fork/linux` source `2ef1df8`,
`bash scripts/test-arch-package-container.sh` built and validated Arch package
`0.1.6-1` (SHA-256
`709d61f931efc7b833e3a9f45f02a5f17927213b3c122e098ffddae5328e1ee8`). The
container test upgraded `0.1.5-1` to `0.1.6-1`, verified the installed
executables, and removed the package while preserving user-data sentinels. It
does not cover package-installed B4 UI flows or native Wayland; those rows stay
open. The packaging output also contains a `namcap` PKGBUILD environment
diagnostic despite an overall exit code of zero. See the [Arch package
lifecycle manifest](../evidence/b4-arch-package-lifecycle-2026-10-09/manifest.json).

## Previous pinned B4 acceptance checkpoint (2026-10-09; linux tip 4bcec064)

At this checkpoint, `fork/linux` was `4bcec064d1dc4a8f4905f92f40461e4c215ed23b`
(PR #419). PR #419 updates test-container reuse/support; it does not change
application runtime code. Exact-source Build Linux run
[#37865445368](https://github.com/cozyGarage/BookiE/actions/runs/37865445368)
was explicitly dispatched against immutable product candidate
`5db1cfe5f15ac258472ac04c82f9083ca2ea81aa`; its B4 rollback, TLS, PostgreSQL
release and installed GTK safety jobs completed successfully. The artifact
reports and exact selectors are in the [candidate manifest](../evidence/b4-hosted-acceptance-2026-10-09/manifest.json).
This advances B4-7/9/11/12/16/17/22 hosted evidence. On current tip
`4bcec064`, Debian 13 package lifecycle passed install, reinstall, upgrade,
downgrade and purge while preserving user data. The MySQL approval dialog GTK
scenario also passed using `/usr/bin/bookie` from the installed package. See
the [package evidence](../evidence/b4-deb-package-lifecycle-2026-10-09/manifest.json).
Other package-installed B4 flows, native Wayland acceptance, and Windows AD
interoperability remain open. PR #420 has since moved `fork/linux` to
`525dee3eb00968a1211161d333e244187c4bce31` with the B3 MongoDB bounded-browse
change. Its Build Linux run [#37872021441](https://github.com/cozyGarage/BookiE/actions/runs/37872021441)
was queued when this note was updated; no B4 acceptance is inferred for that
newer tip from the earlier exact-SHA results.

On exact post-PR-427 `fork/linux` source `b4ee463`, the user-local release executable passed the 53-scenario GTK UI workflow suite and all seven PostgreSQL SSH/mTLS scenarios under Xvfb/AT-SPI. The reported `mysql_unparseable_routine_dialog_denial_preserves_database` scenario also passed twice against MySQL 8.0, so the earlier empty-dialog regression was not reproduced at this tip; its historical cause remains unconfirmed. The approval runner needed the same `ATSPI_DBUS_IMPLEMENTATION=dbus-daemon` setup as the sibling MySQL runner; this change adds it and the script passed without an external override. See [GTK workflows](../evidence/gtk-ui-workflows-installed-linux-b4ee-2026-10-09/manifest.json), [SSH flows](../evidence/b4-ssh-installed-linux-tip-b4ee-2026-10-09/manifest.json), and [MySQL approval regression evidence](../evidence/gtk-mysql-approval-linux-b4ee-2026-10-09/manifest.json). These local runs do not establish distro-package or native Wayland acceptance.

PR #417 adds the MySQL human-approval dialog regression to hosted installed
GTK acceptance. Exact-SHA dispatch [#37867814390](https://github.com/cozyGarage/BookiE/actions/runs/37867814390)
ran against `102ef48017f10c7a63c271608b98d3b05b449795`. Its B4 rollback
(14 MySQL tests and 1 PostgreSQL rollback-failure test), TLS (48 tests), and
PostgreSQL release GTK jobs passed. The PostgreSQL release job's MySQL
human-approval dialog step passed, and all seven SSH/mTLS scenarios passed.
At the initial capture, installed GTK safety and broad driver-integration jobs
were still running. Both subsequently passed; the broad integration layer
passed 462 tests across 13 groups, and the complete workflow concluded
successfully. This hosted pass does not resolve why the operator observed two
earlier empty-dialog failures; the root cause remains open. See the [follow-up
acceptance note](../evidence/b4-hosted-acceptance-2026-10-09/focused.txt).

The native SSH suites were also rerun locally on the same exact source SHA with
`bash scripts/test-ssh.sh`: 10 `agent_auth` and 12 `openssh_session` tests
passed, including native multi-hop, second-hop cancellation, host-key refusal,
agent authentication and OpenSSH forwarding. Distribution-package and native
Wayland trust-flow acceptance remain open. See the [native SSH evidence
manifest](../evidence/b4-ssh-native-current-2026-10-09/manifest.json).

The SQL Server Kerberos/TLS fixture also passed locally on `102ef480`:
`bash scripts/test-mssql-kerberos.sh` ran both verified-TLS ticket
authentication and unregistered-SPN refusal tests successfully against the
Samba AD fixture. This does not establish Windows AD interoperability or
package-installed acceptance. See the [current Kerberos evidence
manifest](../evidence/b4-mssql-kerberos-current-2026-10-09/manifest.json).

## Exact-SHA B4 acceptance checkpoint (2026-10-08)

Earlier B4 layers passed on runtime SHA `a7f14faef07f05bd4a3d63a6ca31b60f2a4e0200`,
including rollback, TLS, SSH, PostgreSQL release GTK, Samba Kerberos,
security-policy and sandbox; its evidence remains in the
[candidate manifest](../evidence/b4-acceptance-2026-10-08/manifest.json). The
tested `fork/linux` tip was `ca1dc6002cf269f1eb799fe9f04ce0b8c255a1b9` (PR #388).
On this exact tip, local SSH, PostgreSQL release and Samba Kerberos fixtures
passed for B4-7, B4-16, B4-17 and B4-21. The [current-tip SSH evidence](../evidence/b4-ssh-current-tip-2026-10-08/manifest.json)
records 22 native SSH tests and seven GTK SSH trust/audit scenarios; the
[Kerberos evidence](../evidence/b4-mssql-kerberos-2026-10-08/manifest.json)
records both Kerberos selectors passing. These were local fixture/Xvfb runs,
not distribution-package or native Wayland acceptance. Build Linux run
[#37794837722](https://github.com/cozyGarage/BookiE/actions/runs/37794837722)
was cancelled before jobs started; Security and Flatpak packaging passed on
that source SHA.

At the previous checkpoint, `fork/linux` was
`c3122d97459685060f1cf3474b55e1a11b961abe` (PR #396). The local PostgreSQL
release fixture passed after rebasing the evidence branch onto that tip; see
the [SSH evidence](../evidence/b4-ssh-current-tip-2026-10-08/manifest.json).
Build Linux run
[#37797466945](https://github.com/cozyGarage/BookiE/actions/runs/37797466945)
completed successfully on `c3122d9`. The later run
[#37806196821](https://github.com/cozyGarage/BookiE/actions/runs/37806196821)
completed successfully on `896f1b3`, including rollback, PostgreSQL release,
Driver TLS, integration, installed GTK and regression-gate jobs. The latest
merged `fork/linux` tip is `e697824f92438ea641b0e3b98cdf7d11173ce25a` (PR #403).
Linux Security run [#37849452452](https://github.com/cozyGarage/BookiE/actions/runs/37849452452)
passed; Build Linux run [#37849452394](https://github.com/cozyGarage/BookiE/actions/runs/37849452394)
is pending and Flatpak run [#37849452274](https://github.com/cozyGarage/BookiE/actions/runs/37849452274)
is in progress. No completed current-tip Linux CI contracts run was visible at
this check. Build Linux #37849452394 has not completed its B4 rollback job, so
the skipped PR-event job on #407 or #408 is not hosted rollback acceptance.
These runs do not qualify the selected frozen B3+B4 candidate.
Older hosted and cancelled runs remain historical in the candidate and
rollback manifests. Distribution-package/native Wayland, Windows AD, optional
MySQL engines and broader rollback side effects remain open.

The previous local checkpoint is candidate
`7eea6f09d7154f03400e82cec7c16215488b2115`; see the [candidate results and
hosted run state](https://github.com/cozyGarage/BookiE/pull/298#issuecomment-6050658653).
Policy, SSH, TLS, PostgreSQL release, GTK bundle audit, SQL Server Kerberos,
MySQL atomicity and PostgreSQL rollback-failure checks passed locally on this
exact source. The initial pinned Build Linux run passed PostgreSQL release,
Fast GTK, TLS, Clippy, and optional DuckDB, but its driver integration job
timed out during workspace compilation and its GTK suite exposed an encrypted
credential restoration failure. The corrected exact-SHA rerun below passed
GTK safety and release-binary SSH scenarios; driver integration again timed
out during compilation. See the
[candidate checkpoint](https://github.com/cozyGarage/BookiE/pull/298#issuecomment-6050658653).
The prior PostgreSQL release job used a debug application binary. PR #286
merged at `d5d63a95`; its pinned hosted dispatch on PR commit
`a056bf1715cd134224caf9c3215d617ae9b5ebb6` passed the focused B4 rollback layer
(9 MySQL cases and 1 PostgreSQL case), hosted release-binary SSH GTK scenarios,
and installed GTK safety smoke. The broad driver integration tier exhausted its
30-minute budget during dependency compilation before tests ran. See the [hosted results
comment on PR #287](https://github.com/cozyGarage/BookiE/pull/287#issuecomment-6049956346)
and [candidate workflow](https://github.com/cozyGarage/BookiE/actions/runs/37708183936).

The earlier `0d22bfe9` checkpoint remains available in the
[PR #258 evidence discussion](https://github.com/cozyGarage/BookiE/pull/258#issuecomment-6048355227).
Neither checkpoint establishes distribution-package installation on native
Wayland, upgrade/rollback acceptance or Windows AD interoperability. This does
not qualify 0.2.0.

---

# Archived completed local slices (2026-10-10 consolidation)

Moved from [b4-task-board.md](../b4-task-board.md). Source-pinned local evidence
and matrices only. Open acceptance rows stay on the live board and ledger.
Retest indicators on the live board are unchanged.

## Completed local slices (pre-consolidation text)

| ID | Local evidence | Scope remaining |
| --- | --- | --- |
| I3 | [Route, authentication and TLS matrix](#i3-route-authentication-and-tls-evidence-2026-10-07) records exact engine/backend, SHA/selector, unsupported and unrun combinations after C6/G5/I2 | Source evidence matrix and frozen candidate `7eea6f09` checks complete; hosted driver/PostgreSQL/GTK checks are running and distribution-package/native Wayland acceptance remains separate |
| G5 | PR #151 merged at `11672cbe6`; before merge, `bash scripts/test-postgres-release.sh` on the rebased branch verified that the actual agentd provider refused an unattended unknown system OpenSSH key without writing it, then reached a guarded PostgreSQL query with a pretrusted key. The PostgreSQL release integration suite passed; `audit_isolation_tests` passed separately (4 tests) | Frozen B3+B4 candidate SHA, completion of hosted checks, and installed acceptance remain separate |
| C6-MySQL / C6-SQLServer | C6 source commit `0ecb5bc4f`; rerun on the assembled B4 branch with `bash scripts/test-driver-tls.sh` on 2026-10-07: all 43 TLS tests passed, including 11 MySQL and 9 SQL Server tests. Both tunneled engines execute a query with valid CA/hostname verification, reject an untrusted CA and wrong/local service identities; MySQL proves no plaintext fallback and SQL Server checks `encrypt_option` plus tunnel cleanup | Built-in SSH forwarding only; system OpenSSH, frozen-candidate, hosted and installed acceptance remain separate |
| I2 | `tablepro-transport::tests::saved_system_openssh_refuses_deterministically_in_flatpak_without_fallback`: injectable sandbox context proves the selected OpenSSH route refuses before password-keyring resolution; explicit built-in route still constructs, and native OpenSSH route remains supported. The `quick` layer passed locally on `b4/i5-reconciled` (2026-10-07) and includes the sandbox tier | Flatpak package/runtime acceptance remains separate |
| F8-headless | `agentd::audit_isolation_tests`: connection A uncertainty leaves B writable; replacement recovers; cancellation of an old write after replacement does not poison the new generation; outcome journal failure blocks other sessions and replacement generations | Re-run on the frozen B3+B4 candidate SHA; hosted and installed restart acceptance remain separate |
| I5 | `security-policy`, `ssh`, and `postgres-release` passed on `b4/i5-reconciled` (2026-10-07). PostgreSQL release fixtures assert one journal event each for built-in unknown/mismatched-key refusal and system OpenSSH unknown/mismatched-key refusal, plus one connected event for pretrusted system OpenSSH. Transport units cover cancellation, audit sink failure (no connection returned; governed writes disabled), and legacy journal deserialization. Agent credentials are hashed before persistence. GTK saved/open, reconnect, connect-dialog submit, and test-connection call sites pass the audit context into the same transport boundary. The targeted GTK setup-failure scenario also proves a closed SSH port produces exactly one durable `connection_failed` outcome; `audit_journal_loss_after_connection_denies_mutation` verifies a live editor still denies writes after journal storage disappears. On current source `ca1dc6002`, the PostgreSQL release and SSH layers passed again; see [current-tip SSH evidence](../evidence/b4-ssh-current-tip-2026-10-08/manifest.json), [setup-failure evidence](../evidence/ssh-gtk-setup-failure-2026-10-07/manifest.json), and the [candidate checkpoint](../evidence/b4-candidate-acceptance-2026-10-07/manifest.json). | Frozen-candidate, hosted and distribution-package/native Wayland acceptance remain |
| F7 | The rollback action sends `ROLLBACK`, awaits its result, then closes the dedicated session; Session stays active and controls stay disabled until both steps finish. Unit coverage gates delayed rollback/close and close-after-rollback-error; isolated GTK dialog coverage checks Cancel, Roll Back and Commit semantics. The `widgets` layer passed 13 selectors, `postgres-release` passed, and the full app library suite passed (537 passed, 39 ignored). The focused PostgreSQL 17 GTK flow passed: Cancel kept the same transaction open, later writes remained uncommitted, and Roll Back closed the session with zero persisted rows. See [GTK session evidence](../evidence/gtk-postgres-session-confirmation-2026-10-07/manifest.json) | Re-run on the frozen B3+B4 candidate; hosted CI and installed acceptance remain |
| B4-16 | The [current-Linux seven-scenario evidence](../evidence/ssh-gtk-audit-linux-fb82ea1-2026-10-07/manifest.json) cuts the saved SSH route during an editor transaction; the transaction remains absent, a stale-session write is refused, and after recovery a new Session successfully runs `SELECT 42`. The local installed release-binary run on `b4ee463` also passed tunnel-loss retirement/reconnect; see [current-tip SSH evidence](../evidence/b4-ssh-installed-linux-tip-b4ee-2026-10-09/manifest.json) | **Unverified:** frozen-candidate, distribution-package/native Wayland acceptance remains |
| B4-17 | Verify native multi-hop, cancellation, and installed trust flow | Product source `93d2e337` passed the local PostgreSQL release acceptance: system OpenSSH, 3 mTLS tests, 59 release integration tests, and all seven GTK SSH/mTLS scenarios covering multi-hop trust/query, second-hop decline, changed-key refusal, and tunnel-loss recovery. Current `fork/linux` tip `5540db7e` contains docs-only PR #437 and test-only PR #424 atop product source `395bc182`; neither source snapshot is qualified by the `93d2e337` run; see [current-tip release evidence](../evidence/b4-ssh-release-linux-tip-2026-10-09/manifest.json). The earlier installed release-binary run on `b4ee463` remains useful, but Debian package-installed SSH trust and native Wayland acceptance remain open |
| B4-21 | Preserve candidate Samba Kerberos+VerifyFull proof, then perform Windows AD interoperability | Exact current Linux tip `e208eb1b` passed both Samba AD Kerberos selectors with verified TLS; see [current-tip evidence](../evidence/b4-mssql-kerberos-linux-tip-2026-10-10/manifest.json). It does not establish Windows AD interoperability, which remains open |
| B4-12 | ~~Repeat the PostgreSQL rollback-failure selector on the selected frozen candidate and hosted CI~~ | The backend-termination selector passed on candidate source `a7f14fa`, the earlier hosted candidate runs, and pinned candidate `5db1cfe` in Build Linux #37865445368. See [current hosted candidate evidence](../evidence/b4-hosted-acceptance-2026-10-09/manifest.json) |
| B4-18 | Candidate `SERVER VERSION`, `LIST TABLES`, and `LIST VIEWS` reads for saved connect and connect-dialog submit now use `CandidateGuardFactory`; Test Connection table listing uses the same guard. `candidate_catalog_reads_use_the_durable_policy_audit_journal` verifies intent/outcome entries; `candidate_metadata_read_refuses_when_its_audit_intent_cannot_be_written` verifies fail-closed behavior. Both passed in `cargo test -p tablepro-app --lib candidate_ -- --nocapture` | Local app tests only; frozen-candidate, hosted, and installed acceptance remain |
| B4-19 | The vendored PostgreSQL SCRAM client rejects server nonces that fail to extend the client nonce or contain non-ASCII/non-printable bytes, before deriving a proof. A local wire fixture sends an echoed nonce, a non-ASCII suffix, and 100,001 iterations; all three cases reject before a client proof is sent. `cargo test -p tablepro-driver-postgres --lib` passed (54 tests) | Local driver tests only; frozen-candidate and hosted acceptance remain |

### I5 sanitized event shape and coverage

```json
{
  "phase": "outcome",
  "principal": { "kind": "agent", "token": "sha256:<short digest>" },
  "connection_id": "<attempt connection UUID>",
  "driver_id": "postgres",
  "operation_class": "administrative",
  "redacted_sql": "[NOT_APPLICABLE]",
  "decision_rule": "transport_attempt",
  "terminal_status": "denied",
  "error_category": "authentication",
  "error": "ssh_host_key_or_authentication_refused",
  "transport_attempt": {
    "client": "system_open_ssh",
    "outcome": "host_key_refused"
  }
}
```

| Caller / SSH client | Local evidence |
| --- | --- |
| GUI saved connect / reconnect / connect-dialog submit and test | Explicit audit context and cancellation reach the shared transport boundary. GTK release-binary scenarios assert exactly one durable outcome for unknown-key refusal, accepted trust/query, and closed-port setup failure; see [refusal](../evidence/b4-gtk-ssh-audit-2026-10-07/manifest.json), [accepted trust](../evidence/ssh-gtk-trust-accept-2026-10-07/manifest.json), and [setup failure](../evidence/ssh-gtk-setup-failure-2026-10-07/manifest.json) evidence |
| Daemon / system OpenSSH | PostgreSQL release fixture asserts unknown-key refusal, changed-key refusal, and trusted connection outcomes from the durable journal; exactly one transport event per attempt |
| Shared transport / built-in SSH | PostgreSQL release fixture asserts unknown-key and changed-key outcomes with exactly one terminal event per attempt |
| Shared transport / failure paths | Unit coverage asserts one cancelled terminal event, sanitized agent principal, and audit-write failure returns no connection and disables governed writes |

### I3 route, authentication and TLS evidence (2026-10-07)

| Engine / caller | Source SHA and selector | Route and authentication evidence | TLS evidence | Scope not established |
| --- | --- | --- | --- | --- |
| MySQL | `0ecb5bc4f`; `verify_full_through_ssh_reaches_the_unpublished_server_and_runs_a_query`, `verify_full_through_ssh_rejects_an_untrusted_authority`, `verify_full_through_ssh_rejects_a_wrong_or_local_identity` | Built-in SSH local socket forward to an unpublished fixture; SSH uses a fixture key and the database uses the fixture username/password | `driver-tls` suite: valid VerifyFull query; untrusted CA and wrong/local service identity refused; TLS-only endpoint rejects plaintext and driver does not retry without TLS | System OpenSSH route; other MySQL authentication plugins; frozen-candidate/hosted/installed runs |
| SQL Server | `0ecb5bc4f`; same three `verify_full_through_ssh_*` selectors as MySQL | Built-in SSH TCP forward to an unpublished fixture; SSH uses a fixture key and the database uses the fixture username/password | `driver-tls` suite: valid VerifyFull query; untrusted CA and wrong/local service identity refused; server `encrypt_option` confirms encryption and dropping the tunnel closes the forward | System OpenSSH route; Kerberos; frozen-candidate/hosted/installed runs |
| PostgreSQL / built-in SSH | `e66ff814e`; `the_shared_transport_verifies_the_database_hostname_through_the_bastion` | Shared transport uses built-in SSH and fixture key to reach PostgreSQL; PostgreSQL uses fixture username/password | `postgres-release` asserts VerifyFull against the database hostname through the bastion and rejects use of the local TCP-forward address as TLS identity | System OpenSSH TLS verification is not separately asserted by the G5 selector; frozen-candidate/hosted/installed runs |
| PostgreSQL / agentd system OpenSSH | `37f984c56` / `c739f5afa`; `agentd_refuses_without_learning_an_unknown_system_openssh_key_then_queries_after_trust` | Actual daemon refuses the unknown SSH host key without learning it, then a pretrusted key reaches a guarded PostgreSQL query; PostgreSQL uses fixture username/password | The G5 saved connection requests VerifyFull, but the acceptance assertion is host-key refusal/trust and guarded query, not a separate TLS-negative matrix | Built-in/system OpenSSH TLS equivalence; frozen-candidate/hosted/installed runs |
| Saved system OpenSSH in Flatpak | `c2399c730`; `saved_system_openssh_refuses_deterministically_in_flatpak_without_fallback` | Deterministic route-resolution test refuses before credential lookup or driver dispatch, with no automatic fallback; built-in SSH remains selectable | Not a TLS integration test | Installed Flatpak runtime acceptance |

The assembled source `0b544ac18` passed `bash scripts/test-driver-tls.sh` (43
tests) after integrating C6. The selector and driver configuration stay in the engine
fixtures and tests; this matrix records only claims established by those tests.
Other TLS-tested engines (ClickHouse, MongoDB and Redis) have direct TLS fixture
coverage, but no SSH-forwarding coverage is claimed here. Do not treat this
matrix as frozen-candidate, hosted, or installed acceptance.

Headless panic retirement is covered by `a_session_whose_driver_panicked_is_not_reused_even_though_its_ping_is_healthy`;
include it in the combined G5/F8 candidate acceptance.

The agentd panic-retirement unit test uses a credential-free saved connection
and carries its tracing subscriber through the async operation. Secret Service
behavior stays in the dedicated keyring tier.

---

# Archived remaining-task prose (2026-10-10 pass 4)

Moved from the live [B4 board](../b4-task-board.md) Remaining tasks table.
These rows were already implemented and locally tested; the live board keeps
only open packaging work (I1) plus acceptance bounds above. Do not treat this
archive as package-installed or native Wayland acceptance.

| ID | Small task and required assertion | Local layers |
| --- | --- | --- |
| I2 | **Implemented and locally tested.** Explicit saved system OpenSSH selection refuses at route resolution inside Flatpak before SSH credential resolution or driver dispatch; there is no automatic backend switch. The deterministic regression also verifies built-in SSH remains selectable inside the sandbox and system OpenSSH remains selectable outside it. Flatpak package/runtime acceptance remains separate | `quick` (includes sandbox tests) |
| I5 | **Local implementation and backend fixture coverage complete.** The shared transport boundary emits one terminal event per SSH attempt. Saved GUI opens/reconnects, connect-dialog submit/test, and daemon opens attach principal/connection identity and cancellation. Built-in and system OpenSSH real fixtures cover unknown and changed host keys; system OpenSSH also covers trusted success. Unit tests cover cancellation, audit-write failure/fail-closed behavior, and legacy journal compatibility. GTK refusal, accepted-query, and closed-port setup-failure scenarios each assert exactly one durable transport outcome. The [current-Linux seven-scenario release-binary run](../evidence/ssh-gtk-audit-linux-fb82ea1-2026-10-07/manifest.json) also passed. All seven PostgreSQL SSH GTK scenarios passed in hosted run [#37708183936](https://github.com/cozyGarage/BookiE/actions/runs/37708183936) at PR #286 head `a056bf1`. Distribution-package/native Wayland acceptance remains open | `security-policy`, `ssh`, `postgres-release` |
| F7 | **Local implementation, unit/widget, and PostgreSQL GTK flow verified.** Toggle-off confirmation keeps Session active; Cancel retains the same open transaction; explicit `ROLLBACK` finishes before session close and leaves no rows persisted | `widgets`, `postgres-release`, and `TABLEPRO_GTK_SCENARIO=postgres_session_transaction_confirmation_cancels_or_rolls_back bash scripts/test-gtk-postgres.sh` passed locally; candidate/hosted/installed acceptance remains |
| B4-atomic-batch / B4-rollback-error | MySQL source and native regressions cover non-DML refusal, rollback failure reporting, InnoDB transactional rows, and surviving MyISAM, MEMORY, CSV and ARCHIVE trigger effects for failed INSERT/UPDATE/DELETE. InnoDB AUTO_INCREMENT and trigger session-variable effects are also covered. The nine-test ignored MySQL atomicity group passed on frozen candidate `7eea6f09` and in hosted run `37708183936`. The PostgreSQL backend-termination rollback test passed on that candidate and in the same hosted run; see the [hosted-results comment on PR #287](https://github.com/cozyGarage/BookiE/pull/287#issuecomment-6049956346). Broad driver integration previously timed out during compilation before tests; wider PostgreSQL side-effect patterns remain open | [Retained MySQL evidence](../evidence/mysql-atomic-results-2026-10-03/manifest.json); [expanded MySQL engine evidence](../evidence/mysql-rollback-engine-effects-2026-10-07/manifest.json); [candidate checkpoint](https://github.com/cozyGarage/BookiE/pull/298#issuecomment-6050658653); [PostgreSQL rollback-failure evidence](../evidence/postgres-rollback-failure-results-2026-10-07/manifest.json) |
| B4-MySQL-engine-atomicity | **Scoped contract verified locally, on frozen candidate, and hosted:** failed InnoDB DML rolls back parent and InnoDB trigger rows, while MyISAM, MEMORY, CSV, and ARCHIVE trigger writes survive failed INSERT, UPDATE, and DELETE batches. An InnoDB AUTO_INCREMENT allocation is not restored, and a trigger session-variable effect survives rollback. The nine-test atomicity group passed on frozen candidate `7eea6f09` and in hosted run `37708183936`; storage engines and side effects beyond these fixtures remain unverified | [Original MyISAM evidence](../evidence/mysql-atomic-results-2026-10-03/manifest.json); [MyISAM and MEMORY regression](../evidence/mysql-nontransactional-trigger-engines-2026-10-07/manifest.json); [CSV regression](../evidence/mysql-csv-trigger-rollback-2026-10-07/manifest.json); [expanded MySQL engine and counter evidence](../evidence/mysql-rollback-engine-effects-2026-10-07/manifest.json); [ARCHIVE regression](../evidence/mysql-archive-rollback-effects-2026-10-07/manifest.json); [multi-engine UPDATE/DELETE regression](../evidence/mysql-update-delete-multiengine-rollback-2026-10-07/manifest.json); [hosted results comment](https://github.com/cozyGarage/BookiE/pull/287#issuecomment-6049956346) |

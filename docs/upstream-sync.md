# Optional upstream reference review

The approved [BookiE convergence sprint](bookie-0.2-sprint.md) now includes shared Rust/Linux foundations as well as behavior review. Apple source trees remain excluded.

## 2026-10-17 04:20 UTC: source-head follow-up

Latest official GitHub heads checked: BookiE `linux` `6ab7d79e1e43facb3f931fffc99d7148c3ea69c4`; TablePro `linux` `7cd300f82eaa4743d18ab049bf40a374d3ecf927` and `main` `bdbcb7de95a267aab261e258fc6d5c745261848f`; dbx `main` `1065bf89ac8b7271388b5e513ac0971d2b179273`; DBeaver `devel` `61c9529849c9fa500c303d1a385897a4088d6656`; Beekeeper Studio `master` `f7ff968f39699c22d4f9a4674f38a5ecfbfbe586`. The last three TablePro, DBeaver and Beekeeper pins are unchanged from the prior review. Latest releases checked remain TablePro macOS 0.81.0, dbx v0.6.46, DBeaver Community 26.2.2 and Beekeeper v6.1.6.

BookiE advanced from `834e5b63e` through #1006, which preserves MySQL `TINYINT(1)` values outside 0/1 as integers. dbx advanced two commits from `35d06151f`: [#12502](https://github.com/t8y2/dbx/pull/12502) preserves PostgreSQL I/O error sources for diagnostics after a proxy-injected connection reset; [#12512](https://github.com/t8y2/dbx/pull/12512) adds table/database-scoped trigger toggles and SQL identifier tests for supported dialects. BookiE's PostgreSQL mapping currently returns a generic disconnected outcome for other I/O errors; consider redacted diagnostic context without weakening that outcome. BookiE exposes trigger metadata but has no trigger-state action; this is a later candidate, not selected work. The complete applicability and test lessons are in the [October 17 peer review](archive/linux-peer-review-2026-10-17.md).

The current PR-conversation refresh found no new human-authored blocking feedback on #996, #1020, #1046 or the synced UX PRs; recent new comments were automated SonarCloud results. #1020 and #1046 are merged; #996 remains open. Thirteen UX-owned branches now include Linux `6ab7d79e1`; their sync comments record exact heads and check snapshots. At this read there were no failed GitHub checks, while some checks remained in progress. Forgejo/native acceptance was not run; the maintainer owns that gate. The live peer tracker #1026 is still open, and its #1028 completion checkbox now agrees with merged #1037.

## 2026-10-17: PR discussion and competitor follow-up

Earlier 2026-10-17 snapshot: BookiE `linux` `333c79006a5823bfbffbf2cc7847bab77d43d0c7`, TablePro `linux` `7cd300f82eaa4743d18ab049bf40a374d3ecf927`, TablePro `main` `bdbcb7de95a267aab261e258fc6d5c745261848f`, dbx `538b8183cd15ba03eaea1e544e585dba896551f9`, DBeaver `61c9529849c9fa500c303d1a385897a4088d6656`, and Beekeeper Studio `f7ff968f39699c22d4f9a4674f38a5ecfbfbe586`. This captured the PR-discussion refresh before the later source-head update above. Its selected merged fixes remain useful; the latest source pins and two later dbx commits are recorded in the 04:20 follow-up.

Reviewed the live GitHub discussion on PRs #996, #1020, #1046, #1037, #1047, #1050, #1002, #1012, #1051 and #1055, and issues #1026, #1029, #1030, #1031, #1032, #1033, #1034, #1054 and #1056. The review comments contain resolved findings and remaining acceptance, not just status updates:

- PR #1020's unconditional Redis `SELECT` refusal broke the app's guarded value refetch. The branch narrowed the refusal to bare database-switch commands, added regression coverage for the native read and quoted/bare `SELECT` forms, and merged. Preserve the read path and refusal cases in future classifier work.
- PR #1050's review found missing direct coverage for Undo, Redo and paste, then missing toolbar, shortcut and bulk-selection paths. Follow-up tests cover those routes; the GUI `DatabaseService` exercises read-only INSERT/UPDATE/DELETE through `PolicyGuard`, and generated-column edit/Set NULL paths are pinned. The latest follow-up found that Undo/Redo were also blocked even though they only change local draft history; a failing-first GTK regression now verifies local undo and redo produce no database writes. At `ea126c834a75ec5a6b3c65bdf54ed5213cbf5101`, the new and existing focused GTK tests pass, and full preflight passes (1,741 unit tests and 1,716 sandbox integration tests). GitHub checks are pending; broader object, approval, audit and installed GTK acceptance remain open for the maintainer/Forgejo gate.
- PR #1047's focus, quit, close and disconnect scenarios are covered, and headless tests pin late-save ownership. Bulk tab-close menu actions remain an installed manual check because the GTK fixture cannot dispatch them. GitHub exposed `workspace_tabs.rs` at 1,209 lines after the menu wiring; the action helpers and GTK test were extracted to a submodule, and the registered selector was updated without raising the baseline or removing tests. At `7d820969e`, all 60 GTK widget tests, full preflight, strict app Clippy and the file-size guard pass locally. GitHub checks restarted; supply-chain fails on the existing `zip` advisories tracked in #1058 while Fast GTK, preflight and Flatpak are pending. Docker and installed acceptance remain Forgejo evidence.
- PRs #1002 and #1012 still own the streamed-tab/session prerequisites for #1032; #1016's recovery disposition remains open. The source audit and synthetic profile show that page-count limits do not bound all retained owners. Do not start overlapping retention implementation before the dependencies land.
- Issue #1030 has native NULL/default observations and a proposed UX contract, but the B3 decision is still required before changing shared parsing or app adapters. Issues #1033/#1034 retain the B3 typed-message then GTK-consumer order. Issue #1054 waits for #1051. Issue #1056 has the documented B3-to-UX handoff and a narrowed SQLite PRAGMA-shadowing scope.

At this refresh, #1026 and its active peer-review children remain open; PEER-6/#1028 is complete and its parent checkbox is now checked. #1020, #1046 and #1037 are merged. #996 remains open, and #1055 merged as commit `258c5c0e1`. The TablePro/dbx/DBeaver/Beekeeper source heads match the October 17 comparison, so there are no newly landed competitor source commits to add. Release-note dates remain those recorded in the comparison.

The refreshed dbx issue and merge feed adds cases for Bookie to test or monitor, not claims that Bookie is affected: [#12484](https://github.com/t8y2/dbx/issues/12484) reports a phantom second page when a MySQL result has exactly 100 rows; [#12504](https://github.com/t8y2/dbx/issues/12504) reports MySQL LONGTEXT writes truncated at 4096 characters; [#12478](https://github.com/t8y2/dbx/issues/12478) reports query-tab renaming mutating an object-tab label; and [#12523](https://github.com/t8y2/dbx/issues/12523) reports the formatter merging multiple no-semicolon SQL statements onto one line. Bookie's formatter uses `ScriptPlan` statement ranges and verifies significant-token preservation, so #12523 is a regression prompt for #893's dialect corpus, not a confirmed Bookie defect. Proposed dbx PR [#12509](https://github.com/t8y2/dbx/pull/12509) is closed without merge, so it is not evidence that the tab-identity bug was fixed. Merged PRs [#12434](https://github.com/t8y2/dbx/pull/12434), [#12435](https://github.com/t8y2/dbx/pull/12435) and [#12468](https://github.com/t8y2/dbx/pull/12468) reinforce exact page-boundary, bounded-metadata and budget-execution tests.

Newly reviewed dbx PRs provide additional test patterns. [#12469](https://github.com/t8y2/dbx/pull/12469) exposes **Copy column comment** only when usable metadata exists and copies multiple selected comments in visible column order; reuse that availability-and-order matrix if BookiE adds the action. [#12443](https://github.com/t8y2/dbx/pull/12443) keeps settings footer actions reachable above 165% UI scale and tests scale fallback plus layout structure; for GTK, test the actual settings at large font scale and short window height rather than transplanting webview sizing code. [#12439](https://github.com/t8y2/dbx/pull/12439) returns DBMS_OUTPUT through bounded messages, tests Unicode-safe truncation and cleanup, and never replays user SQL after cleanup failure; apply these invariants to the ordered #1033 backend and #1034 GTK consumer slices. [#12436](https://github.com/t8y2/dbx/pull/12436) preserves database-browser scroll through tab/view changes and resets it on search, sort, connection or mode changes; Bookie's current sidebar does not persist a per-tab scroll position, so keep this as a future navigation-state test prompt, not a defect claim.

The latest dbx issue feed also adds an ArgoDB table-comment compatibility report ([#12519](https://github.com/t8y2/dbx/issues/12519)), a plugin release-link path bug ([#12516](https://github.com/t8y2/dbx/issues/12516)) and a documentation-discovery question about Notes ([#12517](https://github.com/t8y2/dbx/issues/12517)). ArgoDB and plugin engines are outside BookiE's current scope, and BookiE has no Notes-file feature to document.

The October 16 DBeaver [SQLite metadata shadowing fix](https://github.com/dbeaver/dbeaver/pull/42376) exposed a related Bookie edge case. Local reproduction now covers same-named user tables in both `temp` and `main`; [#1056](https://github.com/cozyGarage/BookiE/issues/1056) tracks a fix that must retain metadata visibility across pooled SQLite connections. The earlier peer-review note that Bookie did not use the same table-valued PRAGMA pattern is superseded by this reproduction; the archived review remains unchanged as a historical record. The workspace identity follow-up [#1054](https://github.com/cozyGarage/BookiE/issues/1054) also remains open under parent #1026.

## 2026-10-17: second live refresh and newly landed competitor work

Verified live GitHub heads after the earlier October 17 snapshot: Bookie `linux` is `f88dc6a009bdab784f5ad6e1aa6daa59de875d72`; TablePro `linux` remains `7cd300f82eaa4743d18ab049bf40a374d3ecf927`, TablePro `main` remains `bdbcb7de95a267aab261e258fc6d5c745261848f`, dbx is now `1065bf89ac8b7271388b5e513ac0971d2b179273`, DBeaver remains `61c9529849c9fa500c303d1a385897a4088d6656`, and Beekeeper Studio remains `f7ff968f39699c22d4f9a4674f38a5ecfbfbe586`.

The new dbx merge [#12512](https://github.com/t8y2/dbx/pull/12512) adds SQL Server trigger enable/disable actions to its structure editor and browser. Its useful pattern is a small dialect capability table, per-dialect identifier quoting, an explicit unsupported result, guarded execution, and tests of generated SQL plus actual UI entry points. Bookie has no trigger toggle surface, so this is a future feature-design pattern rather than a missing fix to port.

Beekeeper's latest Linux-neutral merge [#4859](https://github.com/beekeeper-studio/beekeeper-studio/pull/4859) changes Home/End key handling so those keys do not scroll its tabulator. This is a test prompt only: Bookie's GTK grid has different focus and navigation behavior, so reproduce the unwanted scroll before changing its key handling. TablePro Linux/main and DBeaver have no newer source tip than the earlier October 17 comparison.

The dbx full-cell-search case is now directly tracked in Bookie: dbx [#12508](https://github.com/t8y2/dbx/pull/12508) searches beyond the rendered cell preview; Bookie confirmed the same truncation in `row_find.rs`, and [#1062](https://github.com/cozyGarage/BookiE/issues/1062) is implemented by [PR #1063](https://github.com/cozyGarage/BookiE/pull/1063). Its regression searches beyond the 10,000-character display cutoff while keeping the search limited to loaded values.

Live PR and issue review at this refresh:

- [#1020](https://github.com/cozyGarage/BookiE/pull/1020) and [#1046](https://github.com/cozyGarage/BookiE/pull/1046) are merged. #1020's later test/comment history narrows the Redis `SELECT` refusal to database-switch syntax and preserves Bookie's guarded native-value read. #1046's MCP contract tests are merged; its earlier merge-conflict comments record that tests were preserved while resolving the current `server.rs`, pass-through tests and testing guide.
- [#996](https://github.com/cozyGarage/BookiE/pull/996) remains open and clean against current `linux`. All reported non-skipped GitHub gates, including its Linux regression gate and Fast GTK, now pass. Its latest reported Forgejo run (#620) was for an older head: ClickHouse refused its fixture connection, while the Debian package job exits after printing package metadata without naming the failing command. [#1048](https://github.com/cozyGarage/BookiE/issues/1048) correctly leaves the package failure unresolved; do not treat either the prior failure as proof against the current head or the ambiguous package log as an infrastructure classification.
- [#1047](https://github.com/cozyGarage/BookiE/pull/1047), [#1050](https://github.com/cozyGarage/BookiE/pull/1050) and SQLite [#1057](https://github.com/cozyGarage/BookiE/pull/1057) are based on `f88dc6a0`. At this follow-up read, #1047's Fast GTK and Linux regression gates pass, while only its non-gating Rust CodeQL scan remains in progress. #1050 and #1057 have Fast GTK and Rust CodeQL in progress; their other reported non-skipped GitHub gates pass. #1050 has a local exact-head 65-test GTK-widget pass, and #1057 records a 69-test SQLite driver pass. GitHub skips Docker and installed acceptance; this is not Forgejo evidence.
- [#1063](https://github.com/cozyGarage/BookiE/pull/1063) is based on current `linux`: preflight/sandbox passes, while Fast GTK, Flatpak and Rust CodeQL are in progress; other reported non-skipped checks pass. The updated head still needs hosted confirmation for those pending checks.
- Issues [#1053](https://github.com/cozyGarage/BookiE/issues/1053) and [#1054](https://github.com/cozyGarage/BookiE/issues/1054) remain queued behind #1052 and #1051 respectively. Preserve those sequencing notes before starting either implementation.

These are dated source and status observations. Check current heads and check states before acting; they do not replace the sprint, lane ownership, or Forgejo acceptance gate.

## 2026-10-16: refreshed TablePro Linux and shared-product review

Checked live GitHub branch tips on 2026-10-16: TablePro `linux` at `7cd300f82eaa4743d18ab049bf40a374d3ecf927`, TablePro `main` at `bdbcb7de95a267aab261e258fc6d5c745261848f`, and BookiE `linux` at `f2f9200b07d1e40aa6d1345135f589df73a9089c`. This is a bounded review of merged pull requests, not a full branch diff or runtime test. The detailed cross-client findings and BookiE dispositions are in the [October 16 peer review](archive/linux-peer-review-2026-10-16.md#2026-10-16-follow-up-source-scan).

New Linux fixes reviewed:

- [#3455](https://github.com/TableProApp/TablePro/pull/3455) exposed both false positives and misses in SQLite column-drop dependency detection. It lets SQLite validate the rebuilt schema after restoring dependent objects. Transfer the test matrix (same-named tokens in unrelated SQL, plus triggers that actually reference the dropped column); do not replace BookiE's driver path based on the PR description alone.
- [#3451](https://github.com/TableProApp/TablePro/pull/3451) removes an SSH host-key replacement choice when `StrictHostKeyChecking yes` makes replacement unusable, and fixes the resulting guidance. Verify BookiE's prompt against the effective OpenSSH policy before changing its flow.
- [#3449](https://github.com/TableProApp/TablePro/pull/3449) closes a ClickHouse mutation-outcome race by checking active queries before flushing and reading the query log. The transferable invariant is to order observations around the server's completion guarantee; this does not establish equivalent BookiE query-log semantics.
- [#3448](https://github.com/TableProApp/TablePro/pull/3448) connects a visible deletion-confirmation preference to the operation it describes. Test preferences through the actual action path, and test late save completion after its dialog closes.
- [#3438](https://github.com/TableProApp/TablePro/pull/3438) documents a GTK 4.22 focus/parenting hang and dropped active edits on close. BookiE tracks the analogous lifecycle matrix in [#1029](https://github.com/cozyGarage/BookiE/issues/1029); PR [#1047](https://github.com/cozyGarage/BookiE/pull/1047) is active, so do not create a competing fix.

Main-branch probes reviewed:

- [#3428](https://github.com/TableProApp/TablePro/pull/3428) makes blank typed cells produce NULL for selected types while retaining empty text/binary, across grid, inspector, fill and paste. BookiE's blank/default distinction is tracked in [#1030](https://github.com/cozyGarage/BookiE/issues/1030); preserve its current contract until B3 resolves it with stored-value tests.
- [#3436](https://github.com/TableProApp/TablePro/pull/3436) scopes tabs by selected database. BookiE confirmed connection-only workspace identity and tracks same-connection database isolation in [#1054](https://github.com/cozyGarage/BookiE/issues/1054); its issue requires legacy-state and two-database tests.
- [#3456](https://github.com/TableProApp/TablePro/pull/3456) is a useful Settings accessibility/scrolling probe, but it is SwiftUI-specific. Reproduce the behavior in GTK before adopting a UI change.

No upstream implementation was copied, and no new BookiE issue was opened by this review. The unreviewed remainder of either branch and all platform runtime behavior remain outside this checkpoint.

## 2026-10-15: upstream Linux changelog review

Reviewed upstream `linux` at `20ed72497` (`fix(linux): require the GLES library GTK loads at runtime in the rpm`) from `0e542e3c1` (`chore(linux): drop files main already deleted`, 2026-09-18), against BookiE `linux` at `46a4979b3`. Fourteen commits touch `linux/`. Most are the driver contract v2 switch and remediation steps 31 to 66 on a session crate we do not share. Upstream also rewrote `linux/CHANGELOG.md`, so its Fixed and Security lines were screened as hypotheses against our code. Upstream is AGPL-3.0; every fix below is reimplemented here, not copied.

Applies to us, confirmed by reading our code and filed:

| Upstream | BookiE issue |
| --- | --- |
| `52e666138` credential rules for history recording | [#967](https://github.com/cozyGarage/BookiE/issues/967) query history saves passwords and keys |
| Changelog: creating a SQLite table with a foreign key failed | [#972](https://github.com/cozyGarage/BookiE/issues/972) |
| Changelog: SQL Server drop or type change of a column with a default | [#973](https://github.com/cozyGarage/BookiE/issues/973) |
| Changelog: MySQL rename across databases, ClickHouse rename | [#974](https://github.com/cozyGarage/BookiE/issues/974) |
| Changelog: `real` values showed extra digits | [#975](https://github.com/cozyGarage/BookiE/issues/975) (SQL Server, DuckDB, MySQL) |
| Changelog Security: jump host trusted through ssh_config | [#970](https://github.com/cozyGarage/BookiE/issues/970), the item the 2026-09-25 entry left open |
| `611c95848` two edits of one connection mixing | [#978](https://github.com/cozyGarage/BookiE/issues/978) |

Does not apply:

- `c423710ba` waits for the server to close a cancel request, because tokio-postgres returns once the request is written and a late signal cancels the next statement. We cancel with `SELECT pg_cancel_backend($1)` on a separate pooled connection, which returns after the signal is sent. A "query right after Stop" regression probe is listed in [#983](https://github.com/cozyGarage/BookiE/issues/983).
- `1155d3eb1` disarms a `CancellationToken::drop_guard` on completion. We have no `drop_guard`.
- Driver contract v2, owned calls, the session and health crates, the ClickHouse fixture and rpm packaging.

The remaining changelog lines that touch shared behaviour, together with the dbx and DBeaver probes, are in the intake issue [#983](https://github.com/cozyGarage/BookiE/issues/983).

Addendum 2026-10-16: three later commits to `45d49a23f` (`build(linux): allow the yanked zip 8.6.0 rust_xlsxwriter still needs`). `2d7089204` (cell edits asked about on close, and a close hang on GTK 4.22) is recorded as two checks on [#983](https://github.com/cozyGarage/BookiE/issues/983); we run GTK 4.22.4. `45d49a23f` does not apply because our `deny.toml` only warns on yanked crates, and `0dc391484` is their release channels. For `1155d3eb1`, a guardrail test now pins that a finished call never cancels its caller's operation control ([#1035](https://github.com/cozyGarage/BookiE/pull/1035)).

## 2026-10-03: macOS main applicability review

Follow-up: [U1 SQL Server handoff](archive/upstream-u1-sql-server-2026-10-03.md) records the manual metadata fix for rowversion and temporal period columns, the failing-before/passing-after native regression, and remaining U1 consumers.

Reviewed macOS main at `5c2df3b60cd40c25ba86c57e3d1c87499340cb3c` against BookiE `linux` at `7b08dd4786db22ac38bc341f29d0f350412af82d`. The [review and agent work packets](archive/upstream-main-review-2026-10-03.md) identify SQL Server server-owned columns and identity copying, qualified autocomplete keys, reconnect failure handling, client-certificate integration and MongoDB export coverage. Its inventory distinguishes subject screening from inspected diffs, and the review separates source gaps from cases still needing a reproduction. Existing policy and cancellation protections are retained. The initial review was a documentation handoff. Implementation and tests belong to the linked U1 follow-up.

## 2026-09-25: system OpenSSH transport

Historical adoption checkpoint. The route is now assembled by shared transport and used by GUI/agentd; current behavior and remaining acceptance are in [connection handling](connections.md) and [the B4 board](b4-task-board.md).

At this 2026-09-25 checkpoint, `crates/ssh/src/openssh/` added the system OpenSSH backend beside the unchanged russh `SshTunnel`. The transport, storage, app and `agentd` wiring happened later; current behavior and remaining acceptance are linked above.

Source: upstream `refs/remotes/upstream/linux` at `0e542e3c1`, files `crates/ssh/src/{argv,askpass_bridge,destination,prompt,runtime,session,forward,stderr_classify,supervisor,sweep}.rs`, `src/bin/tablepro-askpass.rs`, `tests/{askpass_helper.rs,openssh_session.rs}` and `tests/fixtures/stderr/*`. The feature landed in `d03430020 feat(ssh): add the system OpenSSH transport with an askpass bridge`; `55528b854 fix(ssh): read the host key fingerprint line from OpenSSH 9 as well` is carried in the prompt parser, which closes the item the 2026-09-19 entry left open.

Taken largely as written: the ControlMaster argv and `-O` control commands, the destination and jump-list parser, the askpass frame format and helper, the handshake loop with its prompt-paused deadline, the supervisor's `-O exit`, grace and kill sequence, the flock-guarded sweep, and the stderr classifier with its fixture files copied verbatim.

Rewritten:

- Errors map to a new `OpenSshError` in the ssh crate. Upstream's `tablepro_core::SshFailure`, `TransportError`, `LivenessPolicy`, `NetworkEndpoint` and `Transport` trait do not exist here, so the crate keeps no dependency on `core`. Timeouts are an `OpenSshTimeouts` value, and a forward returns its local endpoint and the original target so a caller keeps the service host for TLS verification.
- No process-global state. Upstream's `TASKS` tracker and `SshServices`/ `SshRuntimeCell` singletons became an explicit `OpenSshContext` holding the runtime, program paths and timeouts. The runtime base is `$XDG_RUNTIME_DIR/tablepro`, falling back to a private `tablepro-<uid>` directory in the temp dir.
- Forced options add `StrictHostKeyChecking=ask`, so a user's `~/.ssh/config` cannot turn host-key checking off for the destination, plus `StreamLocalBindUnlink=no`, `SessionType=none` and `GatewayPorts=no`. Forwards can also use a loopback TCP port, not only a Unix socket.
- Credential answering is a security rewrite. Upstream answers the first `'s password:` prompt with the stored password whatever account it names, so a jump host could receive the destination's password. Here a stored password answers only a prompt naming exactly the configured `user@host`, and a stored passphrase only a prompt naming exactly the configured key path. Keyboard-interactive text is classified before the password suffix, so a server-supplied prompt cannot pose as a password prompt. Everything else, and every host-key confirmation, goes to a `Prompter` trait; `UnattendedPrompter` declines all of it. Confirmations need an explicit accept and secret prompts need a secret, so a mismatched answer cancels.
- The bridge rejects a peer with another uid as an error, bounds each frame to 64 KiB, times out a peer that sends no prompt, and builds replies in `Zeroizing` buffers. The helper keeps the reply in a `Zeroizing` buffer too.
- Not ported: `known_hosts.rs` (`forget_host_key`) and upstream's `CredentialPrompt` mapping, which belong to the UI slice.

Tests: unit tests per module, a sandbox-tier `tests/openssh_fake_ssh.rs` that drives a shell-script `ssh` through spawn, askpass, deadline, cancel, drop, kill-after-grace, forwards and the sweep, and the Docker-gated `tests/openssh_session.rs`, which adds a jump-host case proving the stored password never reaches the jump host's prompt.

Open: `-J` hops run a separate `ssh` that receives none of our `-o` options, so the user's config still decides host-key checking for jump hosts.

## 2026-09-19: re-survey after upstream rewrote its Linux branch

`origin/linux` is 1,017 commits ahead of ours and 396 behind. The number is misleading in three ways, and each one matters more than the total.

**The old pins are gone.** Upstream force-pushed `linux`, so `5730238f5c72b4924669efbb7c0e79372de50a36`, the pin this document and the sprint plan both cite, no longer resolves in the repository. `807d280944a9…` resolves but is no longer an ancestor of `origin/linux`. Every "commits after X" count in those documents is unverifiable against the current remote. Pin by subject as well as SHA from now on; upstream `5730238f5` is the commit now called `f3cbf7361 fix(linux): rebuild the GSettings schema when it changes and cover SQLite in dev-env`.

**Only 200 of the 1,017 touch `linux/`.** The other 817 are Apple targets, the plugin system, iOS sync and AI chat, all excluded by `AGENTS.md`. Upstream now ships database engines as versioned plugins (`plugin-teradata`, `plugin-trino`, `plugin-typesense`, `plugin-weaviate` tags). That is the opposite of [ADR 0001](decisions/0001-no-plugin-system.md) and of compile-time driver registration. No action; recorded so the divergence is not rediscovered as a gap.

**Of those 200, 19 are new since our last review.** The rest are the rewritten SHAs of commits the sprint plan already dispositioned. The 19 are:

| Kind | Commits |
| --- | --- |
| Features we do not have (13) | CSV import, Excel export, INSERT-statement export, Markdown/HTML/XML export, connection groups, connection import/export, connection colour tags, duplicate a connection, named saved queries, column comments, open a SQL file, JSON log format, recording the statements the app itself runs in history |
| Fixes in code we share (1) | `3bcd8df75` column rename |
| Fixes in code we do not have (1) | `55528b854` OpenSSH 9 askpass fingerprint parsing |
| Housekeeping (4) | roadmap, i18n extraction, two test-stability fixes |

### What the shared fixes cost us

`3bcd8df75` found a real defect in our tree. We already emit `RenameColumn` ahead of the alter, but our alter guard still counted the name as a change, so a column whose name alone changed raised an `AlterColumn` with nothing to do. PostgreSQL and SQL Server swallowed it as `NoChange`. SQLite refused the entire save, because it refuses every alter. MySQL emitted a redundant `MODIFY COLUMN` that restates the definition from a model carrying no collation, character set or comment. Fixed with a cross-dialect regression test.

`55528b854` does not apply: we have no askpass bridge. Carry it forward if the system OpenSSH transport is ever adopted in B4.

One older commit deserves a separate check rather than a claim. `92aea7112 fix(core): export values at the precision their column declares` sits below the boundary, inside the 60 the sprint plan already dispositioned, under "converge serializers". That row records an intention, not a verification, so whether our exporter matches the declared precision is still unconfirmed.

### What we imported

`crates/core/src/import/csv_import.rs` is adapted from upstream `d91c70a92` (`crates/core/src/import/csv_import.rs`). Only the parser came across, and it was rewritten against our `ColumnInfo` and `Value`: upstream's `CellInput`/`ColumnType` model is part of their B3 contract and does not exist here. Nothing of their write path was taken. Upstream's importer has no policy layer, so ours builds its statements with `sql_dialect::build_insert_from_draft` and commits through a scoped approval on `PolicyGuard` instead.

### What the excluded trees still taught us

`242b76e02 fix(plugin-postgresql): quote every catalog literal so a backslash cannot escape it` is a whole bug class we are immune to: our PostgreSQL catalog queries bind `$1`/`$2` rather than interpolating literals. The optional DuckDB driver is the one place that still interpolates a schema and table name into a quoted literal, through an `escape_literal` that doubles quotes and ignores backslashes. DuckDB does not treat a backslash as an escape in an ordinary string, so this is not the same defect, but binding the parameters would remove the question.

`fix(plugin-postgresql): report each column's declared type, and compare it` (#2959) is the most useful thing in the whole survey for B3. Upstream concluded that a column needs both the name it is classified by and the spelling its own schema declares, because collapsing them loses collation, MySQL display width, enum label case and schema-qualified spellings. Our `ColumnInfo.data_type` is a single string. Design B3 for two fields, not one.

## 2026-09-16: script planner and safe formatting

- Reference: `TableProApp/TablePro` Linux `5730238f5c72b4924669efbb7c0e79372de50a36`, changes `f483e4169` and `50a515a36`.
- Imported the standalone `sql_syntax/script` modules and grammar enumeration, and the editor `format_plan`/`significant_tokens` modules with their tests.
- Connected formatting to the owning connection's dialect. Unsupported/non-SQL connections do not silently format as PostgreSQL. Existing execution/policy splitting remains unchanged until its contract migration is verified.
- Storage changes follow the upstream complete-draft and ordered-writer behavior, integrated with this fork's existing workspace queue and close-time failure UI.
- Verification is recorded in the sprint implementation ledger; imports alone do not complete the planned session or driver contract switch.

BookiE is an independent Rust and GTK codebase. Other products in the TablePro family, including `TableProApp/TablePro`, may be reviewed as references for security fixes, product behavior, SQL semantics, and user expectations. This review is optional and is not a source synchronization process.

## Rules

- Never merge, rebase, or cherry-pick Apple source trees into this repository.
- Do not copy platform framework code or assume another implementation's architecture applies to Linux.
- Inspect the behavior and the reason for the change.
- Check whether the same risk or product need exists in the Rust and GTK application.
- Manually implement only the behavior that applies to Linux.
- Keep existing Linux policy, audit, storage, GTK ownership, and driver boundaries intact.
- Add Rust tests that prove the ported behavior here.
- Omit changes that depend on platform services with no Linux equivalent unless there is a clear Linux product requirement.

## Good review targets

Reference review is most useful for:

- SQL safety classification and approval rules
- Credential handling and redaction
- Connection cancellation and reconnect behavior
- TLS and SSH identity checks
- Data-grid correctness and destructive-action guards
- User-facing behavior that should stay consistent with the TablePro family's expectations where Linux applies

Packaging, desktop integration, process management, keyrings, and UI framework details should follow native Linux behavior instead.

## Recording a manual port

Add an entry only when a reference review causes a Linux code or product change. Routine Linux development does not need an entry.

```text
## YYYY-MM-DD: short behavior name

- Reference reviewed: repository, ref, and commit or release.
- Linux relevance: risk or product behavior that also applies here.
- Manual port: Rust or GTK behavior implemented in this repository.
- Not ported: platform-specific parts that do not apply.
- Verification: focused tests, real-driver fixture, or GTK flow run.
```

The entry should describe behavior, not file-by-file source movement. There should be no source-tree merge to record.

## 2026-09-14: Linux safety and SQL character warnings

- Reference reviewed: `TableProApp/TablePro` main through `035ffe8f771797345ad86032e3aead16f18181fe`, verified remotely on September 14; local Linux baseline `5dbf87a44`.
- Manual behavior adoption: `a45fb4672` character warnings, `c180dbcac` cancellable/atomic export, and `558502f87` catalog refresh. Linux uses native Rust/GTK implementations, owning-connection identity, shared serializers and off-thread loaded-row export.
- Additional Linux fixes: dialect-aware IN literals and lexical spans, Redis browse isolation, MongoDB JSON/BSON numbers, and structure-save notification without rename. Updated a yanked transitive dependency.
- Not ported: Apple source/UI/services, plugin ABI, new engines or full database dump/restore. Existing Linux filters and reopen stack remain; further parity work is deferred.
- Verification and remaining gates: [September 14 sprint ledger](archive/sprint-2026-09-14.md). This is a source/behavior review, not a macOS runtime test or release approval.

## 2026-08-18: exact wide integers, export target, and unterminated SQL literals

- Reference reviewed: `TableProApp/TablePro` `origin/main` at `f696b5f3`, commits `060e5ea4` (preserve wide integer values), `e055dcd0` (export from the database you picked), and `00885a7e` (Format Query on an unterminated SQL literal).
- Linux relevance: the GTK grid edited integer cells through a spin button backed by `f64`, so opening the editor on an integer wider than 2^53 rewrote the value; streaming CSV export read from the active connection instead of the browse tab that owns the selection; unterminated literals are a known parser hazard.
- Manual port: integer cells wider than the exact `f64` range, and values that do not parse, now open an exact text editor instead of a spin button. CSV export resolves the browse tab's own connection and reports a closed connection instead of exporting from another one.
- Not ported: macOS view models, the Liquid Glass and Open Quickly work, license gating, and the display-format state machine. Linux has no SQL formatter, so the Format Query crash has no equivalent; the statement splitter was reviewed and covered with unterminated-literal tests instead.
- Verification: `cargo test -p tablepro-app --bins` covers the numeric editor choice, export connection resolution, and unterminated literals in both splitter paths.

## 2026-08-22: data-grid and result-correctness review, v0.62.0 through v0.67.1

- Reference reviewed: `TableProApp/TablePro` `origin/main` at `159be66f5` (v0.67.1), covering the `Fixed` and `Security` entries of v0.62.0 through v0.67.1. The heaviest churn was the data grid and the SQL editor.
- Linux relevance: eleven upstream fix clusters were checked against Rust code paths. Five described a defect that also existed here; six do not apply, because the Linux architecture differs in a way that rules the defect out. Two defects found while checking were not on the upstream list at all.
- Manual port:
  - Statement boundaries follow the connected engine's quoting, so a PostgreSQL dollar-quoted body runs whole and a semicolon inside a MySQL `#` comment is not a boundary. One dialect-aware lexer in `tablepro_core::sql_lex` replaced the editor's own splitter.
  - Statements that read a host file, run a program, or send SQL to another server classify as administrative, so a read-only agent token is refused.
  - Stop and the query timeout abort the running statement on the server for MySQL, ClickHouse and SQLite, matching the PostgreSQL behavior that was already verified. SQL Server retires the connection instead because Tiberius cannot send the TDS attention packet.
  - Copy row as INSERT omits generated columns, which every engine rejects, and escapes each value the way the connected engine reads it.
  - A cell edit is discarded if the row it opened on is no longer at that position, instead of being written to whichever row took its place.
- Not applicable:
  - Results wrongly editable for `UNION`, joins, subqueries and CTEs: the Linux editor renders results read-only, so no table identity is inferred from a result set.
  - Rows-per-page overflow, page numbers crossing tabs, and rows past a row-count estimate: page size comes from a fixed dropdown, pagination is per browse tab, and Next is enabled from a full page rather than a total.
  - A failing query showing a blank result area: the statement's own message is rendered in its result tab.
  - ClickHouse Verify CA falling back to public roots: a named authority replaces the public roots, and an unreadable or empty authority file is an error.
- Found while reviewing, not on the upstream list:
  - The rendered INSERT escaped only quotes. MySQL and ClickHouse read a backslash as an escape, so a stored value ending in one closed the literal early and the rest parsed as SQL. MySQL 8.1 evaluated the payload as an expression and returned 1.
  - Every SQLite column with no declared type decoded as NULL, so `count(*)` and other expressions showed an empty cell.
- Verification: `tablepro_core::sql_lex` and `sql_literal` unit tests, `crates/core/tests/query_pipeline.rs`, the MySQL, ClickHouse, SQLite and SQL Server container suites, the PostgreSQL release fixture, and the installed GTK suite.

## 2026-09-07: PostgreSQL filters, metadata ownership and offline DuckDB

- Reference reviewed: TableProApp/TablePro v0.72.0 at `6e6396c590bc1cc37f5e71e6d98d563dfcf8a2d6`, including `TableProTests/Core/Database/FilterSQLGeneratorColumnTypeTests.swift`, `Plugins/TableProPluginKit/PluginQueryTiming.swift`, and release fixes for filters, stale sidebar state, transaction ownership and offline extensions.
- Linux relevance: non-text pattern filters emitted invalid PostgreSQL operators, the daemon view wrapper inherited an empty default, sidebar refresh lacked connection identity, and DuckDB JSON functions required a downloaded extension.
- Manual port: PostgreSQL text-pattern conversion; ordinary/controlled view forwarding; stale-sidebar rejection; bundled JSON/Parquet. Invalid count fallback and redundant post-DDL browse reads were additional Linux findings. Structure/editor transactions use separate pooled handles; a real-engine regression confirms isolation.
- Not ported: Apple UI, plugins, licensing, bulk dump/restore behavior without a Linux counterpart. Timing remains a specified follow-up, not fabricated engine time.
- Historical verification: [stabilization ledger](archive/stabilization-2026-09.md); [performance evidence](archive/performance-2026-09.md). No Apple source tree was merged.

The editor now uses the imported planner for execution and run-at-cursor as well as formatting, following upstream `statement_cursor.rs`. Fork differences: retain policy/audit dispatch, parameter prompts and run-generation ownership; stop the whole script on errors; reject `GO n` rather than silently ignoring repetition; keep the existing scanner for the additional non-upstream drivers. Run-at-cursor passes the already planned statement directly, so MySQL custom delimiters are not lost by planning the isolated procedure again.

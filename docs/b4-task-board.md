# B4 task board: transport and sessions

Base scope: `aeac107a4`, branch `linux`, reviewed 2026-10-03. The active B4 integration branch advances as work lands. Use each evidence
manifest for the exact source revision and Git for the current branch tip.
The local source includes MySQL batch/result fixes indexed in the [evidence manifest]
(evidence/mysql-atomic-results-2026-10-03/manifest.json).
The [sprint](bookie-0.2-sprint.md) owns release order; [ADR 0008](decisions/0008-connection-and-session-ownership.md)
owns the decisions. Use the current Git tip for its revision because this board is updated
independently of source commits. B4 remains open. Implementation, local execution, hosted
execution and installed acceptance are separate states.

## Release wrap-up review (2026-10-11)

[The source and worktree review](archive/b4-release-wrapup-review-2026-10-11.md)
records the integrated branches, the finite finish order and the scope conflicts.
It reproduced an AUD-9 named derived-projection leak and a missing terminal
audit outcome for a write refused inside a read-only snapshot. The old code
branches are merged. Their unique historical evidence was preserved in
`63f6d2eb3`, and the 16 old worktrees were retired without deleting the shared
build cache. This review does not establish candidate acceptance.

### Finite code finish and candidate handoff

The [0.2.0 scope](0.2.0-scope.md) owns blockers. Finish the three demonstrated
defects below; broader features remain in the backlog. Pending PRs do not close
their ledger rows.

| Work | Implementation | Exit before candidate freeze |
| --- | --- | --- |
| AUD-9 hidden projection sources | [#537](https://github.com/cozyGarage/BookiE/pull/537): unknown derived/renamed sources and whole records fail closed, ordinary qualified columns remain visible | GitHub and Forgejo green on its exact head, then merge; native PostgreSQL cases include `array_agg(c.*)` cast to text |
| Early session refusal audit | [#538](https://github.com/cozyGarage/BookiE/pull/538): snapshot writes, structural refusals, retired-session calls and write-lockdown refusals record a Denied terminal outcome without dispatch | GitHub and Forgejo green on its exact head, then merge; keep transaction state and journal-failure lockdown |
| UI-13b snapshot-or-refusal | [#539](https://github.com/cozyGarage/BookiE/pull/539): refuse unsupported full export before source/destination access, preserve loaded-result and current-page export | Local preflight, app Clippy, 10 export tests and 26 widgets passed; GitHub and Forgejo remain the handoff gates, then merge the refusal and defer verified snapshot implementations |

Mutation triage is bounded to masking, host-key refusal, per-hop secret selection,
bundle rollback and durable audit. Existing fixture coverage and remaining proof
gaps are recorded in [the focused triage](evidence/b4-release-triage-2026-10-11/triage.md).
Do not turn a survivor percentage into release approval or a new blocker.

After the code merges, freeze one SHA. UX/maintainer runs the affected Forgejo
layers and installed Arch/Hyprland acceptance for AUD-2, B4-7, B4-16 and B4-22.
Use the finite TEST-15 list below, then the sprint's retry-free soak and release
decision. Source-build Xvfb, extracted package binaries and older green runs
do not substitute for this candidate.

### TEST-15 release acceptance list

Run the existing driver layer and PostgreSQL release fixture on the frozen SHA.
The six network-engine lost-ack scenarios below need independent stored-state
or request-count evidence of one application, plus a usable reconnect. A later
successful read must not dispatch the failed write again.

| Path | Existing selector or contract | Candidate evidence required |
| --- | --- | --- |
| PostgreSQL pooled UPDATE | `a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect` | Target and trigger witness stay exactly once after reconnect |
| MySQL pooled/prepared UPDATE | Same selector in the MySQL integration target | Target and trigger witness stay exactly once; new TCP connection is observed |
| Redis Lua write | `a_lost_eval_ack_is_not_replayed_after_redis_reconnects` | Independent target and audit keys stay one |
| ClickHouse HTTP INSERT | `a_committed_insert_with_a_lost_http_ack_is_not_replayed` | Native target and materialized-view witness stay one |
| SQL Server UPDATE batch | `a_committed_update_with_a_lost_ack_is_not_replayed` | Independent committed target/audit rows survive restart exactly once |
| MongoDB UPDATE | `a_committed_update_with_a_lost_ack_is_not_replayed_after_reconnect` | One proxy-observed request and one server-profile update; standalone fixture does not qualify replica-set retryable-write modes |
| Pinned sessions and write batches | `guard_tests_session`, `guard_tests_audit`, `session_postgres` and the MySQL atomicity matrix | Unknown post-dispatch outcomes retire/block the affected generation; no pool fallback; close and rollback audit the actual result |
| Allowed retry boundaries | PostgreSQL `query.rs` stale-type-cache predicate; MySQL `session.rs` prepared-protocol fallback | Source review distinguishes an explicit server rejection from a disconnect, timeout or unknown outcome; keep native session and parameter fixtures green |
| SQLite and DuckDB | Local-file drivers, read-only and transaction fixtures | Cancellation, file state and rollback contracts; no network acknowledgement scenario is claimed |

The current PostgreSQL session path enables the stale-type-cache retry, as do
pooled query/execute paths; explicit transactions disable it. MySQL session
fallback is parameter-free and limited to prepared-protocol rejection. These
are reviewed code paths, not a proof that arbitrary routines have no side
effects. MongoDB uses one direct endpoint with SDK defaults; its standalone
lost-ack fixture must not be advertised as all-topology retry proof. Broader
topologies, optional engine/effect matrices and fault-injection expansion stay
open in the backlog unless the maintainer changes release scope.

## Current Linux-tip B4 checkpoint (2026-10-10)

Tip includes #458/`Effects`, #459 engine read-only, #460 migration step 2,
#461 explain-plan masking, #463/#486 DuckDB selected-file pinning (AUD-10
DONE), #475 `MRG_MyISAM` rollback, #480 joined verdicts (AUD-11 step 3), #490
per-hop SSH secret identities (UI-1b storage groundwork), and the shared-analysis
refactor merged in [#506](https://github.com/cozyGarage/BookiE/pull/506).
AUD-11 remains open: #506 shares parsed statement analysis through guard
authorization and transaction-query handling, while classification, sensitive
projection and blast-radius planning still use specialized AST helpers. The
single-AST-walk consolidation in migration step 4 is unfinished. Exact local
verification and acceptance boundaries are recorded below; local runs do not
establish Forgejo gate or frozen-candidate/package acceptance.

## AUD-9 query-plan masking regression (2026-10-10)

PR #456's fail-closed fallback treated plain `EXPLAIN SELECT` as an unknown
projection and redacted the plan returned by the agent `explain_query` tool.
The PostgreSQL release fixture reproduced this twice on the post-#456 source;
the pre-#456 parent passed the same fixture. Merged PR #461 keeps plan output
masked for read-scoped agents and aligns the tool description and release test
with that behavior, because a plan may contain server-generated predicates.
The policy suite passed 216 tests with 4 Docker-only tests ignored. Code tip
`d4d26c8` was rechecked on 2026-10-10: system OpenSSH 1/1, mTLS
3/3, PostgreSQL release integration 59/59 (including plan denial and both
`EXPLAIN ANALYZE` denial checks), and seven SSH/mTLS GTK scenarios passed. See
the [AUD-9 evidence](evidence/aud9-explain-plan-mask-2026-10-10/manifest.json).
This local result does not establish the Forgejo gate, hosted acceptance or
frozen-candidate/installed acceptance.

## AUD-2 MySQL approval-dialog rerun (2026-10-10)

The exact scenario `mysql_unparseable_routine_dialog_denial_preserves_database`
passed three consecutive runs from PR #513 candidate `d4cca38` (based on Linux
`0855cca`). Each run used
`bash scripts/test-gtk-mysql-approval.sh` with a release binary built from
that source, Docker MySQL 8.0, a private D-Bus session, Xvfb/X11 and GTK AT-SPI.
The [run manifest and logs](evidence/aud2-mysql-approval-dialog-current-pr-head-2026-10-10/manifest.json)
record the binary and log hashes. The earlier empty-dialog failure's cause is
still unknown. These isolated Xvfb runs do not establish package-installed or
native Wayland acceptance, and do not replace the Forgejo gate.

## Retest indicators (from archived checkpoints)

Keep these as “test again” signals until cleared on a current candidate SHA.
Full dated narratives are in
[B4 history](archive/b4-history.md#archived-b4-dated-checkpoints-2026-10-09-consolidation).

| Signal | Status at archive | Action |
| --- | --- | --- |
| MongoDB TLS `ConnectionRefused` on `98134709` | Intermittent; later 48/48 TLS passes on `a47b1fb` and hosted `102ef480` | Retest if TLS layer flakes again; do not treat as closed root-cause |
| Empty MySQL approval dialog (operator observation) | Three consecutive Xvfb/AT-SPI passes on PR #513 candidate `d4cca38`; earlier `b4ee463` / hosted `102ef480` also passed; cause unconfirmed | Retest on installed package / native Wayland |
| Build Linux cancelled / pending on superseded tips (`8e5d1b18`, `32b170f`, `e697824`) | Superseded by later green and rate-limited runs | Ignore SHA; retest only current tip |
| Headless Wayland smoke incomplete (`97e5f55`) | No SIGSEGV; AT-SPI not activated | Retest native Wayland PKG-1 path |
| Docker Hub rate limits on tip near `c2f3f78b9` | Infrastructure red, not product signal | Retest Build Linux when pulls succeed |

## Next B4 acceptance run

Rerun affected layers when application or driver code changes. Remaining work
includes distribution-package/native Wayland acceptance, optional MySQL engine
and side-effect coverage, Windows AD interoperability, and UI-1b. Superseded
hosted-run narratives and the MongoDB TLS intermittent failure are in
[B4 history](archive/b4-history.md#archived-b4-dated-checkpoints-2026-10-09-consolidation)
and the retest table above. Xvfb staged-binary runs do not establish
distribution-package or native Wayland acceptance.

| Work | Required evidence on the next candidate | Current boundary |
| --- | --- | --- |
| B4-7, B4-16 | Complete package-installed/native Wayland trust and reconnect acceptance | At exact current Linux tip `227d846b95d14c2d55c366843bdf6ddc386b1c72`, all seven PostgreSQL SSH/mTLS GTK scenarios passed, including unknown-host decline audit, setup-failure audit, multi-hop trust, changed-key refusal and tunnel-loss retirement/reconnect. Frozen-candidate, package-installed and native Wayland acceptance remain open. See [current release evidence](evidence/b4-current-postgres-release-227d846b-2026-10-10/manifest.json) |
| B4-9 | Complete package-installed/native Wayland route/auth/TLS acceptance | Exact current Linux tip `227d846b95d14c2d55c366843bdf6ddc386b1c72` passed the PostgreSQL release layer: 1 system OpenSSH test, 3 mTLS tests, 59 release integration tests and all seven SSH/mTLS GTK scenarios. Frozen-candidate, package-installed and native Wayland acceptance remain open; the earlier MongoDB refusal cause remains undetermined. See [current Linux release evidence](evidence/b4-current-postgres-release-227d846b-2026-10-10/manifest.json), [hosted candidate evidence](evidence/b4-hosted-acceptance-2026-10-09/manifest.json) and [package evidence](evidence/b4-deb-package-lifecycle-2026-10-09/manifest.json) |
| B4-22 | Complete package-installed/native Wayland bundle audit acceptance | Four GTK safety scenarios passed on exact UI-1b bundle-v2 PR head `3f67c1bf`, covering sanitized export/import audit outcomes, encrypted credential restoration and cross-profile import. This was a source build under Xvfb/X11; distribution-package installed flow, frozen-candidate and native Wayland acceptance remain open. See [current UI-1b evidence](evidence/b4-ui1b-bundle-gtk-3f67c1bf-2026-10-10/manifest.json), [prior current-tip evidence](evidence/b4-22-bundle-current-tip-d0debc6-2026-10-10/manifest.json), and [earlier evidence](evidence/b4-22-bundle-current-tip-d916b3aa-2026-10-10/manifest.json) |
| B4-12 | ~~PostgreSQL rollback-failure acceptance on the selected frozen candidate~~ | Hosted candidate and local current-product-source (`fc180933`) backend-termination selectors passed. The scenario confirms `TransactionRollbackFailed`, absent transactional rows and persistent identity/trigger-sequence advancement. See [hosted candidate evidence](evidence/b4-hosted-acceptance-2026-10-09/manifest.json) and [local linux-tip evidence](evidence/b4-rollback-linux-tip-2026-10-09/manifest.json) |
| B4-11 | Extend failed-batch tests to optional/vendor MySQL-family engines and broader side-effect patterns | PR #475 adds `MRG_MyISAM` write-through cases for both MySQL and MariaDB. On exact Linux source tip `43b718ee2dc4b20bff03ac75ad87f4f571501406`, the serialized `mysql_atomic` selector passed 20/20 against Docker MySQL and MariaDB fixtures; see [exact-tip run manifest](evidence/mysql-atomic-linux-43b718ee-2026-10-10/manifest.json). The source matrix covers MyISAM, MEMORY, CSV, ARCHIVE, `MRG_MyISAM`, BLACKHOLE, MariaDB Aria, direct writes, trigger INSERT/UPDATE/DELETE effects, auto-increment allocation, trigger session state, pinned-session `LAST_INSERT_ID()` and advisory locks. The Aria direct and trigger matrix also passed on source `2b79ae3`; see [Aria run manifest](evidence/mysql-aria-batch-effects-linux-2b79ae3-2026-10-10/manifest.json). On exact local source `5f2367e6`, paired MySQL/MariaDB tests verify that a `RELEASE_LOCK()` inside a failing batch remains released after rollback; see [lock-release rollback evidence](evidence/mysql-lock-release-rollback-5f2367e6-2026-10-10/manifest.json). On exact source `80b998ef971a94b9600d28e4797a6f4715eb478a`, paired MySQL and MariaDB tests confirm a DML-assigned session user variable survives a later failed statement while InnoDB row data rolls back; the app warning now covers session state and other non-transactional side effects. See [session-variable rollback evidence](evidence/mysql-session-variable-rollback-80b998ef-2026-10-10/manifest.json). Optional/vendor engines and other side-effect classes remain open; frozen-candidate, package-installed, hosted and Forgejo acceptance remain separate. Earlier pooled `LAST_INSERT_ID()` observations were invalid because they could use a different connection; pinned-session tests provide the relevant oracle. See [advisory-lock evidence](evidence/mysql-advisory-lock-rollback-2026-10-09/manifest.json) and [session-state evidence](evidence/mysql-session-state-rollback-2026-10-09/manifest.json) |
| B4-17 | Complete package-installed/native Wayland trust flow | Exact current Linux tip `227d846b95d14c2d55c366843bdf6ddc386b1c72` passed 1 system OpenSSH test, 3 mTLS tests, 59 PostgreSQL release integration tests and all seven GTK trust scenarios, including multi-hop trust, second-hop decline, changed-key refusal and tunnel-loss recovery. This was a source build under Xvfb/X11; frozen-candidate, package-installed multi-hop trust and native Wayland acceptance remain open. See [current Linux release evidence](evidence/b4-current-postgres-release-227d846b-2026-10-10/manifest.json), [local Arch Wayland evidence](evidence/b4-arch-package-wayland-2026-10-09/manifest.json), [hosted candidate evidence](evidence/b4-hosted-acceptance-2026-10-09/manifest.json), [native SSH evidence](evidence/b4-ssh-native-current-2026-10-09/manifest.json), and [package evidence](evidence/b4-deb-package-lifecycle-2026-10-09/manifest.json) |
| B4-21 | Preserve Samba Kerberos+VerifyFull proof, then perform Windows AD interoperability | At exact Linux source tip `3b9f2c84`, both Samba AD selectors passed with verified TLS. PR #467 bounds the Kerberos connect future inside its five-second blocking-worker deadline and includes a regression for dropping a pending connect. Windows AD interoperability and distribution-package Kerberos remain open. See [current-tip Kerberos evidence](evidence/b4-21-mssql-kerberos-current-3b9f2c84-2026-10-10/manifest.json) and [PR #467](https://github.com/cozyGarage/BookiE/pull/467) |
| UI-1b | Preserve edit refusal while implementing the [per-hop secrets design](proposals/ui-1b-ssh-jump-chain-editor.md) across storage, transport, bundle compatibility and GTK | #490 landed stable hop IDs, credential revisions, v1-to-v2 migration and per-hop Secret Service APIs. #492 merged hop-scoped transport and cache identity; #494 merged encrypted bundle v2, with per-hop passphrase coverage in #528 and source-build GTK bundle-flow evidence. GTK editor, full migration/rollback acceptance and installed trust-flow acceptance remain open; editing stays refused |

## Remaining tasks

Implemented local slices (I2, I5, F7, MySQL atomicity matrices) live in
[B4 history](archive/b4-history.md#archived-remaining-task-prose-2026-10-10-pass-4).
Live acceptance bounds stay above. I1 is complete under ledger B4-10: the
Debian builder includes askpass and package validation rejects its absence.
Debian/GNOME desktop acceptance remains post-0.2.0 work under PKG-2.

## In-progress local slices

| ID | Current implementation and validation | Remaining |
| --- | --- | --- |
| B4-22 | Complete distribution-package/native Wayland bundle audit acceptance | Hosted installed GTK safety passed 53/53 scenarios on pinned candidate `5db1cfe`, including bundle export/import audit, encrypted credential round-trip and cross-profile import. Package/native Wayland acceptance remains open; see [current candidate evidence](evidence/b4-hosted-acceptance-2026-10-09/manifest.json) |
| B4-11 | Extend failed-batch session side-effect coverage | The serialized MySQL rollback selector passed 20/20 on local branch commit `0e6ce7c`, including MySQL/MariaDB cases proving successful `RELEASE_LOCK` and its MyISAM witness survive rollback while the InnoDB row does not. Optional/vendor engines and external acceptance remain open; see [release-lock evidence](evidence/mysql-lock-release-2026-10-10/manifest.json) |
| UI-13b / PERF-8 prerequisite | Policy sessions recognize PostgreSQL `BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY` and `SERIALIZABLE READ ONLY` as guarded read snapshots; weaker `READ ONLY` starts and unsupported-engine starts are refused. Writes and session/host-file side effects are blocked inside the snapshot. Policy tests and Docker PostgreSQL mutation-between-reads test pass locally; full `preflight.sh` passes. | Wire the session into cursor paging and full export, then complete engine-specific and installed acceptance. Debian package validation was skipped locally because `dpkg-deb` is unavailable. |

## Completed local slices

Dated local-slice narratives, the I5 event shape and the I3 route/auth/TLS
matrix live in
[B4 history](archive/b4-history.md#archived-completed-local-slices-2026-10-10-consolidation).
Live acceptance bounds stay in [Next B4 acceptance run](#next-b4-acceptance-run)
and the [ledger](known-issues.md).

| ID | Tip status | Remaining |
| --- | --- | --- |
| I3 / C6 / G5 | Source matrix and tunneled TLS local proof recorded | Package / native Wayland; system OpenSSH TLS equivalence |
| I2 / I5 / F7 / F8-headless | Local implementation and fixture coverage recorded | Frozen candidate, hosted and installed acceptance |
| B4-12 | Scoped rollback DONE on hosted candidate | Full-candidate / package qualification separate |
| B4-16 / B4-17 / B4-21 | Local SSH / Kerberos proof recorded | Package-installed / native Wayland; Windows AD |
| B4-18 / B4-19 | Local unit proof recorded | Frozen-candidate and hosted acceptance |

## Acceptance order

1. Continue B3's bounded cases and evidence reconciliation. B3 completion
   precedes closing B4 acceptance; independent review/preparation may proceed.
2. C6 and G5 are merged; retain local evidence in
   [B4 history](archive/b4-history.md#archived-completed-local-slices-2026-10-10-consolidation).
   Finish headless F8 candidate acceptance and I2/I5/F7 hosted/installed bounds.
3. Freeze an accepted B3+B4 source SHA and run affected `full security-policy
   drivers tls postgres-release widgets ui packaging-contracts`; include keyring
   and optional-feature checks where affected. Avoid repeated overlapping suites.
4. Installed Arch/Omarchy/Hyprland native Wayland workflows and upgrade/rollback.
5. B7 retry-free candidate soak and the maintainer's release decision.
6. After 0.2.0, installed Debian/GNOME native Wayland workflows and
   upgrade/rollback under PKG-2. Publication is separate.

Use the shared checkout and `target` cache in the current single-agent
session. Serialize Cargo and fixture runs. Do not clean the cache to diagnose a
failure. Record exact source hashes, commands, counts and raw sanitized logs.

## B4 completion checklist

- [ ] Shared policy/cache refusal and all session close/retirement routes pass on the candidate.
- [ ] Built-in trust and unattended daemon routes pass against real SSH fixtures.
- [ ] Connection uncertainty, journal failure and headless retirement follow ADR 0008.
- [ ] MySQL and SQL Server TLS through SSH have positive and negative native proof.
- [ ] Transport audit, Flatpak refusal and registered GTK session flow pass.
- [ ] Installed Arch native Wayland and upgrade/rollback evidence recorded.
- [ ] Post-0.2.0: installed GNOME native Wayland evidence recorded (PKG-2;
  Debian rules/helper implementation is complete under B4-10).

## Historical packets

The [October 2 dispatch plan](archive/b4-history.md#october-2-review-and-dispatch-plan),
[October 3 checkpoint](archive/b4-history.md#october-3-integration-checkpoint), original
lane tables, seven decision IDs, worktree reservations and detailed reproducers
are dated history. Their old “open”, “next” and “not merged” wording does not
override the current status above. Keep original task IDs when adding evidence.

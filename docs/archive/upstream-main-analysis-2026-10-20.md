# Upstream main analysis, 2026-10-20

Reviewed 2026-10-20. This is a dated source review and adoption proposal. It does not change accepted ADRs, select a release scope, or establish new runtime defects.

**Completion clarification, 2026-10-20:** The research and execution plan are complete. The implementation proposals below are not completed features. The [archive claim verification](../evidence/archive-claim-verification-2026-10-20/README.md) records the current issue snapshot, source trace and focused test results, including their limits.

- [x] Record source pins, architecture comparison and adoption costs.
- [x] Map regression ideas to existing issues and validation tiers.
- [x] Record the workstation hardware, artifact reuse plan and measured local reuse evidence.
- [ ] Complete the proposed application reconnect, consumer corpus, crash-save, retained-memory, reconciliation and accessibility work through the owning issues in the recommended sequence.

## Sources and comparison boundary

| Source | Verified revision or state |
|---|---|
| TablePro `main` | `3222542a4f66d24dc03c36478f97bf1ce34dbbf3` |
| BookiE GitHub `main` | The same `3222542a4f66d24dc03c36478f97bf1ce34dbbf3`, verified with `git ls-remote` |
| BookiE GitHub/local `linux` | `cc21ad81d81e0e47ca87e6ab382ec15a4bb2b747` |
| Previous Linux adoption review | Upstream `0ab322ea1d7576cfd858ab5946edb9e84cba9e5b`, reviewed October 18 |
| Local cached `origin/main` | `2996dc2731798235b373e3906e628458efb037bd`; stale relative to both public main branches |
| BookiE working copy | Contains an uncommitted documentation/privacy cleanup; product comparisons below use inspected source at the Linux revision |

The main branches are synchronized. This does not merge upstream's `linux/` implementation into BookiE's independent Linux workspace. Upstream now keeps Apple code in `apple/` and Linux code in `linux/`; BookiE's Linux code remains at its repository root. Updating main is a source mirror operation, while adoption into linux is a reviewed implementation change.

There are 76 first-parent commits between the cached main reference and the current upstream main. The narrower comparison since the October 18 adoption pin touches Linux in 22 first-parent commits. These are history counts, not counts of new features or validated fixes.

The review read current implementation and tests for connection replay, write outcomes, value corpora, temporal decoding, large-table tests, SQLite error classification, keyboard column resizing, translation and CI. It sampled recent Apple editor and listing changes and read the relevant public PR explanations. It did not execute either application, database fixtures or upstream CI. Upstream PR authors' verification statements are identified as reported evidence rather than independently repeated results.

## Assessment

The most directly comparable areas are native Linux architecture, explicit outcomes, connection ownership and engine-backed regression testing. Recent changes emphasize finishing observable workflows and proving failures: recovery after a server restart, exact values through different consumer paths, process death during a save, keyboard operation and translated errors.

This is useful because BookiE already shares the layered Rust/native GTK approach and has substantial value, policy and test infrastructure. Reusing a bounded test scenario is cheaper than adopting a parallel framework. Common ancestry and similar goals explain some overlap; this review does not establish who originated a particular idea.

The product boundary still differs. Upstream's [root README](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/README.md) describes Apple and Linux products, Swift plugins and paid Mac features. BookiE's accepted scope is a Linux GTK/Relm4 client with static Rust drivers, no entitlement gates, and shared PolicyGuard/MCP enforcement. Linux-compatible implementations and cross-platform failure patterns can transfer; Apple UI code, plugin ABI and commercial account workflows require different decisions.

## What BookiE has already absorbed

Live GitHub state on October 20 shows all nine adoption children #1140 through #1148 closed. The parent [#1149](https://github.com/cozyGarage/BookiE/issues/1149) remains open with unchecked child boxes, so its body is behind the child issue state. Do not create the same work again from the older review.

| Previous packet | Current evidence and interpretation |
|---|---|
| PgBouncer cancellation and isolation | #1140 closed; #1150 introduced protocol cancellation, and #1159 corrected test pool sizing. Current PostgreSQL code uses `PgCancelToken`; tests exercise session and transaction pooling and cross-client cancellation isolation. |
| MySQL zones and DST | #1141 closed through #1151. Preserve that native-oracle work before changing session defaults. |
| Cancellation/write conformance | #1142 closed; #1154 adds pre-dispatch cancellation audit coverage. A closed packet does not imply every future fault scenario is covered. |
| Reverse keyset navigation | #1143 closed through #1153. Extend the existing implementation instead of importing another pager. |
| GTK blocking boundaries | #1144 closed through #1152. New restrictions need evidence of a remaining escape. |
| Notices, offline inputs, changelog evaluation, doc symbols/catalogues | #1145–#1148 closed. The changelog evaluation retained the current convention; upstream's later towncrier adoption alone does not reverse that choice. |

## Architecture: useful contracts and adaptation costs

Upstream's [Linux architecture](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/linux/ARCHITECTURE.md) separates `core`, `net`, `ssh`, `storage`, `session`, drivers, test fixtures/support and the GTK app. Its `session` crate owns connection leases, link generations, health and the operation runner. Drivers use core/net without depending on session or the UI. BookiE distributes equivalent work across core, transport, SSH, app-services and the GTK service layer, adding policy, MCP and agentd.

The reusable idea is a single operation path with explicit ownership and outcomes. BookiE should complete ADR 0018's headless service extraction around actual lifecycle problems. Moving all upstream session types into BookiE would add a second connection authority and bypass opportunities around policy.

Upstream's [DriverCapabilities](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/linux/crates/core/src/capabilities.rs) describes endpoint kind, authentication/TLS, read-only enforcement, DML versus DDL atomicity, script execution, commit resolution, estimates and object kinds. This is more expressive than scattering engine-name branches through UI code. Adopt a field when an existing consumer needs it, with an explicit unsupported/unknown case. Existing BookiE #1065 owns per-object write capabilities; these are not interchangeable with a driver's broad engine capability.

The most substantial long-term contract is the [WriteLedger](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/linux/crates/core/src/write_ledger.rs). It records the statement being sent, confirmed statement count, whether COMMIT was sent and an optional resolution token. [CommitToken/CommitResolution](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/linux/crates/core/src/commit.rs) distinguish applied, not applied, partially applied, still running and unresolvable outcomes. This can inform BookiE's open #947 reconciliation work. It must integrate with durable audit state and guarded-write lockdown. A server status lookup is useful evidence, but it does not make arbitrary SQL safe to replay or prove non-transactional side effects were undone.

## Recent changes worth adapting

### 1. Reconnect tests distinguish user Stop from retirement of an old connection

Upstream [#3564](https://github.com/TableProApp/TablePro/pull/3564) found that reconnect closed an old connection, an in-flight read returned `Cancelled`, and the retry rule did not recognize connection replacement. The [operation runner](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/linux/crates/session/src/operation/operation_runner.rs) converts that driver cancellation to connection loss only when the caller and session did not cancel and the current link generation is newer. Its [replay rule](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/linux/crates/session/src/operation/replay_rule.rs) permits metadata/page/count reads, once, after relevant connection/network failures. Save, close, export, user Stop and timeout are not replayed by that rule.

A real PostgreSQL restart test checks recovery, an in-flight read, and absence of a replayed write. BookiE's connection monitor already swaps connections and advances audit generations. Its existing driver tests include `a_restarted_postgres_server_restores_the_existing_pool`, `a_committed_write_with_a_lost_ack_is_not_replayed_after_reconnect` and confirmed cancellation with subsequent pool usability in `crates/drivers/postgres/tests/support/disconnection.rs`. The restart test explicitly retries a read after starting the same server again; it does not establish automatic application-level replay. This review did not reproduce an identical BookiE failure. Transfer the test sequence first under existing #593 and #590, coordinating with #947. A SQL `SELECT` can invoke a writing function, so replay must be limited to a genuinely governed/read-only operation rather than a keyword or result shape. Reacquire the guarded handle, preserve the overall deadline and budget, and reject late UI outcomes by request generation.

### 2. A shared real-value corpus tests consumer disagreement

Upstream [#3559](https://github.com/TableProApp/TablePro/pull/3559) adds [a shared corpus case](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/linux/crates/test-support/src/conformance/cases/value_corpus.rs). Each engine declares SQL fixtures and expected visible values; the case reads them through browse, export-stream and editor paths. Its PR reports failures in MySQL BIT width, declared timestamp precision and PostgreSQL values beyond chrono's range before the corresponding fixes.

The [PostgreSQL corpus](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/linux/crates/drivers/postgres/tests/integration/value_corpus.rs) includes BC and far-future dates, infinity, time 24:00, odd time-zone offsets, mixed-sign intervals, scaled and wide numerics, numeric specials, money limits, Unicode/combining text, empty bytes, array NULLs, ranges and extension-like metadata identities.

BookiE already has native-oracle/value-contract tests and far-range calendar fallback in `crates/drivers/postgres/src/temporal.rs`. It is incorrect to treat upstream's far-date fix as a missing BookiE decoder. Reuse the corpus inputs and consumer matrix under #594, not a replacement type hierarchy. Add pgvector/PostGIS cases under #902 only after exact wire semantics are established. Assert typed semantics as well as visible text: a string rendering alone cannot prove exact numeric, array-dimension, JSON, temporal or export round-trip behavior. Upstream explicitly allows editor text to differ from browse output; BookiE must follow its own advertised contract.

### 3. Test death of the process that actually owns the save

Upstream [#3565](https://github.com/TableProApp/TablePro/pull/3565) adds [kill_during_save](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/linux/crates/app/tests/kill_during_save.rs): perform a completed SQLite grid save, start a second multi-update save, use a trigger/journal barrier to ensure work is in flight, send SIGKILL to the app child, then relaunch the real binary. It checks the first committed data survives, the interrupted save is absent, subsequent writes work, and history/settings/tab records remain readable. The PR reports that deliberately committing each UPDATE separately makes the test fail.

BookiE has transaction, active-edit and installed GTK tests, but the inspected tree has no equivalent named crash-mid-grid-save process scenario. This is a coverage gap, not proof of corrupted data. Adapt the deterministic barrier and fresh-process assertions to #1029/#593, with UX/B4 coordination. Use a disposable profile, database, bus and keyring; verify the audit chain and recovery behavior too. SQLite rollback-journal evidence does not qualify WAL, PostgreSQL lost-COMMIT acknowledgement, power loss or filesystem durability. Start with one existing acceptance layer and add the server-backed phase only after the local harness is reliable.

### 4. Large-table tests measure depth, latency and retained memory

Upstream [#3563](https://github.com/TableProApp/TablePro/pull/3563) walks a million-row table, checks first/last pages, compares early versus deep page latency and streams a full CSV export. Its [shared case](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/linux/crates/test-support/src/conformance/cases/large_table.rs) sets explicit time and resident-memory-growth bounds. [ResidentPeak](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/linux/crates/test-support/src/conformance/resident_peak.rs) resets the kernel's process high-water mark before measuring; the case requires a process of its own. #3583 puts SQLite's case into its own binary.

BookiE already has a million-row browse benchmark and GTK memory observations. The useful extension for #1032/#554 is a repeatable assertion through actual page/stream/pin/export/close ownership, including many wide cells and cancellation. Do not import their 64 MiB/2-second thresholds as universal limits. Calibrate on the selected runner and preserve workload/environment evidence. An incremental RSS bound is not a total-process ceiling, and a driver test does not prove UI responsiveness. Adapt paging/current-result export now; BookiE's entire-table export remains refused under ADR 0014 until snapshot consistency is implemented and qualified.

### 5. SQLite lock contention needs an actionable outcome

Upstream [#3585](https://github.com/TableProApp/TablePro/pull/3585) separates file locking from unavailable connection capacity. Its real-file tests cover competing writers, a reader blocking COMMIT in rollback-journal mode, import and editor paths. It keeps `SQLITE_LOCKED` distinct from external `SQLITE_BUSY` contention.

BookiE currently maps SQLite database errors to `DriverError::Query` and both pool closure and pool timeout to `Disconnected` in `crates/drivers/sqlite/src/lib.rs`. That is a confirmed classification difference, not a reproduced reconnect/UI bug. A narrow test should establish whether contention produces misleading guidance or unnecessary recovery before changing the error contract. Preserve code and typed reason through the app; do not infer a disconnect or replay a save from a capacity timeout. PostgreSQL remains the priority, so this is a later bounded reliability candidate.

### 6. Small UX changes expose incomplete workflows

Upstream Linux [#3566](https://github.com/TableProApp/TablePro/pull/3566) resizes the focused grid column by keyboard, uses font-relative steps and persists width through the existing binding. Tests cover layout width, focus and saved settings. BookiE already persists dragged column widths; the inspected grid lacks an equivalent resize action. This is a useful #561 accessibility candidate after correctness work.

Apple [#3674](https://github.com/TableProApp/TablePro/pull/3674) turns Show All Tables into a read-only listing, reuses/refreshes its tab, retains sort/width state and marks partial listings. Its PR explicitly leaves schema-quote handling unresolved for several plugins. Transfer the complete workflow and partial-state tests only if selecting a comparable catalog overview. BookiE #580 owns large-catalog performance and #1054 owns database-scoped workspace identity; listing SQL must remain bound/quoted and policy-guarded.

Apple [#3579](https://github.com/TableProApp/TablePro/pull/3579) tests IME composition, dead-key quotes, auto-pairing and undo. BookiE already tracks GTK grid preedit and refuses close while composition remains active. Use the composing/commit/cancel/undo sequences as native input test prompts; do not port AppKit event handling into GtkSourceView.

Other Apple fixes restore table information after async rows arrive (#3595), hide empty object sections (#3592), keep find/gutter controls inside the editor (#3591), and paint editor margins with the selected theme (#3596). Their shared lesson is to verify background completion, theme changes, narrow layouts and keyboard behavior at the rendered surface. These fixes do not establish corresponding GTK defects. Result-chart facets (#3593) are a feature candidate with lower priority than reliability and PostgreSQL depth.

## CI, maintenance and translations

Upstream's [CI entry point](https://github.com/TableProApp/TablePro/blob/3222542a4f66d24dc03c36478f97bf1ce34dbbf3/.github/workflows/ci.yml) plans affected suites and exposes one aggregate required check. Main compares against the last successful CI push so replaced/failed runs do not lose changed-path coverage. PR runs cancel obsolete heads; dispatch/release runs use distinct concurrency keys. Its Linux workflow caps Docker job concurrency at three and moves packaging/Flatpak/MSRV work to its own nightly/manual path. Version fixtures and matrix entries test PostgreSQL default 17 plus 14 and 18, with 13 available for legacy catalog checks.

BookiE should retain the existing GitHub cheap/serialized Forgejo acceptance split. Do not copy upstream's nightly placement and accidentally remove required merge-tier coverage. Version selection and process isolation are useful within existing tiers: start with the declared PostgreSQL floor and newest supported release, including a catalog branch boundary and PgBouncer interaction; use nightly for broader compatibility only when that preserves the accepted gate. More jobs are not automatically more evidence per unit of runner time.

Upstream also removes custom style ratchets, drops its doc-symbol check and generated POT tracking, and adopts towncrier. BookiE has just implemented/evaluated these areas differently. Measure false positives, merge conflict cost and deterministic regeneration before copying a maintenance convention. Keep checks that protect a real invariant. The upstream default nextest filter explicitly excludes several Tiberius cancellation tests due to an acknowledgement problem; a green run must be read together with its exclusions.

Linux #3555/#3586 carry typed application-controlled error reasons to translated UI text, including SSH fields and connection persistence failures. Reuse the error-reason-to-localized-next-step pattern. Audit BookiE's actual displayed strings, keeping raw server details separate and sanitized; simply translating an outer sentence does not translate embedded application-generated text.

## Recommended next sequence

| Order | Work | Existing owner / expected evidence | Confidence |
|---|---|---|---|
| 1 | PostgreSQL restart and lost-ack phase matrix, including explicit Stop and no replay of writes | #593/#590, B4 with B3/UX handoffs; real server plus guarded/audit assertions | High value; identical defect unproven |
| 2 | Cross-consumer PostgreSQL corpus using native expected values | #594 and #902; B3, existing driver/release layers; typed plus display/export assertions | High |
| 3 | Process death during a real grid save and fresh-profile recovery | #1029/#593, UX/B4; deterministic process barrier, database and local-state oracles | High coverage value; runtime defect unproven |
| 4 | Repeated page/stream retention and calibrated memory assertions | #1032/#554; real page walk, pins/export/teardown and existing profiling | High |
| 5 | Outcome reconciliation design informed by WriteLedger/tokens | #947, B4; explicit ADR/contract decision and ambiguity tests before UI unlock | High relevance; substantial integration cost |
| 6 | Keyboard column resizing and translation completeness | #561/#575, UX; focus/persistence/IME/rendered acceptance | Medium, useful bounded polish |
| Later | SQLite contention reasons, table overview, chart facets | Reproduce user impact or select a product task before filing implementation | Medium; no confirmed local user bug |

Use existing issues rather than reopening completed UP-2–UP-10. Each implementation should take one observable contract and failing regression, adapt compatible source with exact provenance and attribution, run its existing tier, and use the serialized Forgejo gate. The observed sources declare AGPL licensing; preserve relevant notices and review each reused dependency under the repository's policy. No driver, UI framework or test-tier replacement is selected by this report.

## Verification and limits

Remote tips, first-parent history and relevant source/test files were inspected. GitHub PR bodies and current BookiE issue states were read directly. Public issue status can change after this date. No upstream green-CI claim is made, and no test-author statement is substituted for an independent run. No application tests, database tests, builds, performance measurements or Forgejo runs were started for this documentation analysis.

Follow-up execution planning: [workstation test reuse](../proposals/workstation-test-reuse.md) records the dated hardware inspection, cache strategy and nightly-dependent next steps.

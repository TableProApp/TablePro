# TablePro upstream movement and BookiE lessons

This initial audit predates the maintainer's confirmation that BookiE 0.2.0 work is complete. Its proposed work is now tracked in the [post-0.2.0 adoption review](upstream-linux-adoption-2026-10-18.md); earlier scheduling language below is historical.

Reviewed 2026-10-18. Public GitHub evidence was captured around 20:28 UTC. This is a source and public CI audit, not installed acceptance or a complete security audit. Neither client was built or launched, and no database tests were run. BookiE's working checkout was left unchanged during this initial audit.

## 1. Assessment

Upstream has made a material commitment to Linux. It merged a substantial Rust/GTK application into its default branch, made Linux a required check, prepared Linux-specific release tags and package workflows, and publicly described a release-process effort over the next one to two weeks. The implementation now addresses many of the same hard problems BookiE addresses: lossless values, cancellation that reaches the server, session identity, uncertain writes, bounded result retention, durable drafts and real-engine tests.

This warrants regular technical review. It does not establish that upstream has released Linux, passed desktop acceptance, matched BookiE's governed execution model, or copied BookiE's later work. There is demonstrable shared Linux history from April. Similar architecture alone cannot establish the direction of influence.

The most valuable lessons are specific contracts and reproductions. A wholesale merge, a framework rewrite, or a feature-count race would obscure the differences that matter.

## 2. Source pins and evidence

| Item | Audited value |
|---|---|
| TablePro main | `0ab322ea1d7576cfd858ab5946edb9e84cba9e5b` |
| Linux branch head merged into main | `8a06bc0559012ae7181c5f8450ec54536003a5a7` |
| Main immediately before merge | `dabe00beae720725a10d0905193b69e2856c4f7e` |
| BookiE local and GitHub Linux at snapshot | `8626129e60c8f62661cf6d64a70067a6cbfbe654` |
| Upstream source checkout | `/tmp/tablepro-upstream-audit-20261018` |
| Evidence | [Source pins and public observations](evidence/upstream-linux-audit-2026-10-18/source-pins.json); raw API responses were retained in the temporary audit directory |
| Previous local review used for reconciliation | `docs/archive/code-and-ui-audit-2026-10-18.md` at the BookiE pin |

GitHub PRs, issue comments, workflows, rulesets and source files were inspected. Source comparison covered the workspace architecture, value and binding contracts, owned calls, write outcomes, PostgreSQL cancellation and pooler tests, MySQL time-zone writes, paging, export encoders and file replacement, GTK startup/lifecycle, and conformance infrastructure. BookiE counterparts were read before proposing gaps.

Evidence labels used below:

- **Confirmed source:** directly visible implementation or repository configuration.
- **Hosted evidence:** a recorded GitHub run and its exact head; not a local rerun.
- **Investigation:** a plausible BookiE risk or improvement needing a reproduction or measurement.
- **Recommendation:** proposed work, not an approved release blocker or newly created issue.

## 3. What changed today

At **20:12:11 UTC on October 18**, [PR #3541](https://github.com/TableProApp/TablePro/pull/3541) merged Linux into main with a merge commit. It reports **369 commits, 1,574 changed files, 269,915 additions and 150 deletions**. Those are integration totals covering historical branch work, not one day's output. The actual merge has two parents, preserving that history.

An earlier PR, #3538, was accidentally squash merged. The replacement PR explains that main was reset and #3541 restored the intended history. That explains the nearby duplicate merge PRs and cancelled runs; it should not be interpreted as two independent Linux implementations.

The branch inventory no longer contains `linux`. It contains main, release/0.82, gh-pages and a documentation follow-up branch. Linux now lives under `linux/` in the monorepo. BookiE remains its own root-level Linux workspace.

The ruleset API confirms that **Linux is required** on the default and release branches. Both relevant tag rulesets include `refs/tags/linux-v*`. [PR #3542](https://github.com/TableProApp/TablePro/pull/3542), open at the snapshot, updates documentation to reflect those completed configuration steps. Its remaining setup references include release secrets, the PPA variable, Launchpad and COPR. Their availability was not independently proven here.

The maintainer's [Linux-support discussion](https://github.com/TableProApp/TablePro/issues/311) changed from a September 25 statement that there was no Linux roadmap to an October 18 announcement of merging Linux and working on release infrastructure, estimated at another one to two weeks. This is a concrete change in stated commitment. It is an estimate, not a release date.

### Readiness boundary

The pinned Linux README and roadmap explicitly state that nothing has shipped and there is no `linux-v*` tag. The first 100 public releases contained no Linux release. The README's apt/dnf commands are described as usable from the first release; they are not evidence that the repositories are ready today.

At the snapshot:

- [Linux run 39153770057](https://github.com/TableProApp/TablePro/actions/runs/39153770057) succeeded on `8a06bc05`, the branch head used in the merge. Its 17 jobs all reported success, including real-engine, session, app, SSH, Flatpak and supply-chain jobs.
- A later run on the same head was cancelled during the merge transition, making its aggregate Linux job fail. It is separate from the successful run above.
- [Main push run 39162230649](https://github.com/TableProApp/TablePro/actions/runs/39162230649) was still in progress at capture. The exact merged main head was not declared green by this audit.
- Three SQL Server cancellation cases are excluded by the committed nextest filter pending the Tiberius attention acknowledgement issue. A green suite does not establish those cases.

## 4. Movement over time

The Linux scaffold began on April 26. Both current histories contain the same early Linux commit objects. The latest shared commit touching `linux/` found in this comparison is `014bdf580f4dfb0d453e4b35b02b4c617246034b`, authored April 27 at 00:43:59 +07:00, or April 26 UTC. The overall Git merge base is an August 1 macOS commit, so it is unsuitable as the date the Linux implementations diverged.

The public discussion also records cozyGarage offering ClickHouse work in July and pointing users to the independent BookiE fork in September. Upstream was aware of the fork. That establishes awareness, not reuse of particular later changes.

A bounded Git history query since October 12 found **50 upstream commits touching `linux/`**. The author strings are three spellings of the maintainer's name; this is not proof of multiple contributors or of staffing capacity. BookiE has a different change cadence and commit granularity, so commit counts are not a quality or velocity ranking.

The recent upstream work falls into three phases:

| Period | Movement | Interpretation |
|---|---|---|
| October 13 | Driver contract v2, maintained client libraries, owned cancellation, explicit write phases | A foundation replacement rather than UI-only expansion |
| October 14–15 | GTK subclass/session rewrite, remediation batches, lossless value/dialect ADR | More explicit ownership and native GNOME integration |
| October 16–18 | PPA/COPR strategy, paging, time zones, imports, accessibility, storage errors, packaging, main merge | Release preparation and correction of integration defects |

On the Apple side, recent main history is also active, but much of October 17–18 concerns plugin discovery and compatibility, plugin updates, signed beta feeds, immutable native-library releases, and stock Apple release tooling. Those changes should not be counted as Linux capabilities.

## 5. Architecture comparison

The upstream [Linux workspace](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/Cargo.toml) is Rust 2024, pinned to Rust 1.98 with a 1.97 floor. It contains core, net, ssh, session, storage, app, test-support, test-fixtures and five driver crates. MySQL and MariaDB share a driver. Its Linux source is separate from the Swift macOS/iOS implementations.

| Area | Upstream Linux | BookiE at its audited pin | Assessment |
|---|---|---|---|
| UI | GTK subclasses and composite templates; two Relm4 dialogs remain | Relm4 architecture with ongoing headless service extraction | Different maintenance tradeoffs; no framework migration justified by popularity |
| Window ownership | One connection session per window; workspace never adopts a replacement session | Existing workspace/session identities and generation checks | Learn from explicit lifetime boundaries and teardown tests |
| Driver contracts | Rich capabilities, connection-owned calls, dedicated editor sessions, write ledger, event sink | Core contracts, controlled operations, transactions, batches, cursor path through PolicyGuard | Compare each missing guarantee rather than replace all traits |
| PostgreSQL | tokio-postgres plus deadpool; protocol cancellation; unnamed typed operations | SQLx plus separate `pg_cancel_backend` connection | High-value compatibility investigation |
| SSH | System OpenSSH, private Unix-socket forwarding, askpass | Built-in russh plus explicit OpenSSH route | Adopt security cases selectively; preserve intentional config restrictions |
| Values | Rich native variants, exact text fallback, non-NULL decode failures represented explicitly | ADR 0007 typed values, exact fallback/refusal, stored-value proof | Strong overlap; richer enum alone is not stronger correctness |
| Governance | Driver read-only contracts and UI confirmations | PolicyGuard, approvals, masking, durable audit, scopes/allowlists across GUI and agentd | Upstream Linux has no equivalent composition path in the inspected workspace |
| Engines | PostgreSQL, MySQL/MariaDB, SQL Server, ClickHouse, SQLite | Those plus Redis, MongoDB and optional DuckDB | BookiE is broader; each extra engine increases acceptance work |
| Distribution | GNOME 50, Ubuntu 26.04/26.10, Fedora 44, PPA/COPR preparation; Flathub later | Arch/Hyprland 0.2 target; Debian builds and later wider acceptance | Different initial audiences; neither source build proves desktop readiness |

Upstream macOS has MCP and runtime plugins. The Linux manifest and composition root do not import those Swift capabilities. Conversely, absence of BookiE's governance layer does not make upstream's desktop client inherently unsuitable; it serves a different contract.

## 6. Highest-value technical lessons

### 6.1 PostgreSQL: cancellation, poolers and client-library tradeoffs

Upstream [ADR 0016](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/docs/decisions/0016-driver-contract-v2.md) explains why it left SQLx PostgreSQL: protocol cancellation, arbitrary transport streams, controlled TLS, and unnamed statements. Its `cancel.rs` arms a token for the actual connection and sends the PostgreSQL cancel request through the endpoint.

Its [PgBouncer tests](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/crates/drivers/postgres/tests/integration/pgbouncer.rs) exercise transaction pooling with prepared statement tracking disabled, cancellation followed by another query, session-state isolation and custom-type table reads. This is stronger source coverage than simply testing that a query connects through a pooler.

BookiE's `crates/drivers/postgres/src/lib.rs` still acquires a separate connection and executes `SELECT pg_cancel_backend($1)`. Its existing `tests/support/network_paths.rs` checks basic session/transaction pooling and the diagnostic for missing prepared-statement support, but its inspected `exercise` does not test cancellation, independent-client isolation or session-state leakage through the pooler.

**Investigation:** after a transaction pooler reassigns a physical backend, is the remembered backend PID still the right cancellation target? Can the control connection get a slot while the operation it must stop occupies the pool? Does a late cancellation affect a subsequent operation? These are source-motivated questions, not reproduced defects.

**Recommended acceptance:** real PgBouncer session and transaction modes, prepared tracking both on and off, small server pools, simultaneous clients, slow reads and writes, cancel/deadline races, then a clean subsequent query. Observe the intended backend and prove the other client's work survives. Preserve policy decisions and terminal audit outcomes throughout.

Do not switch libraries immediately. Upstream accepts important costs: PostgreSQL editor results are text because simple-query metadata lacks native types, transaction status uses inference and SAVEPOINT probes, and cursor execution changes planning characteristics. A BookiE migration must explicitly preserve typed result metadata, codecs, TLS service identity, session semantics, cursor behavior and PolicyGuard.

### 6.2 Cancellation must own the resource until the stop settles

Upstream [OwnedCalls](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/crates/core/src/owned_calls.rs) keeps work alive when its caller disappears, propagates cancellation, waits within a grace period, and discards an unsafe resource. It distinguishes statement-scoped and connection-scoped stops. For the latter, returning a connection early can let a delayed stop hit its next request.

BookiE already has server-side cancellation and acknowledgement requirements. The useful extension is a reusable race matrix: drop caller, deadline while dispatching cancel, delayed stop after work completes, stop transport failure, pool reuse and shutdown. Assert actual server and reuse behavior, not only the returned error.

**Owner:** B4 with the affected driver owner. Existing cancellation work should be reconciled before opening any new packet.

### 6.3 Write phases explain uncertain outcomes

Upstream's `WriteLedger` records statements being sent and confirmed and commit being sent. It distinguishes rollback, partial application and unknown commit outcomes, and can carry a resolution token. It holds engine cancellation while commit or an irreversible statement is in flight.

BookiE already distinguishes unknown outcomes, rollback failures and durable audit obligations. The lesson is to compare the complete phase matrix, especially nontransactional MySQL tables, ClickHouse mutations and lost commit acknowledgement. A simpler ledger is useful only if it retains BookiE's cross-consumer audit semantics.

**Recommended acceptance:** disconnect before send, during statement, between statements, before commit, after commit send and before acknowledgement; independently read stored rows; assert no automatic write replay. A documented state table would be more useful than another broad error wrapper.

### 6.4 MySQL: UTC reads do not settle write-default semantics

Upstream [server_zone.rs](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/crates/drivers/mysql/src/server_zone.rs) explicitly separates UTC reads from writes in the server's global zone. It converts timestamp parameters, checks round trips through repeated DST hours, and closes a connection if the read zone cannot be restored. Its strict workspace mode adds `STRICT_ALL_TABLES` to prevent coercive saves on lenient servers.

BookiE initializes UTC connections and has real-engine test source proving that a timestamp in a manually changed non-UTC session is refused rather than mislabeled. It also intentionally tests preservation of server SQL modes. Those contracts do not by themselves prove the expected wall time for `DATETIME DEFAULT CURRENT_TIMESTAMP`, ON UPDATE expressions, temporal ALTER operations or repeated-hour keys.

**Investigation, B3/B4:** compare grid saves with the native mysql client on servers using UTC, fixed offset and named DST zones. Test TIMESTAMP and DATETIME defaults, constant defaults restated by ALTER, both repeated-hour instants, and unchanged sibling rows. Decide whether workspace writes should use the server zone before adopting any session mutation. Strict-mode changes also need an explicit compatibility decision.

### 6.5 Paging: extend the existing implementation

Upstream [paging source](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/crates/core/src/browse/read_page.rs) supports forward/backward anchors, last-page navigation and PostgreSQL heap-block windows for suitable keyless tables. Its real-engine paging tests read forward and backward across tables with gaps and inspect query plans.

BookiE already has primary-key seeking after a deep-offset threshold. Its browse service deliberately falls back to OFFSET for explicit sorts and keyless tables, and the UI clears the cursor on Previous because reverse keyset navigation is not implemented. Claiming BookiE lacks keyset paging would be wrong.

**Useful extension:** reverse navigation and plan-based acceptance under existing PERF work. Start with stable primary keys. Heap-window paging is a separate engine-specific design, because physical identifiers change, partitions need disambiguation, and separate pages are not one snapshot. Do not use this as justification to loosen BookiE's keyless-edit refusal.

### 6.6 Streaming exports: useful capability, stronger acceptance needed

Upstream streams export rows through an awaited sink in batches of 256, and explicitly describes editor Export All as rerunning a statement on a separate read-only connection without the original tab's USE/SET state. That makes the changed execution context visible. It is a useful model for backpressure and progress.

BookiE currently refuses full-table export pending ADR 0014 snapshot acceptance. Upstream's existence of `stream_read` does not satisfy that ADR. Isolation, engine storage behavior, multiple results, session-local state, masking, audit, cancellation and publication all need evidence.

Its [file writer](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/crates/app/src/ui/export/replace_file_writer/mod.rs) also demonstrates a useful filesystem distinction: GIO temporary replacement protects some existing regular files, while symlinks, hard links and some directories may take a truncation path. It reports Removed, Untouched or Incomplete and claims destinations within the process.

**Recommended acceptance:** slow sink/backpressure, large cells, cancellation and disk-full, empty results, duplicate labels, snapshot consistency under concurrent writes, and destination/symlink/hardlink identity. Treat buffer row counts and aggregate byte budgets separately.

### 6.7 One conformance suite across engines

Upstream's test-support crate emits connection, DDL and TLS suites through engine adapters. Capability consistency checks prevent some adapters from silently disabling tests for advertised behavior. It has fault fakes for deterministic lifecycle tests, alongside real servers.

BookiE already has TLS fixtures, shared driver helpers, guardrails and test mapping. The opportunity is a reusable behavioral suite for common operations, not replacing the current tiers or duplicating all existing cases. Add engine exceptions explicitly, with reasons and coverage of the exception.

**First common matrix:** non-NULL undecodable data, row-limit boundaries, cancellation acknowledgement, subsequent connection reuse, row guards, loss during commit and capability/refusal agreement. For BookiE, run the relevant cases through both raw driver contracts and the governed consumer path.

### 6.8 GTK lifecycle and responsive behavior

Upstream makes workspace/session lifetime structural, uses GApplication activation rather than only a lock file, owns async work through one app runtime, and holds the process while durable work finishes. Close, quit, logout, drafts, save/export completion and restoration all have explicit owners.

Its lazy restore waits until a tab remains mapped past the main-loop turn, avoiding a briefly selected first tab starting unnecessary reads. Its responsive workspace and pager use native breakpoints and overflow actions. Its accelerator table ties bindings to action owners and the shortcut dialog.

BookiE already has request generations, deferred restore and active UI work. The transferable cases are: transient mapping does not fetch; close during connect disposes the result; quit cancelled halfway preserves remaining windows; pending durable saves keep the process alive; hidden controls hand focus onward; resize stays narrow after totals change. Reconcile existing UX PRs and #1026 before changing these files.

The upstream framework rewrite has costs: two UI patterns remain, substantial churn landed recently, and manual desktop acceptance remains open. Evaluate a small lifecycle boundary in BookiE before considering a new ADR on UI architecture.

## 7. Practices and behaviors to reject or adapt carefully

| Upstream observation | Why BookiE should treat it carefully |
|---|---|
| SQL INSERT export substitutes `/* ... omitted */ NULL` when a literal cannot be represented | This creates executable SQL containing a different value. Preserve BookiE's explicit refusal/exact-value contract. The upstream streaming encoder separately refuses Undecodable values; the broader literal fallback still exists. |
| PostgreSQL editor results are all text | Useful compatibility tradeoff for upstream, but a regression if BookiE loses native result metadata or downstream type behavior without an approved design. |
| Read-only wrapper or rollback around generated work | Does not replace policy classification, approval, masking or durable terminal audit. |
| Automatic replay of metadata/page/count after a newer link appears | Limited to workspace reads upstream. Do not extend this into BookiE's dedicated SQL sessions or snapshot cursors. |
| Crash report includes raw panic payload plus backtrace | Local-only private reports are useful UX, but BookiE deliberately withholds panic messages. A diagnostic feature must preserve secret/value redaction and bounded retention. |
| GNOME 50 floor and newer Ubuntu/Fedora packaging | A clear target, but it does not establish acceptance for BookiE's Arch/Hyprland target or justify dropping a supported floor. |
| Large batch remediation and a green aggregate suite | Useful progress evidence; excluded tests and unrun manual criteria still count as gaps. |
| Paid Mac capabilities and runtime plugin infrastructure | Product choices in the Apple app. BookiE's no-entitlement and static-driver ADRs remain authoritative. No new Linux payment gate was established by this audit. |

Source for the SQL export behavior: [core/export/sql.rs](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/crates/core/src/export/sql.rs). Source for crash payload handling: [crash_report.rs](https://github.com/TableProApp/TablePro/blob/0ab322ea1d7576cfd858ab5946edb9e84cba9e5b/linux/crates/app/src/crash_report.rs).

## 8. Product direction and competitive implications

Upstream's advantage is becoming a recognizable native multi-platform product with an established Apple audience, a broad feature surface on Apple, and Linux now integrated into normal development. The main-branch gate and package work make it more likely that Linux gets continuing attention. That is an inference from shipped repository changes and the maintainer's announcement, not a guarantee of maintenance.

BookiE's credible distinction is its Linux operational workflow and the shared governed path for a person and an agent. PolicyGuard, audit durability, masking, scopes, allowlists, uncertain-write handling and headless operation must be correct in daily use for that distinction to matter. More engines and safety-related type names do not prove it.

Upstream Linux already offers server notices and explicit streaming export flows that BookiE documents as missing or unavailable. Those are real capability differences worth learning from. BookiE has broader engine support and governed headless access absent from the inspected Linux composition. Neither observation proves an overall quality winner.

BookiE should continue the approved 0.2 development-release sequence. The immediate product risk is allowing comparison-driven expansion to delay usable, reliable Arch/Hyprland delivery. The technical risk is ignoring specific upstream reproductions because the fork already has more extensive safety machinery.

## 9. Proposed follow-up packets

These are recommendations to reconcile against the live board, not newly assigned work or release blockers. No issues, comments or messages were posted.

| Order | Packet | Owner | Concrete outcome and gate |
|---|---|---|---|
| 1 | PgBouncer cancellation and backend identity | B3 with B4 | Reproduce with concurrent clients and a tiny pool; prove only intended work stops and following work is clean. Driver tier plus governed/audit cases. |
| 2 | MySQL server-zone defaults and strict saves | B3 with B4 | Native-client oracle for defaults, DST key identity, ALTER and cleanup failures. Driver tier; no mode change without compatibility decision. |
| 3 | Cancellation/write-phase conformance | B4 and drivers | One state matrix across dispatch, stop, commit and resource reuse, with native stored outcomes. Unit/fault tests plus driver tier. |
| 4 | Reverse paging and query-plan evidence | B3/UX | Extend existing keyset work; page both ways with stable identities and filters. Driver plans plus installed navigation. |
| 5 | NOTICE/PRINT result events | Existing UI-20/#550 owners | Bounded ordered messages tied to the originating run; no late cross-tab updates or focus theft. Backend first, then GTK. |
| 6 | Lazy restore, quit and responsive transitions | UX | Reconcile existing implementations; fetch only intended tabs, preserve drafts/holds, keep keyboard actions visible. Widget and installed Arch/Hyprland evidence. |
| 7 | Full export design | ADR 0014 owners | One consistent governed read, backpressure, byte bounds and safe publication. Separate later feature; no early removal of refusal. |
| 8 | Sanitized local diagnostics | UX/B4 | Build/profile/library context, private bounded storage, no raw panic SQL/secret data. Existing incident workflow first. |

Every selected packet should name the existing issue, pin the baseline, produce one failing-before case, state native expected values or server state, and name the existing test tier. Cross-lane handoffs must be recorded before implementation. Forgejo remains BookiE's merge acceptance gate; upstream GitHub success cannot replace it.

## 10. Monitoring without duplicating the roadmap

Review meaningful upstream Linux changes weekly and before BookiE release qualification. Watch `linux/crates/core`, drivers, session, storage, app and Linux workflows, plus new `linux-v*` releases and the support discussion. Review Apple changes when they contain a portable user failure or protocol lesson.

For each candidate record only: upstream pin, user case, BookiE existing coverage, missing case, owner and decision to test/adapt/defer/reject. Keep active tasks on Project #3. Keep dated comparison evidence in the archive rather than growing another active backlog.

## 11. Remaining uncertainty

- No runtime, database, benchmark, screenshot, accessibility or desktop acceptance was performed by this audit.
- No exhaustive review of every file in the 369-commit merge was attempted. The source paths listed above define the review boundary.
- Root README statements about AI, MCP, plugins and paid Mac features were checked as product positioning; the full Swift security implementation was not audited.
- The first release page is not an exhaustive historical release search. The pinned Linux README and roadmap independently state that no Linux tag/release exists; tag creation after this snapshot is outside the finding.
- Package secrets, Launchpad/COPR service readiness, and a future release date are not proven.
- GitHub CI status is scoped to the recorded heads and capture time. BookiE release readiness was not reassessed by running its gates.
- Shared history and public awareness cannot establish copying or a causal relationship between later architectural decisions.

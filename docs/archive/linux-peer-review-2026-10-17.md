# Linux peer review: source and issue refresh

Reviewed 2026-10-17 at 04:20 UTC. This is a bounded source and public-tracker review, not a runtime audit or release gate. It refreshes the October 16 peer review and feature comparison; it does not change the 0.2.0 scope.

Follow-up checked at 12:00 UTC against current GitHub refs. BookiE Linux is `fe310a20763b1025c325b33e993c58358b020420`; TablePro Linux remains `6fd0d19326c2aa7404215972e9b0bb53948f9542`, TablePro main `2be4682f3faf924237225f7662174b8a26e36216`, dbx main `ab921297529deb9a996ebf43622340916f2a84a4`, DBeaver `devel` `61c9529849c9fa500c303d1a385897a4088d6656`, and Beekeeper `master` `f7ff968f39699c22d4f9a4674f38a5ecfbfbe586`. Latest checked releases remain TablePro 0.81.0, dbx 0.6.46, DBeaver 26.2.2 and Beekeeper 6.1.6. Since the prior BookiE pin, #1057 and #1040 merged; since the prior dbx pin, its only code change is Mycat proxy database/table listing. No competitor builds or runtime tests were performed.

## Pins and method

| Project | Ref checked | Release checked |
|---|---|---|
| BookiE | `linux` `6ab7d79e1e43facb3f931fffc99d7148c3ea69c4` | Development branch |
| TablePro | `linux` `7cd300f82eaa4743d18ab049bf40a374d3ecf927`; `main` `bdbcb7de95a267aab261e258fc6d5c745261848f` | Linux 1.7.0; macOS 0.81.0 |
| dbx | `main` `1065bf89ac8b7271388b5e513ac0971d2b179273` | v0.6.46 |
| DBeaver | `devel` `61c9529849c9fa500c303d1a385897a4088d6656` | Community 26.2.2 |
| Beekeeper Studio | `master` `f7ff968f39699c22d4f9a4674f38a5ecfbfbe586` | v6.1.6 |

GitHub compare results show two BookiE commits after `834e5b63e`: a documentation source refresh and #1006. They show two dbx commits after `35d06151f`: #12502 and #12512. TablePro, DBeaver and Beekeeper still match the preceding review pins. Read the two dbx merged PRs and their associated issues; checked BookiE's PostgreSQL error mapping and trigger catalog/UI paths. No competitor was built or run.

## New findings

### Duplicate result-column names must preserve column position during export

Beekeeper Studio [#4818](https://github.com/beekeeper-studio/beekeeper-studio/issues/4818) reported that TSV/Excel, JSON and Markdown clipboard exports kept only the last value when a query returned duplicate labels such as `SELECT 1 num, 2 num, 3 num`. The issue records a fix commit on October 1. This is a projection-result case, not a table-schema case: SQL expressions can legally share labels even when stored table columns cannot.

BookiE's CSV and TSV renderers walk each row by position, and JSON export creates distinct field names for repeated labels ([`json_field_names`](../../crates/core/src/export/json.rs)). The inspected implementation therefore does not show the same map-key overwrite path. Add one shared export regression matrix with duplicate labels for CSV, TSV, JSON and Markdown, asserting that every value survives in order. This is a regression-hardening candidate, not a confirmed BookiE bug; do not change output naming policy without a separate compatibility decision.

Source: [Beekeeper Studio #4818](https://github.com/beekeeper-studio/beekeeper-studio/issues/4818), [BookiE JSON field naming](../../crates/core/src/export/json.rs), [BookiE CSV rendering](../../crates/core/src/export/csv.rs), [BookiE TSV rendering](../../crates/core/src/export/csv.rs).

### Package installation failures need package-specific acceptance

DBeaver [#42129](https://github.com/dbeaver/dbeaver/issues/42129) reported a Community `.deb` startup crash on Ubuntu 26.04.1 while the tarball worked; the reporter confirmed that 26.2.2 fixed it on Debian 13/KDE/Wayland. The public issue establishes the packaging-path difference and the follow-up fix, but does not identify a root cause in its comments. Treat this as a release-process lesson: test the exact installed artifact on the target desktop and keep package, distro, display-server and app-start evidence together. BookiE's installed GTK and distro-floor gates already provide that structure; this report does not establish a missing BookiE check.

Source: [DBeaver #42129](https://github.com/dbeaver/dbeaver/issues/42129).

### Preserve useful connection diagnostics without leaking secrets

dbx [#12502](https://github.com/t8y2/dbx/pull/12502), related to [#12282](https://github.com/t8y2/dbx/issues/12282), reproduces a PostgreSQL socket reset after Bind/Execute using a local TCP proxy. The driver error's display text omitted the underlying OS I/O cause, so the PR logs the source chain. The test compares the diagnostic before and after the reset while a direct connection remains successful.

BookiE's PostgreSQL driver maps connection-refused errors distinctly and certificate errors to TLS, but other SQLx I/O errors become the generic `Disconnected` outcome. That is safe for the operation contract but gives little support evidence. Treat this as a diagnostics improvement prompt, not a confirmed data-path defect: preserve the generic user outcome while considering a bounded, redacted tracing field for the underlying error kind. Do not log connection strings, endpoint identity, SQL parameters or secrets. An adapter-level fault-injection test should prove the useful cause survives mapping and that sensitive fields do not.

Source: [dbx #12502](https://github.com/t8y2/dbx/pull/12502), [BookiE PostgreSQL error mapping](https://github.com/cozyGarage/BookiE/blob/6ab7d79e1e43facb3f931fffc99d7148c3ea69c4/crates/drivers/postgres/src/lib.rs#L1012-L1068).

### Catalog performance fixes should be matched to the query shape

dbx [issue #12393](https://github.com/t8y2/dbx/issues/12393) reported a roughly 40-second column load; merged [#12513](https://github.com/t8y2/dbx/pull/12513) removes an `information_schema.columns` join used only to determine nullability. BookiE's PostgreSQL `fetch_columns` already reads `pg_catalog.pg_attribute` and filters by schema and table, so that exact join is not present here. This does not close BookiE [#580](https://github.com/cozyGarage/BookiE/issues/580): profile the sidebar/catalog queries under many schemas and restricted roles before changing them, and keep table-structure load time as a separate measurement.

Source: [dbx #12513](https://github.com/t8y2/dbx/pull/12513), [BookiE PostgreSQL column query](https://github.com/cozyGarage/BookiE/blob/6ab7d79e1e43facb3f931fffc99d7148c3ea69c4/crates/drivers/postgres/src/lib.rs#L237-L320).

### Trigger state changes need dialect and scope contracts

dbx [#12512](https://github.com/t8y2/dbx/pull/12512) fixes an unreachable SQL Server structure-editor control and adds tree actions. Its SQL builder distinguishes table- and database-scoped SQL Server operations, PostgreSQL-family table operations and Oracle-style trigger operations. It returns no statement for unsupported combinations and tests quoting/escaping, context-menu dispatch and editor visibility. The linked user report is [#12254](https://github.com/t8y2/dbx/issues/12254).

BookiE can list trigger catalog objects, but the reviewed GTK app has no enable/disable action. This is a possible later feature, not a 0.2.0 commitment or an open issue. If selected, start with an explicit driver capability and narrow table-level operation; require PolicyGuard and audit for the DDL, verify permissions and refresh state only after success. Database-wide toggles need separate blast-radius treatment. Tests should exercise real generated SQL and identifier boundaries per engine.

Source: [dbx trigger SQL builder and tests](https://github.com/t8y2/dbx/pull/12512), [BookiE trigger catalog contract](https://github.com/cozyGarage/BookiE/blob/6ab7d79e1e43facb3f931fffc99d7148c3ea69c4/crates/core/src/catalog.rs#L1-L32).

## Existing work and tracking refresh

- BookiE #1006 keeps MySQL `TINYINT(1)` values other than 0 and 1 as integers. Preserve its stored-type regression when changing Boolean-like metadata handling.
- The October 17 comments on the open UX PRs and the focused #996, #1020 and #1046 threads introduced no new human-authored blocker. Recent additions were automated SonarCloud status comments. #1020 is merged; its Redis value-refetch allow case and database-switch denial matrix remain documented in [upstream-sync](../upstream-sync.md#2026-10-17-pr-discussion-and-competitor-follow-up). #1046 is merged. #996 remains open.
- The live [peer-review tracker #1026](https://github.com/cozyGarage/BookiE/issues/1026) now marks #1028 complete and closed by merged #1037. #1029, #1030, #1031, #1032, #1033 and #1034 remain open in their recorded lanes; #1054 and #1056 are separate open follow-ups. Check the project before selecting work.
- Thirteen UX-owned PR branches were synced to Linux `6ab7d79e1`; merge-only comments record each exact head and GitHub check snapshot. No failures were present at the refresh; some inexpensive jobs remained in progress. Forgejo/native acceptance remains separate and was not run in this review.

The longer October 16 source review remains at [linux-peer-review-2026-10-16.md](linux-peer-review-2026-10-16.md). The comparison table is maintained in [0.2-feature-comparison.md](../0.2-feature-comparison.md); open work and order remain on Project #3 and the active sprint.

## 2026-10-17 12:00 UTC: current issue and PR follow-up

Beekeeper Studio [#4818](https://github.com/beekeeper-studio/beekeeper-studio/issues/4818) reports that clipboard export loses all but the last value when result columns have duplicate labels. BookiE's CSV/TSV and Markdown writers traverse cells by index, and JSON export creates collision-free field names in `json_field_names`; this source inspection does not show the same overwrite path. Keep [#1073](https://github.com/cozyGarage/BookiE/issues/1073) as regression coverage across formats and assert every value and its order. Do not change the established JSON naming policy without a compatibility decision.

DBeaver [#40884](https://github.com/dbeaver/dbeaver/issues/40884) documents a PostgreSQL catalog query that loads millions of relation rows and grows both server and client memory. It reinforces the existing Bookie [#580](https://github.com/cozyGarage/BookiE/issues/580) scope-filter and catalog-performance work; it does not justify replacing the query without profiling Bookie's own sidebar paths. DBeaver [#42129](https://github.com/dbeaver/dbeaver/issues/42129) also records a `.deb` startup failure on Ubuntu while the tarball worked, later confirmed fixed. Bookie's installed-package acceptance remains the right evidence boundary; the competitor report does not identify a transferable root cause.

dbx [#11013](https://github.com/t8y2/dbx/pull/11013) implements OpenSSH `ProxyCommand` support through a helper process and an explicit executable allowlist, without invoking a shell. This is a useful security boundary for any future proxy-command support. Bookie has explicit `russh` and system OpenSSH connection paths and does not import arbitrary `ProxyCommand` configuration; this is a deliberate boundary pending a product issue and threat review, not a missing implementation to copy. Existing [#970](https://github.com/cozyGarage/BookiE/issues/970) remains the specific jump-host host-key-policy issue.

dbx [#10374](https://github.com/t8y2/dbx/issues/10374) originally attributed editor stalls to synchronous debug-log persistence and batched writes in #10375. The report was later corrected: the user's debugging log was disabled and empty while the stall persisted, so the shipped fix was not the root cause of that observed editor lag. This is a useful investigation lesson: validate the suspected path is active in the exact reproducer, and keep correlation, a fixed adjacent defect, and the user's reported cause separate. Bookie has no equivalent browser `localStorage` path.

Beekeeper [#4861](https://github.com/beekeeper-studio/beekeeper-studio/issues/4861) reports leading comments being stripped before SQL Server `CREATE PROCEDURE`. Bookie's lexical span splitter retains source text around comments, but this scan did not run an installed SQL Server reproduction through the complete editor path. Treat it as a test prompt only; do not file a Bookie defect until the actual `ScriptPlan`/GO-batch path is exercised.

The PR discussion pass found no new human-authored review request; the new non-owner comments were automated SonarCloud results. Current GitHub Linux advanced to `fe310a207`; UX-owned open PR branches were updated to it, with checks restarting. PR #1074 still has a failed SonarCloud quality gate at its current synced head and needs that result resolved before it is review-ready. This review does not run or replace the Forgejo gate.

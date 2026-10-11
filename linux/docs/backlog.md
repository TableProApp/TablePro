# Backlog after 0.2.0

Rows here are real work that does not block 0.2.0. The ledger keeps the evidence;
this page keeps the order. Draft of 2026-10-11, for the maintainer.

## 0.2.x features

| Row | What | Notes |
|---|---|---|
| SNAP-2 to SNAP-4 | Database snapshots: PostgreSQL, SQL Server, then SQLite and DuckDB file copies | ADR 0015 / SNAP-1 accepted the feature for 0.2.x (not a 0.2.0 blocker); limit 5 snapshots per database |
| UI-1b | Edit SSH jump chains in the form | Storage, transport, bundle v2 and per-hop passphrase coverage merged in #490, #492, #494 and #528; GTK editing stays refused until its complete path passes |
| UI-19 | Foreign key picker and navigation, enum and set pickers, paste TSV, estimated counts | |
| UI-20 | Server output (NOTICE, PRINT) and a timing breakdown | with PERF-4 |
| UI-15b | Null display style preference | vim keys are already an opt-in preference |
| UI-17b, UI-18, UI-22, UI-23, UI-26 | Preview tabs, history as a panel, code folding and split panes, typed PostgreSQL activity console, editable SSH profiles | accepted for later; PostgreSQL catalog objects are already built (UI-23) |
| PKG-2 | Debian and GNOME desktop pass (UI-D1 to D4) | the packages keep building and passing the distro floor in CI; this is the desktop acceptance |
| PKG-4, PKG-8 | Flatpak Flathub submission and screenshots, and the file-access decision (`--filesystem=home` or portal only) | guest build/install/launch is proven; not part of 0.2.0; decide PKG-8 before PKG-4 |

## Performance

| Row | What |
|---|---|
| PERF-2, PERF-7, PERF-8 | Stream results instead of materialising up to three caps; progressive loading in the editor |
| PERF-3 | MongoDB browse on large collections | Deep unfiltered `_id` keyset seek landed in #493; filtered, sorted, keyless and installed/network acceptance remain |
| PERF-4 | Server time next to elapsed time |
| PERF-5, PERF-6 | Idle memory and binary size, accepted for now |

## Quality and tooling

| Row | What |
|---|---|
| TEST-2 | Broad mutation audit: policy, core, transport, SSH and storage are measured; remaining survivor triage stays open (see [TEST-32](oracle-review.md) and [reports](evidence/test-quality-2026-10-11/transport-mutants.md)) |
| AUD-11 consolidation | Finish the single AST walk for classification, masking and blast-radius planning | Behavioural S6/S7/S8 fixes are merged; shared analysis landed in #506. Structural consolidation follows 0.2.0; candidate acceptance of the fixes stays in the ledger |
| TEST-12 | MongoDB metadata sample consistency |
| UI-21, TEST-28 | Fake connection for the GTK tier, native Ubuntu AT-SPI menu reachability |
| TEST-30 | Remaining SonarCloud and CodeQL findings |
| AUD-5 | About 4,700 comment lines in `src/` to move into docs, file by file |
| DOC-3, DOC-5 | Orca and high contrast pass; value comparison with DBeaver and dbx |
| B4-9, B4-11, B4-17, B4-21 | Route and TLS acceptance evidence, failed-batch rollback on optional MySQL engines and package acceptance, native multi-hop trust flow, SQL Server Kerberos Windows AD interoperability and package acceptance |
| UI-13b | Consistent snapshot for a full export (ADR 0014) |

## Infrastructure

- Enable Hyper-Threading on two lab hosts, raise executor sizes, split runners by
  job class, then allow two gates to overlap.
- Stop committing the generated `docs/ignored-tests.md`. Every pull request that adds
  or moves an ignored test conflicts in it, and each conflict is resolved by
  regenerating the file. Generate it in CI and check its content there instead, or
  write it to a build output.
- Folder layout ([proposal](proposals/folder-restructure.md)): separate the platform-neutral crates from the Linux application,
  and test suites from code.

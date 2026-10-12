# Backlog after 0.2.0

Rows here are selected work that does not block 0.2.0. The ledger keeps the evidence; this page keeps the order. Draft of 2026-10-11, for the maintainer.

The [feature comparison](0.2-feature-comparison.md) holds the wider parity
candidate inventory. An item becomes backlog work only after selection; add an
owner, acceptance layer and GitHub issue when promoting it. Do not treat the
candidate inventory as a release commitment.

## 0.2.x features

| Row | What | Notes |
|---|---|---|
| SNAP-2 to SNAP-4 | Database snapshots: PostgreSQL, SQL Server, then SQLite and DuckDB file copies | ADR 0015 / SNAP-1 accepted the feature for 0.2.x (not a 0.2.0 blocker); limit 5 snapshots per database |
| UI-1b | Edit SSH jump chains in the form | Storage, transport, bundle v2 and per-hop passphrase coverage merged in #490, #492, #494 and #528; GTK editing stays refused until its complete path passes |
| UI-19 | Foreign key value picker, estimated counts | FK navigation, paste TSV and the ENUM and SET pickers (PostgreSQL, MySQL, MariaDB) landed |
| UI-20 | Server output (NOTICE, PRINT) and a timing breakdown | with PERF-4 |
| UI-36 | Selection statistics popover with count, min/max and copy for selected loaded rows | Existing sum/average stays exact for numeric values; [#625](https://github.com/cozyGarage/BookiE/issues/625) |
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
| AUD-11 consolidation | Finish the single AST walk for classification, masking and blast-radius planning | Behavioural fixes are closed on the current policy suite; shared analysis landed in #506. Structural consolidation follows 0.2.0 |
| TEST-12 | MongoDB metadata sample consistency |
| UI-21, TEST-28 | Fake connection for the GTK tier, native Ubuntu AT-SPI menu reachability |
| TEST-30 | Remaining SonarCloud and CodeQL findings |
| AUD-5 | About 4,700 comment lines in `src/` to move into docs, file by file |
| DOC-3, DOC-5 | Orca and high contrast pass; value comparison with DBeaver and dbx |
| B4-9, B4-11, B4-17, B4-21 | Route and TLS acceptance evidence, failed-batch rollback on optional MySQL engines and package acceptance, native multi-hop trust flow, SQL Server Kerberos Windows AD interoperability and package acceptance |
| UI-13b | Implement verified snapshot export paths (ADR 0014); unsupported full export is refused |

## Infrastructure

- Enable Hyper-Threading on two lab hosts, raise executor sizes, split runners by job class, then allow two gates to overlap.
- Folder layout: done on 2026-10-11 (`crates/`, `apps/linux/`, `tests/`; see [ARCHITECTURE](../ARCHITECTURE.md#repository-layout)). Moving every per-crate integration test out of its crate stays a separate, larger step if wanted.

## GitHub issues

Each backlog theme has an issue, created 2026-10-11 so the work can be picked up without reading the ledger first.

| Issue | Theme |
|---|---|
| [#547](https://github.com/cozyGarage/BookiE/issues/547) | Database snapshots (SNAP-2 to SNAP-4) |
| [#548](https://github.com/cozyGarage/BookiE/issues/548) | SSH jump chains and reusable profiles in the form (UI-1b, UI-26) |
| [#549](https://github.com/cozyGarage/BookiE/issues/549) | Foreign key value picker, estimated counts (UI-19); FK navigation, paste TSV and the ENUM and SET pickers are done |
| [#550](https://github.com/cozyGarage/BookiE/issues/550) | Server output and timing breakdown (UI-20, PERF-4) |
| [#552](https://github.com/cozyGarage/BookiE/issues/552) | Preview tabs, history panel, folding, split panes, activity console (UI-17b, 18, 22, 23, 26) |
| [#553](https://github.com/cozyGarage/BookiE/issues/553) | Consistent snapshot for full-table export (UI-13b) |
| [#554](https://github.com/cozyGarage/BookiE/issues/554) | Streamed results (PERF-2, 7, 8) |
| [#555](https://github.com/cozyGarage/BookiE/issues/555) | MongoDB browse on large collections (PERF-3) |
| [#556](https://github.com/cozyGarage/BookiE/issues/556) | Intermittent installed GTK suite (TEST-31) |
| [#557](https://github.com/cozyGarage/BookiE/issues/557) | Debian and Ubuntu desktop acceptance (PKG-2) |
| [#558](https://github.com/cozyGarage/BookiE/issues/558) | Flatpak (PKG-4, PKG-8) |
| [#559](https://github.com/cozyGarage/BookiE/issues/559) | Mutation triage (TEST-2) |
| [#560](https://github.com/cozyGarage/BookiE/issues/560) | Native Ubuntu AT-SPI and fake connection (TEST-28, UI-21) |
| [#561](https://github.com/cozyGarage/BookiE/issues/561) | Accessibility pass and value comparison (DOC-3, DOC-5) |
| [#562](https://github.com/cozyGarage/BookiE/issues/562) | SonarCloud and CodeQL findings (TEST-30) |
| [#563](https://github.com/cozyGarage/BookiE/issues/563) | Comment lines into docs (AUD-5) |
| [#564](https://github.com/cozyGarage/BookiE/issues/564) | Generated ignored-test inventory |
| [#565](https://github.com/cozyGarage/BookiE/issues/565) | Where per-crate integration tests live |
| [#566](https://github.com/cozyGarage/BookiE/issues/566) | B4 acceptance evidence (B4-9, 11, 17, 21) |
| [#567](https://github.com/cozyGarage/BookiE/issues/567) | MongoDB metadata sample consistency (TEST-12) |
| [#571](https://github.com/cozyGarage/BookiE/issues/571) | AUD-11 single-AST-walk consolidation |
| [#572](https://github.com/cozyGarage/BookiE/issues/572) | Clear NEEDS REVIEW on PRODUCT, personas and capability specs |
| [#573](https://github.com/cozyGarage/BookiE/issues/573) | Lab runners: Hyper-Threading, sizing, overlapping gates |
| [#574](https://github.com/cozyGarage/BookiE/issues/574) | PKG-1 Arch / Omarchy / Hyprland Wayland acceptance |
| [#575](https://github.com/cozyGarage/BookiE/issues/575) | TEST-6 manual verification checklist triage |
| [#579](https://github.com/cozyGarage/BookiE/issues/579) | MySQL/MariaDB Unix socket endpoint (Omarchy-relevant); implementation is in review, with installed-form acceptance remaining |
| [#580](https://github.com/cozyGarage/BookiE/issues/580) | Filter Schemas and PostgreSQL many-schema catalog performance |
| [#625](https://github.com/cozyGarage/BookiE/issues/625) | Selection statistics popover (UI-36) |

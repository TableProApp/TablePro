# BookiE 0.2 active sprint

Approved 2026-09-16. Delivery branch: `linux`; source version 0.1.6-dev (0.1.5 is released); target 0.2.0. Implementation is authorized; no 0.2 release is approved.


## 0.2.0 readiness: 2026-10-11

The maintainer's current delivery target is the Arch/Hyprland development release in [0.2.0 scope](0.2.0-scope.md). That page owns the blocker list. Broader engine matrices, Debian/GNOME desktop acceptance and Flatpak continue after 0.2.0 in the [backlog](backlog.md). Historical acceptance gaps below stay open without becoming additional release blockers.

No 0.2 release is approved. Before a frozen candidate SHA, these stay open (owner in brackets; details in the [ledger](known-issues.md)):

- B3 [B3]: the broader type, consumer and configuration matrix, PERF-10 memory reduction (the preview is display-only; full values are still held), PERF-3 MongoDB census, UI-19 (deferred), mutation triage, installed grid acceptance. TEST-29's fast and durable test-container paths are in PR #457. Published head `e0bb6ce` passes the MySQL and MongoDB jobs; Forgejo run 101 found two PostgreSQL driver test failures. PR #461 aligned the release expectation with fail-closed explain-plan masking for read-scoped agents. Run 127 re-proves the run-101 PostgreSQL driver fixes; the latest merged `linux` branch still needs its exact-head gate. Its separate `pg-release` failure is B4-owned. See the [B3 retest record](type-contract-strategy.md#retest-indicators).
- B4 [B4]: B4-12 scoped rollback acceptance is complete. Frozen-candidate and installed acceptance remains for the other transport rows; B4-11 optional engine/effect coverage, AUD-2 hosted/installed acceptance, AUD-9 exact-candidate masking acceptance, UI-1b (GTK editor after #490 storage groundwork), UI-13b, TEST-15, PERF-2 and PERF-8 remain. AUD-10 is done (#486); AUD-11 behavioural fixes are closed on the current policy suite and single-AST-walk consolidation is post-0.2.0 backlog work. #537/#538/#539 are merged. See the [B4 board](b4-task-board.md) and [ledger](known-issues.md) for exact status and evidence.
- Desktop acceptance [maintainer]: PKG-1 native Wayland on Arch, PKG-2 Debian/GNOME, PKG-4 Flathub submission and screenshots, PKG-8 the Flatpak file-access decision, TEST-6 the 107-item manual checklist.
- B7: a frozen SHA, the affected gates green on Forgejo at that SHA (the acceptance gate since 2026-10-08), installed checks on Arch and Debian, and the 30-attempt soak (Forgejo nightly `gtk-soak`).

## Current continuation

Merged `linux` baseline includes PRs #459–#461, #463, #475, #480, #482, #484,
#486, #490, #493, #497, #498, #501, #504, #506, #512 and #515: engine read-only
enforcement, order-independent script classification, fail-closed explain-plan masking, joined policy verdicts (AUD-11 step 3) with the S6/S7 unit pack (#484), DuckDB selected-file pinning (AUD-10, #486), typed grid quark keys (#482), per-hop SSH secret identities (UI-1b storage, #490), MongoDB deep browse seek (#493), CSV value-path change contracts (#497), MySQL invalid calendar mode coverage (#501), DuckDB extended temporal unit pins (#504), AUD-11 shared analysis (#506), the 0.2.0 scope drafts (#512), oracle Part A sample rows (#515), and the docs sprint/board cleanup tip (#498). AUD-11 behaviour is closed on the current policy suite; its single-AST-walk consolidation is post-0.2.0 backlog work. UI-1b GTK editor and acceptance remain. Case detail lives on the [B3 board](type-contract-strategy.md), [B4 board](b4-task-board.md), [value evidence index](value-contracts.md) and [ledger](known-issues.md). Dated PR-by-PR continuation notes are in [sprint history](archive/bookie-0.2-history.md#archived-from-active-sprint-on-2026-10-09-consolidation).

Order for 0.2.0: **B3/B4 correctness blockers → installed Arch/Omarchy/Hyprland Wayland → B7 qualification**. Debian/GNOME desktop acceptance follows in 0.2.x. Review may overlap reserved fixtures; a lane pass does not close a milestone. The tip is not release-qualified. Limitations that 0.2.0 accepts stay in [known limitations](known-limitations.md); fixes after 0.2.0 stay in the [backlog](backlog.md).

### Retest indicators (do not drop)

These failed or incomplete runs stay open until re-proven on a current SHA:

| Signal | Owner | Note |
| --- | --- | --- |
| Forgejo run 101: two PostgreSQL driver failures | B3 | Run 127 re-proves these fixes; the current `linux` head still needs its exact-head gate. See the [B3 retest record](type-contract-strategy.md#retest-indicators) |
| AUD-9 named outer alias and #461 plan behavior | B4 / AUD-9 | Outer-alias leak is fixed in #537 and has a dedicated native test; plan output remains redacted by #461. The frozen-candidate PostgreSQL release layer remains the acceptance gate |
| Forgejo run 88 GTK waits: `open_editor`, `audit_failure_denies` | UX | Cause unclassified; run 88 predates #451/#452 |
| TEST-28 native Ubuntu AT-SPI grid / Columns UI | UX | Container distro-floor passes; native job is the broken surface |
| TEST-31 intermittent Forgejo GTK / distro-floor timeouts | UX / lab | Executor capacity 3→2 on Debian hosts; next ten full runs decide; tip green alone is not enough |
| Build Linux on `c2f3f78b9`: Docker Hub `toomanyrequests` | lab | Auth wired (#476); treat as infra retest if anonymous pull returns |


Feature gaps against other clients are in [the feature comparison](0.2-feature-comparison.md); none is a 0.2 blocker unless the maintainer adds it.

## Technical decisions

| Topic | Canonical decision |
| --- | --- |
| Static drivers; Linux GTK stack; component ownership | ADRs [0001](decisions/0001-no-plugin-system.md), [0002](decisions/0002-rust-gtk4-libadwaita.md), [0003](decisions/0003-relm4-architecture.md) |
| Credentials; server cancellation; panic containment | ADRs [0004](decisions/0004-libsecret-secret-storage.md), [0005](decisions/0005-server-side-cancellation.md), [0006](decisions/0006-driver-panic-containment.md) |
| Shared type/value outcomes, metadata and proof | [ADR 0007](decisions/0007-type-and-value-preservation.md) |
| Live connection/session ownership, trust and uncertainty | [ADR 0008](decisions/0008-connection-and-session-ownership.md) |
| Durable identity, migration and rollback compatibility | [ADR 0009](decisions/0009-persistence-and-identity-compatibility.md) |
| Redis topology in 0.2.0 | One host/port endpoint; Sentinel and Cluster deferred ([known-issues ledger](known-issues.md#owners-and-handoff)) |

Plans and case evidence apply these decisions; they do not define another conversion, transport or persistence policy. Internal contracts update owning wrappers/consumers together. Engine expansion such as Oracle remains outside this existing-eight-driver stabilization scope.

## Current milestone status

| Milestone | Established scope | Remaining acceptance / owner |
| --- | --- | --- |
| A1–A4 | Prior correctness, drafts/planning, Jump to Column and BookiE branding implemented | Historical 0.1.x proof does not qualify 0.2; A5 installed candidate work folds into B7 |
| B1 platform/build | Rust 1.98, GNOME 50, SQLx/system SQLite, resources and dev profiles integrated | Installed Arch then Debian/GNOME qualification; full Flatpak qualification separate |
| B2 runtime/storage | Owned tasks/stores, migrations, GSettings mirrors and coalesced writers implemented | Installed upgrade/rollback and shutdown acceptance in B7 |
| B3 type/value contracts | Focused native and consumer cases are recorded across the existing engines. SQLite STRICT `ANY` computed `iif()` now has native storage-class and typed CSV coverage (#331); declared BOOLEAN/temporal decoding, BLOB-affinity runtime classes, malformed temporal text fallback, and enum-like NUMERIC-affinity grid/CSV parsing have focused tests (#333, #335, #359). PostgreSQL domain-over-enum metadata/query coverage now reaches 302 and 512 layers, including arrays (#338, #340, #342, #344); PostgreSQL, MySQL, Redis, ClickHouse and SQL Server have committed-write lost-ack contracts (#315, #345, #354, #355); MongoDB now covers a dropped post-commit update acknowledgement with a native row oracle and `system.profile` replay oracle (`a_committed_update_with_a_lost_ack_is_not_replayed_after_reconnect`). U2 identity-copy behavior is implemented and covered for PostgreSQL, SQL Server and MySQL policy; PostgreSQL enum parameter inference has restricted-role coverage, and PR #249 adds a keyed grid-edit case under shadowed transaction-local `search_path`. The broader engine/type/consumer/configuration matrix, mutation triage, remaining TEST-15 paths and installed grid acceptance remain open. | [Type/consumer board](type-contract-strategy.md), [B3 findings](archive/b3-review-2026-10-01.md), [value evidence index](value-contracts.md) |
| B4 transport/sessions | SSH audit, rollback-failure, Kerberos, GTK trust-flow, prompt-timeout, cross-engine DML regressions and B4-11 failed-batch INSERT/UPDATE/DELETE coverage (#337, #353) are merged. | [Current B4 board](b4-task-board.md): frozen-candidate and hosted/installed acceptance remains open for the listed rows; B4-11 broader engine/effect coverage, B4-21 Windows AD interoperability, and UI-1b chain editing remain. B4-12's scoped frozen-source rollback acceptance is complete; full-candidate and package qualification remain separate |
| B5 editor/files | Open/Save/Save As, changed-on-disk detection and file relinking implemented | Installed file-dialog/recovery/dirty-close flows |
| B6 PostgreSQL catalog | Guarded read-only catalog/types implemented | Restricted-role, stale-owner and installed catalog flows |
| B7 qualification | Open | Frozen SHA, affected automated gates, both installed desktop targets and retry-free soak; publication separate |

This table summarizes source/evidence ownership, not a fresh runtime pass. Consult each exact case/SHA; do not promote a whole type or engine from one test.

Detailed case outcomes and exact proofs are maintained by the [B3 board](type-contract-strategy.md), [value evidence index](value-contracts.md), and linked manifests. Historical test runs are consulted from the evidence/history records; they are not repeated in the active sprint.

## B3 work packets

Use [ADR 0007](decisions/0007-type-and-value-preservation.md) for the standard, [the board](type-contract-strategy.md) for remaining targets and [the evidence index](value-contracts.md) for proof lookup. Choose one bounded engine/type/consumer/configuration case; preserve existing fallbacks/refusals.

| Packet | Deliverable |
| --- | --- |
| B3-P1 coverage | Reconcile one remaining row against source/tests; return the smallest uncovered case and existing SHA/selector |
| B3-P2 native boundary | One decoder/calendar/array/type boundary with an independent native oracle and affected consumer proof |
| B3-P3 consumer parity | One format's value/type, NULL/empty, numeric, temporal, binary or nested round trip; destination survives refusal |
| B3-P4 grid/bind | One typed edit/binding path; native persisted kind/value, full row key and untouched siblings |
| B3-P5 delivery/SQL | One malformed-tail, zero-row, cap, multi-result or partial-stream case; identity/order/completeness and handle state |
| B3-P6 mutation | One relevant survivor/timeout group; independent assertions and scoped rerun; unavailable output stays unproven |


R1–R5/R7 have recorded fixes; R6 evidence portability and the remaining matrix stay open. U1 server-owned columns have native consumer coverage for metadata, grid editability, CSV import, Copy as SQL and SQL export replay (`value_contract_mssql_server_owned_columns_use_native_defaults_across_consumers`); the grid assertion is helper-level, while installed GTK interaction remains part of release acceptance. U2–U6 and older-release O1–O3 are mapped in [main review](archive/upstream-main-review-2026-10-03.md) and [older-release review](archive/upstream-older-releases-review-2026-10-03.md). Reuse these owners; do not create a second completion cache, exporter or type policy.

## Arch / Omarchy / Wayland UI packets

Use [manual acceptance](manual-verification-0.2-features.md) and [the platform guide](platforms.md#arch-and-omarchy-package). This is application work; no desktop/system configuration changes are requested by the sprint.

| Packet | Acceptance |
| --- | --- |
| UI-A1 connections/SSH | Driver defaults and saved values, narrow layout, focus/Enter/Escape, trust decline without writes |
| UI-A2 editor/session | Stop, Session, reconnect, every close/disconnect route, files/recovery; native database/audit postconditions |
| UI-A3 grid/export/catalog | Full cell values and typed edits, import/export, shortcuts, empty/error/denied states and stale/restricted-role catalog |
| UI-A4 installed candidate | Arch install/upgrade/rollback, aliases/resources/askpass/GSettings, profile isolation and recoverable durable data |

Record binary/package SHA and checksum, actual Wayland backend, desktop/library versions, scale/monitor setup and light/dark screenshots. Check keyboard, clipboard, popovers, resizing and scaling. Xvfb regressions do not qualify Wayland.

## After 0.2.0: GNOME on Debian Wayland

After UI-A1–A4 (Debian askpass packaging I1 is done), repeat the applicable installed workflows on GNOME/Wayland with libraries meeting ADR 0002. Record the actual Debian/library versions; do not assume stable Debian meets GNOME 50 requirements. UI-D1 proves package contents; UI-D2 repeats A1–A3; UI-D3 proves upgrade/rollback; UI-D4 resolves platform differences. Source changes require a new SHA and affected Arch reruns. This phase remains planned work under PKG-2; it is not a 0.2.0 prerequisite.

## Qualification and handoff

B7 for 0.2.0 requires a frozen clean SHA, affected automated gates, installed Arch/Hyprland checks, and **30 consecutive retry-free GTK attempts across at least six runs** at that SHA. Failed/blocked/not-run items stay open. No recipe, version bump, older package or green task grants release approval.

Use the [agent task template](validation-playbook.md#agent-task-template): one invariant/case, allowed files, exact baseline, selected layers and reserved build/ fixture resources. Return initial behavior, patch, selectors/results, report paths, source fingerprints, unresolved gaps and resulting SHA. Serialize shared Cargo/Docker work; preserve warm build reuse per [toolchains](platforms.md#rust-toolchain). Do not infer new passes from test-source inspection. Documentation packets use diff/link checks; runtime/package claims require their actual owning checks.

## History lookup

[Sprint history](archive/bookie-0.2-history.md) preserves original scope, dated progress, commit tables, build-cache measurements and rollback details. Read a relevant section only. New current work updates this sprint/owning board; new case results update the value ledger, with links here instead of copied logs/counts.

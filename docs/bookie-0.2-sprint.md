# BookiE 0.2 active sprint

Approved 2026-09-16. Delivery branch: `linux`; source version 0.1.6-dev (0.1.5 is released); target 0.2.0. Implementation is authorized; no 0.2 release is approved.


## 0.2.0 readiness (reviewed 2026-10-18 against `6e4edf5d0`)

The maintainer's current delivery target is the Arch/Hyprland development release in [0.2.0 scope](0.2.0-scope.md). That page owns the blocker list. Broader engine matrices, Debian/GNOME desktop acceptance and Flatpak continue after 0.2.0 in the [backlog](backlog.md). Historical acceptance gaps below stay open without becoming additional release blockers.

No 0.2 release is approved. The [0.2.0 scope](0.2.0-scope.md) is the sole source for blockers and their exit criteria. Current lane status is summarized below; Project #3 and the owning boards hold the active work.

## Current continuation

The merged baseline is the current `linux` branch. Use `git log` for landed changes and [Project #3](https://github.com/users/cozyGarage/projects/3) for open work; this sprint does not maintain a copied pull request count.

Order for 0.2.0: **B3/B4 correctness blockers → installed Arch/Omarchy/Hyprland Wayland → B7 qualification**. Debian/GNOME desktop acceptance follows in 0.2.x. Review may overlap reserved fixtures; a lane pass does not close a milestone. The tip is not release-qualified. Limitations that 0.2.0 accepts stay in [known limitations](known-limitations.md); fixes after 0.2.0 stay in the [backlog](backlog.md).

### Current acceptance signals

Historical run results remain in the archive. These environment-specific acceptance items are still open:

| Signal | Owner | Note |
| --- | --- | --- |
| TEST-28 native Ubuntu AT-SPI grid / Columns UI | UX | The Debian 13 and Ubuntu 24.04 containers expose and activate the grid menu (a menu-reachability scenario passes on both once it clicks the cell by its extents, [#646](https://github.com/cozyGarage/BookiE/pull/646)); the native Ubuntu host remains ([#560](https://github.com/cozyGarage/BookiE/issues/560)) |
| TEST-31 intermittent Forgejo GTK / distro-floor failures | UX / lab | The startup restore layout abort was fixed in [#821](https://github.com/cozyGarage/BookiE/pull/821). The issue remains open for intermittent failures and the required consecutive full-run evidence; inspect its latest updates before qualifying a candidate ([#556](https://github.com/cozyGarage/BookiE/issues/556)) |


Feature gaps against other clients are in [the feature comparison](0.2-feature-comparison.md); none is a 0.2 blocker unless the maintainer adds it.

## Technical decisions

| Topic | Canonical decision |
| --- | --- |
| Static drivers; Linux GTK stack; component ownership | ADRs [0001](decisions/0001-no-plugin-system.md), [0002](decisions/0002-rust-gtk4-libadwaita.md), [0003](decisions/0003-relm4-architecture.md) |
| Credentials; server cancellation; panic containment | ADRs [0004](decisions/0004-libsecret-secret-storage.md), [0005](decisions/0005-server-side-cancellation.md), [0006](decisions/0006-driver-panic-containment.md) |
| Shared type/value outcomes, metadata and proof | [ADR 0007](decisions/0007-type-and-value-preservation.md) |
| Live connection/session ownership, trust and uncertainty | [ADR 0008](decisions/0008-connection-and-session-ownership.md) |
| Durable identity, migration and rollback compatibility | [ADR 0009](decisions/0009-persistence-and-identity-compatibility.md) |
| Redis topology in 0.2.0 | One host/port endpoint; Sentinel and Cluster deferred ([ledger index](known-issues.md), [known limitations](known-limitations.md)) |

Plans and case evidence apply these decisions; they do not define another conversion, transport or persistence policy. Internal contracts update owning wrappers/consumers together. Engine expansion such as Oracle remains outside this existing-eight-driver stabilization scope.

## Current milestone status

| Milestone | Established scope | Remaining acceptance / owner |
| --- | --- | --- |
| A1–A4 | Prior correctness, drafts/planning, Jump to Column and BookiE branding implemented | Historical 0.1.x proof does not qualify 0.2; A5 installed candidate work folds into B7 |
| B1 platform/build | Rust 1.98, GNOME 50, SQLx/system SQLite, resources and dev profiles integrated | Installed Arch qualification for 0.2.0; Debian/GNOME and full Flatpak qualification are later work |
| B2 runtime/storage | Owned tasks/stores, migrations, GSettings mirrors and coalesced writers implemented | Installed upgrade/rollback and shutdown acceptance in B7 |
| B3 type/value contracts | Native and consumer coverage spans the supported engines. The broader engine/type/consumer/configuration matrix, mutation triage and installed grid acceptance remain open. | [Type/consumer board](type-contract-strategy.md) and [value evidence index](value-contracts.md) |
| B4 transport/sessions | Policy, transport, rollback and audit fixes are merged; the full B4 lane is not yet accepted. TEST-15 lost-ack acceptance remains open on the maintainer-designated candidate. | The [current B4 board](b4-task-board.md) and Project #3 own the remaining acceptance. B4-12's scoped rollback acceptance is complete; other rows still need their listed candidate or installed proof |
| B5 editor/files | Open/Save/Save As, changed-on-disk detection and file relinking implemented | Installed file-dialog/recovery/dirty-close flows |
| B6 PostgreSQL catalog | Guarded read-only catalog/types implemented | Restricted-role, stale-owner and installed catalog flows |
| B7 qualification | Open | Frozen SHA, affected automated gates, installed Arch/Hyprland checks and retry-free soak; publication separate |

This table summarizes source/evidence ownership, not a fresh runtime pass. Consult each exact case/SHA; do not promote a whole type or engine from one test.

The current `linux` tip includes the merged B4 changes for backup/restore cancellation (#1078), MySQL session statements (#1079), SSH jump-host key checks (#1081), unresolved-write rollback (#1106) and recovered rollback scope tests (#1109). These changes do not close the installed-package or frozen-candidate acceptance still listed in the scope and ledger.

### Crate readiness for the next round

This is a preparation list, not new 0.2.0 scope. The current workspace already has eight database-driver crates and established libraries for the supported engines. This first-pass source review found no concrete reason to add a dependency or another engine crate before the product gaps below are selected.

| Area | Current crate surface | Next review |
| --- | --- | --- |
| Headless application logic | `crates/app-services` alongside GTK-facing services in `apps/linux/app` | Continue the staged boundary work in APP-MOD under [ADR 0018](decisions/0018-headless-app-services-crate.md); identify which remaining logic is reusable and testable without GTK before moving it |
| SQL and command safety | `sqlparser` is used by `crates/policy` and several drivers; `crates/core` also owns script and dialect helpers | Reconcile the dialect lexer profiles in PEER-2 and the fail-closed Redis command table in PEER-3. Decide whether existing crate boundaries suffice before considering a parser or policy dependency |
| Driver clients | Eight static crates under `crates/drivers/`; SQLx backs PostgreSQL, MySQL/MariaDB and SQLite, with separate clients for the other engines | Review maintenance, Rust version support, license/advisory status, local patches, native build cost and contract gaps for each client. [Adding drivers](adding-drivers.md) records current maturity and libraries |
| Test infrastructure | Driver tests use testcontainers and per-crate integration targets | Measure fixture and executor cost against the CI feedback work in [#573](https://github.com/cozyGarage/BookiE/issues/573); prioritize missing independent oracles and scenarios over another test framework |
| Engine breadth | Redis Sentinel/Cluster are deferred; Oracle is outside the current eight-engine stabilization scope | Confirm a user and release requirement before proposing a driver crate or changing maturity; preserve the current scope until then |

For each promoted item, record the failing user case, owning crate and boundary, existing dependency behavior, test tier, and license/MSRV/advisory/build-cost findings. Use `cargo metadata --no-deps` for workspace boundaries, `cargo tree -e features` for selected dependency paths, and `cargo deny check` for license and advisory review. Keep candidates in the [backlog](backlog.md) until an owner and acceptance criterion are selected; do not add a dependency solely to create a cleaner abstraction.

Detailed case outcomes and exact proofs are maintained by [Project #3](https://github.com/users/cozyGarage/projects/3) (Lane B3), the [value evidence index](value-contracts.md), and linked manifests. Historical test runs are consulted from the evidence/history records; they are not repeated in the active sprint.

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
| UI-A1 connections/SSH | Driver defaults and saved values, narrow layout, focus/Enter/Escape, trust decline without writes, connection colour strip after connect/change/disconnect |
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

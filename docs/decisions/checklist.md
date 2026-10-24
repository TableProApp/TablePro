# Decision checklist

Which product and architecture forks BookiE has already answered, and where. Silence is not an answer: each applicable fork is a link, N/A, or an open item. No new decisions are invented here.

Last full review against the ADR index, code and living docs: 2026-10-20. The release-gate rows were refreshed on 2026-10-23 for the published 0.2.0 assets. An ADR-index cross-check on 2026-10-24 added missing entries for ADRs 0017 and 0018; other statuses were not re-audited. Each row points to its decision owner; open product and architecture decisions remain open until their named owners resolve them.

## Foundation

| Fork | Status | Where it lives |
| --- | --- | --- |
| Repo topology | Decided | Cargo workspace at the repository root (`crates/`, `apps/linux/`, `tests/`, `scripts/`, `docs/`). [ARCHITECTURE](../../ARCHITECTURE.md#repository-layout), [AGENTS](../../AGENTS.md). |
| Domain / module boundaries | Decided | Crates by capability (`core`, `policy`, `mcp`, `transport`, `ssh`, drivers). [ARCHITECTURE](../../ARCHITECTURE.md). Static drivers: [ADR 0001](0001-no-plugin-system.md). |
| Build graph and packaging inputs | Decided | One Cargo graph; Meson and Flatpak packaging consume the same crates. |
| Language & type strictness | Decided | Rust 1.98; Clippy denies `unwrap` / `expect` / `panic` on production paths. [AGENTS](../../AGENTS.md). |
| Working language | Decided | English. [AGENTS](../../AGENTS.md). |
| Dependency & supply-chain policy | Decided | License and advisory review through root `deny.toml`. [AGENTS](../../AGENTS.md). |

## Runtime and data

| Fork | Status | Where it lives |
| --- | --- | --- |
| Datastore & persistence model | Decided | Desktop client, not a hosted store. XDG files plus Secret Service. [ADR 0004](0004-libsecret-secret-storage.md), [ADR 0009](0009-persistence-and-identity-compatibility.md). |
| Schema evolution & migrations | Decided | Compatible adapters and recoverable migrations for saved state. [ADR 0009](0009-persistence-and-identity-compatibility.md). |
| Async, eventing & background jobs | Decided | Relm4 messages and component-scoped commands. No product job queue. [ADR 0003](0003-relm4-architecture.md). |
| Caching | N/A | No general application cache layer. Browse pages and SQL results remain owned by their tabs under separate bounds. |
| Numerical / semantic compatibility | Decided | Native type and value preservation. [ADR 0007](0007-type-and-value-preservation.md). |

## Interfaces and contracts

| Fork | Status | Where it lives |
| --- | --- | --- |
| API / contract style & versioning | Decided | No general-purpose REST API. MCP is the machine interface and supports stdio and streamable HTTP; existing `tablepro` protocol contracts stay on the rename boundary. [ARCHITECTURE](../../ARCHITECTURE.md). |
| Auth & authorization model | Decided | Secret Service stores desktop credentials; database permissions remain engine-controlled. MCP access composes token scopes, connection allowlists and `PolicyGuard` SQL policy. [ADR 0004](0004-libsecret-secret-storage.md), [ADR 0008](0008-connection-and-session-ownership.md), [ADR 0016](0016-governed-consumer-seam.md), [AGENTS](../../AGENTS.md). |
| Error & result modeling | Decided | Typed `thiserror` at crate boundaries. Panic containment: [ADR 0006](0006-driver-panic-containment.md). |
| Config & secrets management | Decided | Database and SSH credentials use Secret Service. GUI-issued MCP token plaintext is returned once and keyring storage is attempted; headless token issuance emits plaintext once to stdout or an explicitly selected owner-only file. Secrets never go in connection JSON, argv, traces, errors or audit fields. [ADR 0004](0004-libsecret-secret-storage.md), [AGENTS](../../AGENTS.md). |

## Quality and safety

| Fork | Status | Where it lives |
| --- | --- | --- |
| Testing strategy | Decided | Named tiers, one script and one gate each. [AGENTS](../../AGENTS.md), [validation playbook](../validation-playbook.md). |
| Observability | Decided | `tracing` fields. Workspace lints deny `print!`. No SQL parameters or secrets in logs. [AGENTS](../../AGENTS.md). |
| Security baseline | Partial | In-code invariants in AGENTS. Dedicated security-baseline ADR still open (see open forks). |
| Accessibility baseline | Undecided | GTK / libadwaita. No WCAG claim recorded. DOC-3 / maintainer in the [ledger](../known-issues.md). |
| UX review lens | Undecided | Folded with accessibility until a separate record is worth writing. |
| Design tokens & design-system handoff | N/A | Platform Adwaita theme. No token pipeline. |
| Performance & scaling budget | Partial | Caps and PERF-* rows live on the ledger and boards. Not a single budget ADR yet. |

## Delivery

| Fork | Status | Where it lives |
| --- | --- | --- |
| Branching & release strategy | Decided | Work on `linux`. Maintainer cuts releases. Changelog under `[Unreleased]` in root `CHANGELOG.md`. [AGENTS](../../AGENTS.md). |
| Integration method & history shape | Decided | Squash-merge on GitHub; Forgejo is the acceptance gate, not the merge target. [AGENTS](../../AGENTS.md#workflow). |
| CI/CD & environments | Decided | GitHub cheap tier; Forgejo merge tiers. [AGENTS](../../AGENTS.md), [validation playbook](../validation-playbook.md#ci-tiers). |
| Feature-flagging & rollout | Decided | No account, license or remote entitlement flags. [AGENTS](../../AGENTS.md), [PRODUCT.md](../../PRODUCT.md). |
| Changelog & release notes | Decided | Keep a Changelog 1.1.0 in root `CHANGELOG.md`. [AGENTS](../../AGENTS.md). |
| Externally-owned release gate | Undecided | 0.2.0 includes a published GNOME 50 Flatpak bundle, but no Flathub listing. Flathub submission remains backlog work (PKG-4/PKG-8); no external distribution review is adopted as a release gate. |
| Native library floors | Decided | One floor: GTK 4.24, libadwaita 1.10, GtkSourceView 5.22. [ADR 0021](0021-toolkit-floor.md), [platforms](../platforms.md). |

## Product

| Fork | Status | Where it lives |
| --- | --- | --- |
| Target users and workflows | Recorded | [Product overview](../../PRODUCT.md) and [user contexts](../personas.md). |
| Pricing / monetization | Decided in PRODUCT | Free, no account. [PRODUCT.md](../../PRODUCT.md). Promote to a separate BDR only if the wording must bind apart from PRODUCT. |
| Data retention & compliance | Undecided | No retention period recorded. Do not invent one here. |
| SLAs & support | N/A | Desktop client. No uptime SLA. |
| Vendor / platform lock-in | Decided | GTK / libadwaita and Secret Service are accepted costs. [ADR 0002](0002-rust-gtk4-libadwaita.md), [ADR 0004](0004-libsecret-secret-storage.md). |
| Positioning & messaging | Partial | Free / no-account and Linux-native bet live in PRODUCT; market one-liner not separately recorded. |
| Product outcome measures | Defined | Product outcomes are acceptance statements; the application has no telemetry or KPI collection system. [PRODUCT.md](../../PRODUCT.md). |
| Analytics tracking plan | N/A | No product telemetry pipeline. |
| Flathub as primary distribution | N/A | Flathub is not selected as the primary channel; the artifacts recorded in [platforms](../platforms.md) are from GitHub Releases. Verify the release page for current publication status. |

## Feature decisions already recorded

| Topic | Record |
| --- | --- |
| Aggregate Forgejo acceptance and merge trains | [ADR 0020](0020-aggregate-forgejo-trains.md) |
| Secret Service credentials | [ADR 0004](0004-libsecret-secret-storage.md), [secret-storage spec](../../specs/secret-storage/spec.md) (draft) |
| Governed consumer seam (`PolicyGuard`) | [ADR 0016](0016-governed-consumer-seam.md), [governed SQL spec](../../specs/governed-sql/spec.md) (draft) |
| Server-side cancellation | [ADR 0005](0005-server-side-cancellation.md) |
| Cursor-paged editor results | [ADR 0011](0011-paged-query-results.md) (accepted; PostgreSQL editor support has landed; broader memory acceptance remains open under #554) |
| Sidebar object tree | [ADR 0012](0012-sidebar-object-tree.md) |
| Multiple result sets | [ADR 0013](0013-multiple-query-result-sets.md) |
| Full-table export read snapshot | [ADR 0014](0014-full-table-export-snapshot.md) (not the same as ADR 0015) |
| Database clone / restore snapshots | [ADR 0015](0015-database-snapshots.md) (accepted design; implementation is post-0.2.0 backlog work, with no release target) |
| Bundle admin audit | [ADR 0010](0010-administrative-action-audit.md) |
| Official Rust MCP SDK behind the governed seam | [ADR 0017](0017-mcp-sdk-behind-the-governed-seam.md) (accepted direction; production remains hand-written, with an optional stdio prototype) |
| Headless application-services crate | [ADR 0018](0018-headless-app-services-crate.md) (accepted; staged module moves continue under APP-MOD) |
| File conversion, schema migrations, logical backup | [ADR 0019](0019-database-tooling-without-sidecars.md) (accepted design; implementation status varies by tool, with remaining work post-0.2.0) |

## Open forks (do not invent answers here)

| Fork | Who unblocks | Next step |
| --- | --- | --- |
| SSH and capability specs | Architect | Review [specs/](../../specs/README.md); when a spec and the code disagree, fix the spec. The `PolicyGuard` decision is [ADR 0016](0016-governed-consumer-seam.md); the governed SQL spec is still a draft |
| Security baseline ADR | Architect | Extract from AGENTS security invariants only if a contestable choice remains |
| Accessibility / WCAG claim | Maintainer | Ledger DOC-3; do not claim AA from Adwaita alone |
| Data retention | Product | Leave open until legal or product answers |
| Performance budget ADR | Architect | Optional; PERF-* ledger rows may stay sufficient |
| Flathub / distro as external release gate | Architect / packaging | Decide whether external review is a release gate before planning a Flathub or distro submission. The published 0.2.0 includes a GNOME 50 Flatpak bundle but has no Flathub listing. |

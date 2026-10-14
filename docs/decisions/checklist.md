# Decision checklist

Which product and architecture forks BookiE has already answered, and where. Silence is not an answer: each applicable fork is a link, N/A, or an open item. No new decisions are invented here.

Reviewed against the current ADR index, code and living docs on 2026-10-14. The menu shape follows the [repository-standards decision checklist](https://repositorystandards.com/docs/checklist.html); living records stay in this directory and in [AGENTS.md](../../AGENTS.md). Open product and architecture decisions remain open until their named owners resolve them.

## Foundation

| Fork | Status | Where it lives |
| --- | --- | --- |
| Repo topology | Decided | Cargo workspace at the repository root (`crates/`, `apps/linux/`, `tests/`, `scripts/`, `docs/`). [ARCHITECTURE](../../ARCHITECTURE.md#repository-layout), [AGENTS](../../AGENTS.md). |
| Domain / module boundaries | Decided | Crates by capability (`core`, `policy`, `mcp`, `transport`, `ssh`, drivers). [ARCHITECTURE](../../ARCHITECTURE.md). Static drivers: [ADR 0001](0001-no-plugin-system.md). |
| Two authored descriptions of one structure | Decided | One Cargo graph. Packaging Meson/Flatpak consume the same crates. |
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
| API / contract style & versioning | Decided | No public HTTP product API. MCP tools; `tablepro` protocol contracts stay on the rename boundary. [ARCHITECTURE](../../ARCHITECTURE.md). |
| Auth & authorization model | Decided | Desktop: Secret Service. MCP: token scopes, connection allowlists, then `PolicyGuard`. [ADR 0004](0004-libsecret-secret-storage.md), [ADR 0008](0008-connection-and-session-ownership.md), [ADR 0016](0016-governed-consumer-seam.md), [AGENTS](../../AGENTS.md). |
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
| Externally-owned release gate | Undecided | Flathub and distro review exist as packaging work (PKG-4) but the fork is unrecorded as a gate. Flatpak is left out of 0.2.0 ([PRODUCT.md](../../PRODUCT.md)). |
| Native library floors | Decided | Build/CI floor vs GNOME 50 package line. [ADR 0002](0002-rust-gtk4-libadwaita.md), [platforms](../platforms.md). |

## Product

| Fork | Status | Where it lives |
| --- | --- | --- |
| Target personas | Draft | [docs/personas.md](../personas.md) (`NEEDS REVIEW`). |
| Pricing / monetization | Decided in PRODUCT | Free, no account. [PRODUCT.md](../../PRODUCT.md). Promote to a separate BDR only if the wording must bind apart from PRODUCT. |
| Data retention & compliance | Undecided | No retention period recorded. Do not invent one here. |
| SLAs & support | N/A | Desktop client. No uptime SLA. |
| Vendor / platform lock-in | Decided | GTK / libadwaita and Secret Service are accepted costs. [ADR 0002](0002-rust-gtk4-libadwaita.md), [ADR 0004](0004-libsecret-secret-storage.md). |
| Positioning & messaging | Partial | Free / no-account and Linux-native bet live in PRODUCT; market one-liner not separately recorded. |
| North Star & KPI tree | Draft | [PRODUCT.md](../../PRODUCT.md) (`NEEDS REVIEW`). |
| Analytics tracking plan | N/A | No product telemetry pipeline. |
| Multi-tenant SaaS auth | N/A | Not a hosted multi-tenant service. |
| Node API versioning | N/A | No Node application stack. |
| Flathub as primary distribution | N/A | Packages are GitHub releases today. |

## Feature decisions already recorded

| Topic | Record |
| --- | --- |
| Secret Service credentials | [ADR 0004](0004-libsecret-secret-storage.md), [secret-storage spec](../../specs/secret-storage/spec.md) (draft) |
| Governed consumer seam (`PolicyGuard`) | [ADR 0016](0016-governed-consumer-seam.md), [governed SQL spec](../../specs/governed-sql/spec.md) (draft) |
| Server-side cancellation | [ADR 0005](0005-server-side-cancellation.md) |
| Cursor-paged editor results | [ADR 0011](0011-paged-query-results.md) (accepted; core/PostgreSQL/PolicyGuard support exists, editor integration remains) |
| Sidebar object tree | [ADR 0012](0012-sidebar-object-tree.md) |
| Multiple result sets | [ADR 0013](0013-multiple-query-result-sets.md) |
| Full-table export read snapshot | [ADR 0014](0014-full-table-export-snapshot.md) (not the same as ADR 0015) |
| Database clone / restore snapshots | [ADR 0015](0015-database-snapshots.md) (accepted for 0.2.x after 0.2.0) |
| Bundle admin audit | [ADR 0010](0010-administrative-action-audit.md) |

## Open forks (do not invent answers here)

| Fork | Who unblocks | Next step |
| --- | --- | --- |
| PRODUCT / personas / North Star draft markers | Maintainer / product | Clear `NEEDS REVIEW` on [PRODUCT.md](../../PRODUCT.md) and [personas](../personas.md) |
| SSH and capability specs | Architect | Review [specs/](../../specs/README.md); when a spec and the code disagree, fix the spec. The `PolicyGuard` decision is [ADR 0016](0016-governed-consumer-seam.md); the governed SQL spec is still a draft |
| Security baseline ADR (R19-style axes) | Architect | Extract from AGENTS security invariants only if a contestable choice remains |
| Accessibility / WCAG claim | Maintainer | Ledger DOC-3; do not claim AA from Adwaita alone |
| Data retention | Product | Leave open until legal or product answers |
| Performance budget ADR | Architect | Optional; PERF-* ledger rows may stay sufficient |
| Flathub / distro as external release gate | Architect / packaging | Name the gate when PKG-4 moves; Flatpak out of 0.2.0 already |

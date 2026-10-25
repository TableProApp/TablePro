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
| Caching | Partial | No general application cache layer. Browse pages and SQL results remain owned by their tabs under separate bounds; streamed query page spooling is implemented on `ux/stream-result-spool`, with [ADR 0025](0025-transient-result-page-spool.md) proposed pending gates. |
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
| Branching & release strategy | Decided | Work on `linux`. Maintainer cuts releases. Release notes from commit trailers ([ADR 0022](0022-release-notes-from-merge-commits.md)). [AGENTS](../../AGENTS.md). |
| Integration method & history shape | Decided | Squash-merge on GitHub; Forgejo is the acceptance gate, not the merge target. [AGENTS](../../AGENTS.md#workflow). |
| CI/CD & environments | Decided | GitHub cheap tier; Forgejo merge tiers. [AGENTS](../../AGENTS.md), [validation playbook](../validation-playbook.md#ci-tiers). |
| Feature-flagging & rollout | Decided | No account, license or remote entitlement flags. [AGENTS](../../AGENTS.md), [PRODUCT.md](../../PRODUCT.md). |
| Changelog & release notes | Decided | `Release-Note:` trailers on squash commits, assembled at release. [ADR 0022](0022-release-notes-from-merge-commits.md). |
| Externally-owned release gate | Undecided | See the open fork below; distribution work remains in the [backlog](../backlog.md). |
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
| Cursor-paged editor results | [ADR 0011](0011-paged-query-results.md) (accepted) and [ADR 0025](0025-transient-result-page-spool.md) (proposed); same-execution navigation for fetched PostgreSQL pages landed in #1660. #1032 tracks broader resource and lifecycle acceptance. |
| Sidebar object tree | [ADR 0012](0012-sidebar-object-tree.md) |
| Multiple result sets | [ADR 0013](0013-multiple-query-result-sets.md) |
| Full-table export read snapshot | [ADR 0014](0014-full-table-export-snapshot.md) (not the same as ADR 0015) |
| Database clone / restore snapshots | [ADR 0015](0015-database-snapshots.md) (accepted design; implementation is post-0.2.0 backlog work, with no release target) |
| Bundle admin audit | [ADR 0010](0010-administrative-action-audit.md) |
| Official Rust MCP SDK behind the governed seam | [ADR 0017](0017-mcp-sdk-behind-the-governed-seam.md) (accepted direction; production remains hand-written, with an optional stdio prototype) |
| System OpenSSH askpass and transport boundaries | [ADR 0023](0023-system-openssh-transport-boundaries.md) |
| Stale grid edits and deletes | [ADR 0024](0024-keyed-grid-writes-check-what-they-overwrite.md) |
| Headless application-services crate | [ADR 0018](0018-headless-app-services-crate.md) (accepted; staged module moves continue under APP-MOD) |
| File conversion, schema migrations, logical backup | [ADR 0019](0019-database-tooling-without-sidecars.md) (accepted design; implementation status varies by tool, with remaining work post-0.2.0) |

## Declined or out-of-scope directions

Recorded so a contributor does not reopen them without new evidence. Each row cites where the choice was made; the ADR column, when present, carries the reasoning.

| Direction | Status | Record |
| --- | --- | --- |
| In-app AI client or chat | Out of scope | The governed MCP server is the agent interface ([ADR 0017](0017-mcp-sdk-behind-the-governed-seam.md), [ADR 0016](0016-governed-consumer-seam.md)); source: [feature comparison](../0.2-feature-comparison.md#explicitly-out-of-scope-unless-product-goals-change). |
| Upstream TablePro as a merge target | Declined | Upstream is a behaviour and fixture reference; upstream compatibility is not an acceptance criterion by itself. [upstream sync](../upstream-sync.md), [capability review](../capability-review.md). |
| Oracle, Cassandra and runtime-bridge engines | Out of scope | [ADR 0001](0001-no-plugin-system.md). |
| Importing dbx crates | Declined | [ADR 0018](0018-headless-app-services-crate.md). |
| Second SQL classifier, permissive fail-open classification, lifecycle scripting hooks | Declined | [ADR 0016](0016-governed-consumer-seam.md). |
| Connection-wide commit switch; automatic retry of failed statements | Declined | [ADR 0008](0008-connection-and-session-ownership.md). |
| `LIMIT`/`OFFSET` paging; unbounded page retention | Declined | [ADR 0011](0011-paged-query-results.md). |
| Keyless edits through `ctid` or another physical locator | Declined | Keyless-write refusal stays; source: [dbx follow-up](../archive/dbx-follow-up-2026-10-21.md). |
| Apple-only services, license-gated features, Sparkle or AppleScript, iCloud-synced icons | Out of scope | [PRODUCT.md](../../PRODUCT.md) for the no-license rule; the rest from [feature comparison](../0.2-feature-comparison.md#explicitly-out-of-scope-unless-product-goals-change). |
| dbx's cell and error model: cells as `serde_json::Value`, binary as `"0x…"` text, user WHERE or edits spliced into SQL, a regex production-safety unlock, passwords as plain strings across the UI | Declined | [ADR 0007](0007-type-and-value-preservation.md) and bound values; source: [application-layer audit](../archive/app-layer-external-audit-2026-10-06.md). |
| Trusted production mutations, unattended MCP writes, a public package | Not approved (SEC-8) | [ADR 0016](0016-governed-consumer-seam.md). |
| A YAML driver capability manifest or runtime-loaded engine descriptors | Declined | Capabilities are compile-time Rust types on the driver contract ([ADR 0001](0001-no-plugin-system.md)); the proposed direction is one static `DriverCapabilities` struct replacing the `supports_*` methods; source: [dbx features review](../archive/tablepro-dbx-review-2026-10-20/d-dbx-features.md). |
| Result charts, facet charts, theme editor or theme sync | Out of scope | Not in product goals; source: [feature comparison history](../archive/feature-comparison-history-2026-10-23.md). |

## Open forks (do not invent answers here)

| Fork | Who unblocks | Next step |
| --- | --- | --- |
| SSH and capability specs | Architect | Review [specs/](../../specs/README.md); when a spec and the code disagree, fix the spec. The `PolicyGuard` decision is [ADR 0016](0016-governed-consumer-seam.md); the governed SQL spec is still a draft |
| Security baseline ADR | Architect | Extract from AGENTS security invariants only if a contestable choice remains |
| Accessibility / WCAG claim | Maintainer | Ledger DOC-3; do not claim AA from Adwaita alone |
| Other data retention | Product | Query-result spool retention is defined in proposed [ADR 0025](0025-transient-result-page-spool.md); resolve any remaining retention policy with legal or product |
| Timed write unlock for production connections | Architect | Needs an amendment to [ADR 0016](0016-governed-consumer-seam.md) before any work; the production marker stays a display cue |
| SOCKS5 proxy for database connections | Product | Adapt only, low priority. Needs a threat review and a DNS-leak rule first ([dbx features review](../archive/tablepro-dbx-review-2026-10-20/d-dbx-features.md)) |
| SQLite loadable extensions | Architect | Security-sensitive; needs an explicit extension-loading decision before exposure ([feature comparison](../0.2-feature-comparison.md)) |
| Multi-session strip (several live sessions in one window) | Product | Not copied from TablePro without a product decision; one active connection window today |
| Performance budget ADR | Architect | Optional; PERF-* ledger rows may stay sufficient |
| Flathub / distro as external release gate | Architect / packaging | Decide whether external review is a release gate before planning a Flathub or distro submission. The published 0.2.0 includes a GNOME 50 Flatpak bundle but has no Flathub listing. |

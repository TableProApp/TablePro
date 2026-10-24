# Architecture decision records

These documents record the reasons behind major technical choices. Accepted decisions stay stable. A later decision may supersede an earlier one by linking to it explicitly.

Which forks already have an answer (and which are still open) is listed in the [decision checklist](checklist.md). Prefer a link there over inventing a second record for the same choice.

## Format

```markdown
# 000N: Title

- **Status**: Proposed | Accepted | Superseded by 000M | Deprecated
- **Date**: YYYY-MM-DD

## Context

What requires a decision.

## Decision

The selected approach.

## Rationale

Why it fits the project constraints.

## Consequences

Costs and benefits accepted by the project.

## Alternatives considered

Other options and why they were rejected.
```

## Index

| # | Title | Status | Summary |
|---|---|---|---|
| [0001](0001-no-plugin-system.md) | Database drivers are statically linked | Accepted | Driver crates are registered at compile time. |
| [0002](0002-rust-gtk4-libadwaita.md) | Rust, GTK4, and libadwaita | Accepted; toolkit floor superseded by 0021 | Native Linux UI with a virtualized data grid. |
| [0003](0003-relm4-architecture.md) | Relm4 for application architecture | Accepted | Typed component state and async message flow. |
| [0004](0004-libsecret-secret-storage.md) | Secret Service through oo7 | Accepted | Credentials stay in the desktop keyring. |
| [0005](0005-server-side-cancellation.md) | Cancellation must reach the database | Accepted | Drivers report cancellation only when the engine confirms it; unsupported or unconfirmed operations remain unknown. |
| [0006](0006-driver-panic-containment.md) | A driver panic is contained, not trusted away | Accepted | The guard converts a panic to a typed failure; the GUI wakes its monitor, and agentd retires its cached session for replacement on the next acquisition. |
| [0007](0007-type-and-value-preservation.md) | Native type and value preservation | Accepted | One outcome, conversion and proof standard across every driver and consumer. |
| [0008](0008-connection-and-session-ownership.md) | Connection/session ownership and trust | Accepted | Distinct live identities, no pool/replay/security fallback, and scoped uncertainty with durable audit obligations. |
| [0009](0009-persistence-and-identity-compatibility.md) | Durable identity and recoverable state | Accepted | Stable identifiers, compatible adapters, recoverable migrations and distinct persistence writer contracts. |
| [0010](0010-administrative-action-audit.md) | Audit confirmed bundle administration | Accepted | Bundle import/export use durable, paired aggregate audit records and fail closed before side effects. |
| [0011](0011-paged-query-results.md) | Page large editor results through a cursor | Accepted | Supported single-statement PostgreSQL editor SELECTs stream within an estimated 64 MiB row-storage budget; other paths keep their caps, and broader memory acceptance remains open. |
| [0012](0012-sidebar-object-tree.md) | Show database objects in a collapsible sidebar tree | Accepted | Collapsible Tables and Views groups use the existing `GtkListBox`; `GtkTreeListModel` migration and lazy catalog groups remain open. |
| [0013](0013-multiple-query-result-sets.md) | Preserve every result set from a query | Accepted | Ordered result batches keep SQL Server's later sets under one shared budget; the editor uses a result-set dropdown, MCP preserves sets, and GUI export handles one set |
| [0014](0014-full-table-export-snapshot.md) | Full table exports use one read snapshot | Accepted | Paged exports must read one guarded database snapshot or refuse before publishing a file |
| [0015](0015-database-snapshots.md) | Database snapshots and restore | Accepted design; implementation has no release target | Per-engine native snapshots behind a capability flag, generated names, one guarded and audited operation per action, a safety copy on restore |
| [0016](0016-governed-consumer-seam.md) | PolicyGuard is the only consumer connection | Accepted | Composition roots wrap consumer connections in `PolicyGuard`; the `Arc<dyn Connection>` interface does not encode that invariant as a distinct type |
| [0017](0017-mcp-sdk-behind-the-governed-seam.md) | Official Rust MCP SDK behind the governed seam | Accepted direction; migration incomplete | Target: replace the hand-written protocol and transport layer while keeping tokens, allowlists, approval and audit in BookiE's code. The production server remains hand-written; the SDK is an optional stdio prototype. |
| [0018](0018-headless-app-services-crate.md) | Headless application-services crate | Accepted | GTK-free services, the tab model and workspace persistence have moved; GTK controllers and page handling remain in the app. |
| [0019](0019-database-tooling-without-sidecars.md) | Database tooling without sidecars | Accepted; partial implementation | DuckDB for file conversion, `refinery` behind `PolicyGuard` for migrations, supervised vendor dump tools for backup; no sidecar binaries |
| [0020](0020-aggregate-forgejo-trains.md) | Aggregate pull requests are the Forgejo gate unit | Accepted | Gate one immutable aggregate head, verify its merge tree and close constituent PRs as included |
| [0021](0021-toolkit-floor.md) | Support only the newest GTK toolkit | Accepted | GTK 4.24, libadwaita 1.10 and GtkSourceView 5.22 at startup, build, package and CI; older distributions are unsupported |
| [0022](0022-release-notes-from-merge-commits.md) | Release notes come from merge commits | Accepted; workflow wiring pending | A `Release-Note:` trailer on each squash commit replaces edits to `CHANGELOG.md`; notes are assembled at release. |
| [0023](0023-system-openssh-transport-boundaries.md) | System OpenSSH transport boundaries | Accepted | Askpass answers only exact prompts, forced client options, no global state, and no `core` dependency in the ssh crate. |
| [0024](0024-keyed-grid-writes-check-what-they-overwrite.md) | Keyed grid writes check what they overwrite | Accepted | Relational updates compare edited columns' original values and must affect exactly one row; MongoDB guards by field and row; deletes and ABA are limits. |

Three records use "snapshot" for different things: ADR 0011 a read-only snapshot session, ADR 0014 the read snapshot a full export holds, and ADR 0015 a saved copy of a database.

Decisions 0007–0009 extract existing approved sprint/task-board rules. Accepted means the architecture choice is recorded; implementation and runtime acceptance remain on the relevant milestone records and owning boards.

## Adding a decision

1. Use the next number.
2. Copy the format above into a lowercase dash-separated filename.
3. Keep the document focused on one decision.
4. Add it to the index in the same change.
5. Update the [checklist](checklist.md) row for that fork (Decided with a link, or leave Open).
6. Submit it through the normal review process.
7. Record every rejected alternative with its reason under **Alternatives considered**, including options a review or comparison document turned down. A dated review that declines something is not a decision record until it is here.
8. A limitation entry never overrides an accepted ADR. If shipped behaviour differs from an ADR, amend the ADR or fix the behaviour.

# Architecture decision records

These documents record the reasons behind major technical choices. Accepted decisions stay stable. A later decision may supersede an earlier one by linking to it explicitly.

## Format

```markdown
# 000N: Title

- **Status**: Accepted | Superseded by 000M | Deprecated
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
| [0002](0002-rust-gtk4-libadwaita.md) | Rust, GTK4, and libadwaita | Accepted | Native Linux UI with a virtualized data grid. |
| [0003](0003-relm4-architecture.md) | Relm4 for application architecture | Accepted | Typed component state and async message flow. |
| [0004](0004-libsecret-secret-storage.md) | Secret Service through oo7 | Accepted | Credentials stay in the desktop keyring. |
| [0005](0005-server-side-cancellation.md) | Cancellation must reach the database | Accepted | Stop and timeouts abort the statement server-side, and only the engine's own abort error is terminal. |
| [0006](0006-driver-panic-containment.md) | A driver panic is contained, not trusted away | Accepted | The guard turns a driver panic into a failed operation and the connection is replaced. |
| [0007](0007-type-and-value-preservation.md) | Native type and value preservation | Accepted | One outcome, conversion and proof standard across every driver and consumer. |
| [0008](0008-connection-and-session-ownership.md) | Connection/session ownership and trust | Accepted | Distinct live identities, no pool/replay/security fallback, and scoped uncertainty with durable audit obligations. |
| [0009](0009-persistence-and-identity-compatibility.md) | Durable identity and recoverable state | Accepted | Stable identifiers, compatible adapters, recoverable migrations and distinct persistence writer contracts. |
| [0010](0010-administrative-action-audit.md) | Audit confirmed bundle administration | Accepted | Bundle import/export use durable, paired aggregate audit records and fail closed before side effects. |
| [0011](0011-paged-query-results.md) | Page large editor results through a cursor | Accepted | An optional guarded, audited server cursor returns pages of 5,000 rows; PostgreSQL first, other engines keep the caps |
| [0012](0012-sidebar-object-tree.md) | Show database objects in a collapsible sidebar tree | Accepted | A `GtkListView` over a `GtkTreeListModel` with real group rows, lazy catalog groups and saved collapse state |
| [0013](0013-multiple-query-result-sets.md) | Preserve every result set from a query | Accepted | Ordered result batches keep SQL Server's later sets, with one shared budget, guard masking/audit, UI tabs and MCP output |
| [0014](0014-full-table-export-snapshot.md) | Full table exports use one read snapshot | Accepted | Paged exports must read one guarded database snapshot or refuse before publishing a file |
| [0015](0015-database-snapshots.md) | Database snapshots and restore | Accepted (0.2.x after 0.2.0) | Per-engine native snapshots behind a capability flag, generated names, one guarded and audited operation per action, a safety copy on restore |

Decisions 0007–0009 extract existing approved sprint/task-board rules. Accepted
means the architecture choice is recorded; implementation and runtime acceptance
remain on the [active sprint](../bookie-0.2-sprint.md) and owning boards.

## Adding a decision

1. Use the next number.
2. Copy the format above into a lowercase dash-separated filename.
3. Keep the document focused on one decision.
4. Add it to the index in the same change.
5. Submit it through the normal review process.

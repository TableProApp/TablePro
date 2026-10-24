# 0016: PolicyGuard is the only consumer connection

- **Status**: Accepted
- **Date**: 2026-10-12

### Clarification (2026-10-20)

The statement below that "the type boundary cannot" forget the guard is an architectural requirement, not a compiler-enforced guarantee. `ConnectionProvider::connection` returns `Arc<dyn Connection>`, so composition roots and provider implementations must preserve the invariant and tests must cover issued handles. The accepted decision is unchanged.

## Context

The GTK app, MCP tools and `bookie-agentd` all need a live database handle. Optional checks around a raw driver connection are easy to skip from a new screen, tool or import path. Later features must not open a second execute path or a second value model.

Behaviour extracted from the code lives in [the governed SQL spec](../../specs/governed-sql/spec.md). This record is the architecture choice. Cancellation is [ADR 0005](0005-server-side-cancellation.md). Panic containment is [ADR 0006](0006-driver-panic-containment.md). Values are [ADR 0007](0007-type-and-value-preservation.md). Identity and trust are [ADR 0008](0008-connection-and-session-ownership.md).

## Decision

`PolicyGuard` is the only `Connection` a consumer may hold. Composition roots may keep a raw driver internally for reconnect and monitoring. They wrap it before the GUI, MCP or `bookie-agentd` issues a handle.

Three checks stay separate. None replaces another:

| Check | Question |
|---|---|
| MCP token scopes | Who may call which tools? |
| Connection allowlists | Which saved connections may that token use? |
| `PolicyGuard` | What SQL may run, how is it masked, and what is audited? |

A user SQL statement follows this order: classify, evaluate rules, request approval when required, write required audit intent, execute, mask eligible consumer results, then write the terminal audit outcome. Preview, transaction, retry and batch paths use the same policy and audit pipeline. When audit intent is required, a failed write prevents execution. Denied, failed, cancelled, timed-out and unknown outcomes still get a terminal audit state. Exact intent requirements and conditional agent masking stay in the governed SQL spec.

Metadata and browse fetches that do not carry user SQL still go through the guard. They do not invent a raw driver path.

Modularity means crate seams and capability flags, not a runtime driver ABI ([ADR 0001](0001-no-plugin-system.md)).

Future features may extend these workflows only when they stay on this seam:

- Presentation of read-only or production connections (colors, watermarks, confirmations). The presentation does not become a second gate, and an MCP or CLI path cannot widen a human unlock.
- Grid bandwidth: previews, hidden-column projection and cursor paging ([ADR 0011](0011-paged-query-results.md)) through the guard.
- One headless service facade that the GTK app and `bookie-agentd` both call, so a new tool cannot diverge from the GUI path.
- Optional engine capabilities, as in [ADR 0011](0011-paged-query-results.md) and [ADR 0015](0015-database-snapshots.md). Unsupported engines refuse or keep the existing capped path.

These stay rejected:

- Runtime driver plugins, OSGi JDBC bundles, or out-of-process JDBC/JSON-RPC agents ([ADR 0001](0001-no-plugin-system.md)).
- A browser or webview UI ([ADR 0002](0002-rust-gtk4-libadwaita.md)).
- JSON or string cells as the value contract ([ADR 0007](0007-type-and-value-preservation.md)).
- Any execute path that skips `PolicyGuard`.

The [statement-effects proposal](../proposals/policy-effects-and-verdict.md) is not accepted here. Rule join and a single AST walk stay a proposal until a later ADR accepts them.

## Rationale

One typed handle covers every consumer. A new surface inherits classify, approval, masking and audit without a separate checklist. Capability flags and a shared facade let the product take useful UI and paging ideas without copying another client's plugin host or value model.

## Consequences

- A consumer that holds a raw driver `Connection` is a defect.
- MCP scope or allowlist work does not move SQL decisions out of `tablepro-policy`.
- Cross-surface features (GUI and agent) change the guarded path once and update both callers.
- Performance work bounds pages and bytes through the guard. It does not remove classify or audit to go faster.

- An MCP request deadline bounds driver work, authorization and rollback, but not the durable audit append: abandoning it could leave an unconfirmed terminal state, so policy stays fail-closed while the request waits ([production audit](../archive/production-audit.md), known limits).
- Trusted production mutations, unattended MCP writes and a public package are not approved (maintainer decision SEC-8, [pre-migration ledger](../archive/known-issues-pre-project-migration-2026-10-12.md)). Do not build them without amending this record.

## Alternatives considered

- **Safety as preferences on a normal connection.** Rejected. A new path can forget a preference. The type boundary cannot.
- **Policy only inside the GTK app.** Rejected. MCP and `bookie-agentd` would need a second implementation.
- **Copy a plugin or agent driver host for modularity.** Rejected in [ADR 0001](0001-no-plugin-system.md). Seams are crates and traits.
- **A second statement classifier or editor permission engine** (for example an editor "Safe Mode" classifier in `core`). Rejected. Shared lexical facts may inform the existing classifier, but one authorization path stays authoritative ([TablePro collaboration review](../archive/tablepro-collaboration-2026-10-21.md)).
- **Treat a classification failure as a safe read.** Rejected, including the permissive direction of DBeaver #42374. An unparseable statement keeps governed approval or refusal ([Linux peer review](../archive/linux-peer-review-2026-10-16.md)).
- **Masking by extending a list of serialization-function names.** Rejected as the only defence. Unknown source lineage is handled conservatively (redacted), with allowed simple-column cases ([B4 wrap-up review](../archive/b4-release-wrapup-review-2026-10-11.md), AUD-9).
- **A read-only wrapper or a rollback around generated work as a policy substitute.** Rejected. It does not replace classification, approval, masking or the durable terminal audit ([upstream movement review](../archive/upstream-linux-movement-2026-10-18.md), section 7).
- **Scripting hooks (Bash, Python, Lua) on connection lifecycle.** Declined. They would add an execution surface outside the guard ([database client review](../archive/database-client-review-2026-10-23.md)).
- **A timed write unlock for production connections.** Not decided. The production marker is a display cue only. A timed unlock would change this safety contract, so it needs an amendment here first ([feature comparison](../0.2-feature-comparison.md)).

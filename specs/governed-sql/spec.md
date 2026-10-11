# Governed SQL

> [NEEDS REVIEW] Draft written on 2026-10-11 from PolicyGuard, MCP auth and ARCHITECTURE. A maintainer review is pending.

**Spec tier:** buildable
**Serves:** `Local DBA`, `MCP operator`
**Status:** in-development
**Success metric:** Every GUI, MCP and agent database handle is a `PolicyGuard`; denied and cancelled work still write a terminal audit state.

## Purpose

The only path a consumer may hold to a live database. Token scopes and connection allowlists answer who and which connection. They never replace this capability.

## Scope

- Wrapping a driver `Connection` in `PolicyGuard` before the GUI, MCP or `bookie-agentd` can use it.
- Per-statement order: classify, evaluate rules, request approval when required, apply masking, execute, write the audit outcome.
- MCP token scopes (`tools:read` / `tools:write` via `TokenPermissions`) and per-token connection allowlists.
- Preview, transaction, retry and batch paths using the same checks as direct execution.

## Out of scope

- Opening SSH tunnels and host-key trust ([ssh-transport](../ssh-transport/spec.md)).
- Secret Service storage of passwords and MCP plaintext tokens after issuance.
- Grid display, browse paging and export snapshot rules (later specs; ADRs 0011 and 0014).

## Core concepts

- **PolicyGuard.** The only consumer-facing database handle. Defined in `crates/policy/src/guard.rs`.
- **Decision.** `Allow`, `RequireApproval` or `Deny`, each with a `rule` string (`crates/policy/src/verdict.rs`).
- **StatementClass.** Coarse class including `Unparseable`, which is treated as a write (`crates/policy/src/classify.rs`).
- **Three MCP checks.** Scopes, allowlist, then PolicyGuard (`crates/mcp/src/lib.rs`).

## Data contracts

`McpToken` persisted by `TokenStore` (`crates/mcp/src/tokens.rs`):

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | Token identity used as the agent principal. |
| `name` | string | Shown to the operator; used as MCP client name. |
| `token_hash` | SHA-256 hex | Hash of the plaintext token. Plaintext is shown once at issuance and never stored. |
| `permissions` | `read_only` or `read_write` | `full_access` deserializes as `read_write`. |
| `connection_allowlist` | list of connection UUIDs | Empty list denies connection use. |
| `created_at` | datetime | Issuance time. |
| `expires_at` | optional datetime | When set, authentication fails after this instant. |
| `revoked` | bool | Revoked tokens do not authenticate. |

`Decision` (`crates/policy/src/verdict.rs`):

```text
Allow { rule }
RequireApproval { rule, reason, preview }
Deny { rule, message }
```

`AuditTerminalStatus` (`crates/policy/src/audit.rs`): `pending`, `succeeded`, `failed`, `denied`, `cancelled`, `timed_out`, `unknown`.

`StatementClass` (`crates/policy/src/classify.rs`): `select`, `insert`, `update`, `delete`, `ddl`, `administrative`, `transaction`, `other`, `unparseable`. `is_write` is true for every class except `select` and `transaction`.

## Interface contracts

### `PolicyGuard::authorize` / `authorize_analysis`

Source: `crates/policy/src/guard.rs` (the `authorize` family from line 114).

1. Classify the SQL (`analyze_statement`).
2. Evaluate categorical / shared-connection / eligible-write rules.
3. On `Allow`, continue to execute and mask.
4. On `Deny`, write audit terminal `denied` with `AuditErrorCategory::Policy`, then return `DriverError::PolicyDenied`.
5. On `RequireApproval`, call `ApprovalSink::request` and wait, honouring `OperationControl` cancellation.

Audit intent is written before driver execution. If that write fails, execution does not proceed (`DriverError::PolicyDenied` containing `audit intent could not be persisted`, `crates/policy/src/guard_tests_gating.rs`).

### MCP scope check

`authorize_scopes(perms, required)` in `crates/mcp/src/auth.rs`:

- `read_only` grants `ToolsRead` only.
- `read_write` grants `ToolsRead` and `ToolsWrite`.
- Failure: `token lacks scope {:?}; has {:?}`.

### MCP allowlist check

`McpBridge::ensure_connection_allowed` in `crates/mcp/src/bridge.rs`:

- Empty allowlist: `token has an empty connection allowlist`.
- Connection not listed: `token is not allowed to access this connection`.
- `list_connections` with an empty allowlist returns an empty list rather than every saved connection.

### Connection provider

`ConnectionProvider::connection` must return a policy-gated handle. `tablepro-mcp` documents that there is no path to a raw driver connection from that crate (`crates/mcp/src/lib.rs`).

| Endpoint | Status | errorCode | Message / condition |
|----------|--------|-----------|---------------------|
| PolicyGuard authorize | n/a | `PolicyDenied` | Rule denied the statement; audit terminal `denied`. |
| PolicyGuard authorize | n/a | `PolicyDenied` | Audit intent could not be persisted; execution skipped. |
| `authorize_scopes` | n/a | scope error | Token lacks `ToolsWrite` (or `ToolsRead`) for the tool. |
| `ensure_connection_allowed` | n/a | allowlist error | Empty allowlist, or connection UUID not listed. |
| Token authenticate | n/a | auth error | Unknown hash, revoked, or expired. |

## Algorithms & rules

1. Classify the statement. Parser rejection becomes `StatementClass::Unparseable` and is a write.
2. Evaluate policy for the principal, environment, `read_only` flag and connection-scoped `PolicyConfig`.
3. If the decision is `Deny`, persist terminal audit `denied` and return. Do not execute.
4. If the decision is `RequireApproval`, wait for `ApprovalOutcome`. A timeout or cancel still writes a terminal audit state.
5. Persist audit intent. On failure, return `PolicyDenied` and do not call the driver.
6. Execute through the inner `Connection`, honouring `OperationControl` cancellation and timeouts.
7. Apply masking to the result (`apply_masking`).
8. Persist the terminal audit outcome: `succeeded`, `failed`, `cancelled`, `timed_out`, or `unknown`. Audit failure after execution must not open a path around policy.
9. MCP tools call `authorize_scopes`, rate limit, then allowlist, then `provider.connection`, which wraps the driver in `PolicyGuard` before any SQL.

## State machine

| From | To | Trigger | Guard |
|------|----|---------|-------|
| unclassified | classified | `analyze_statement` | always |
| classified | allowed | `Decision::Allow` | rules pass |
| classified | awaiting-approval | `Decision::RequireApproval` | rules require it |
| classified | denied | `Decision::Deny` | rules deny; audit `denied` |
| awaiting-approval | allowed | approval accepted | approval sink |
| awaiting-approval | denied | approval rejected or timed out | audit terminal `denied` or `timed_out` |
| allowed | intent-recorded | audit intent write | fail closed if the write fails |
| intent-recorded | succeeded | driver returns | audit `succeeded` |
| intent-recorded | failed | driver error | audit `failed` |
| intent-recorded | cancelled | `OperationControl` cancelled | audit `cancelled` |
| intent-recorded | timed_out | timeout | audit `timed_out` |

Terminal audit states: `succeeded`, `failed`, `denied`, `cancelled`, `timed_out`, `unknown`.

## Requirements

### Guard wrapping

- The system MUST wrap every consumer-facing database handle in `PolicyGuard`.
- MCP and `bookie-agentd` MUST NOT expose a raw driver connection.
- Preview, transaction, retry and batch paths MUST use the same authorize path as direct execution.

### MCP checks

- A token MUST present `ToolsRead` to call read tools and `ToolsWrite` to call write tools.
- A token with an empty `connection_allowlist` MUST NOT use a saved connection.
- A missing token, scope, allowlist entry or policy decision MUST deny access.

### Audit

- Denied, failed, cancelled and timed-out operations MUST produce the matching terminal audit state.
- Audit failure MUST NOT open a path around policy.

## Invariants

- A consumer MUST NOT hold a live `Connection` that is not a `PolicyGuard`.
- An empty MCP allowlist MUST deny connection use.
- `Unparseable` SQL MUST be treated as a write.
- A failed audit-intent write MUST prevent execution.

## Config & flags

| Flag | Effect |
|------|--------|
| connection `read_only` | Categorical deny of writes before eligible-write evaluation. |
| `TokenPermissions` | `read_only` or `read_write` on the MCP token. |
| `PolicyConfig` / blast-radius max rows | Eligible writes may require a row estimate and approval. |

## Edge cases

- `full_access` on a stored token deserializes as `read_write`.
- Listing connections with an empty allowlist returns no rows; using a connection with an empty allowlist errors.
- Shared-connection decisions short-circuit categorical evaluation (`shared_connection_decision` in `crates/policy/src/guard.rs`).
- A dropped UI future is not proof the driver stopped. Cancellation must reach the database (ADR 0005).

## Trust boundaries

- MCP input, saved connection files, imported files, environment variables and database metadata are untrusted.
- Token plaintext crosses the boundary once at issuance; only `token_hash` is stored.
- SQL parameters are bound, not concatenated. Identifiers are dialect-quoted.
- Policy decisions are evaluated inside `tablepro-policy`. MCP may ask whether a statement needs write scope; it does not evaluate rules or write audit records itself.

## Cross-capability interactions

### ssh-transport

Transport opens the tunnel and preserves the TLS service identity. This capability starts after a driver `Connection` exists.

## Acceptance criteria

- **Guard is the handle.** GIVEN a GUI, MCP or agentd consumer WHEN a database handle is obtained THEN the value is a `PolicyGuard` and not a raw driver connection.
- **Deny audits.** GIVEN a statement the rules deny WHEN authorize runs THEN the caller receives `DriverError::PolicyDenied` AND the journal has terminal status `denied`.
- **Audit intent fail-closed.** GIVEN an audit sink that cannot persist intent WHEN authorize would otherwise allow THEN execution does not run AND the error mentions that audit intent could not be persisted.
- **Read-only token.** GIVEN `TokenPermissions::ReadOnly` WHEN a write tool is called THEN `authorize_scopes` fails and no `PolicyGuard` execute path for that write starts.
- **Empty allowlist.** GIVEN a token whose `connection_allowlist` is empty WHEN `ensure_connection_allowed` runs THEN the error is `token has an empty connection allowlist`.
- **Unparseable is a write.** GIVEN SQL the parser rejects WHEN classify runs THEN `StatementClass` is `Unparseable` AND `is_write` is true.
- **Cancel still audits.** GIVEN an in-flight governed statement WHEN `OperationControl` is cancelled THEN the journal records terminal `cancelled`.

## Open questions

None known.

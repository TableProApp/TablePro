# Governed SQL

> [NEEDS REVIEW] Draft written on 2026-10-11 from PolicyGuard, MCP auth and ARCHITECTURE. A maintainer review is pending.

**Spec tier:** buildable **Serves:** `Local DBA`, `MCP operator` **Status:** in-development **Success metric:** Every issued GUI, MCP and agent database handle is a `PolicyGuard`; denied work and cancelled approval or bulk finish still write a terminal audit state.

## Purpose

The only path a consumer may hold to a live database. Token scopes and connection allowlists answer who and which connection. They never replace this capability.

## Scope

- Wrapping a driver `Connection` in `PolicyGuard` before the GUI, MCP or `bookie-agentd` issues a handle to a consumer.
- Per-statement order: classify, evaluate rules, request approval when required, write required audit intent, execute, mask eligible consumer results, then write the terminal audit outcome.
- Optional session query cursors for one read statement in a read-only snapshot. `PolicyGuard` authorizes once, masks each page, and records page and terminal outcomes under one operation. PostgreSQL is the only driver that supports cursors; the SQL editor is not wired to this path yet.
- MCP token scopes (`tools:read` / `tools:write` via `TokenPermissions`), per-token rate limits and connection allowlists.
- Preview, transaction, retry and batch paths using the same rule, approval, intent and audit pipeline as direct execution. Session mode skips the shared-connection short-circuit.

## Out of scope

- Opening SSH tunnels and host-key trust ([ssh-transport](../ssh-transport/spec.md)).
- Secret Service storage of database and SSH credentials, plus GUI-issued MCP token plaintext ([secret-storage](../secret-storage/spec.md)).
- Grid page retention/display, browse paging and export snapshot rules (later specs; ADRs 0011 and 0014).

## Core concepts

- **PolicyGuard.** The issued consumer-facing database handle (`PolicyGuard` in `crates/policy/src/guard.rs`). Composition roots may keep a raw driver internally for reconnect; `DatabaseService::handle` and `agentd::guarded` wrap before return.
- **Decision.** `Allow`, `RequireApproval` or `Deny`, each with a `rule` string (`Decision` in `crates/policy/src/verdict.rs`).
- **StatementClass.** Coarse class including `Unparseable`, which `is_write` treats as a write (`StatementClass` in `crates/policy/src/classify.rs`).
- **MCP pre-connection steps.** Scope check, per-token rate limit, connection allowlist, then a policy-gated handle from `ConnectionProvider` (`McpBridge::start_connection_operation` in `crates/mcp/src/bridge.rs`).

## Data contracts

`McpToken` persisted by `TokenStore` (`crates/mcp/src/tokens.rs`):

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | Token identity used as the agent principal. |
| `name` | string | Shown to the operator; used as MCP client name. |
| `token_hash` | SHA-256 hex | `TokenStore` persists only the hash. GUI issuance returns plaintext once and attempts Secret Service storage; `bookie-agentd` emits it once to stdout or an explicitly selected owner-only file. |
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

`AuditTerminalStatus` (`crates/policy/src/audit.rs`): `pending` is used for intent and non-final cursor-page records; final outcomes are `succeeded`, `failed`, `denied`, `cancelled`, `timed_out` or `unknown`.

`StatementClass` (`crates/policy/src/classify.rs`): `select`, `insert`, `update`, `delete`, `ddl`, `administrative`, `transaction`, `other`, `unparseable`. `is_write` is true for every class except `select` and `transaction`.

## Interface contracts

### `PolicyGuard::authorize` / `authorize_analysis`

Source: `PolicyGuard` authorize family in `crates/policy/src/guard.rs`.

1. Classify the SQL (`analyze_statement`).
2. On a shared connection, `authorize_analysis` may return early from `shared_connection_decision` before categorical rules. Session mode calls `authorize_classified`, which skips that short-circuit and goes to `authorize_with_bound`.
3. On `Allow`, continue to execute; mask the returned result when `should_mask` applies (agent-only).
4. On `Deny`, write audit terminal `denied` with `AuditErrorCategory::Policy`, then return `DriverError::PolicyDenied`.
5. On `RequireApproval`, call `ApprovalSink::request` and wait. `ApprovalOutcome` is `AllowOnce` or `Deny` (`crates/policy/src/approval.rs`). `OperationControl` interrupts the wait on cancellation or deadline; the guard records the matching `cancelled` or `timed_out` audit outcome.

Audit intent is written before driver execution when `intent_is_required` is true. A failed required intent write returns `DriverError::PolicyDenied` mentioning that audit intent could not be persisted (`required_intent_failure_prevents_driver_execution`). Local or Dev human principals with `human_allow_unaudited_writes` may continue after a warning (`handle_intent_failure`).

### MCP scope check

`authorize_scopes(perms, required)` in `crates/mcp/src/auth.rs`:

- `read_only` grants `ToolsRead` only.
- `read_write` grants `ToolsRead` and `ToolsWrite`.
- Failure string is built in `authorize_scopes`. Tests assert the error mentions `scope`, not the exact format.

### MCP allowlist check

`McpBridge::ensure_connection_allowed` in `crates/mcp/src/bridge.rs`:

- Empty allowlist: `token has an empty connection allowlist` (`empty_allowlist_denies_connection_access` asserts the error mentions `allowlist`).
- Connection not listed: `token is not allowed to access this connection`.
- `list_connections` with an empty allowlist returns an empty list rather than every saved connection (code in `McpBridge::list_connections`; no dedicated test).

### Connection provider

`ConnectionProvider::connection` must return a policy-gated handle. `tablepro-mcp` documents that there is no path to a raw driver connection from that crate (`crates/mcp/src/lib.rs`).

| Endpoint | Status | errorCode | Message / condition |
|----------|--------|-----------|---------------------|
| PolicyGuard authorize | n/a | `PolicyDenied` | Rule denied the statement; audit terminal `denied`. |
| PolicyGuard authorize | n/a | `PolicyDenied` | Audit intent could not be persisted; execution skipped. |
| `authorize_scopes` | n/a | scope error | Token lacks `ToolsWrite` (or `ToolsRead`) for the tool. |
| `ensure_connection_allowed` | n/a | allowlist error | Empty allowlist, or connection UUID not listed. |
| Token authenticate | n/a | auth error | Unknown hash or revoked (`a_subprocess_issue_cannot_resurrect_a_revoked_token`). Expiry is implemented in `TokenStore::authenticate`; no dedicated test. |

## Algorithms & rules

1. Classify the statement. Parser rejection becomes `StatementClass::Unparseable` and is a write.
2. Evaluate policy for the principal, environment, `read_only` flag and connection-scoped `PolicyConfig`.
3. If the decision is `Deny`, persist terminal audit `denied` and return. Do not execute.
4. If the decision is `RequireApproval`, wait for `ApprovalOutcome` under `OperationControl`. A cancel during the wait writes terminal `cancelled`; a deadline writes `timed_out`; rejection writes `denied`.
5. Persist audit intent when required. On required-intent failure, return `PolicyDenied` and do not call the driver.
6. Execute through the inner `Connection`, honouring `OperationControl` cancellation and timeouts.
7. Apply masking to the returned result (`apply_masking`) when the principal requires it.
8. Persist the terminal audit outcome: `succeeded`, `failed`, `cancelled`, `timed_out`, or `unknown`. Audit failure after execution must not open a path around policy.
9. MCP tools call `authorize_scopes`, then `check_rate`, then `ensure_connection_allowed`, then `provider.connection`, which wraps the driver in `PolicyGuard` before any SQL. Write tools also require `ToolsWrite` before a connection opens.

## State machine

| From | To | Trigger | Guard |
|------|----|---------|-------|
| unclassified | classified | `analyze_statement` | always |
| classified | allowed | `Decision::Allow` | rules pass |
| classified | awaiting-approval | `Decision::RequireApproval` | rules require it |
| classified | denied | `Decision::Deny` | rules deny; audit `denied` |
| awaiting-approval | allowed | approval accepted | approval sink |
| awaiting-approval | denied | approval rejected | audit terminal `denied` |
| awaiting-approval | cancelled | `OperationControl` cancelled during wait | audit terminal `cancelled` |
| awaiting-approval | timed_out | `OperationControl` deadline during wait | audit terminal `timed_out` |
| allowed | intent-recorded | audit intent write | fail closed if the write fails |
| intent-recorded | succeeded | driver returns | audit `succeeded` |
| intent-recorded | failed | driver error | audit `failed` |
| intent-recorded | cancelled | `OperationControl` cancelled | audit `cancelled` |
| intent-recorded | timed_out | timeout | audit `timed_out` |

Terminal audit states: `succeeded`, `failed`, `denied`, `cancelled`, `timed_out`, `unknown`.

## Requirements

### Guard wrapping

- The system MUST wrap every issued consumer-facing database handle in `PolicyGuard`.
- MCP and `bookie-agentd` MUST NOT expose a raw driver connection through `ConnectionProvider`.
- Preview, transaction, retry and batch paths MUST use the same rule, approval, intent and audit pipeline as direct execution. Session statements MAY skip `shared_connection_decision`.

### MCP checks

- A token MUST present `ToolsRead` to call read tools and `ToolsWrite` to call write tools.
- A token with an empty `connection_allowlist` MUST NOT use a saved connection.
- A missing token, scope, allowlist entry or policy decision MUST deny access.

### Audit

- Denied, failed, cancelled and timed-out operations MUST produce the matching terminal audit state.
- Audit failure MUST NOT open a path around policy.

## Invariants

- An issued consumer handle MUST be a `PolicyGuard`. Composition roots MAY hold a raw driver internally for reconnect.
- An empty MCP allowlist MUST deny connection use.
- `Unparseable` SQL MUST be treated as a write.
- A failed audit-intent write MUST prevent execution when intent is required.

## Guarded query cursors

`PolicySession` admits a cursor only inside a read-only snapshot and for one read statement. It applies policy before opening the driver cursor, masks every fetched page, and writes the intent and page outcomes with one operation ID. A failed or cancelled fetch closes the driver cursor and records its outcome. Other drivers return `Unsupported`; the caller keeps the materialized path.

## Config & flags

| Flag | Effect |
|------|--------|
| connection `read_only` | Categorical deny of writes before eligible-write evaluation. |
| `TokenPermissions` | `read_only` or `read_write` on the MCP token. |
| `PolicyConfig` / blast-radius max rows | Eligible writes may require a row estimate and approval. |

## Edge cases

- `full_access` on a stored token deserializes as `read_write`.
- Shared-connection decisions short-circuit categorical evaluation (`shared_connection_decision` in `crates/policy/src/guard.rs`).
- A dropped UI future is not proof the driver stopped. Cancellation must reach the database (ADR 0005).

## Trust boundaries

- MCP input, saved connection files, imported files, environment variables and database metadata are untrusted.
- Token plaintext is returned once at issuance; `TokenStore` persists only `token_hash`. GUI issuance attempts Secret Service storage, while `bookie-agentd` emits the token once to stdout or an explicitly selected owner-only file.
- SQL parameters are bound, not concatenated. Identifiers are dialect-quoted.
- Policy decisions are evaluated inside `tablepro-policy`. MCP may ask whether a statement needs write scope; it does not evaluate rules or write audit records itself.

## Cross-capability interactions

### ssh-transport

Transport opens the tunnel and preserves the TLS service identity. This capability starts after a driver `Connection` exists.

## Acceptance criteria

Each line names the tip proof. When the proof is code only, that is marked.

- **Guard is the handle.** GIVEN a GUI, MCP or agentd consumer WHEN a handle is issued THEN it is a `PolicyGuard`. Proof: `DatabaseService::handle` / `guard_with_identity`; `agentd::guarded`; MCP `ConnectionProvider` impls. The app may store a raw driver internally. No test downcasts the issued type.
- **Deny audits.** GIVEN a statement the rules deny WHEN authorize runs THEN the caller receives `DriverError::PolicyDenied` AND the journal has terminal status `denied`. Proof: `a_denied_approval_writes_the_terminal_audit_state_and_grants_nothing`; `sql_server_batches_with_mutations_are_classified_and_denied_before_dispatch`.
- **Audit intent fail-closed.** GIVEN required audit intent that cannot persist WHEN authorize would otherwise allow THEN execution does not run AND the error mentions that audit intent could not be persisted. Proof: `required_intent_failure_prevents_driver_execution`. Exception: Local/Dev human with `human_allow_unaudited_writes` (`handle_intent_failure`).
- **Read-only token.** GIVEN `TokenPermissions::ReadOnly` WHEN a write tool is called THEN `authorize_scopes` fails and no connection is opened for that write. Proof: `write_without_tools_write_scope_denied`; `a_read_only_token_is_refused_a_delete_before_a_connection_opens`.
- **Empty allowlist.** GIVEN a token whose `connection_allowlist` is empty WHEN `ensure_connection_allowed` runs THEN connection use is denied. Proof: `empty_allowlist_denies_connection_access` (asserts the error mentions `allowlist`). Code string: `token has an empty connection allowlist`.
- **Unparseable is a write.** GIVEN SQL the parser rejects WHEN classify runs THEN `StatementClass` is `Unparseable` AND `is_write` is true. Proof: `parse_failure_fail_closed`.
- **Cancel still audits.** GIVEN a pending approval or governed bulk finish WHEN work is cancelled THEN the journal records terminal `cancelled`. Proof: `cancelling_a_pending_approval_records_a_terminal_cancelled_outcome`; `a_cancelled_import_writes_the_cancelled_terminal_state`. Mapping `DriverError::Cancelled` after intent to journal `cancelled` is in `controlled_error_terminal_status` and has no dedicated post-intent execute test.
- **Cursor pages stay governed.** GIVEN a single read in a read-only snapshot WHEN pages are fetched THEN every page is masked and all records share one operation ID. A page failure, cancellation or timeout closes the cursor and records the outcome. Proof: `cursor_masks_every_page_and_keeps_one_audit_operation_id`, `a_page_error_closes_the_cursor_and_records_failure_after_prior_pages`, `cancellation_after_a_delivered_page_closes_and_audits_the_cursor`, and `a_cursor_timeout_closes_and_audits_the_cursor`.
- **Unsupported cursor stays refused.** GIVEN a driver without cursor support WHEN a cursor is opened THEN it returns `Unsupported` without materializing the query. Proof: `unsupported_cursor_is_refused_without_materializing_the_query`.

## Open questions

None known. Architect review of this draft is still the open checklist fork.

# 0008: Keep connection identity, session ownership and trust explicit

- **Status**: Accepted
- **Date**: 2026-10-03
- **Origin**: Approved sprint B4 and the seven decisions recorded on its task board on 2026-09-27. Extraction does not close their implementation tasks.

## Context

Saved connection UUIDs can survive a reconnect; physical handles and dedicated sessions cannot. Pool reuse, stale callbacks, weaker transport fallback and global uncertainty state can cross the intended ownership boundary.

## Decision

### Identity and transaction ownership

Use shared transport assembly and guarded handles in GUI/agentd/MCP. Keep the saved UUID, live connection identity, editor session UUID and selected namespace distinct. Completion/catalog/run callbacks must belong to the current owner. After loss/replacement, an unusable dedicated session refuses further SQL; it never falls back to a pool or replays an uncertain write. Teardown awaits settlement and close. Cancellation follows ADR 0005; panic containment follows ADR 0006.

Refuse implicit transaction starters (`SET autocommit=0`, `SET IMPLICIT_TRANSACTIONS ON`, `XA START`) and unterminated transaction batches on shared connections. Inside a dedicated MySQL interactive transaction, allow locking reads, user-variable assignments, savepoint operations and recognized `SHOW` forms because they do not commit implicitly. This does not make session effects transactional: `ROLLBACK` does not restore user-variable values or release named locks acquired by functions in assignment expressions. Keep refusing DDL, account statements, `LOCK TABLES`, raw transaction-control SQL and `SET autocommit`; unknown statement forms fail closed.

### Trust and route selection

The GUI must ask before accepting an unknown SSH host key on every hop, for built-in and system OpenSSH routes; unattended agentd refuses unknown keys. A selected system OpenSSH route unavailable in Flatpak is refused with a clear message. Do not silently switch backends or weaken TLS/auth. Daemon cache reuse requires verified current connection/key material; a digest failure refuses reuse, and a post-connect failure drops the new handle. Audit tunnel setup and host-key refusal through the approved audit contract.

### Uncertainty scope

An unknown write outcome blocks governed writes for that connection. Recovery uses the approved connection restart path. Journal-wide failure and unresolved durable recovery obligations stay fail-closed. Reconnect cannot erase an audit intent or prove whether the server committed a write. Old-generation callbacks cannot clear or poison a replacement's state. Each live connection owns its audit generation; a shared generation across connections is not this contract.

Remaining transport, audit and installed acceptance live on [the B4 board](../b4-task-board.md).

## Rationale

Explicit owners prevent a saved UUID from authorizing a stale handle or write. Refusal keeps a route/cache failure from becoming a weaker security path. Connection uncertainty and journal failure have different scopes and recovery requirements; both need durable terminal outcomes.

## Consequences

Cross-owner changes require coordinated core/policy/transport/daemon/UI work. Tests need stale generations, no dispatch/replay, cleanup and database/audit postconditions. Safe refusal remains until the owning task proves recovery. The [manual checklist](../manual-verification-0.2-features.md) retains installed acceptance. Task completion does not imply B4 or release completion.

## Alternatives considered

- Reuse a saved UUID as the sole live identity: cannot distinguish reconnects.
- Pool fallback or retry after session loss: changes state/transaction ownership and risks duplicate writes.
- Backend/TLS fallback after failure: changes the trust contract without consent.
- Clear every audit failure on reconnect: loses journal-wide recovery obligations.

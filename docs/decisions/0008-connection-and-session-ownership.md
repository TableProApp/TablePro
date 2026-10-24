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
- **One global generation counter for every kind of identity.** Rejected. The saved UUID, the physical connection identity, the editor-session UUID and the selected database or schema are four different identities ([upstream older releases review](../archive/upstream-older-releases-review-2026-10-03.md), O1).
- **Probing an uncertain write by committing again.** Rejected. After an unknown outcome, never probe by re-commit. A non-transactional DDL engine such as MySQL is reported as possibly mixed, not as rolled back ([dbx features review](../archive/tablepro-dbx-review-2026-10-20/d-dbx-features.md)).
- **A connection-wide Auto/Manual-Commit switch, or a toolbar Commit/Rollback for the connection.** Rejected. A connection-wide control can target the wrong session. Transactions exist only in a dedicated editor Session that reports "transaction open" and asks commit or roll back when it closes ([Beekeeper Studio observation](../archive/beekeeper-studio-live-ux-observation-2026-10-22.md)).
- **Automatic retry or replay of a failed statement, or deciding liveness from error text.** Rejected, with two reviewed exceptions: the PostgreSQL stale-type-cache retry and the MySQL parameter-free prepared-protocol fallback. Both fire only on an explicit server rejection, never after a disconnect, timeout or unknown outcome, and an explicit transaction disables the retry. They are reviewed code paths, not proof that an arbitrary routine has no side effects ([B4 task board](../archive/b4-task-board-pre-project-migration-2026-10-12.md), "Allowed retry boundaries"). MongoDB uses one direct endpoint with SDK defaults; its standalone lost-acknowledgement fixture is not proof for replica-set or other topologies. The reason: identical error text can describe a request never sent or a lost response after execution, so a retry of a write can duplicate it. Any retry is limited to a named source/routine pair that is proven to be safe, such as the PostgreSQL `0A000` case in [capability review](../capability-review.md) ([database client review](../archive/database-client-review-2026-10-23.md)).

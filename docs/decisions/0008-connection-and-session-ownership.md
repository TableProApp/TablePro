# 0008: Keep connection identity, session ownership and trust explicit

- **Status**: Accepted
- **Date**: 2026-10-03
- **Origin**: Approved sprint B4 and the seven decisions recorded on its task
  board on 2026-09-27. Extraction does not close their implementation tasks.

## Context

Saved connection UUIDs can survive a reconnect; physical handles and dedicated
sessions cannot. Pool reuse, stale callbacks, weaker transport fallback and
global uncertainty state can cross the intended ownership boundary.

## Decision

### Identity and transaction ownership

Use shared transport assembly and guarded handles in GUI/agentd/MCP. Keep the
saved UUID, live connection identity, editor session UUID and selected namespace
distinct. Completion/catalog/run callbacks must belong to the current owner.
After loss/replacement, an unusable dedicated session refuses further SQL;
it never falls back to a pool or replays an uncertain write. Teardown awaits
settlement and close. Cancellation follows ADR 0005; panic containment follows
ADR 0006.

Refuse implicit transaction starters (`SET autocommit=0`,
`SET IMPLICIT_TRANSACTIONS ON`, `XA START`) and unterminated transaction batches
on shared connections. The existing dedicated-session contract remains distinct;
this decision does not expand supported session syntax.

### Trust and route selection

The GUI must ask before accepting a new built-in SSH host key; unattended agentd
refuses unknown keys. A selected system OpenSSH route unavailable in Flatpak is
refused with a clear message. Do not silently switch backends or weaken TLS/auth.
Daemon cache reuse requires verified current connection/key material; a digest
failure refuses reuse, and a post-connect failure drops the new handle. Audit
tunnel setup and host-key refusal through the approved audit contract.

### Uncertainty scope

The approved B4 target blocks governed writes for the connection with an unknown
outcome, with recovery on the approved connection restart path. Journal-wide
failure and unresolved durable recovery obligations remain fail-closed; reconnect
cannot erase an audit intent or prove whether the server committed a write.
Old-generation callbacks cannot clear or poison a replacement's state.

F8's GUI generation split is merged in `6346a431c`; the daemon still supplies
one shared `AuditState` to all cached connections. GUI source integration does
not prove headless parity or installed recovery. F4/F9 reconnect/session
invalidation and F6 host consent are merged. Remaining transport, daemon,
audit and installed acceptance live on [the B4 board](../b4-task-board.md),
with current source findings in [the release audit](../archive/release-audit-2026-10-03.md).

## Rationale

Explicit owners prevent a saved UUID from authorizing a stale handle or write.
Refusal keeps a route/cache failure from becoming a weaker security path.
Connection uncertainty and journal failure have different scopes and recovery
requirements; both need durable terminal outcomes.

## Consequences

Cross-owner changes require coordinated core/policy/transport/daemon/UI work.
Tests need stale generations, no dispatch/replay, cleanup and database/audit
postconditions. Safe refusal remains until the owning task proves recovery.
The [manual checklist](../manual-verification-0.2-features.md) retains installed
acceptance. Task completion does not imply B4 or release completion.

## Alternatives considered

- Reuse a saved UUID as the sole live identity: cannot distinguish reconnects.
- Pool fallback or retry after session loss: changes state/transaction ownership
  and risks duplicate writes.
- Backend/TLS fallback after failure: changes the trust contract without consent.
- Clear every audit failure on reconnect: loses journal-wide recovery obligations.

# 0009: Preserve durable identity and recoverable state during evolution

- **Status**: Accepted
- **Date**: 2026-10-03
- **Origin**: Approved sprint A4/B2 and its migration/compatibility rules.

## Context

The BookiE rename and storage upgrades span multiple package generations.
Renaming durable identifiers or replacing a concurrent writer can disconnect
credentials/history/audit from saved connections or destroy rollback data.

## Decision

Change visible branding and command names with compatibility aliases. Keep the
existing application ID, config/data paths, keyring schema, connection UUIDs,
audit format and protocol contracts unless a separate explicit migration is
approved. Do not globally replace `tablepro`/`com.tablepro.linux` strings.

Version persisted formats and validate supported versions. Before upgrading
preferences/history/workspace formats, preserve private pre-migration data;
migrate transactionally or with the format's atomic/idempotent equivalent,
retain recoverable legacy data until the new state is durable, and document
restoration on package rollback. Failures must preserve the last durable state
and remain visible. Do not rewrite audit history. Keep wire and persistence
adapters separate from internal type changes.

GSettings preferences/geometry retain their JSON fallback and rollback mirrors.
Whole-document `StateFile` and locked per-connection `WorkspaceStore` merges
remain different writer contracts. Coalescing must preserve ordering and settle
flush waiters; a whole-map replacement must not lose another window's entries.
Shutdown must flush persistence and settle governed operations.

Operational restoration steps belong in [storage](../storage.md) and
[state management](../state-management.md), with the prior draft restoration
procedure retained in [sprint history](../archive/bookie-0.2-history.md#workspace-rollback-procedure).
Installed upgrade/rollback remains sprint B7 acceptance.

## Rationale

Stable durable identifiers keep users' existing credentials and state attached
to the same connections. Recoverable migrations permit package rollback without
treating a compiler or unit-test pass as installed compatibility proof.

## Consequences

Storage changes need malformed/future-version, interruption, concurrent-write,
backup and restoration evidence. Newer optional fields must follow the existing
compatibility contract; no blanket claim that every old format accepts them.
Packaging must retain aliases/resources and prove actual installed recovery.

## Alternatives considered

- Rename every identifier with the product: strands durable state and grants.
- Migrate in place without recovery data: makes partial failure destructive.
- Unify every background writer: erases distinct merge/locking guarantees.
- Couple internal types directly to persisted/wire layouts: turns a carrier
  improvement into an unreviewed compatibility change.

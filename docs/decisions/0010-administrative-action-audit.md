# 0010: Audit confirmed bundle administration

- **Status**: Accepted
- **Date**: 2026-10-07

## Context

BookiE's connection bundle import and export can read or mutate saved connection
configuration and credentials. The audit journal previously described guarded
database operations and transport attempts, but not these process-wide settings
operations. Recording file paths, connection names, identifiers, or credentials
would disclose sensitive configuration details.

## Decision

After explicit user confirmation and before a bundle export or import performs
its side effect, BookiE writes a durable `Intent` event. It writes a matching
durable `Outcome` event after the attempt, using the same operation identifier.
The event identifies a stable administrative action code and may include only
an aggregate affected-item count. Process-wide settings events use a nil
connection identifier and the fixed `local_settings` identity.

Events must not contain bundle paths, connection names or identifiers,
connection strings, passwords, private keys, or other secret material. Bundle
preview and decryption that occur before confirmation are not audited because
they do not mutate saved configuration or credentials.

If the intent cannot be made durable, BookiE does not begin the operation. If
the outcome cannot be made durable, the audit runtime disables governed writes
and reports a generic failure. An intent left without an outcome after a crash
is an unresolved process-wide administrative obligation; recovery must retain
that uncertainty for review rather than infer success or failure.

## Rationale

Pairing intent and outcome provides a durable record around configuration and
credential changes while keeping the event useful for review and bounded in
sensitive data. Reusing the existing journal and audit event model avoids a
parallel logging path.

## Consequences

- Export and confirmed import can be refused when the audit journal is
  unavailable.
- Import outcomes may report an aggregate partial count; per-connection
  outcomes are intentionally not recorded.
- Recovery must surface unmatched administrative intents without guessing the
  operation's result.
- Existing event records remain readable because the administrative metadata
  is optional.

## Alternatives considered

- Logging paths and connection identities was rejected because it would expose
  user configuration in the journal.
- A separate administrative log was rejected because it would duplicate
  durability and recovery machinery.
- Logging only after completion was rejected because a crash could leave a
  configuration mutation with no preceding durable record.

# 0078: SSH profile names settle by lowest id, as credential profile names do

- **Status**: Accepted; amends 0075
- **Date**: 2026-11-28

## Context

[0075](0075-the-downgrade-mirror-record-rules-and-team-library-readings-are-settled.md), Credential profile names, settles two credential profiles of one name that a pull brings together. SSH profiles are picked by name the same way, and E2E round 4 found two SSH profiles made under one name on two devices while offline keep that name on both after they sync.

## Decision

- The rule 0075 gives credential profile names covers SSH profiles too. When a pull brings an SSH profile whose name matches another's in any case, the lowest id, compared as bytes, keeps the name. The others take `<name> (2)`, `(3)` and on, written as this device's edit.
- Both kinds settle at the same point, the library adapter's pull, through one rule.

## Consequences

- Every device settles an SSH profile name collision the same way, by id.
- A connection that names an SSH profile by id is not touched by the rename.

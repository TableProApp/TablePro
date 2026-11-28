# 0078: SSH profile names settle by lowest id, as credential profile names do

- **Status**: Accepted; amends 0075
- **Date**: 2026-11-28

## Context

[0075](0075-the-downgrade-mirror-record-rules-and-team-library-readings-are-settled.md), Credential profile names, settles two credential profiles of one name that a pull brings together. SSH profiles are picked by name the same way, and E2E round 4 found two SSH profiles made under one name on two devices while offline keep that name on both after they sync.

## Decision

- The rule 0075 gives credential profile names covers SSH profiles too. When a pull brings an SSH profile whose name matches another's in any case, the lowest id, compared as bytes, keeps the name. The others take `<name> (2)`, `(3)` and on, written as this device's edit.
- Both kinds settle at the same point, the library adapter's pull, through one rule.

## Consequences

- Every device leaves the name to the same profile, the lowest id. With three or more profiles of one name arriving in different orders, as across pull pages, two devices can number the others differently; each rename goes up as an ordinary edit, so the names converge as any edit does. The same holds for credential profiles under 0075.
- A connection that names an SSH profile by id is not touched by the rename.

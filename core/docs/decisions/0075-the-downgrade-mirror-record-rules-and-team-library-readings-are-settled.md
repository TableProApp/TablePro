# 0075: The downgrade mirror, record rules and Team Library readings are settled

- **Status**: Accepted; amends 0051, 0052, 0054 and 0061; credential profile names extended to SSH profiles by 0078
- **Date**: 2026-11-28

## Context

The downgrade mirror lane (K6e), the history and library adapters (K6a-3a, K6a-3b) and the core-engine integration rounds 3 and 4 met places where [0051](0051-sync-protocol-and-record-rules.md), [0052](0052-synced-records-have-canonical-ids.md), [0054](0054-one-sync-engine-in-the-core-for-tablepro-sync-and-icloud.md) and [0061](0061-the-records-crate-settles-six-record-rules-the-adrs-left-open.md) leave a gap. Each ruling below is the orchestrator's, or a lane's reading the orchestrator confirmed, checked against the merged engine. Those ADRs are Accepted, so the rulings go here, and they change only their Status lines.

## Decision

### The downgrade mirror (0054, The Apple apps on the engine)

What the Mac writes for the previous stable, and what it imports from it:

1. **Approvals.** A record whose pulled values wait for the person, or were rejected, is listed by name in `changes_held_for_unreadable`. A record held whole for approval is not listed; its record type leaves `readable_record_types`, so the previous stable reads that whole type.
2. **The pre-pull copy.** While a record waits for approval, the previous stable gets its copy from before the pull: the prior base's CloudKit tag and fields, kept in `legacy_mirror` as `prior/<kind>/<id>`. It goes when nothing of the record waits any more, or a pulled deletion arrives.
3. **An older build ran** when the Swift metadata, without its marks and its records' system fields, differs from what the mirror wrote, when a tombstone went, or when a dirty mark went without becoming a tombstone. A new mark, such as the engine's own offline marks, does not count.
4. **A state file with the zone and no mirror record** imports nothing.
5. **The Swift metadata is trusted** as the previous stable trusts it, with no size or count cap. Malware on an unlocked device is out of scope (threat model).
6. **A failed metadata read** stops iCloud sync until it reads. Each pass reads it again first.
7. **`removals_pending_for_unreadable`** imports as held deletions.
8. **The change token** is kept only when every record type the engine reads is listed as readable. Otherwise a full fetch runs. The content kinds' entries play no part, so only a whole record type missing forces one.
9. **An unknown last account.** When Swift's last account is unknown or another one, the import keeps only the dirty marks and standing, and drops the tombstones, the token, the held sets and the record cache.
10. **Journal marks wait for the owners.** Marks made before the owners are read from the state file wait, in order, until they are, before any CloudKit call. A flush waits at most 5 seconds for the owners, then fails with the marks kept.

### Records (0051, What syncs; 0052; 0061)

- **History.** Only the person's deletions write history tombstones, with no cap; a prune writes none. An entry of an engine whose credential rules the core lacks, such as Oracle, Redshift and Snowflake, stays on the device. The history and saved queries of sample connections stay on the device. A pulled saved query or folder with no times takes the time it arrived.
- **Tag colours.** Teal is written `Teal`. A pulled colour this build does not know reads as Slate.
- **Driver names** (0061, item 4). The records crate's `DRIVER_TYPES` maps the Mac's `DatabaseType` names on the wire to the core's driver ids, for the apps that name an engine by driver id.
- **Credential profile names** (0052). When a pull brings a profile whose name matches another's in any case, the lowest id, compared as bytes, keeps the name. Profiles keep no creation date to order by. The others take `<name> (2)`, `(3)` and on, written as this device's edit. The Swift rule renamed the arriving profile, which does not converge across devices.
- **SSH routes.** `SyncConfig.route_publisher`, this device's id as the host of its SSH routes, becomes a device-only `route_publisher` mark on each connection copy. Only a copy whose mark is the route's publisher can clear the route.

### Team Library (0051, Teams; 0052, Team scope)

- **Push order.** A team scope's push sends its writes first, then its deletions: queries, folders, then connections.
- **Ids in other case.** A pulled team library record whose id another record of its kind holds in other case is held as `collides`, with the server's copy as its base. Neither spelling is listed, planned or pushed, nor an item that names a folder or connection held this way.
- **The verified delete.**
  - Each state database has one marker, `<owner>.<database>.deleting`, staged `store`, then `rows`.
  - The owner's file is fenced while the owner-wide marker or any database's `store` stage stands, or while the markers cannot be listed.
  - Each database clears only its own marker, and the owner-wide one.
  - The file is checked, deleted and the stages moved on under the store's locks. A marker that landed outranks the run's obligation in memory.
- **Teams-only Macs.** Team Library runs on a Mac whose personal provider is iCloud or Off; `team_library_runs_on_a_mac_whose_personal_provider_is_icloud_or_off` pins it.

## Consequences

- The previous stable reads a record that waits for approval as it was before the pull.
- A failed Swift metadata read stops iCloud sync on that Mac until it reads.
- Every device settles a credential profile name collision the same way, by id.
- A team push deletes an item before the folder or connection it names.

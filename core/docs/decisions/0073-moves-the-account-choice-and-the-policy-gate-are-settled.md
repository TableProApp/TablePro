# 0073: Moves between providers, the account choice and the policy gate are settled

- **Status**: Accepted; amends 0054, 0055 and 0066
- **Date**: 2026-11-28

## Context

The core-engine integration rounds 3, 3b and 4, and the provider lane M5b-1, met places where [0054](0054-one-sync-engine-in-the-core-for-tablepro-sync-and-icloud.md)'s moves and account switches, [0055](0055-managed-policies-for-the-sync-provider-and-tablepro-app-traffic.md)'s policies and [0066](0066-the-state-file-keeps-refused-changes-and-per-kind-refills-and-the-engine-rulings-are-settled.md)'s rules leave a gap or say what the engine does not do. Each ruling below is the orchestrator's, checked against the merged engine. 0054, 0055 and 0066 are Accepted, so the rulings go here, and those ADRs change only their Status lines.

## Decision

### The state file (0054, The state file; 0066)

Schema 2 gains two tables, with no version bump, since no released build wrote schema 2:

| Table | Holds |
|---|---|
| `moves`, after `legacy_mirror` | At most one row: the provider a move left (or none), its target, and its phase, `Open` or `Done` |
| `left_behind`, after `moves` | Per record key: the SHA-256 of the fields a push would send for a settings copy Start empty left on the device (below) |

### Moving between providers (0054, Moving between providers)

- **The move marker** is the payload member `moved_from_icloud`: `{"tag", "fields"}`, the SHA-256 of the CloudKit base's archived system fields, which stands for its change tag, and the SHA-256 of each top-level member. It rides only in the push patch and never in a base. A pull strips it before any store, base or held write, and a member of the wrong shape reads as no marker.
- **A later mover lists the zone.** At move time it runs a full fetch from no change token that writes nothing, and reads a marked service record that neither the listing nor its store holds as deleted on iCloud, beside its own deletions. There is no listing when the zone is gone, another Apple ID is signed in, or iCloud is forbidden.
- **Off to TablePro Sync** is a first upload, not a move, even with an iCloud state file left from before: that file is deleted under a policy read. A first upload is refused while iCloud is the provider.
- **The move row.**
  - The iCloud file a move leaves runs no pass while it holds a row whose target is the service, in either phase.
  - The service file writes `Open` in the commit that lets go of the device's personal data, and `Done` when the arrival ends. The row goes once the app opens sync with the move's target as its provider.
  - A stale file's row authorizes nothing, and its refill drops it.
  - `SyncService::open_move` gives the app the move in flight, its target and whether it is done, and sync resumes it as it opens.

### Another account (0054, The engine and Another account or server; 0066, Rules)

- **On TablePro Sync,** the app keeps `SyncConfig.service_account`, opaque text from `SyncService::service_account`, which names the last sign-in until the person chooses. A start under another account or another server, not a new sign-in of the same account, counts the last file's unsent changes and writes the `AccountChoice` wait into the new file. The last file stays until the person answers, for the count, and the choice deletes it. Team scopes keep syncing. The wait comes from the text the host keeps on every start, so a restored state file cannot erase it.
- **On iCloud,** the engine counts the last account's file, deletes it at once as 0054 has it, and writes the same wait.
- **The prompt** shows the count of unsent edits first (`SyncService::plan_new_identity`).
- **Start empty**, on either provider:
  - The records this device synced leave it, through the store adapters, and stay with the old account. Nothing is deleted there.
  - Local only records and records this build cannot read stay.
  - The device fills from the new account's full fetch.
  - Settings stay and are not uploaded as creates. Start empty marks each settings kind for refill and writes one `left_behind` row per settings copy that syncs, so the new account's copy wins on pull. A create, or a revival over a tombstone, whose digest still matches its row sends nothing. The row goes once a live base exists or the copy changed, so a category goes up only after the person edits it on this device. Upload Again clears the rows.
- **After an integrity recovery**, the account choice is asked again. Any recovery, a restored file's repair, a stale file, a file with no anchor or lost under its anchor, or a foreign copy started over, writes `PushWait::AccountChoice` on the personal scope row in its own commit, over an Upload Again wait, making the row when there is none. Its count is `PushWait::UNCOUNTED` until an engine counts what the device would send, on its next pass or plan. Nothing personal goes up until the person picks. `start_over` clears `left_behind` with the other sync tables, and asking again is the answer: Start empty writes the rows again.
- **A zone another device made again** leaves this device download-only until its own Upload Again. A later fetch that reaches the new zone does not clear the wait. 0066 said "as the Swift engine did"; the Swift engine resumed uploads once a download reached the new zone (`SyncSettlement.needsUpload`).

### Policies (0055, When a value applies and PersonalSyncProvider)

- **CloudKit calls are fenced.** The core checks the iCloud policy before and after each call of the CloudKit transport, and a failed check answers `sync.icloud.restricted`.
- **A forbidden TablePro Sync** rests personal data for the life of the `SyncService`, an engine it restarts included. No move or mode change brings it back.
- **A forbidden server** stops the service engine, teams included.
- **Forced iCloud** stops TablePro Sync's personal sync at once, keeping team scopes, and waits for the person's confirmed move back. No move starts by itself.
- **Forced TablePro Sync with iCloud forbidden** moves forward when the app asks, from the iCloud state file's bases, with no last iCloud pass and no zone fetch, so it lists no iCloud deletions.
- **The policy gate.** `tablepro_account::PolicyGate` orders managed policy changes against the commits that act on them.
  - `Account::apply_policy` applies a change inside `PolicyGate::change`. It blocks the host's calling thread until the reads in flight end and holds new reads back, so a change lands wholly before a commit, which is then refused, or after it, when the next step is refused.
  - Each commit that writes a move row, or ends a move back, holds a read from its policy check until it lands. Move checks that commit nothing read through the gate too.
  - Team Library's publish, import and Keep Mine commits read the server's policy through the same gate.
  - A commit that only drops a move row, a finished one the app kept or a stale file's, checks nothing.
- **The arrival pass holds no gate.** The data commits of a forward move's arrival, pulled pages and push answers, store only what was pulled or what the server already took, so nothing leaves the device through the gap. The next stop check rests personal data once the watcher applies the change. This narrows 0055's "a pass under a provider that stops being allowed commits nothing more".

## Consequences

- A sign-in to another account or server asks before anything personal goes up, and a restore or a reinstall of the state file asks again.
- Start empty never uploads the device's settings to the new account until the person edits them.
- A policy change waits on the host's thread for the commits in flight, each from its check until it lands.
- A device whose zone another device made again stays download-only until its person acts, where the Swift engine resumed uploads.

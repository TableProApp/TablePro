# 0054: One sync engine in the core for TablePro Sync and iCloud

- **Status**: Accepted; amends 0010 and 0044
- **Date**: 2026-11-25

## Context

[0010](0010-macos-on-the-core.md) moves the Mac onto the core in slices and keeps the CloudKit transport in Swift: the container and zone, subscriptions, the record cache, dirty and deleted tracking, push batches and the rebase of a refused push. The core maps field values and never names CloudKit. [0044](0044-sync-through-one-service-run-by-us-or-on-premises.md) makes `tablepro-sync` the TablePro Sync client of all four apps, keeps iCloud beside it on the Mac and iPhone, and asks for one field merge that CloudKit and the service share, with some pulled fields applied only after approval.

The iCloud engine today:

- **Size.** 7,945 lines of Swift in `apple/TablePro/Core/Sync`, `TableProSyncTransport` and `TableProSync`, and 1,415 more in the iOS app's `Sync` folder. Each app runs a coordinator and a record mapper of its own.
- **State.** One change token, dirty and tombstone keys per record type in UserDefaults, and one archived `CKRecord` per record in `SyncRecordCache`, which a push merges against.
- **Rules,** in `.claude/rules/data-sync-storage.md`:
  - a record this build cannot read is met by its id and its standing, and its pulled changes and deletions are held by id;
  - a deletion for a category that is off waits;
  - a full fetch infers deletions;
  - a removed zone asks before anything is uploaded again.
- **Callers.** 16 files outside `Core/Sync` mark changes through `SyncChangeTracker`.
- **iOS** reads 5 of the 12 record types and pushes the same 5 (`IOSSyncCoordinator.swift:41-43`).
- **A shipped defect.** On `unknownItem`, a push recreates the whole record (`SyncRecordEdit.swift:72,112`). A reorder on one Mac after a deletion on another brings the deleted record back when the reorder moved it.
- **The core's mapping is unused.** Slice 1a's `ConnectionLibrary::cloud_edits` and `apply_cloud_pull` cover groups and connection placement. Only the account code imports `TableProFFI`.

The service engine needs the same rules: records it cannot read, Local only connections, refill after a lost base, batching, the rebase of a refused write, approvals. Built beside a Swift CloudKit engine, each rule would live twice, in two languages, which 0010 exists to end.

The review of the sync plan recommended sharing only the pure parts for this milestone: the field merge, the field classes, approvals and the settings registry, with the Swift engine kept as 0010 has it. On 2026-11-25 the maintainer decided instead to move the whole iCloud engine into the core, with CloudKit as a Swift transport and a dual write for downgrades. The maintainer also froze iCloud at the record types it carries: the 12 of today and `ConnectionProject`, which #4376 adds.

## Decision

One engine in `tablepro-sync` syncs every app with TablePro Sync and the Apple apps with iCloud. Each provider is a transport under it: TablePro Sync's is Rust, over the generated `/v2` client, and iCloud's is CloudKit, which the Swift apps implement behind a callback interface. For both, the engine owns the record cache, dirty and deleted state, standing, held changes, deferred deletions, the rebase of a refused push and batching. Swift keeps the UI, the Keychain, CloudKit's operations, subscriptions and the account status. iCloud gains no record type or field, and every new kind is TablePro Sync only. While the previous stable still runs the Swift engine, the Mac also writes the Swift sync metadata after every pass, so that build can take over.

## How it works

### Crates

| Crate | Holds | Depends on |
| --- | --- | --- |
| `tablepro-cloud-api` | The generated `/v2` client with its bearer hooks and its problem and 429 mapping, moved out of `tablepro-account` | no workspace crate |
| `tablepro-records` | Kinds, wire schemas and record ids; field classes; each platform's settings option registry; the field-map three-way merge; the sort and cycle rules; RFC 7396 diff and apply; a mirror of the server's secret-key rule; the CloudKit projection (`tablepro_storage::cloudkit` moves here) and the schema registry | `core`, `storage` |
| `tablepro-keys` | The end-to-end crypto (0053) | no workspace crate |
| `tablepro-sync` | The engine and its state file, the `Transport` and `RecordAdapter` traits, the service transport, the scheduler, approvals, team conflicts, moves between providers and the end-to-end flows | the three above, `account`, `storage` |

`ffi` gives the apps a `SyncService` and a listener that only signals ([0002](0002-uniffi-bindings.md)).

### The engine

- **Transports.** A `Transport` pulls a page from a cursor and pushes a batch. It answers each record with a value: applied with its new change tag, conflict, gone, or refused with a code. A conflict names the stored record's change tag, not its fields. On the service it also carries the version, revision and epoch and whether the record is a tombstone, as [0051](0051-sync-protocol-and-record-rules.md) has it.
- **Adapters.** Each kind has a `RecordAdapter` over its core store. Settings take a `HostSettings` adapter that each app implements, since each platform keeps them its own way.
- **A pass** pulls, then pushes.
  - A pull merges three ways against the base, then writes the store, the bases, and last the cursor or change token. A crash replays it with no effect.
  - A push builds its batch from the diff and splits it by bytes and on CloudKit's `limitExceeded`. On a conflict the engine reads the stored copy, merges it field by field against the base, and pushes again on the stored tag. On the service it pulls the record, since the conflict answer holds no fields. On CloudKit it takes the copy `serverRecordChanged` carries, and fetches the record by name when the error carries none.
- **Dirty state is a diff.** A record is dirty when its store copy differs from its base. It is deleted when its base exists, the store lacks it, and the adapter does not hold it as unreadable. Create-once kinds, such as history entries, differ: a local prune drops the entry and its base and pushes nothing, and a deletion goes up only from a tombstone the store keeps, until it is pushed, when the person deletes an entry or clears history. The diff leaves out fields held for approval, fields a rejection keeps as device-local overrides, and fields a pull drops. Each store's write path calls a change journal that names the kind and asks for a pass soon. The diff, not the journal, decides what goes up, so a missed call delays a push and loses nothing. This replaces 0044's dirty mark before the store write and the Mac's "Persist, then notify".
- **Store identity.** Each store keeps a generation id and a write sequence, and the state keeps both beside the bases.
  - A new generation means the file was restored from `.backup`, replaced or copied in. A lower sequence means it went back in time, as after a Time Machine restore.
  - Either one puts that store's kinds into refill: the pull wins, local records the provider has never seen go up as creates, then the diff runs again. That is how the saved queries' `sync_refill` works today.
  - Another process and a hand edit keep the generation, so their changes stay edits. `IntegrityStampedFileStore` and the iOS `LibraryFile` write a new generation when they restore.
- **The offline queue is on disk:** the diff, plus the batch in flight with its idempotency key on the service. Team Library's unsent edits stop living only in memory.
- **Rules for both providers.** Each rule the Swift engine has is ported with a test before its Swift code goes:
  - a record this build cannot read meets sync by its id and its standing, never by its payload. Its pulled changes and deletions are held by id. Unknown kinds and fields are kept and sent back unchanged;
  - Local only and sample connections never leave the device;
  - a category that is off sends nothing, and a deletion pulled for it waits until the category is read;
  - a full fetch treats a record it did not return as deleted, and an expired change token starts one;
  - a removed zone clears the state, and Upload Again asks before anything is sent;
  - another iCloud account clears the state: the engine deletes the old account's file and starts the new account's from a full fetch;
  - a content edit revives a record deleted elsewhere, and a placement edit (order, parent, group, favourite) never does. On `unknownItem`, a placement-only edit is dropped instead of recreating the record, which ends the defect above;
  - approval-required fields wait for the person on both providers. The first run of the engine loosens no consent the device has today:
    - each decision an app's consent store holds, such as the Mac's approved environment variable references and local credentials, moves into the core as it stands, refusals and the not yet asked included;
    - a value the device applies today without asking, such as a host or startup SQL an iCloud pull brought, counts as approved, so the upgrade asks nothing new;
    - a store that fails its integrity check grants nothing.
- **Scheduling.** One pass at a time per state file, and one process per state file under a file lock. A pass runs on a journal signal, at launch, on foreground, when the network returns, on a CloudKit push, on the service's poll interval, and on iCloud's fallback timer. A failure backs off with jitter and honors `Retry-After` and CloudKit's retry-after.

### The CloudKit transport

Swift implements one async callback interface. The core never calls it under a lock ([0002](0002-uniffi-bindings.md)). A pass that stops drops the call's future, which cancels the Swift task, and the task cancels its CloudKit operation. The names and shapes below are a sketch that the engine's lane fixes.

```rust
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait CloudKitTransport: Send + Sync {
    async fn account_status(&self) -> Result<CloudKitAccount, CloudKitFailure>;
    async fn ensure_zone(&self, account: String) -> Result<(), CloudKitFailure>;
    async fn delete_zone(&self, account: String) -> Result<(), CloudKitFailure>;
    async fn fetch_changes(&self, account: String, token: Option<Vec<u8>>) -> Result<CloudKitChanges, CloudKitFailure>;
    async fn fetch_records(&self, account: String, names: Vec<String>) -> Result<Vec<CloudKitFetched>, CloudKitFailure>;
    async fn modify(&self, account: String, saves: Vec<CloudKitRecord>, deletes: Vec<String>)
        -> Result<Vec<CloudKitOutcome>, CloudKitFailure>;
}

pub struct CloudKitRecord {
    pub record_type: String,
    pub name: String,
    pub system_fields: Option<Vec<u8>>,
    pub fields: Vec<CloudKitField>,
}

pub enum CloudKitValue {
    Text(String),
    Int64(i64),
    Double(f64),
    Timestamp(i64),
    Bytes(Vec<u8>),
    TextList(Vec<String>),
}

pub struct CloudKitChanges {
    pub changed: Vec<CloudKitRecord>,
    pub deleted: Vec<CloudKitDeletion>,
    pub unfetched: Vec<String>,
    pub token: Vec<u8>,
    pub more: bool,
}

pub enum CloudKitOutcome {
    Saved { name: String, system_fields: Vec<u8> },
    Deleted { name: String },
    ServerChanged { name: String, server: Option<CloudKitRecord> },
    UnknownItem { name: String },
    Failed { name: String, code: i64, retry_after_ms: Option<u64> },
}

pub enum CloudKitFailure {
    NoAccount,
    Restricted,
    AccountTemporarilyUnavailable,
    AccountChanged,
    TokenExpired,
    ZoneNotFound,
    ZoneDeletedByUser,
    LimitExceeded,
    QuotaExceeded,
    Network,
    Throttled { retry_after_ms: Option<u64> },
    Other { code: i64 },
}
```

- **System fields.** `system_fields` is what `CKRecord.encodeSystemFields(with:)` writes, and the base keeps it as bytes. Swift rebuilds the record from it with `CKRecord(coder:)`, sets the fields and saves with `.ifServerRecordUnchanged`, so the change tag still guards every save. A create sends none.
- **Field values** cross as CloudKit's own types.
  - `tablepro-records` maps them to core fields and back, for every record type.
  - It writes only the types and fields its schema registry lists as deployed to Production. The registry replaces Swift's `verifiedInProduction`. A Rust test compares it with `apple/CloudKit/production-schema.ckdb`, and `ProductionSchemaParityTests` stays.
  - It keeps writing the legacy fields that older builds read (`isReadOnly`, `colorTag`, `tagId`).
  - It stamps `modifiedAtLocal` and `schemaVersion`, which 0010 left to Swift.
- **Swift decides nothing.** It maps each `CKError` to an outcome or a failure and returns. Retries, batch splits, merges and the token are the engine's.
- **Every call is bound to one account.** `account` is the iCloud user record name the pass's state file is bound to.
  - The checks before and after an operation cannot close the gap between them, so CloudKit itself refuses a write meant for another account. A create and a deletion name their zone with `account` as its owner, not `CKCurrentUserDefaultName`, so that CloudKit refuses them under another signed-in user; the run against the Development container proves that refusal before the engine ships, and without it the lane finds another fence. A save rebuilt from system fields carries a change tag that no record of another account has, so CloudKit answers it with `unknownItem`, as the Swift engine sees today.
  - Swift also reads the current user record before it starts the operation and again when it ends, and fails the call with `AccountChanged` when either differs. The engine then discards the call's results, ends the pass and drops its state file's session.
- **Subscriptions and account changes stay in Swift.** A CloudKit push calls the service's `sync_now`. `CKAccountChanged` cancels the operations in flight, then calls `sync_now`, and the engine reads `account_status` and opens the state file of the account it finds.
- **One transport for both apps.** It lives in `TableProSyncTransport`, over `CloudKitSyncEngine`'s operations, so iOS uses the Mac's.

### The state file

- **One per provider and account.**
  - TablePro Sync: `<state>/sync/service/<digest>.db`, the digest being a hex SHA-256 over a fixed label, the sign-in key, which names the server and the account file, and the account id.
  - iCloud: `<state>/sync/icloud/<digest>.db`, over another label and the iCloud user record name.
  - `<state>` is `StoragePaths::state`. Only hex digits reach the path, so an account id a server chose cannot name another file. The identity itself is kept inside the file.
- **Format.** SQLite through sqlx in WAL mode, with migrations of its own. It is created with mode 0600 where the platform has modes. An upgrade copies it first, as [0012](0012-copies-before-a-format-upgrade.md) says.
- **Bound to its identity.** The file records the provider, server, account and device it was made for, and the engine refuses it for any other. Another account opens another file, so no base, cursor or queued change crosses accounts.
- **The key holder's state.** The TablePro Sync file of an account is the state file 0053 gives that device's key holder, and holds its key tables. iCloud files have none. What each key table holds, and its rules, are 0053's. Their names, encoding and freshness are set here.

| Table | Holds |
| --- | --- |
| `binding` | The provider, the server origin, the account id or iCloud user record name, the device id and the schema version; the file id, 16 random bytes set when the file is made; the write counter; the state MAC |
| `scopes` | Per scope: its type and role; on the service, its epoch, cursor, horizon and policies; on iCloud, the zone's change token; whether it is in refill |
| `stores` | Each store's generation id and write sequence |
| `bases` | Per (scope, kind, record id): the change tag (the service's opaque tag, or CloudKit's system fields), the version, the revision, and the fields as last agreed. Create-once kinds, such as history entries, keep no fields |
| `standing` | Per record id: syncs, Local only, or unknown |
| `held` | Records held by id, because they are unreadable, of an unknown kind or waiting for approval, with the change or deletion held |
| `deferred` | Deletions for a category that is off |
| `outbox` | The batch in flight: scope, idempotency key, request digest and age |
| `approvals` | Pulled values waiting for the person, and rejections kept as device-local overrides |
| `conflicts` | Team records whose field both sides changed: base, mine and theirs |
| `key_statements` | Every statement of each log the holder follows |
| `key_heads` | Each log's head |
| `key_pins` | The holder's own identity head, and per team the team head and the confirmed members |
| `key_comparisons` | Comparisons opened and not yet finished |
| `key_floors` | Key version floors and rotations pending |
| `envelope_counters` | Per envelope, the highest counter accepted and the hash of that ciphertext |
| `deleted_history` | History entry ids this device saw deleted |
| `legacy_mirror` | What the downgrade mirror last wrote |

### Integrity and freshness

- **Integrity.** The file carries 0053's state MAC, `HMAC-SHA256(key, LP("tablepro/v1/state") || LP(origin) || LP(account) || state)`, keyed from the device store.
  - `state` is `LP(file id) || LP(counter) || LP(digest)`, with the counter as 8 bytes big-endian.
  - The digest is SHA-256 over the key tables in the order the table above lists them. Each table is `LP(name) || LP(row count)`, then its rows in the byte order of their primary keys, each row the `LP` of each column's bytes in column order. iCloud files have no key tables, so their digest covers none.
  - The digest is computed again when a key table changes, and the MAC on every commit. A file whose MAC does not verify is refused.
  - One MAC covers the whole snapshot, so rows from two copies of the file cannot be mixed.
- **Freshness.** A MAC proves the file is this device's, not that it is the latest. Sealed state needs a monotonic counter kept apart from what it seals; this follows ROTE (Matetic et al., "ROTE: Rollback Protection for Trusted Execution", USENIX Security 2017), with the device store in place of a trusted counter.
  - Every commit raises the counter by one. The file's **anchor**, an item in the device store, holds the file id and a current entry: the counter, the MAC and the key tables' digest. A new file writes its anchor first.
  - **A commit writes its anchor in two steps.** Before the commit, the engine adds a pending entry to the anchor with the next counter, its MAC and its digest. After the commit, the pending entry becomes the current one. A commit starts only when no pending entry is left; while one cannot be settled, the engine stops.
  - **Apple platforms:** a Keychain item in the data protection keychain, `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` and not synchronizable. Apple Platform Security, "Keychain data protection", says items of that class don't sync to iCloud Keychain, aren't backed up and aren't in escrow keybags. Other ThisDeviceOnly classes do not serve: "Keybags for Data Protection" (Backup keybag) has them restored to the device they were backed up from. The anchor reads only while the device is unlocked, so a pass that starts locked waits. A device with no passcode uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and falls under the limit below.
  - **Windows:** a Credential Manager item with local machine persistence. **Linux:** a Secret Service item.
  - **On open,** with the anchor's file id:
    - a file that matches the current entry, with no pending entry, is fresh;
    - a file that matches the pending entry is fresh, since the commit landed and only the anchor's second step was lost. The engine finishes that step;
    - a file that matches the current entry while a pending entry remains may be a commit that never landed, or a commit that landed and a restore of the copy before it. Its sync tables refill. Its key tables stay trusted only when the pending digest equals the current one, so the commit in flight changed no key table; otherwise they are stale;
    - anything else is stale: an older counter, another file id, a file with no anchor, or an anchor with no file.
- **A stale file** is trusted for nothing.
  - Its sync tables go into refill, as a restored store does: the pull wins, records the provider has never seen go up as creates, then the diff runs again.
  - Its key tables are not trusted. The holder accepts no log, wrap or envelope and writes no secret until it pins again through a comparison with another holder of the account or with S, as 0053's device approval does. Its holder keys stay, so it is the same holder.
  - An anchor with no file, as after a reinstall that kept the device store, is handled the same way.
- **The limit.** A restore that brings back the file and its anchor together goes unseen on this device. On Linux a restore of the home folder brings back the keyring, and on Windows a restore of the user profile brings back Credential Manager. Such a device holds an older checkpoint, and until its next comparison with another holder the server can show it what 0053's threat model calls a rollback for a device that never saw the newer head. The Mac and iOS lanes check that a Time Machine restore and a device backup restore do not bring the anchor back; where one does, that platform falls under this limit too.

### Providers

- **Choice.** Each Mac and iPhone picks Off, iCloud or TablePro Sync for personal data. Linux and Windows offer Off or TablePro Sync. A managed device picks only among the providers [0055](0055-managed-policies-for-the-sync-provider-and-tablepro-app-traffic.md) allows. Team scopes always use the service.
- **The provider key.** `SyncSettings` gains a provider, and `enabled` keeps meaning "iCloud on". Choosing TablePro Sync sets the provider and turns `enabled` off.
  - The build that reads the key ships one release before the build that writes it.
  - That reader shows that this device syncs with TablePro Sync, which needs a newer TablePro, and never turns iCloud on by itself.
  - A build older than the reader sees iCloud off.
- **The Keychain follows the provider.**
  - On iCloud, secrets stay synchronizable items, as today.
  - On TablePro Sync, each secret gets a device-only item and an envelope. The synchronizable item stays, since deleting one removes it on every device.
  - Both forms stay readable.
- **No secret store.** A device without one, such as a Linux session with no Secret Service, syncs team records only, without their secrets. Under 0053, nothing personal reaches a device before it is approved, and approval needs device keys kept in a secret store.
- **History** syncs only through TablePro Sync.
  - The client keeps a window, the local retention setting. It pulls newest first, and pages older entries in when the history view asks.
  - A prune by the local retention pushes no deletion, as 0044 says. Only a deletion the person makes goes up.
  - An entry over the record limit stays local, with a notice.

### Moving between providers

**To TablePro Sync**, on each device:

1. A last iCloud push and pull, then the CloudKit transport stops.
2. A snapshot of the service.
3. Each local record goes up under its id:
   - as a create when the service lacks it;
   - otherwise as a three-way merge against the copy both providers last shared. When the service copy carries a move marker, that copy is the marker's. Otherwise it is this device's CloudKit base, mapped to core fields. With no common copy, every field that differs would read as changed on both sides, and the mover would win.
4. The first device that moves a record writes its **move marker**, an inert reserved field: the change tag of the CloudKit base it moved from, and a digest of each field's value in that base. A later mover leaves the marker as it is. Against a marker, a field counts as changed on a side when its value's digest differs from the marker's. So an edit a device made on iCloud after another device moved still reads as its own edit when it moves, and is not lost to the older service value.
5. Local only and sample connections, and categories this device has turned off, stay behind.
6. Keychain secrets are sealed into envelopes and get device-only copies.
7. iCloud turns off on this device. The zone stays until the person deletes it.

**Deletions made on a device still on iCloud.** A later mover deletes a service record when both of these hold:

- this device holds a CloudKit deletion for its id, or its id has a CloudKit base here and no local record;
- the service copy carries a move marker, and every content field still matches the marker's digest. Placement fields do not count, so a reorder on the service never keeps a record a device on iCloud deleted.

A copy whose content changed after the move is kept, since a content edit wins. A record with no marker was created on the service and is left alone.

**Back to iCloud.**
1. A last service pull.
2. For each service tombstone whose id has a CloudKit base, the engine fetches the CloudKit copy and deletes it when its content fields still equal the base's. A copy whose content another device changed on iCloud is kept, as above. CloudKit deletes without a change tag, so an edit another device saves between that fetch and the deletion is lost, as it is for any iCloud deletion today. The fetch keeps that window to one round trip.
3. iCloud turns on as it does today.

**Mixed devices.** A device that moves stops syncing with devices still on iCloud, and the move sheet says so.

**Another account or server.** The person picks Move my data or Start empty. Nothing goes up to another account without that choice.

### The Apple apps on the engine

- **First launch** imports the Swift metadata once:
  - the change token;
  - the `SyncRecordCache` records, as bases;
  - tombstones, as pending deletions;
  - standing, and the held and deferred sets.

  The diff against those bases then finds the unsent edits that the dirty keys named.
- **Downgrade mirror.** While the previous stable runs the Swift engine, the Mac writes what that build reads.
  - After every committed pass: the change token, the dirty and tombstone keys, standing, the held and deferred sets, and the `SyncRecordCache` files, rebuilt from the bases and their system fields.
  - On every journal signal, offline too: the dirty and tombstone keys of the records that write changed, after the store write as `SyncChangeTracker` does today. An edit made with no network, then a downgrade before the next pass, still reaches the previous stable as an upload, and a deletion as a tombstone.

  The mirror records what it wrote. At launch, Swift metadata that differs from that record means an older build ran in between, and the engine imports it again. Comparing the token alone would miss a run that only pushed. The mirror and `SyncRecordCache` go once the previous stable runs the engine.
- **No CloudKit schema change.** Records, names and fields stay as they are.
- **iOS** runs the same engine and transport. It keeps every record type iCloud carries, including those it shows no UI for. It writes the mirror too, unless its lane shows iOS has no path back to an older build; TestFlight to the App Store counts as one.
- **Removed from Swift** once core tests cover each rule:
  - both `SyncRecordMapper`s;
  - `SyncRecordEdit`, `SyncConflictRebase`, `SyncJSONMerge` and `SyncSettingsDocument`;
  - `SyncChangeTracker`, whose 16 callers move to the journal;
  - `SyncScope`.

  `ConnectionLibrary::cloud_edits` and `apply_cloud_pull` go with them.

## Rationale

- **One home per rule.** Each sync rule is written once in Rust, tested against a fake of each transport and fixed once. The defect on `unknownItem` ends for every app with one rule.
- **Approvals cover iCloud.** A pulled host or startup SQL waits for the person on iCloud too, as 0044 asks of every pull. With only the pure parts shared, the Swift engine would still have needed the core's approval queue and its state.
- **The move between providers runs in one process over one state.** It reads the CloudKit bases and deletions and writes service records in the same engine, and its three-device test runs in Rust on two fake transports.
- **iOS stops dropping data.** It keeps every record type the Mac syncs, through the same adapters.
- **CloudKit stays in Swift where it has to.** The framework, the device's iCloud account and push delivery exist only in the app. The transport carries values and decides nothing, so the engine is tested without CloudKit.
- **An async callback** lets Swift call CloudKit's async API on its own executor, so no core thread waits on CloudKit, and dropping the call cancels the operation.

## Consequences

- **The path most users run is rewritten.** Every Mac and iPhone with iCloud on moves to new code. Each Swift rule is ported with a test before its code goes, and the downgrade test runs real builds of the previous stable.
- **It costs more now.** The CloudKit engine and the Mac's and iPhone's moves onto it are planned at 28 to 46 agent-hours, against 9 to 15 for sharing only the pure parts. The work sits on the critical path of the first macOS release with TablePro Sync.
- **A dual write lives for one stable cycle.** The mirror is extra code, deleted after that cycle. A defect in it can hand the previous stable stale marks, so its test checks that the previous stable pushes the unsent edits and overwrites nothing newer.
- **The core names CloudKit.** `tablepro-records` knows its record types, field types and schema registry, and `tablepro-sync` its outcomes. Linux and Windows build that code and never call it.
- **CloudKit deletions stay unconditional.** CloudKit has no change tag on a deletion, so the content-edit rule holds on iCloud only when the deletion reaches CloudKit first, as today.
- **Every CloudKit call crosses the FFI.** A pass makes a few calls per page or batch, not one per record.
- **Until an app runs the engine,** a fix to one of its sync rules lands in Swift, and again in Rust once that rule is ported.
- **A restored state file costs a comparison.** After a restore, a reinstall that kept the device store, or a copied-in file, the device asks another device or S once before it handles secrets again, and its sync data refills.
- **This amends 0010.**
  - Swift keeps the container, zone operations, subscriptions and the account status.
  - The record cache, dirty and deleted tracking, push batches and the rebase move into the core.
  - `tablepro_storage::cloudkit` moves into `tablepro-records` and covers every record type, and the core stamps `modifiedAtLocal` and `schemaVersion`.
- **This amends 0044.**
  - The client is four crates.
  - Dirty state is a diff, not a mark before the store write.
  - State is one file per provider and account.
  - The move from iCloud merges against the copy both providers last shared, kept in a move marker, and carries the deletion rule above, in place of creates from `base_version` 0.
  - Keychain items get device-only copies instead of becoming device-only.
- **The sync rows** of `.claude/rules/data-sync-storage.md` are rewritten for the engine when the Mac moves onto it.

## Verification

- **Rust:**
  - a fake CloudKit with change tags, `serverRecordChanged` with the server's copy, `unknownItem`, `limitExceeded`, token expiry and a removed zone;
  - the shared merge fixtures through both transports, and each ported rule;
  - both crash windows, and a restored store going into refill;
  - a history prune followed by a pass pushes nothing, and a history entry the person deleted goes up after a restart;
  - an iCloud account change between `account_status` and `modify`, and while a fetch completes, saves nothing to either account;
  - an older copy of a state file with a valid MAC opens stale: its sync tables refill, and its key tables are trusted only after a comparison;
  - a crash at each step of a commit and its anchor opens as the rules say. A restore of the copy before a commit whose anchor did not settle leaves the key tables untrusted when that commit changed them;
  - a file with no anchor, and an anchor with no file, both need a comparison before any log is trusted;
  - a key table row copied from another copy of the file fails the MAC;
  - the first run keeps every consent decision and refusal, and leaves an unapproved synced connection unapproved;
  - the moves with three devices on two fake transports: a deletion on iCloud after another device moved, with and without a later content edit or reorder on the service; an edit on iCloud after another device moved; a record created on the service after the move; and the move back.
- **Bindings:** Swift tests over a Swift fake transport.
- **Apps:**
  - the import from fixtures, and the import again after a downgrade and an upgrade;
  - the downgrade test with the previous stable's build, after a pass and after offline edits and deletions with the app quit before the next pass;
  - `ProductionSchemaParityTests` unchanged;
  - a run against the Development container, including a switch to a second iCloud account, with the zone, after the check before an operation and before CloudKit receives it: neither account gets a write.

## Alternatives considered

- **Share only the pure parts.** The field merge, field classes, approvals and the settings registry go in the core, and the Swift engine stays as 0010 has it. The plan's review recommended it for this milestone: it leaves the path most users run alone, needs no dual write and costs less. The maintainer chose the whole move, since the service engine needs the same rules: each would live in Swift and in Rust, and iOS would keep its partial copy.
- **CKSyncEngine.** It needs macOS 14, and the Mac supports 13.0. It would also be a second engine beside the service's, with state of its own.
- **CloudKit Web Services from Rust.** A transport with no Swift, but each person would sign in to Apple again for a web token, which the framework gets from the device's account, and push delivery would still need the app.
- **One state file per device, with a provider column.** An account switch, a move and a sign-out would delete rows across tables in step. A file per identity is deleted whole and is never read for another account.
- **An HMAC alone over the state file.** It proves the file is the device's, not that it is the latest, so a backup copy passes.
- **A checkpoint the holder signs and keeps on the server.** The server cannot forge it but can serve an older one, and a device's old cursor tells it when a restore happened.
- **A MAC per row.** Rows from two copies of the file would each verify, and could be mixed.
- **A blocking callback,** as `HostWebAuthenticator` is. Each CloudKit call would hold a core thread for its whole round trip, and Swift would wait on its own async API with a semaphore.

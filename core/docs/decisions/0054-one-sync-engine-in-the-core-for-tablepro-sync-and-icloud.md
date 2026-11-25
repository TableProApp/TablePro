# 0054: One sync engine in the core for TablePro Sync and iCloud

- **Status**: Accepted; amends 0010 and 0044; the change journal, what a store is and the restore path amended by 0060
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
| `tablepro-keys` | The end-to-end crypto ([0056](0056-end-to-end-keys-per-account-and-device.md)) | no workspace crate |
| `tablepro-sync` | The engine and its state file, the `Transport` and `RecordAdapter` traits, the service transport, the scheduler, approvals, team conflicts, moves between providers and the end-to-end flows | the three above, `account`, `storage` |

`ffi` gives the apps a `SyncService` and a listener that only signals ([0002](0002-uniffi-bindings.md)).

### The engine

- **Transports.** A `Transport` pulls a page from a cursor and pushes a batch. It answers each record with a value: applied with its new change tag, conflict, gone, or refused with a code. A conflict names the stored record's change tag, not its fields. On the service it also carries the version, revision and epoch and whether the record is a tombstone, as [0051](0051-sync-protocol-and-record-rules.md) has it.
- **Adapters.** Each kind has a `RecordAdapter` over its core store. Settings take a `HostSettings` adapter that each app implements, since each platform keeps them its own way.
- **A pass** pulls, then pushes.
  - A pull merges three ways against the base, then writes the store, the bases, and last the cursor or change token. A crash replays it with no effect.
  - On the service a pull applies key objects before what depends on them: a delta page holds whole change sets ([0051](0051-sync-protocol-and-record-rules.md), Pull), and the key objects of a snapshot wait until the pull is caught up (0051, Pull), then go in as one set before its envelopes (0056, Rollback). While it applies deltas, the engine tracks the scope key version in force at each place in the revision order. The `scopes` row stores it with the cursor, in the same commit, and only applying a pull moves it; a push does not.
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
- **The device's key state.** The TablePro Sync file of an account holds that device's key tables: the key objects, pins and versions 0056 keeps under this file's MAC and anchor (0056, Pins and Rollback). iCloud files have none. 0056 sets the rules; this ADR holds the column list, the encoding and the freshness.

| Table | Holds |
| --- | --- |
| `binding` | The provider, the server origin, the account id or iCloud user record name, the device id and the schema version; the file id, 16 random bytes set when the file is made; the write counter; the state MAC |
| `scopes` | Per scope: its type and role; on the service, its epoch, cursor, the scope key version in force at that cursor, horizon and policies; on iCloud, the zone's change token; whether it is in refill |
| `stores` | Each store's generation id and write sequence |
| `bases` | Per (scope, kind, record id): the change tag (the service's opaque tag, or CloudKit's system fields), the version, the revision, and the fields as last agreed. Create-once kinds, such as history entries, keep no fields |
| `standing` | Per record id: syncs, Local only, or unknown |
| `held` | Records held by id, because they are unreadable, of an unknown kind or waiting for approval, with the change or deletion held |
| `deferred` | Deletions for a category that is off |
| `outbox` | The batch in flight: scope, idempotency key, request digest and age |
| `approvals` | Pulled values waiting for the person, and rejections kept as device-local overrides |
| `conflicts` | Team records whose field both sides changed: base, mine and theirs |
| `legacy_mirror` | What the downgrade mirror last wrote |

The key tables, in digest order. Columns are listed in order, the primary key first:

| Table | Columns | Holds |
| --- | --- | --- |
| `key_objects` | `scope`, `kind`, `record_id`; `fields`, `applied` | Each key object's `fields`, as the server served them or as this device wrote them, one row per 0052 record id. After a new epoch the device pushes back, with the same fields, those the server lacks (0051, After a restore). What cannot go back stops or ends its scope in `key_versions` (0051, What cannot go back). `applied` is set once an object is in force: served by the server, or written by this device and applied by it. Every key kind is create-only, so at the id of an applied object a different object is refused with an alarm (0056, Rollback). An object not applied, this device's own candidate, gives way to whatever the server later serves at its id. The device pushes its own candidates again until they apply or give way. A `key.reset` row stays while the reset is pending and goes with its tombstone |
| `key_pins` | `account`; `ik`, `av`, `how`, `alert`, `replaced` | Per account the device meets, its own included: the pinned IK, the newest `av` verified under it, how it pinned (`first_use`, `compared` or `replaced`), whether an alert is open, and the IKs it saw replaced, 32 bytes each in the order replaced, which it never goes back to |
| `key_device_pins` | `key_device`; `dek`, `dsk` | Own-device pins: each key device of the account this device compared with, with the DEK and DSK the words covered, never taken from a certificate (0056, Approving a device). A device approved again keeps only its approver here |
| `key_versions` | `scope`, `purpose`; `version`, `record`, `holders`, `state`, `epoch` | The newest version of each scope key the device verified, and `record`, the SHA-256 of that version record's signed bytes. It never writes below that version, a version record below it is historical, and at it only the record with that digest counts (0056, Rollback). `holders`, for a team row, is the holders the device accepted for that version under Advancing: the version's signer, then each recipient of a wrap it accepts. It is a sorted, duplicate-free list of (account id, accepted IK) pairs, encoded as `u32` count, then per pair the 16-byte account id and the 32-byte IK, ascending by account then IK; personal and history rows hold a count of 0. While the scope is stopped it does not change. A signer matches a pair when its account is the pair's and its IK is the pair's or one reachable from it through a verified chain of endorsed replaces with no unendorsed reset in it; an IK after an unendorsed reset does not match (0056, Teams, Holders). `epoch` is null unless the row ended. `state` is `ok`, `stopped` while a catch-up or a restore leaves the device waiting (0056, Teams), or `ended`, which nothing clears, with `epoch` the epoch it ended in (0051, What cannot go back). An approval merges these as 0056 step 7 says |
| `key_envelopes` | `scope`, `record_id`; `kv` | Per envelope, the highest `kv` the device accepted. It never takes a copy under a lower one (0056, Rollback) |
| `key_comparisons` | `session`; `role`, `peer`, `view`, `state`, `expires_at` | Comparison sessions: the view this side fixed and the session's state (0056, Approving a device). A session that ended keeps its row until its request is purged, so its words never show twice |
| `key_pending` | `flow`; `state` | Key flows that span pushes and must survive a crash: an account rotation's team rotations still to write, with the members its review marked for removal; an approval this device is completing; a reset this device proposed, whose new private keys wait in the device store until it activates or ends; and a stop report to withdraw, written in the same commit as the move to `ok` or `ended` and sent again after a restart until the server answers, before any new report for that team. The engine resumes them at the next pass |
| `deleted_history` | `record_id` | The ids of history entries with a `user` tombstone |

`scope` is the scope id, `account` and `key_device` the 16 bytes of an account or key device id, and `purpose` `personal`, `history` or `team` (0056).

A device that erases its keys, on Sign Out or when another account signs in on its row (0056), clears its key tables in the same commit, so its next checkpoint is empty and it joins again as a new device would. An approval merges what the trust plaintext gives into its key tables in one commit (0056, Approving a device), with its new device keys and key device id. A device left out of a rotation, or told `device_removed`, locks and keeps them.

### Integrity and freshness

- **Integrity.** The file carries the state MAC, `HMAC-SHA256(key, LP("tablepro/v1/state") || LP("tp1") || LP(origin) || LP(account) || state)`, in 0056's encoding: `LP(x)` is a u32 big-endian length, then the bytes of `x`. Its key is the **state MAC key**: 32 random bytes in a device-store item of its own per state file, in the anchor's class, device-only, never synced or exported. A file whose state MAC key is gone cannot verify, and opens as a file with no anchor.
  - `state` is `LP(file id) || LP(counter) || LP(key digest) || LP(sync digest)`, with the counter as 8 bytes big-endian.
  - **The key digest** is SHA-256 over the key tables in the order the column list gives. It frames with `LP`. Each table is `LP(name) || u32(row count)`, then its rows in the byte order of their encoded primary keys. A row is its values in column order. A value is one byte, 0 for null and 1 otherwise, then for a present value `LP` of its bytes: text as UTF-8, an integer or flag as 8 bytes big-endian, bytes as they are. iCloud files have no key tables, so their key digest covers none.
  - **The sync digest** is SHA-256 over every other table, in the order the table above lists them, framed the same way, with each row's columns in the order the file's schema version defines. `binding` goes in without its state MAC column, since that MAC is computed over this digest. Bases, approvals, cursors and the outbox decide what a pass sends and applies, so a local writer must not swap them either.
  - Each digest is computed again when its tables change, and the MAC on every commit. A file whose MAC does not verify is refused.
  - One MAC covers the whole snapshot, so rows from two copies of the file cannot be mixed. The key digest stays apart because the anchor's checks use it.
- **Freshness.** A MAC proves the file is this device's, not that it is the latest. Sealed state needs a monotonic counter kept apart from what it seals; this follows ROTE (Matetic et al., "ROTE: Rollback Protection for Trusted Execution", USENIX Security 2017), with the device store in place of a trusted counter.
  - Every commit raises the counter by one. The file's **anchor** in the device store is a small root item and the checkpoint items it names. A new file writes its anchor first.
  - **The root** holds the file id, a current entry and at most one pending entry. An entry holds the counter, the MAC, the key tables' digest and the digest of its checkpoint.
  - **The checkpoint** holds what only moves forward:
    - each `key_pins` row, so a restored file cannot forget a newer `av`, an IK it saw replaced or an open alert;
    - each `key_versions` row, so it cannot forget a newer scope key version, take another record at it, or forget that a scope stopped or ended;
    - each `key_envelopes` row, so it cannot take an envelope it held back under an older version.

    `key_objects`, own-device pins, comparisons, pending flows and `deleted_history` stay in the file alone.
  - **Size.** A checkpoint is written to items of its own only when it changes, before the entry that names it, and items no entry names are deleted once the entry settles. Each commit rewrites only the root. A checkpoint grows with the accounts pinned, the scope keys held and the envelopes held, about 60 bytes an envelope.
  - **A commit writes its anchor in two steps.** Before the commit, the engine writes the new checkpoint when it changed, then adds a pending entry to the root with the next counter, its MAC and its digests. After the commit, the pending entry becomes the current one. A commit starts only when no pending entry is left; while one cannot be settled, the engine stops.
  - **Apple platforms:** Keychain items in the data protection keychain, `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` and not synchronizable. Apple Platform Security, "Keychain data protection", says items of that class don't sync to iCloud Keychain, aren't backed up and aren't in escrow keybags. Other ThisDeviceOnly classes do not serve: "Keybags for Data Protection" (Backup keybag) has them restored to the device they were backed up from. The anchor reads only while the device is unlocked, so a pass that starts locked waits. Turning the passcode off deletes every item of that class (Apple's `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` documentation), so the device then has a file with no anchor, which is approved again as below. A device with no passcode keeps its anchor in `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which a backup restores to the same device, and falls under the limit below.
  - **Windows:** Credential Manager items with local machine persistence. A checkpoint is split over numbered items, since one item's blob holds at most 2,560 bytes. **Linux:** Secret Service items.
  - **On open,** with the anchor's file id:
    - a file that matches the current entry, with no pending entry, is fresh;
    - a file that matches the pending entry is fresh, since the commit landed and only the anchor's second step was lost. The engine finishes that step;
    - a file that matches the current entry while a pending entry remains may be a commit that never landed, or a commit that landed and a restore of the copy before it. Its sync tables refill. Its key tables stay trusted only when the pending entry's key-table digest equals the current one's, so the commit in flight changed no key table; otherwise they are stale;
    - anything else is stale: an older counter, another file id, a file with no anchor, or an anchor with no file.
- **A stale file** is trusted for nothing.
  - Its sync tables go into refill, as a restored store does: the pull wins, records the provider has never seen go up as creates, then the diff runs again.
  - Its key tables are not trusted, and the device keys stay, so it is the same device. It rebuilds the key tables from the key objects the server holds, accepting only what is at or above the anchor's checkpoint, the pending entry's when one is left:
    - for each anchored pin, a certificate under that IK at the anchored `av` or above, or under an IK that it endorsed, never under an IK the anchor lists as replaced. An alert the anchor holds stays open until the person re-confirms;
    - for each anchored scope key, the version record at the anchored version whose digest the anchor holds, then its successors. Older versions still open what they sealed, through the rings;
    - for each anchored envelope, a copy at the anchored `kv` or above.

    Until the server shows every anchored pin and version, it accepts no wrap or envelope and writes no secret.
  - An anchor with no file, as after a reinstall that kept the device store, rebuilds the same way.
  - A file with no anchor has no checkpoint. It handles no secret until another device approves it again, with new device keys and a new key device id as a new device has, and it starts from that device's pins and versions, or until the person recovers with the recovery key (0056). It falls under the limit below.
- **The limit.** Nothing on the device then proves a newer `av` or version than the ones it holds:
  - a restore that brings back the file and its anchor together goes unseen. On Linux a restore of the home folder brings back the keyring, and on Windows a restore of the user profile brings back Credential Manager;
  - a file with no anchor starts from what its approving device holds, so an approver that missed a newer version gives it that older view, as for a new device, and a recovery starts with no pins;
  - a stale file loses `deleted_history`, so the server can show again a history entry the person deleted.

  Until it meets the newer state, such a device faces what the threat model (0056) calls rollback for a device that never saw it. The Mac and iOS lanes check that a Time Machine restore and a device backup restore do not bring the anchor back; where one does, that platform falls under this limit too.

### Providers

- **Choice.** Each Mac and iPhone picks Off, iCloud or TablePro Sync for personal data. Linux and Windows offer Off or TablePro Sync. A managed device picks only among the providers [0055](0055-managed-policies-for-the-sync-provider-and-tablepro-app-traffic.md) allows. Team scopes always use the service, and so do the key objects in the personal scope, whatever the device picks, since team secrets need the account keys (0056).
- **The provider key.** `SyncSettings` gains a provider, and `enabled` keeps meaning "iCloud on". Choosing TablePro Sync sets the provider and turns `enabled` off.
  - The build that reads the key ships one release before the build that writes it.
  - That reader shows that this device syncs with TablePro Sync, which needs a newer TablePro, and never turns iCloud on by itself.
  - A build older than the reader sees iCloud off.
- **The Keychain follows the provider.**
  - On iCloud, secrets stay synchronizable items, as today.
  - On TablePro Sync, each secret gets a device-only item and an envelope. The synchronizable item stays, since deleting one removes it on every device.
  - Both forms stay readable.
- **No secret store.** A device without one, such as a Linux session with no Secret Service, syncs team records only, without their secrets. Under 0056, nothing personal reaches a device before it is approved, and approval needs device keys kept in a secret store.
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
2. For each service tombstone with `deleted_reason` `user` whose id has a CloudKit base, the engine fetches the CloudKit copy and deletes it when its content fields still equal the base's. A `policy` tombstone never deletes on iCloud, since a device keeps its copy of what a policy removed (0051). Before it deletes anything, the move-back sheet says how many iCloud records the move deletes and the person confirms, since a server can write `user` tombstones for any record it holds. A copy whose content another device changed on iCloud is kept, as above. CloudKit deletes without a change tag, so an edit another device saves between that fetch and the deletion is lost, as it is for any iCloud deletion today. The fetch keeps that window to one round trip.
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
- **A restored state file refills.** After a restore, a reinstall that kept the device store, or a copied-in file, the device's sync data refills. With its anchor, the device rebuilds its key tables from the server's key objects at or above the anchored checkpoint, with no comparison. With no anchor, another device approves it again, or the person recovers with the recovery key, before it handles secrets again.
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
  - an older copy of a state file with a valid MAC, its anchor intact, opens stale: its sync tables refill, and its key tables rebuild from key objects at or above the anchored checkpoint, with no comparison;
  - a crash at each step of a commit and its anchor opens as the rules say. A restore of the copy before a commit whose anchor did not settle leaves the key tables untrusted when that commit changed them, and rebuilds them on the pending checkpoint;
  - an anchor with no file rebuilds from key objects at or above its checkpoint; a file with no anchor handles no secret until it is approved again or recovered;
  - after a restore, a certificate below an anchored `av`, a version record below an anchored version, an envelope below its anchored `kv`, and a certificate under an IK the anchor lists as replaced are refused, and an alert the anchor holds stays open;
  - after a new epoch, key objects the server lacks are pushed back with the same fields in 0051's order, and a refusal is final: the scope ends and stays ended after a restart, even once another device puts the version back, while a version another account signed stops the team until it is back; a rotation this device pushed, then a restart before its next pull, then an envelope another device wrote under the old version before that rotation, taken; after a file-only restore, a version record at an anchored version with another digest is refused; a different object at the id of an applied one is refused, while the winner over this device's own candidate and a reset after two cancelled ones that the device was offline for are taken; a device that a rotation leaves out locks and keeps its key tables until an approval merges into them; a crash between an account rotation and its team rotations resumes from `key_pending` with the review's choices; a snapshot that serves envelopes before their key objects applies them in dependency order, and a delta page never splits a change set;
  - digest vectors cover a null, an empty value, a key object at the record limit, and `holders` in order, empty, after one endorsed replacement and after two during a stop, and after a reset during a stop;
  - a key table row copied from another copy of the file fails the MAC, and so does a base, approval, cursor or outbox row swapped in while the binding, counter and key tables stay current; writing the MAC changes neither digest;
  - after a restore, envelopes and history sealed under older key versions still open through the rings, when the restore kept those versions or devices pushed them back;
  - the first run keeps every consent decision and refusal, and leaves an unapproved synced connection unapproved;
  - the moves with three devices on two fake transports: a deletion on iCloud after another device moved, with and without a later content edit or reorder on the service; an edit on iCloud after another device moved; a record created on the service after the move; and the move back, where a `policy` tombstone deletes nothing on iCloud and nothing is deleted before the person confirms the count.
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
- **A checkpoint the device signs and keeps on the server.** The server cannot forge it but can serve an older one, and a device's old cursor tells it when a restore happened.
- **A MAC per row.** Rows from two copies of the file would each verify, and could be mixed.
- **A blocking callback,** as `HostWebAuthenticator` is. Each CloudKit call would hold a core thread for its whole round trip, and Swift would wait on its own async API with a semaphore.

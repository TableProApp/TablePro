// The Swift metadata into the state file (0054, The Apple apps on the engine, First launch): the change token, the
// `SyncRecordCache` records as bases, the tombstones as pending deletions, standing, and the held and deferred sets.
// The diff against those bases then finds the unsent edits the dirty keys named. Imported again when an older build
// ran in between, its metadata replaces what the state file held of the zone. A record with a value waiting for the
// person, or kept here after a rejection, keeps the base the state file holds: the push sends that base's value in
// those members, and the Swift metadata no MAC covers must not supply it.

use std::collections::{BTreeMap, BTreeSet};

use tablepro_records::Kind;
use tablepro_records::cloudkit::{record_name, record_type_named, record_type_of};
use tablepro_records::record_id::{self, shortened, uuid_id};
use tablepro_records::settings::owner;
use uuid::Uuid;

use super::super::fetch::SCOPE;
use super::super::fetch::copy::{self, Incoming};
use crate::adapters::approval;
use crate::api::cloudkit::{CloudKitFailure, CloudKitFetched, CloudKitRecord, CloudKitTransport};
use crate::api::error::SyncError;
use crate::api::ids::{ChangeTag, Cursor, KindName, RecordKey};
use crate::api::legacy::{LegacyMetadata, LegacyTombstone};
use crate::api::state::{
    BaseRow, DeferredRow, HeldReason, HeldRow, PushWait, Row, RowKey, RowRange, ScopeRow, Standing, StandingRow,
    StateTxn, Table,
};
use crate::api::transport::{DeletedReason, PulledRecord};

fn pulled(key: &RecordKey, tag: Vec<u8>, deleted: bool) -> PulledRecord {
    PulledRecord {
        kind: key.kind.clone(),
        record_id: key.record_id.clone(),
        tag: ChangeTag::CloudKit(tag),
        fields: None,
        fields_json: None,
        deleted: deleted.then_some(DeletedReason::User),
        service: None,
    }
}

// A base for a tombstone's record that neither the cache nor a fetch by name gave, whose deletion goes up by name.
fn bare(key: RecordKey) -> BaseRow {
    BaseRow {
        key,
        tag: ChangeTag::CloudKit(Vec::new()),
        version: None,
        revision: None,
        epoch: None,
        deleted: None,
        fields: None,
        created_ms: None,
    }
}

fn tombstone_key(tombstone: &LegacyTombstone) -> Option<(Kind, RecordKey)> {
    let kind = record_type_named(&tombstone.record.record_type)?.kind;
    let wire = shortened(kind, tombstone.record.id.clone());
    record_id::check(kind, &wire).ok()?;
    Some((kind, RecordKey::new(SCOPE, kind, wire)))
}

// `SyncBoundary.owner(of:)`: the tombstone's own owner, or the connection a column layout's category names.
pub(super) fn owner_of(kind: Kind, tombstone: &LegacyTombstone) -> Option<Uuid> {
    tombstone
        .owner
        .or_else(|| kind.is_settings().then(|| owner(&tombstone.record.id)).flatten())
}

// The connections whose records the Swift engine keeps off sync: those it was told to, and Local only ones.
pub(super) fn kept_off(metadata: &LegacyMetadata) -> BTreeSet<Uuid> {
    let local_only = metadata
        .standing
        .iter()
        .filter(|entry| entry.standing == Standing::LocalOnly)
        .map(|entry| entry.connection);
    metadata
        .owners_kept_off_sync
        .iter()
        .copied()
        .chain(local_only)
        .collect()
}

// A tombstone of a connection kept off sync, which the Swift engine never sent.
pub(super) fn kept_off_sync(kind: Kind, tombstone: &LegacyTombstone, kept_off: &BTreeSet<Uuid>) -> bool {
    owner_of(kind, tombstone).is_some_and(|owner| kept_off.contains(&owner))
}

// What the zone holds of a tombstone's record that the cache lacks.
#[derive(Debug, Clone)]
pub(super) enum ZoneCopy {
    Copy(CloudKitRecord),
    // The zone holds no such record: nothing to delete.
    Gone,
}

// Under the 400 items per operation that CloudKit's `limitExceeded` documentation gives as its guideline.
const NAMES_PER_CALL: usize = 200;

// Each tombstone's record the cache lacks, fetched by name, so its deletion goes up on the zone's copy as its base and
// a full fetch reads that copy as deleted here rather than as new. A name CloudKit does not answer fails the import,
// which the next pass runs again: a deletion with no base would come back as a new record. A removed zone holds none
// of them, and the pass's fetch finds it removed. Called outside any state transaction.
pub(super) async fn uncached(
    transport: &dyn CloudKitTransport,
    account: &str,
    metadata: &LegacyMetadata,
) -> Result<BTreeMap<RecordKey, ZoneCopy>, SyncError> {
    let cached: BTreeSet<&str> = metadata.cache.iter().map(|record| record.name.as_str()).collect();
    let kept_off = kept_off(metadata);
    let mut asked: BTreeMap<String, RecordKey> = BTreeMap::new();
    for tombstone in &metadata.tombstones {
        let Some((kind, key)) = tombstone_key(tombstone) else {
            continue;
        };
        let Some(name) = record_name(kind, &key.record_id) else {
            continue;
        };
        if !cached.contains(name.as_str()) && !kept_off_sync(kind, tombstone, &kept_off) {
            asked.insert(name, key);
        }
    }
    let mut zone: BTreeMap<RecordKey, ZoneCopy> = BTreeMap::new();
    let names: Vec<String> = asked.keys().cloned().collect();
    let mut calls: Vec<Vec<String>> = names.chunks(NAMES_PER_CALL).rev().map(<[String]>::to_vec).collect();
    while let Some(call) = calls.pop() {
        let answers = match transport.fetch_records(account.to_owned(), call.clone()).await {
            Ok(answers) => answers,
            Err(CloudKitFailure::LimitExceeded) if call.len() > 1 => {
                let (first, second) = call.split_at(call.len() / 2);
                calls.push(second.to_vec());
                calls.push(first.to_vec());
                continue;
            }
            Err(CloudKitFailure::ZoneNotFound | CloudKitFailure::ZoneDeletedByUser) => return Ok(BTreeMap::new()),
            Err(failure) => return Err(failure.into()),
        };
        for answer in answers {
            let (name, copy) = match answer {
                CloudKitFetched::Found { record } => (record.name.clone(), ZoneCopy::Copy(record)),
                CloudKitFetched::Missing { name } => (name, ZoneCopy::Gone),
                CloudKitFetched::Failed {
                    code, retry_after_ms, ..
                } => {
                    let failure = retry_after_ms.map_or(CloudKitFailure::Other { code }, |retry_after_ms| {
                        CloudKitFailure::Throttled {
                            retry_after_ms: Some(retry_after_ms),
                        }
                    });
                    return Err(failure.into());
                }
            };
            if let Some(key) = asked.get(&name) {
                zone.insert(key.clone(), copy);
            }
        }
    }
    if asked.values().any(|key| !zone.contains_key(key)) {
        return Err(SyncError::Malformed { what: "fetch by name" });
    }
    Ok(zone)
}

// The records the approval queue holds a value of.
async fn waiting(txn: &mut dyn StateTxn) -> Result<BTreeSet<RecordKey>, SyncError> {
    Ok(approval::held_members(txn, SCOPE)
        .await?
        .into_keys()
        .map(|(kind, record_id)| RecordKey::new(SCOPE, kind, record_id))
        .collect())
}

async fn clear(txn: &mut dyn StateTxn, waiting: &BTreeSet<RecordKey>) -> Result<(), SyncError> {
    for row in txn.scan(&RowRange::Scope(Table::Bases, SCOPE)).await? {
        if !matches!(&row, Row::Base(base) if waiting.contains(&base.key)) {
            txn.delete(&row.key()).await?;
        }
    }
    for row in txn.scan(&RowRange::Scope(Table::PendingBases, SCOPE)).await? {
        txn.delete(&row.key()).await?;
    }
    for row in txn.scan(&RowRange::Scope(Table::Held, SCOPE)).await? {
        if let Row::Held(held) = &row
            && matches!(held.reason, HeldReason::Unreadable | HeldReason::UnknownKind)
        {
            txn.delete(&row.key()).await?;
        }
    }
    for row in txn.scan(&RowRange::Scope(Table::Deferred, SCOPE)).await? {
        if let Row::Deferred(deferred) = &row
            && deferred.record.deleted.is_some()
        {
            txn.delete(&row.key()).await?;
        }
    }
    let connections = RowRange::ScopeKind(Table::Standing, SCOPE, KindName::of(Kind::Connection));
    for row in txn.scan(&connections).await? {
        txn.delete(&row.key()).await?;
    }
    Ok(())
}

// The zone the Swift engine saw, at its token. A kind this engine reads that the older build's last pull did not read
// starts a full fetch, as the Swift engine does when the types it reads grow.
async fn scope(txn: &mut dyn StateTxn, metadata: &LegacyMetadata, reads: &BTreeSet<Kind>) -> Result<(), SyncError> {
    let existing = match txn.get(&RowKey::Scope(SCOPE)).await? {
        Some(Row::Scope(row)) => Some(row),
        _ => None,
    };
    let seen = match metadata.zone_state.as_deref() {
        Some(state) => matches!(state, "confirmed" | "removed"),
        None => metadata.token.is_some(),
    };
    // What the zone's push waits for is this device's person's to lift, whatever the Swift metadata says.
    let held = existing.as_ref().and_then(|row| row.push_wait);
    if !seen {
        match (existing, held) {
            (Some(row), Some(_)) => {
                txn.put(Row::Scope(ScopeRow {
                    cursor: None,
                    caught_up: false,
                    ..row
                }))
                .await?;
            }
            (Some(_), None) => txn.delete(&RowKey::Scope(SCOPE)).await?,
            (None, _) => {}
        }
        return Ok(());
    }
    let read_all = reads
        .iter()
        .filter_map(|kind| record_type_of(*kind))
        .all(|record_type| {
            metadata
                .readable_record_types
                .iter()
                .any(|read| read == record_type.name)
        });
    let mut row = existing.unwrap_or_else(|| ScopeRow::new(SCOPE));
    row.cursor = metadata.token.clone().filter(|_| read_all).map(Cursor::CloudKit);
    row.caught_up = false;
    // The Swift engine saw the zone removed: nothing goes up until this device's person asks to upload again, even if
    // another device made the zone again before this build's first pass (0066, Rules).
    if metadata.zone_state.as_deref() == Some("removed") {
        row.push_wait = Some(PushWait::UploadAgain);
        row.cursor = None;
    }
    txn.put(Row::Scope(row)).await?;
    Ok(())
}

async fn cache(
    txn: &mut dyn StateTxn,
    cache: &[CloudKitRecord],
    waiting: &BTreeSet<RecordKey>,
) -> Result<(), SyncError> {
    for record in cache {
        match copy::changed(record) {
            Some(Incoming::Changed(copy)) if waiting.contains(&copy.key) => {}
            Some(Incoming::Changed(copy)) => {
                txn.put(Row::Base(BaseRow {
                    key: copy.key,
                    tag: ChangeTag::CloudKit(copy.tag),
                    version: None,
                    revision: None,
                    epoch: None,
                    deleted: None,
                    fields: Some(copy.fields),
                    created_ms: copy.created_ms,
                }))
                .await?;
            }
            // A cached copy this build cannot project is no base to merge against: it waits by id, as a pulled one
            // does, until a change to it arrives.
            Some(Incoming::Unread { key, tag: Some(tag) }) => {
                txn.put(Row::Held(HeldRow {
                    record: pulled(&key, tag, false),
                    key,
                    reason: HeldReason::Unreadable,
                }))
                .await?;
            }
            _ => {}
        }
    }
    Ok(())
}

// A tombstone of a connection kept off sync leaves no base, cached or not, so its deletion never goes up, as the Swift
// engine never sent it; the mirror keeps the tombstone for the previous stable.
async fn tombstones(
    txn: &mut dyn StateTxn,
    metadata: &LegacyMetadata,
    zone: &BTreeMap<RecordKey, ZoneCopy>,
) -> Result<(), SyncError> {
    let kept_off = kept_off(metadata);
    for tombstone in &metadata.tombstones {
        let Some((kind, key)) = tombstone_key(tombstone) else {
            continue;
        };
        if kept_off_sync(kind, tombstone, &kept_off) {
            txn.delete(&RowKey::Base(key)).await?;
            continue;
        }
        if txn.get(&RowKey::Base(key.clone())).await?.is_some() {
            continue;
        }
        let base = match zone.get(&key) {
            Some(ZoneCopy::Gone) => continue,
            Some(ZoneCopy::Copy(record)) => match copy::changed(record) {
                Some(Incoming::Changed(copy)) if copy.key == key => BaseRow {
                    key: copy.key,
                    tag: ChangeTag::CloudKit(copy.tag),
                    version: None,
                    revision: None,
                    epoch: None,
                    deleted: None,
                    fields: Some(copy.fields),
                    created_ms: copy.created_ms,
                },
                Some(Incoming::Unread { tag: Some(tag), .. }) => BaseRow {
                    tag: ChangeTag::CloudKit(tag),
                    ..bare(key)
                },
                _ => bare(key),
            },
            None => bare(key),
        };
        txn.put(Row::Base(base)).await?;
    }
    Ok(())
}

async fn held(txn: &mut dyn StateTxn, metadata: &LegacyMetadata) -> Result<(), SyncError> {
    let changes = metadata.changes_held_for_unreadable.iter().map(|name| (name, false));
    let deletions = metadata
        .deletions_held_for_unreadable
        .iter()
        .chain(&metadata.removals_pending_for_unreadable)
        .map(|name| (name, true));
    for (name, deleted) in changes.chain(deletions) {
        let Some(key) = copy::key_of_name(name) else {
            continue;
        };
        if let Some(Row::Held(held)) = txn.get(&RowKey::Held(key.clone())).await?
            && !matches!(held.reason, HeldReason::Unreadable | HeldReason::UnknownKind)
        {
            continue;
        }
        txn.put(Row::Held(HeldRow {
            record: pulled(&key, Vec::new(), deleted),
            key,
            reason: HeldReason::Unreadable,
        }))
        .await?;
    }
    for name in &metadata.deferred_deletions {
        let Some(key) = copy::key_of_name(name) else {
            continue;
        };
        txn.put(Row::Deferred(DeferredRow {
            record: pulled(&key, Vec::new(), true),
            key,
        }))
        .await?;
    }
    Ok(())
}

async fn standing(txn: &mut dyn StateTxn, metadata: &LegacyMetadata) -> Result<(), SyncError> {
    for entry in &metadata.standing {
        if entry.standing == Standing::Unknown {
            continue;
        }
        txn.put(Row::Standing(StandingRow {
            key: RecordKey::new(SCOPE, Kind::Connection, uuid_id(entry.connection)),
            standing: entry.standing,
        }))
        .await?;
    }
    Ok(())
}

// `metadata` is already the account's (`LegacyMetadata::for_account`), `zone` what `uncached` fetched for it, and
// `reads` the kinds this engine reads now.
pub(super) async fn import(
    txn: &mut dyn StateTxn,
    metadata: &LegacyMetadata,
    zone: &BTreeMap<RecordKey, ZoneCopy>,
    reads: &BTreeSet<Kind>,
) -> Result<(), SyncError> {
    let waiting = waiting(txn).await?;
    clear(txn, &waiting).await?;
    scope(txn, metadata, reads).await?;
    cache(txn, &metadata.cache, &waiting).await?;
    tombstones(txn, metadata, zone).await?;
    held(txn, metadata).await?;
    standing(txn, metadata).await?;
    Ok(())
}

// A state file that never held the zone: no scope row and no base.
pub(super) async fn fresh(txn: &mut dyn StateTxn) -> Result<bool, SyncError> {
    if txn.get(&RowKey::Scope(SCOPE)).await?.is_some() {
        return Ok(false);
    }
    Ok(txn.scan(&RowRange::Scope(Table::Bases, SCOPE)).await?.is_empty())
}

// The Swift engine's metadata in UserDefaults and `SyncRecordCache` as the Mac's mirror keeps it (0054, Downgrade
// mirror), with the rules of `LegacySyncMetadataWriter` and `LegacySyncMetadataReader`: a write of another account
// first drops the last account's position, tombstones, held sets and record cache; a mark makes a written record dirty
// and turns a deleted one's dirty mark into a tombstone; record types the previous stable does not know are left out;
// a cached record with no system fields is not a copy that build can merge against. A test plays an older build by
// replacing what it holds.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tablepro_records::cloudkit::RECORD_TYPES;
use tablepro_sync::api::AdapterError;
use tablepro_sync::api::cloudkit::CloudKitRecord;
use tablepro_sync::api::legacy::{LegacyMetadata, LegacyMirror, LegacyRecordRef, LegacyStanding, LegacyTombstone};
use tablepro_sync::api::state::Standing;
use uuid::Uuid;

type Record = (String, String);

#[derive(Debug, Default)]
struct Held {
    token: Option<Vec<u8>>,
    dirty: BTreeSet<Record>,
    tombstones: BTreeMap<Record, (i64, Option<Uuid>)>,
    deferred_deletions: BTreeSet<String>,
    changes_held_for_unreadable: BTreeSet<String>,
    removals_pending_for_unreadable: BTreeSet<String>,
    deletions_held_for_unreadable: BTreeSet<String>,
    owners_kept_off_sync: BTreeSet<Uuid>,
    syncing: BTreeSet<Uuid>,
    kept_off: BTreeSet<Uuid>,
    readable_record_types: BTreeSet<String>,
    account: Option<String>,
    zone_state: Option<String>,
    synced_once: bool,
    cache: BTreeMap<String, CloudKitRecord>,
}

#[derive(Debug, Default)]
struct Calls {
    reads: usize,
    writes: usize,
    marks: usize,
    fail_reads: usize,
    fail_writes: usize,
    fail_marks: usize,
}

#[derive(Debug, Default)]
pub struct FakeLegacyMirror {
    held: Mutex<Held>,
    calls: Mutex<Calls>,
    // CloudKit encodes system fields anew each time it rebuilds a record from the cache.
    reencode: Mutex<bool>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

// `SyncRecordType`: the types Production holds.
fn known(record_type: &str) -> bool {
    RECORD_TYPES
        .iter()
        .any(|known| known.deployed && known.name == record_type)
}

fn host_failure() -> AdapterError {
    AdapterError::Host {
        detail: "the defaults could not be read or written".to_owned(),
    }
}

fn record(reference: &LegacyRecordRef) -> Record {
    (reference.record_type.clone(), reference.id.clone())
}

impl Held {
    fn forget_account(&mut self) {
        self.cache.clear();
        self.token = None;
        self.tombstones.clear();
        self.deferred_deletions.clear();
        self.changes_held_for_unreadable.clear();
        self.removals_pending_for_unreadable.clear();
        self.deletions_held_for_unreadable.clear();
        self.zone_state = Some("unknown".to_owned());
    }

    fn set(&mut self, metadata: LegacyMetadata, writer: bool) {
        if writer && self.account != metadata.account {
            self.forget_account();
        }
        self.account = metadata.account;
        self.token = metadata.token;
        self.dirty = metadata
            .dirty
            .iter()
            .filter(|dirty| !writer || known(&dirty.record_type))
            .map(record)
            .collect();
        self.tombstones = metadata
            .tombstones
            .iter()
            .filter(|tombstone| !writer || known(&tombstone.record.record_type))
            .map(|tombstone| (record(&tombstone.record), (tombstone.deleted_at_ms, tombstone.owner)))
            .collect();
        self.deferred_deletions = metadata.deferred_deletions.into_iter().collect();
        self.changes_held_for_unreadable = metadata.changes_held_for_unreadable.into_iter().collect();
        self.removals_pending_for_unreadable = metadata.removals_pending_for_unreadable.into_iter().collect();
        self.deletions_held_for_unreadable = metadata.deletions_held_for_unreadable.into_iter().collect();
        self.owners_kept_off_sync = metadata.owners_kept_off_sync.into_iter().collect();
        self.syncing.clear();
        self.kept_off.clear();
        for entry in metadata.standing {
            match entry.standing {
                Standing::Syncs => {
                    self.syncing.insert(entry.connection);
                }
                Standing::LocalOnly => {
                    self.kept_off.insert(entry.connection);
                }
                Standing::Unknown => {}
            }
        }
        self.readable_record_types = metadata.readable_record_types.into_iter().collect();
        self.zone_state = metadata.zone_state;
        self.synced_once |= writer;
        self.cache = metadata
            .cache
            .into_iter()
            .filter(|cached| !writer || cached.system_fields.as_ref().is_some_and(|bytes| !bytes.is_empty()))
            .map(|cached| (cached.name.clone(), cached))
            .collect();
    }

    // `SyncMetadataStorage.zoneState`: with none recorded, a stored token or a Last Synced date reads as confirmed.
    fn zone(&self) -> String {
        self.zone_state.clone().unwrap_or_else(|| {
            if self.token.is_some() || self.synced_once {
                "confirmed".to_owned()
            } else {
                "unknown".to_owned()
            }
        })
    }

    fn read(&self, reencode: bool) -> LegacyMetadata {
        let standing = self
            .syncing
            .difference(&self.kept_off)
            .map(|connection| LegacyStanding {
                connection: *connection,
                standing: Standing::Syncs,
            })
            .chain(self.kept_off.iter().map(|connection| LegacyStanding {
                connection: *connection,
                standing: Standing::LocalOnly,
            }));
        let mut standing: Vec<LegacyStanding> = standing.collect();
        standing.sort_by_key(|entry| entry.connection.hyphenated().to_string().to_uppercase());
        LegacyMetadata {
            token: self.token.clone(),
            dirty: self
                .dirty
                .iter()
                .map(|(record_type, id)| LegacyRecordRef {
                    record_type: record_type.clone(),
                    id: id.clone(),
                })
                .collect(),
            tombstones: self
                .tombstones
                .iter()
                .map(|((record_type, id), (deleted_at_ms, owner))| LegacyTombstone {
                    record: LegacyRecordRef {
                        record_type: record_type.clone(),
                        id: id.clone(),
                    },
                    deleted_at_ms: *deleted_at_ms,
                    owner: *owner,
                })
                .collect(),
            deferred_deletions: self.deferred_deletions.iter().cloned().collect(),
            changes_held_for_unreadable: self.changes_held_for_unreadable.iter().cloned().collect(),
            removals_pending_for_unreadable: self.removals_pending_for_unreadable.iter().cloned().collect(),
            deletions_held_for_unreadable: self.deletions_held_for_unreadable.iter().cloned().collect(),
            owners_kept_off_sync: self.owners_kept_off_sync.iter().copied().collect(),
            standing,
            readable_record_types: self.readable_record_types.iter().cloned().collect(),
            account: self.account.clone(),
            zone_state: Some(self.zone()),
            cache: self
                .cache
                .values()
                .map(|cached| {
                    let mut read = cached.clone();
                    read.fields.retain(|field| field.value.is_some());
                    if reencode {
                        read.system_fields = read.system_fields.map(|mut bytes| {
                            bytes.push(0);
                            bytes
                        });
                    }
                    read
                })
                .collect(),
        }
    }
}

impl FakeLegacyMirror {
    pub fn new() -> Self {
        Self::default()
    }

    // What an older build left: its own metadata, written by its own code.
    pub fn holding(metadata: LegacyMetadata) -> Self {
        let mirror = Self::default();
        mirror.replace(metadata);
        mirror
    }

    // An older build ran and left this.
    pub fn replace(&self, metadata: LegacyMetadata) {
        lock(&self.held).set(metadata, false);
    }

    // What the previous stable would read now.
    pub fn metadata(&self) -> LegacyMetadata {
        lock(&self.held).read(false)
    }

    pub fn reencode_system_fields(&self) {
        *lock(&self.reencode) = true;
    }

    pub fn fail_reads(&self, times: usize) {
        lock(&self.calls).fail_reads = times;
    }

    pub fn fail_writes(&self, times: usize) {
        lock(&self.calls).fail_writes = times;
    }

    pub fn fail_marks(&self, times: usize) {
        lock(&self.calls).fail_marks = times;
    }

    pub fn reads(&self) -> usize {
        lock(&self.calls).reads
    }

    pub fn writes(&self) -> usize {
        lock(&self.calls).writes
    }

    pub fn marks(&self) -> usize {
        lock(&self.calls).marks
    }

    fn fails(&self, pick: impl FnOnce(&mut Calls) -> &mut usize) -> bool {
        let mut calls = lock(&self.calls);
        let left = pick(&mut calls);
        if *left == 0 {
            return false;
        }
        *left -= 1;
        true
    }
}

#[async_trait]
impl LegacyMirror for FakeLegacyMirror {
    async fn read(&self) -> Result<LegacyMetadata, AdapterError> {
        lock(&self.calls).reads += 1;
        if self.fails(|calls| &mut calls.fail_reads) {
            return Err(host_failure());
        }
        let reencode = *lock(&self.reencode);
        Ok(lock(&self.held).read(reencode))
    }

    async fn write(&self, metadata: LegacyMetadata) -> Result<(), AdapterError> {
        lock(&self.calls).writes += 1;
        if self.fails(|calls| &mut calls.fail_writes) {
            return Err(host_failure());
        }
        lock(&self.held).set(metadata, true);
        Ok(())
    }

    async fn mark(&self, dirty: Vec<LegacyRecordRef>, tombstones: Vec<LegacyTombstone>) -> Result<(), AdapterError> {
        lock(&self.calls).marks += 1;
        if self.fails(|calls| &mut calls.fail_marks) {
            return Err(host_failure());
        }
        let mut held = lock(&self.held);
        for dirty in dirty.iter().filter(|dirty| known(&dirty.record_type)) {
            held.dirty.insert(record(dirty));
        }
        for tombstone in tombstones
            .iter()
            .filter(|tombstone| known(&tombstone.record.record_type))
        {
            let key = record(&tombstone.record);
            held.dirty.remove(&key);
            held.tombstones.insert(key, (tombstone.deleted_at_ms, tombstone.owner));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests;

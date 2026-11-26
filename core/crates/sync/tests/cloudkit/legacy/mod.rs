// The Swift engine's metadata (0054, The Apple apps on the engine; Downgrade mirror): the import at the first launch
// and again after an older build ran, the mirror written after every pass and marked on every journal signal, and
// the previous stable taking over from what the mirror wrote.

mod adapters;
mod downgrade;
mod import;
mod mirror;

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;
use tablepro_records::cloudkit::{CloudFields, CloudValue, RECORD_TYPES, record_name, record_type_named, to_wire};
use tablepro_sync::api::cloudkit::{
    CloudKitAccount, CloudKitChanges, CloudKitFailure, CloudKitFetched, CloudKitOutcome, CloudKitRecord,
    CloudKitTransport, CloudKitValue,
};
use tablepro_sync::api::legacy::{LegacyMetadata, LegacyRecordRef, LegacyTombstone};
use tablepro_sync_testing::FakeCloudKit;
use tablepro_sync_testing::FakeLegacyMirror;

use crate::support::{Rig, USER, cloud_fields};

pub fn record(record_type: &str, id: &str) -> LegacyRecordRef {
    LegacyRecordRef {
        record_type: record_type.to_owned(),
        id: id.to_owned(),
    }
}

pub fn tombstone(record_type: &str, id: &str) -> LegacyTombstone {
    LegacyTombstone {
        record: record(record_type, id),
        deleted_at_ms: 1_767_225_000_000,
        owner: None,
    }
}

// Every type the previous stable reads, as a build with every category on records them.
pub fn every_type() -> Vec<String> {
    RECORD_TYPES
        .iter()
        .filter(|record_type| record_type.deployed)
        .map(|record_type| record_type.name.to_owned())
        .collect()
}

// What the previous stable keeps once it synced this account and has not pulled yet.
pub fn signed_in() -> LegacyMetadata {
    LegacyMetadata {
        account: Some(USER.to_owned()),
        zone_state: Some("confirmed".to_owned()),
        readable_record_types: every_type(),
        ..LegacyMetadata::default()
    }
}

fn cloud_value(value: &CloudKitValue) -> CloudValue {
    match value {
        CloudKitValue::Text(text) => CloudValue::Text(text.clone()),
        CloudKitValue::Int64(number) => CloudValue::Int64(*number),
        CloudKitValue::Double(number) => CloudValue::Double(*number),
        CloudKitValue::Timestamp(millis) => CloudValue::Timestamp(*millis),
        CloudKitValue::Bytes(bytes) => CloudValue::Bytes(bytes.clone()),
        CloudKitValue::TextList(items) => CloudValue::TextList(items.clone()),
    }
}

pub fn wire_of(record: &CloudKitRecord) -> (tablepro_records::Kind, String, serde_json::Value) {
    let fields: CloudFields = record
        .fields
        .iter()
        .filter_map(|field| Some((field.name.clone(), cloud_value(field.value.as_ref()?))))
        .collect();
    let wire = to_wire(&record.record_type, &record.name, &fields).unwrap();
    (wire.kind, wire.record_id, wire.fields)
}

fn same(left: &LegacyRecordRef, record_type: &str, id: &str) -> bool {
    left.record_type == record_type && left.id == id
}

fn name_of(record: &LegacyRecordRef) -> String {
    record_name(record_type_named(&record.record_type).unwrap().kind, &record.id).unwrap()
}

// The Swift engine of the previous stable over the rig's stores and zone, reading and writing only what the mirror
// holds: its push saves each dirty record on the system fields of its cached copy, and its pull applies the zone's
// changes since its token to every record it holds no dirty mark for.
pub struct PreviousStable<'r> {
    pub rig: &'r Rig,
    pub mirror: &'r FakeLegacyMirror,
}

impl PreviousStable<'_> {
    // `runSyncCycle`: the push, then the pull.
    pub async fn pass(&self) -> Vec<CloudKitOutcome> {
        let pushed = self.push().await;
        self.pull().await;
        pushed
    }

    pub async fn pull(&self) {
        let mut metadata = self.mirror.metadata();
        let mut token = metadata.token.clone();
        loop {
            let changes = self
                .rig
                .cloud
                .fetch_changes(USER.to_owned(), token.clone())
                .await
                .unwrap();
            for changed in &changes.changed {
                let (kind, id, fields) = wire_of(changed);
                let record_type = changed.record_type.as_str();
                if !metadata.dirty.iter().any(|dirty| same(dirty, record_type, &id)) {
                    self.rig.store(kind).put(&id, fields);
                }
                metadata.cache.retain(|cached| cached.name != changed.name);
                metadata.cache.push(changed.clone());
            }
            for deleted in &changes.deleted {
                let record_type = record_type_named(&deleted.record_type).unwrap();
                let id = deleted.name.strip_prefix(record_type.prefix).unwrap();
                self.rig.store(record_type.kind).remove(id);
                metadata.cache.retain(|cached| cached.name != deleted.name);
            }
            token = Some(changes.token);
            if !changes.more {
                break;
            }
        }
        metadata.token = token;
        self.mirror.replace(metadata);
    }

    // A save CloudKit refuses as changed stays dirty: it overwrote nothing.
    pub async fn push(&self) -> Vec<CloudKitOutcome> {
        let mut metadata = self.mirror.metadata();
        let mut saves = Vec::new();
        for dirty in &metadata.dirty {
            let record_type = record_type_named(&dirty.record_type).unwrap();
            let Some(fields) = self.rig.store(record_type.kind).fields(&dirty.id) else {
                continue;
            };
            let name = record_name(record_type.kind, &dirty.id).unwrap();
            let system_fields = metadata
                .cache
                .iter()
                .find(|cached| cached.name == name)
                .and_then(|cached| cached.system_fields.clone());
            saves.push(CloudKitRecord {
                record_type: record_type.name.to_owned(),
                name,
                system_fields,
                created_ms: None,
                fields: cloud_fields(record_type.kind, &dirty.id, &fields),
            });
        }
        let deletes: Vec<String> = metadata
            .tombstones
            .iter()
            .map(|tombstone| name_of(&tombstone.record))
            .collect();
        let outcomes = self
            .rig
            .cloud
            .modify(USER.to_owned(), saves.clone(), deletes)
            .await
            .unwrap();
        for outcome in &outcomes {
            match outcome {
                CloudKitOutcome::Saved { name, system_fields } => {
                    let mut saved = saves.iter().find(|save| save.name == *name).unwrap().clone();
                    saved.system_fields = Some(system_fields.clone());
                    metadata.dirty.retain(|dirty| name_of(dirty) != *name);
                    metadata.cache.retain(|cached| cached.name != *name);
                    metadata.cache.push(saved);
                }
                CloudKitOutcome::Deleted { name } | CloudKitOutcome::UnknownItem { name } => {
                    metadata
                        .tombstones
                        .retain(|tombstone| name_of(&tombstone.record) != *name);
                    metadata.cache.retain(|cached| cached.name != *name);
                }
                _ => {}
            }
        }
        self.mirror.replace(metadata);
        outcomes
    }
}

// The previous stable, signed in and caught up with the zone as the rig holds it.
pub async fn synced(rig: &Rig) -> Arc<FakeLegacyMirror> {
    let mirror = Arc::new(FakeLegacyMirror::holding(signed_in()));
    PreviousStable { rig, mirror: &mirror }.pull().await;
    mirror
}

// The journal's marks go out on a task of their own.
pub async fn marked(mirror: &FakeLegacyMirror, marks: usize) {
    for _ in 0..1_000 {
        if mirror.marks() >= marks {
            return;
        }
        tokio::task::yield_now().await;
    }
    panic!("the journal's marks never reached the host");
}

pub fn dirty(metadata: &LegacyMetadata) -> Vec<(String, String)> {
    metadata
        .dirty
        .iter()
        .map(|dirty| (dirty.record_type.clone(), dirty.id.clone()))
        .collect()
}

pub fn tombstones(metadata: &LegacyMetadata) -> Vec<(String, String)> {
    metadata
        .tombstones
        .iter()
        .map(|tombstone| (tombstone.record.record_type.clone(), tombstone.record.id.clone()))
        .collect()
}

// The zone, counting the records its fetches of changes return.
pub struct Counting {
    pub inner: Arc<FakeCloudKit>,
    pub changed: AtomicUsize,
}

impl Counting {
    pub fn new(inner: &Arc<FakeCloudKit>) -> Arc<Self> {
        Arc::new(Self {
            inner: Arc::clone(inner),
            changed: AtomicUsize::new(0),
        })
    }

    pub fn changed(&self) -> usize {
        self.changed.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl CloudKitTransport for Counting {
    async fn account_status(&self) -> Result<CloudKitAccount, CloudKitFailure> {
        self.inner.account_status().await
    }

    async fn ensure_zone(&self, account: String) -> Result<(), CloudKitFailure> {
        self.inner.ensure_zone(account).await
    }

    async fn delete_zone(&self, account: String) -> Result<(), CloudKitFailure> {
        self.inner.delete_zone(account).await
    }

    async fn fetch_changes(&self, account: String, token: Option<Vec<u8>>) -> Result<CloudKitChanges, CloudKitFailure> {
        let changes = self.inner.fetch_changes(account, token).await?;
        self.changed.fetch_add(changes.changed.len(), Ordering::SeqCst);
        Ok(changes)
    }

    async fn fetch_records(
        &self,
        account: String,
        names: Vec<String>,
    ) -> Result<Vec<CloudKitFetched>, CloudKitFailure> {
        self.inner.fetch_records(account, names).await
    }

    async fn modify(
        &self,
        account: String,
        saves: Vec<CloudKitRecord>,
        deletes: Vec<String>,
    ) -> Result<Vec<CloudKitOutcome>, CloudKitFailure> {
        self.inner.modify(account, saves, deletes).await
    }
}

pub fn transport(rig: &Rig) -> Arc<dyn CloudKitTransport> {
    Arc::clone(&rig.cloud) as Arc<dyn CloudKitTransport>
}

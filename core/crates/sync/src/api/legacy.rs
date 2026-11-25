// The Swift engine's iCloud metadata, which the Mac imports once on the core engine's first launch and writes back
// while the previous stable still runs the Swift engine (0054, The Apple apps on the engine; Downgrade mirror). The
// host reads and writes UserDefaults and the `SyncRecordCache` files; the engine decides what they hold.

use async_trait::async_trait;
use uuid::Uuid;

use super::cloudkit::CloudKitRecord;
use super::error::AdapterError;
use super::state::Standing;

#[async_trait]
pub trait LegacyMirror: Send + Sync {
    // At launch: what the Swift metadata holds now. One that differs from what the mirror last wrote means an older
    // build ran in between, and the engine imports it again.
    async fn read(&self) -> Result<LegacyMetadata, AdapterError>;

    // After every committed pass.
    async fn write(&self, metadata: LegacyMetadata) -> Result<(), AdapterError>;

    // On every journal signal, offline too, after the store write: the records that write changed.
    async fn mark(&self, dirty: Vec<LegacyRecordRef>, tombstones: Vec<LegacyTombstone>) -> Result<(), AdapterError>;
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct LegacyMetadata {
    // The archived `CKServerChangeToken`.
    pub token: Option<Vec<u8>>,
    pub dirty: Vec<LegacyRecordRef>,
    pub tombstones: Vec<LegacyTombstone>,
    pub deferred_deletions: Vec<String>,
    pub owners_kept_off_sync: Vec<Uuid>,
    pub standing: Vec<LegacyStanding>,
    pub readable_record_types: Vec<String>,
    pub account: Option<String>,
    pub zone_state: Option<String>,
    // `SyncRecordCache`: each record as last agreed, with its system fields.
    pub cache: Vec<CloudKitRecord>,
}

// A record by its Swift record type and id.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct LegacyRecordRef {
    pub record_type: String,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct LegacyTombstone {
    pub record: LegacyRecordRef,
    pub owner: Option<Uuid>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LegacyStanding {
    pub connection: Uuid,
    pub standing: Standing,
}

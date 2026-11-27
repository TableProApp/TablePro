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

impl LegacyMetadata {
    // What the import takes for the iCloud account the engine runs for, as Swift's `adoptAccount` does: metadata of
    // another account, or of none, keeps only the dirty keys and the standing; the server position, tombstones, held
    // sets and cache are that other account's.
    #[must_use]
    pub fn for_account(self, account: &str) -> Self {
        if self.account.as_deref() == Some(account) {
            return self;
        }
        Self {
            dirty: self.dirty,
            standing: self.standing,
            account: Some(account.to_owned()),
            ..Self::default()
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct LegacyMetadata {
    // The archived `CKServerChangeToken`.
    pub token: Option<Vec<u8>>,
    pub dirty: Vec<LegacyRecordRef>,
    pub tombstones: Vec<LegacyTombstone>,
    pub deferred_deletions: Vec<String>,
    // Record names a pull changed while this device's copy could not be read, fetched by id once it reads.
    pub changes_held_for_unreadable: Vec<String>,
    // Unread copies a pull deleted, removed by the next save of their file.
    pub removals_pending_for_unreadable: Vec<String>,
    // Deletions pulled while this device could not tell whether its unreadable copy syncs.
    pub deletions_held_for_unreadable: Vec<String>,
    pub owners_kept_off_sync: Vec<Uuid>,
    pub standing: Vec<LegacyStanding>,
    pub readable_record_types: Vec<String>,
    pub account: Option<String>,
    pub zone_state: Option<String>,
    // `SyncRecordCache`: each record as last agreed, with its system fields.
    pub cache: Vec<CloudKitRecord>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn metadata(account: Option<&str>) -> LegacyMetadata {
        let record = LegacyRecordRef {
            record_type: "Connection".to_owned(),
            id: "A".to_owned(),
        };
        LegacyMetadata {
            token: Some(vec![1]),
            dirty: vec![record.clone()],
            tombstones: vec![LegacyTombstone {
                record,
                deleted_at_ms: 1,
                owner: None,
            }],
            deferred_deletions: vec!["Group_B".to_owned()],
            changes_held_for_unreadable: vec!["Connection_C".to_owned()],
            standing: vec![LegacyStanding {
                connection: Uuid::nil(),
                standing: Standing::LocalOnly,
            }],
            account: account.map(str::to_owned),
            ..LegacyMetadata::default()
        }
    }

    #[test]
    fn another_account_s_metadata_imports_only_the_dirty_keys_and_the_standing() {
        let same = metadata(Some("_a")).for_account("_a");
        let other = metadata(Some("_b")).for_account("_a");
        let none = metadata(None).for_account("_a");

        assert_eq!(same, metadata(Some("_a")));
        for imported in [other, none] {
            assert_eq!(imported.dirty, metadata(None).dirty);
            assert_eq!(imported.standing, metadata(None).standing);
            assert_eq!(imported.token, None);
            assert!(imported.tombstones.is_empty() && imported.deferred_deletions.is_empty());
            assert!(imported.changes_held_for_unreadable.is_empty());
        }
    }
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
    // Milliseconds since the Unix epoch, which the Swift engine prunes tombstones by.
    pub deleted_at_ms: i64,
    pub owner: Option<Uuid>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LegacyStanding {
    pub connection: Uuid,
    pub standing: Standing,
}

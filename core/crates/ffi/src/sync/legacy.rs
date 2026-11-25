use std::sync::Arc;

use async_trait::async_trait;
use tablepro_session::runtime::Tasks;
use tablepro_sync::api::AdapterError;
use tablepro_sync::api::legacy as sync;
use tablepro_sync::api::state::Standing;
use uuid::Uuid;

use super::cloudkit::CloudKitRecord;
use crate::host::HostSecretError;

// The Mac's Swift sync metadata in UserDefaults and `SyncRecordCache` (core ADR 0054, Downgrade mirror). Each call
// may block, so the core makes it on a blocking thread.
#[uniffi::export(callback_interface)]
pub trait HostLegacyMirror: Send + Sync {
    fn read(&self) -> Result<LegacyMetadataArg, HostSecretError>;

    fn write(&self, metadata: LegacyMetadataArg) -> Result<(), HostSecretError>;

    fn mark(&self, dirty: Vec<LegacyRecordArg>, tombstones: Vec<LegacyTombstoneArg>) -> Result<(), HostSecretError>;
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LegacyMetadataArg {
    pub token: Option<Vec<u8>>,
    pub dirty: Vec<LegacyRecordArg>,
    pub tombstones: Vec<LegacyTombstoneArg>,
    pub deferred_deletions: Vec<String>,
    // Upper-case UUID text.
    pub owners_kept_off_sync: Vec<String>,
    pub standing: Vec<LegacyStandingArg>,
    pub readable_record_types: Vec<String>,
    pub account: Option<String>,
    pub zone_state: Option<String>,
    pub cache: Vec<CloudKitRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct LegacyRecordArg {
    pub record_type: String,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct LegacyTombstoneArg {
    pub record: LegacyRecordArg,
    pub owner: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum LegacyStandingTag {
    Syncs,
    LocalOnly,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct LegacyStandingArg {
    pub connection: String,
    pub standing: LegacyStandingTag,
}

fn uuid(text: &str) -> Result<Uuid, AdapterError> {
    Uuid::parse_str(text).map_err(|_| AdapterError::Host {
        detail: "the legacy metadata holds an id that is not a UUID".to_owned(),
    })
}

fn wire_uuid(id: Uuid) -> String {
    id.hyphenated().to_string().to_uppercase()
}

impl From<LegacyRecordArg> for sync::LegacyRecordRef {
    fn from(record: LegacyRecordArg) -> Self {
        Self {
            record_type: record.record_type,
            id: record.id,
        }
    }
}

impl From<sync::LegacyRecordRef> for LegacyRecordArg {
    fn from(record: sync::LegacyRecordRef) -> Self {
        Self {
            record_type: record.record_type,
            id: record.id,
        }
    }
}

impl From<sync::LegacyTombstone> for LegacyTombstoneArg {
    fn from(tombstone: sync::LegacyTombstone) -> Self {
        Self {
            record: tombstone.record.into(),
            owner: tombstone.owner.map(wire_uuid),
        }
    }
}

fn standing_tag(standing: Standing) -> LegacyStandingTag {
    match standing {
        Standing::Syncs => LegacyStandingTag::Syncs,
        Standing::LocalOnly => LegacyStandingTag::LocalOnly,
        Standing::Unknown => LegacyStandingTag::Unknown,
    }
}

fn standing(tag: LegacyStandingTag) -> Standing {
    match tag {
        LegacyStandingTag::Syncs => Standing::Syncs,
        LegacyStandingTag::LocalOnly => Standing::LocalOnly,
        LegacyStandingTag::Unknown => Standing::Unknown,
    }
}

impl LegacyMetadataArg {
    fn into_metadata(self) -> Result<sync::LegacyMetadata, AdapterError> {
        Ok(sync::LegacyMetadata {
            token: self.token,
            dirty: self.dirty.into_iter().map(Into::into).collect(),
            tombstones: self
                .tombstones
                .into_iter()
                .map(|tombstone| {
                    Ok(sync::LegacyTombstone {
                        record: tombstone.record.into(),
                        owner: tombstone.owner.as_deref().map(uuid).transpose()?,
                    })
                })
                .collect::<Result<_, AdapterError>>()?,
            deferred_deletions: self.deferred_deletions,
            owners_kept_off_sync: self
                .owners_kept_off_sync
                .iter()
                .map(|owner| uuid(owner))
                .collect::<Result<_, _>>()?,
            standing: self
                .standing
                .into_iter()
                .map(|entry| {
                    Ok(sync::LegacyStanding {
                        connection: uuid(&entry.connection)?,
                        standing: standing(entry.standing),
                    })
                })
                .collect::<Result<_, AdapterError>>()?,
            readable_record_types: self.readable_record_types,
            account: self.account,
            zone_state: self.zone_state,
            cache: self.cache.into_iter().map(Into::into).collect(),
        })
    }

    fn of(metadata: sync::LegacyMetadata) -> Self {
        Self {
            token: metadata.token,
            dirty: metadata.dirty.into_iter().map(Into::into).collect(),
            tombstones: metadata.tombstones.into_iter().map(Into::into).collect(),
            deferred_deletions: metadata.deferred_deletions,
            owners_kept_off_sync: metadata.owners_kept_off_sync.into_iter().map(wire_uuid).collect(),
            standing: metadata
                .standing
                .into_iter()
                .map(|entry| LegacyStandingArg {
                    connection: wire_uuid(entry.connection),
                    standing: standing_tag(entry.standing),
                })
                .collect(),
            readable_record_types: metadata.readable_record_types,
            account: metadata.account,
            zone_state: metadata.zone_state,
            cache: metadata.cache.into_iter().map(Into::into).collect(),
        }
    }
}

fn host_error(failure: impl std::fmt::Display) -> AdapterError {
    AdapterError::Host {
        detail: failure.to_string(),
    }
}

pub(crate) struct LegacyMirrorBridge {
    pub(crate) host: Arc<dyn HostLegacyMirror>,
    pub(crate) tasks: Tasks,
}

#[async_trait]
impl sync::LegacyMirror for LegacyMirrorBridge {
    async fn read(&self) -> Result<sync::LegacyMetadata, AdapterError> {
        let host = Arc::clone(&self.host);
        let read = self
            .tasks
            .spawn_blocking_task(move || host.read())
            .await
            .map_err(host_error)?;
        read.map_err(host_error)?.into_metadata()
    }

    async fn write(&self, metadata: sync::LegacyMetadata) -> Result<(), AdapterError> {
        let (host, metadata) = (Arc::clone(&self.host), LegacyMetadataArg::of(metadata));
        let written = self
            .tasks
            .spawn_blocking_task(move || host.write(metadata))
            .await
            .map_err(host_error)?;
        written.map_err(host_error)
    }

    async fn mark(
        &self,
        dirty: Vec<sync::LegacyRecordRef>,
        tombstones: Vec<sync::LegacyTombstone>,
    ) -> Result<(), AdapterError> {
        let host = Arc::clone(&self.host);
        let dirty = dirty.into_iter().map(Into::into).collect();
        let tombstones = tombstones.into_iter().map(Into::into).collect();
        let marked = self
            .tasks
            .spawn_blocking_task(move || host.mark(dirty, tombstones))
            .await
            .map_err(host_error)?;
        marked.map_err(host_error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_crosses_the_boundary_and_back_unchanged() {
        let metadata = sync::LegacyMetadata {
            token: Some(vec![1, 2]),
            dirty: vec![sync::LegacyRecordRef {
                record_type: "Connection".to_owned(),
                id: "A".to_owned(),
            }],
            tombstones: vec![sync::LegacyTombstone {
                record: sync::LegacyRecordRef {
                    record_type: "Group".to_owned(),
                    id: "B".to_owned(),
                },
                owner: Some(Uuid::from_u128(7)),
            }],
            standing: vec![sync::LegacyStanding {
                connection: Uuid::from_u128(9),
                standing: Standing::LocalOnly,
            }],
            ..sync::LegacyMetadata::default()
        };

        let back = LegacyMetadataArg::of(metadata.clone()).into_metadata().unwrap();

        assert_eq!(back, metadata);
    }
}

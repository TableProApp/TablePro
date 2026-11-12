use tablepro_storage::cloudkit::{CloudConnection, CloudGroup, CloudIds, CloudPull, CloudRecords};
use uuid::Uuid;

use crate::error::CoreError;
use crate::library::{ConnectionLibrary, parse_id};

// Only existing CloudKit fields cross this boundary; ADR 0010 defines their mapping.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct CloudGroupFields {
    pub group_id: String,
    pub name: Option<String>,
    pub color: Option<String>,
    pub icon_name: Option<String>,
    pub parent_id: Option<String>,
    pub sort_order: Option<i64>,
}

// The fields that place a connection; its name is read only to break a tie in the order.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct CloudConnectionFields {
    pub connection_id: String,
    pub name: Option<String>,
    pub group_id: Option<String>,
    pub sort_order: Option<i64>,
    pub is_favorite: Option<i64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct CloudLibraryRecords {
    pub groups: Vec<CloudGroupFields>,
    pub connections: Vec<CloudConnectionFields>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct CloudLibraryPull {
    // Every library record held before the pull, as the server last gave it.
    pub base: CloudLibraryRecords,
    pub changed: CloudLibraryRecords,
    pub deleted_group_ids: Vec<String>,
    pub deleted_connection_ids: Vec<String>,
    // Deleted on this device and not pushed yet.
    pub deleted_here_group_ids: Vec<String>,
    pub deleted_here_connection_ids: Vec<String>,
    // The favourites' order to keep when the library does not hold it yet, as on a first sync.
    pub favorites_order: Option<Vec<String>>,
}

#[uniffi::export]
impl ConnectionLibrary {
    // The records a push sends: new ones, and those with a field that differs from what the server last gave.
    pub async fn cloud_edits(&self, base: CloudLibraryRecords) -> Result<CloudLibraryRecords, CoreError> {
        let base = CloudRecords::from(base);
        self.blocking(move |store| Ok(CloudLibraryRecords::from(store.cloud_edits_blocking(&base)?)))
            .await
    }

    // Apply rebased push replies here before caching them, so remote edits are not mistaken for local edits.
    pub async fn apply_cloud_pull(&self, pull: CloudLibraryPull) -> Result<(), CoreError> {
        let pull = CloudPull {
            base: pull.base.into(),
            changed: pull.changed.into(),
            deleted: ids(&pull.deleted_group_ids, &pull.deleted_connection_ids)?,
            deleted_here: ids(&pull.deleted_here_group_ids, &pull.deleted_here_connection_ids)?,
            favorites_order: pull
                .favorites_order
                .map(|order| order.iter().map(|id| parse_id(id)).collect::<Result<Vec<Uuid>, _>>())
                .transpose()?,
        };
        let deleted = pull.deleted.connections.clone();
        let _held = self.hold_writes().await;
        self.blocking(move |store| Ok(store.apply_cloud_pull_blocking(&pull)?))
            .await?;
        self.delete_secrets(deleted).await
    }
}

fn ids(groups: &[String], connections: &[String]) -> Result<CloudIds, CoreError> {
    let parse = |ids: &[String]| ids.iter().map(|id| parse_id(id)).collect::<Result<Vec<Uuid>, _>>();
    Ok(CloudIds {
        groups: parse(groups)?,
        connections: parse(connections)?,
    })
}

impl From<CloudLibraryRecords> for CloudRecords {
    fn from(records: CloudLibraryRecords) -> Self {
        Self {
            groups: records
                .groups
                .into_iter()
                .map(|group| CloudGroup {
                    group_id: group.group_id,
                    name: group.name,
                    color: group.color,
                    icon_name: group.icon_name,
                    parent_id: group.parent_id,
                    sort_order: group.sort_order,
                })
                .collect(),
            connections: records
                .connections
                .into_iter()
                .map(|connection| CloudConnection {
                    connection_id: connection.connection_id,
                    name: connection.name,
                    group_id: connection.group_id,
                    sort_order: connection.sort_order,
                    is_favorite: connection.is_favorite,
                })
                .collect(),
        }
    }
}

impl From<CloudRecords> for CloudLibraryRecords {
    fn from(records: CloudRecords) -> Self {
        Self {
            groups: records
                .groups
                .into_iter()
                .map(|group| CloudGroupFields {
                    group_id: group.group_id,
                    name: group.name,
                    color: group.color,
                    icon_name: group.icon_name,
                    parent_id: group.parent_id,
                    sort_order: group.sort_order,
                })
                .collect(),
            connections: records
                .connections
                .into_iter()
                .map(|connection| CloudConnectionFields {
                    connection_id: connection.connection_id,
                    name: connection.name,
                    group_id: connection.group_id,
                    sort_order: connection.sort_order,
                    is_favorite: connection.is_favorite,
                })
                .collect(),
        }
    }
}

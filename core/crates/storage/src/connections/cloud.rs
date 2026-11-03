use std::collections::HashSet;

use uuid::Uuid;

use super::ConnectionStore;
use crate::cloudkit::{self, CloudPull, CloudRecords};
use crate::error::StorageError;

impl ConnectionStore {
    // The records a push sends for the library, against what the server last gave this device.
    pub fn cloud_edits_blocking(&self, base: &CloudRecords) -> Result<CloudRecords, StorageError> {
        Ok(cloudkit::edits(&self.list_blocking()?, base))
    }

    // The host adds unknown connections before applying their placement fields.
    pub fn apply_cloud_pull_blocking(&self, pull: &CloudPull) -> Result<(), StorageError> {
        self.edit(|document| {
            let deleted: HashSet<Uuid> = pull.deleted.connections.iter().copied().collect();
            document.connections.retain(|saved| !deleted.contains(&saved.id));
            document.favorites.retain(|id| !deleted.contains(id));
            let list = document.list();
            let merged = cloudkit::merged(&list, pull);
            let order = pull.favorites_order.as_deref().unwrap_or(&list.favorites);
            let laid = cloudkit::layout(&list, &merged, order);
            document.groups = laid.groups.to_vec();
            document.connections = laid.connections.to_vec();
            document.favorites = laid.favorites.to_vec();
            Ok(())
        })
    }
}

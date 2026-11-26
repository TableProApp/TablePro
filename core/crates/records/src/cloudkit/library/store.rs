use tablepro_storage::{ConnectionStore, StorageError};

use super::{CloudPull, CloudRecords, edits, layout, merged};

// The records a push sends for the library, against what the server last gave this device.
pub fn edits_of(store: &ConnectionStore, base: &CloudRecords) -> Result<CloudRecords, StorageError> {
    Ok(edits(&store.list_blocking()?, base))
}

// The host adds unknown connections before applying their placement fields.
pub fn apply_pull(store: &ConnectionStore, pull: &CloudPull) -> Result<(), StorageError> {
    store.lay_out_blocking(&pull.deleted.connections, |list| {
        let merged = merged(list, pull);
        let order = pull.favorites_order.as_deref().unwrap_or(&list.favorites);
        layout(list, &merged, order)
    })
}

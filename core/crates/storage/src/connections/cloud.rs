use std::collections::HashSet;

use uuid::Uuid;

use super::{ConnectionList, ConnectionStore};
use crate::error::StorageError;

impl ConnectionStore {
    // A pull's layout: the connections it deleted go with their favourite marks, then the groups, places and
    // favourites take what `lay_out` gives for the rest. `tablepro-records` computes it.
    pub fn lay_out_blocking(
        &self,
        deleted: &[Uuid],
        lay_out: impl FnOnce(&ConnectionList) -> ConnectionList,
    ) -> Result<(), StorageError> {
        self.edit(|document| {
            let deleted: HashSet<Uuid> = deleted.iter().copied().collect();
            document.connections.retain(|saved| !deleted.contains(&saved.id));
            document.favorites.retain(|id| !deleted.contains(id));
            let laid = lay_out(&document.list());
            document.groups = laid.groups.to_vec();
            document.connections = laid.connections.to_vec();
            document.favorites = laid.favorites.to_vec();
            Ok(())
        })
    }
}

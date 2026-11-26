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
            // The host deletes a pulled deletion's secrets, so an entry this build cannot read goes too.
            for id in &deleted {
                document.connections.release(*id);
            }
            document.favorites.retain(|id| !deleted.contains(id));
            let held: HashSet<Uuid> = document.connections.held_ids().into_iter().collect();
            let held_favorites: Vec<Uuid> = document
                .favorites
                .iter()
                .copied()
                .filter(|id| held.contains(id))
                .collect();
            let laid = lay_out(&document.list());
            document.groups = laid.groups.to_vec();
            *document.connections = laid.connections.to_vec();
            // The layout knows only the connections it can read; the others keep their mark.
            document.favorites = laid.favorites.to_vec();
            document.favorites.extend(held_favorites);
            Ok(())
        })
    }
}

use std::path::Path;

use uuid::Uuid;

use super::{MAX_CONNECTIONS, SavedConnection, connections_path, load_from, lock_path, save_to_unlocked};
use crate::StorageError;

/// A copy of `id` under a fresh `Uuid` and a distinct name. The new id
/// has no Secret Service entries, so the copy starts without any saved
/// credentials and the caller must say so.
pub async fn duplicate_connection(id: Uuid) -> Result<SavedConnection, StorageError> {
    duplicate_from(&connections_path()?, id).await
}

pub(super) async fn duplicate_from(path: &Path, id: Uuid) -> Result<SavedConnection, StorageError> {
    let _guard = lock_path(path).await?;
    let mut existing = load_from(path).await?;
    let Some(source) = existing.iter().find(|connection| connection.id == id) else {
        return Err(StorageError::Schema("no saved connection with that id".into()));
    };
    let copy = SavedConnection {
        id: Uuid::new_v4(),
        name: distinct_copy_name(&source.name, &existing),
        last_opened_at: None,
        ..source.clone()
    };
    existing.push(copy.clone());
    save_to_unlocked(path, &existing).await?;
    Ok(copy)
}

/// `name (copy)`, then `name (copy 2)` upward, so a second duplicate
/// does not produce two rows the user cannot tell apart.
fn distinct_copy_name(source: &str, existing: &[SavedConnection]) -> String {
    let taken = |candidate: &str| existing.iter().any(|connection| connection.name == candidate);
    let first = format!("{source} (copy)");
    if !taken(&first) {
        return first;
    }
    for suffix in 2..=MAX_CONNECTIONS {
        let candidate = format!("{source} (copy {suffix})");
        if !taken(&candidate) {
            return candidate;
        }
    }
    format!("{source} (copy {})", Uuid::new_v4())
}

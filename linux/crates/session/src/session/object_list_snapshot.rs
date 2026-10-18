use std::sync::Arc;

use tablepro_core::meta::{ObjectInfo, ObjectScope};

use crate::operation::OperationError;

/// One scope's object list as the catalog last read it.
///
/// A failed read keeps the list and records why, so a view goes on
/// showing what it has and can still say the refresh failed.
#[derive(Debug, Clone)]
pub struct ObjectListSnapshot {
    pub scope: ObjectScope,
    /// Bumps each time a new list lands, so a view can tell a new list
    /// from a failed refresh of the one it already shows.
    pub generation: u64,
    pub objects: Arc<[ObjectInfo]>,
    pub last_error: Option<Arc<OperationError>>,
}

impl ObjectListSnapshot {
    pub(crate) fn empty(scope: ObjectScope) -> Self {
        Self {
            scope,
            generation: 0,
            objects: Arc::from([]),
            last_error: None,
        }
    }
}

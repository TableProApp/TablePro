use std::sync::Arc;

use tablepro_core::meta::{ObjectInfo, SchemaInfo};

use crate::health::LinkGeneration;

/// The catalog read when the current connection was established.
///
/// Each reconnect reads it again and publishes it over the old one, so
/// the sidebar never goes empty while the new list is on its way.
#[derive(Debug, Clone)]
pub struct CatalogSnapshot {
    pub generation: LinkGeneration,
    pub schemas: Arc<[SchemaInfo]>,
    pub objects: Arc<[ObjectInfo]>,
}

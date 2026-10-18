use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use tablepro_core::FilterSet;
use tablepro_storage::document::VersionedDocument;

/// Per-table filters, keyed connection, schema, table.
///
/// The same nesting as the column widths, with a `FilterSet` at the
/// leaf instead of a width.
#[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize)]
pub struct FilterSettingsDocument {
    #[serde(default)]
    pub connections: HashMap<String, Schemas>,
}

pub type Schemas = HashMap<String, Tables>;
pub type Tables = HashMap<String, FilterSet>;

impl VersionedDocument for FilterSettingsDocument {
    const KIND: &'static str = "filter-settings";
    const VERSION: u32 = 1;
}

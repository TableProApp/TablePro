use std::collections::{BTreeSet, HashMap};

use serde::{Deserialize, Serialize};
use tablepro_core::FilterSet;
use tablepro_storage::document::{Upgrade, VersionedDocument};

/// Per-table filters, keyed connection, schema, table.
///
/// The same nesting as the column widths, with a `FilterSet` at the
/// leaf instead of a width.
#[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize)]
pub struct FilterSettingsDocument {
    #[serde(default)]
    pub connections: HashMap<String, Schemas>,
    // A schema name means something only inside its database, so each
    // database of a connection keeps its own.
    #[serde(default)]
    pub sidebar_schemas: HashMap<String, SidebarSchemas>,
}

pub type Schemas = HashMap<String, Tables>;
pub type Tables = HashMap<String, FilterSet>;
pub type SidebarSchemas = HashMap<String, BTreeSet<String>>;

impl VersionedDocument for FilterSettingsDocument {
    const KIND: &'static str = "filter-settings";
    const VERSION: u32 = 2;
    const UPGRADES: &'static [Upgrade] = &[keep_v1];
}

// Version 1 had no sidebar filters, which read as none.
fn keep_v1(document: serde_json::Value) -> Result<serde_json::Value, String> {
    Ok(document)
}

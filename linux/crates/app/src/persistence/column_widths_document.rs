use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use tablepro_storage::document::VersionedDocument;

/// Column widths, keyed connection, schema, table, column.
///
/// The schema is part of the key so `public.users` and `audit.users` do
/// not share one set of widths on a multi-schema database. `None` is
/// stored as the empty string, so every JSON key is concrete.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ColumnWidthsDocument {
    #[serde(default)]
    pub connections: HashMap<String, Schemas>,
}

pub type Schemas = HashMap<String, Tables>;
pub type Tables = HashMap<String, Widths>;
pub type Widths = HashMap<String, i32>;

impl VersionedDocument for ColumnWidthsDocument {
    const KIND: &'static str = "column-widths";
    const VERSION: u32 = 1;
}

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use tablepro_storage::document::VersionedDocument;

use crate::services::grid::HighlightRule;

/// Per-table highlight rules, keyed connection, schema, table, in the
/// same nesting as the filters.
#[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize)]
pub struct HighlightRulesDocument {
    #[serde(default)]
    pub connections: HashMap<String, Schemas>,
}

pub type Schemas = HashMap<String, Tables>;
pub type Tables = HashMap<String, Vec<HighlightRule>>;

impl VersionedDocument for HighlightRulesDocument {
    const KIND: &'static str = "highlight-rules";
    const VERSION: u32 = 1;
}

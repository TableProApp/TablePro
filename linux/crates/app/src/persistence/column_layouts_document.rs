use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use tablepro_storage::document::VersionedDocument;

use crate::services::grid::ColumnLayout;

/// Each table's column layout, keyed connection, schema, table.
///
/// The schema is part of the key so `public.users` and `audit.users` do
/// not share one layout on a multi-schema database. `None` is stored as
/// the empty string, so every JSON key is concrete.
#[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize)]
pub struct ColumnLayoutsDocument {
    #[serde(default)]
    pub connections: HashMap<String, Schemas>,
}

pub type Schemas = HashMap<String, Tables>;
pub type Tables = HashMap<String, ColumnLayout>;

impl VersionedDocument for ColumnLayoutsDocument {
    const KIND: &'static str = "column-layouts";
    const VERSION: u32 = 1;
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use tablepro_storage::document::{decode_document, encode_document};

    use super::*;

    #[test]
    fn a_layout_writes_back_as_version_1() {
        let mut document = ColumnLayoutsDocument::default();
        document
            .connections
            .entry("c1".to_owned())
            .or_default()
            .entry("public".to_owned())
            .or_default()
            .insert("users".to_owned(), ColumnLayout::default().with_hidden("secret", true));

        let bytes = encode_document(&document).expect("encode");
        let text = String::from_utf8_lossy(&bytes);

        assert!(text.contains("\"version\": 1"), "{text}");
        let read = decode_document::<ColumnLayoutsDocument>(Path::new("/tmp/column_layouts.json"), text.as_bytes())
            .expect("the file reads");
        assert_eq!(read, document);
    }
}

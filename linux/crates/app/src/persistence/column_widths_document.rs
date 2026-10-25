use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tablepro_storage::document::{Upgrade, VersionedDocument};

use crate::services::grid::ColumnLayout;

/// Each table's column layout, keyed connection, schema, table.
///
/// The schema is part of the key so `public.users` and `audit.users` do
/// not share one layout on a multi-schema database. `None` is stored as
/// the empty string, so every JSON key is concrete.
#[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize)]
pub struct ColumnWidthsDocument {
    #[serde(default)]
    pub connections: HashMap<String, Schemas>,
}

pub type Schemas = HashMap<String, Tables>;
pub type Tables = HashMap<String, ColumnLayout>;

impl VersionedDocument for ColumnWidthsDocument {
    const KIND: &'static str = "column-widths";
    const VERSION: u32 = 2;
    const UPGRADES: &'static [Upgrade] = &[widths_to_layouts];
}

/// Version 1 kept only each column's width.
#[derive(Deserialize)]
struct WidthsV1 {
    #[serde(default)]
    connections: HashMap<String, SchemasV1>,
}

type SchemasV1 = HashMap<String, HashMap<String, HashMap<String, i32>>>;

fn widths_to_layouts(document: Value) -> Result<Value, String> {
    let old: WidthsV1 = serde_json::from_value(document).map_err(|error| error.to_string())?;
    let connections = old
        .connections
        .into_iter()
        .map(|(connection, schemas)| (connection, schemas_to_layouts(schemas)))
        .collect();
    serde_json::to_value(ColumnWidthsDocument { connections }).map_err(|error| error.to_string())
}

fn schemas_to_layouts(schemas: SchemasV1) -> Schemas {
    schemas
        .into_iter()
        .map(|(schema, tables)| {
            let tables = tables
                .into_iter()
                .map(|(table, widths)| {
                    let layout = ColumnLayout {
                        widths: widths.into_iter().filter(|(_, width)| *width > 0).collect(),
                        ..ColumnLayout::default()
                    };
                    (table, layout)
                })
                .collect();
            (schema, tables)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use tablepro_storage::document::{decode_document, encode_document};

    use super::*;

    fn decode(text: &str) -> ColumnWidthsDocument {
        decode_document::<ColumnWidthsDocument>(Path::new("/tmp/column_widths.json"), text.as_bytes())
            .expect("the file reads")
    }

    fn layout_of<'a>(document: &'a ColumnWidthsDocument, schema: &str, table: &str) -> &'a ColumnLayout {
        document
            .connections
            .get("c1")
            .and_then(|schemas| schemas.get(schema))
            .and_then(|tables| tables.get(table))
            .expect("the table's layout")
    }

    #[test]
    fn a_version_1_file_keeps_its_widths_as_layouts() {
        let document = decode(
            r#"{"version": 1, "connections": {"c1": {
                "public": {"users": {"name": 240, "email": 180}},
                "": {"notes": {"body": 400, "broken": 0}}
            }}}"#,
        );

        let users = layout_of(&document, "public", "users");
        assert_eq!(users.widths.get("name"), Some(&240));
        assert_eq!(users.widths.get("email"), Some(&180));
        assert!(users.order.is_empty() && users.hidden.is_empty());
        let notes = layout_of(&document, "", "notes");
        assert_eq!(notes.widths.len(), 1, "a width no column can have is dropped");
    }

    #[test]
    fn a_layout_writes_back_as_version_2() {
        let mut document = ColumnWidthsDocument::default();
        document
            .connections
            .entry("c1".to_owned())
            .or_default()
            .entry("public".to_owned())
            .or_default()
            .insert("users".to_owned(), ColumnLayout::default().with_hidden("secret", true));

        let bytes = encode_document(&document).expect("encode");
        let text = String::from_utf8_lossy(&bytes);

        assert!(text.contains("\"version\": 2"), "{text}");
        assert_eq!(decode(&text), document);
    }

    #[test]
    fn a_version_1_file_that_is_not_widths_fails_the_upgrade() {
        let problem = decode_document::<ColumnWidthsDocument>(
            Path::new("/tmp/column_widths.json"),
            br#"{"version": 1, "connections": {"c1": {"public": {"users": {"name": "wide"}}}}}"#,
        )
        .expect_err("a width that is no number");

        assert!(
            matches!(
                problem.kind,
                tablepro_storage::DocumentProblemKind::UpgradeFailed {
                    found: 1,
                    expected: 2,
                    ..
                }
            ),
            "{problem:?}"
        );
    }
}

use std::ops::RangeInclusive;

use serde::{Deserialize, Serialize};
use tablepro_core::FilterSet;
use tablepro_storage::DraftId;

use super::{EditorFileRecord, SortRecord};

/// What the page size preference allows.
const PAGE_SIZES: RangeInclusive<u64> = 100..=100_000;
const DEFAULT_PAGE_SIZE: u64 = 1_000;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TabRecord {
    Table {
        schema: Option<String>,
        table: String,
        offset: u64,
        page_size: u64,
        sort: Option<SortRecord>,
        /// The tab's own filter, which two tabs on one table can hold
        /// apart. `None` in a record written before tabs kept one,
        /// which opens on the table's remembered filter as it did.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        filter: Option<FilterSet>,
    },
    Structure {
        schema: Option<String>,
        table: String,
    },
    /// The text lives in the draft store, so a script of any length
    /// costs the record one id.
    Editor {
        draft: DraftId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        file: Option<EditorFileRecord>,
    },
    /// A key-value engine's key, by the name the sidebar lists it as.
    Key { key: String },
}

impl TabRecord {
    /// The record as a tab can be built from it, or `None` when it names
    /// nothing that could exist.
    pub(super) fn clamped(self) -> Option<Self> {
        match self {
            Self::Table {
                schema,
                table,
                offset,
                page_size,
                sort,
                filter,
            } => {
                if table.is_empty() {
                    return None;
                }
                let page_size = if PAGE_SIZES.contains(&page_size) {
                    page_size
                } else {
                    DEFAULT_PAGE_SIZE
                };
                Some(Self::Table {
                    schema,
                    table,
                    offset,
                    page_size,
                    sort,
                    filter,
                })
            }
            Self::Structure { schema, table } => (!table.is_empty()).then_some(Self::Structure { schema, table }),
            Self::Editor { draft, file } => Some(Self::Editor { draft, file }),
            // A key's name can be empty, as Redis lets one be.
            Self::Key { key } => Some(Self::Key { key }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(name: &str, page_size: u64) -> TabRecord {
        TabRecord::Table {
            schema: Some("public".to_owned()),
            table: name.to_owned(),
            offset: 0,
            page_size,
            sort: None,
            filter: None,
        }
    }

    #[test]
    fn a_page_size_outside_the_preference_range_falls_back_to_the_default() {
        let Some(TabRecord::Table { page_size, .. }) = table("users", 999_999).clamped() else {
            panic!("the table record was dropped");
        };

        assert_eq!(page_size, DEFAULT_PAGE_SIZE);
        assert_eq!(table("users", 250).clamped(), Some(table("users", 250)));
    }

    #[test]
    fn a_record_naming_no_table_is_dropped() {
        assert_eq!(table("", 1_000).clamped(), None);
        let structure = TabRecord::Structure {
            schema: Some("public".to_owned()),
            table: String::new(),
        };
        assert_eq!(structure.clamped(), None);
    }

    #[test]
    fn a_key_reads_back_as_it_was_written() {
        let record = TabRecord::Key {
            key: "\"\\xff\"".to_owned(),
        };

        let json = serde_json::to_string(&record).unwrap();

        assert_eq!(json, r#"{"kind":"key","key":"\"\\xff\""}"#);
        assert_eq!(serde_json::from_str::<TabRecord>(&json).unwrap(), record);
        assert_eq!(record.clone().clamped(), Some(record));
    }

    #[test]
    fn a_long_name_is_kept() {
        // SQLite sets no limit on a name's length.
        let long = table(&"t".repeat(1_000), 1_000);
        let structure = TabRecord::Structure {
            schema: Some("s".repeat(1_000)),
            table: "users".to_owned(),
        };

        assert_eq!(long.clone().clamped(), Some(long));
        assert_eq!(structure.clone().clamped(), Some(structure));
    }
}

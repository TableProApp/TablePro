use std::ops::RangeInclusive;

use serde::{Deserialize, Serialize};
use tablepro_storage::DraftId;

use super::SortRecord;

/// What the page size preference allows.
const PAGE_SIZES: RangeInclusive<u64> = 100..=100_000;
const DEFAULT_PAGE_SIZE: u64 = 1_000;
/// No engine allows a name this long, so a record with one names no
/// table there is to reopen.
const MAX_NAME_BYTES: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TabRecord {
    Table {
        schema: Option<String>,
        table: String,
        offset: u64,
        page_size: u64,
        sort: Option<SortRecord>,
    },
    Structure {
        schema: Option<String>,
        table: String,
    },
    /// The text lives in the draft store, so a script of any length
    /// costs the record one id.
    Editor {
        draft: DraftId,
    },
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
            } => {
                if !names_fit(schema.as_deref(), &table) {
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
                })
            }
            Self::Structure { schema, table } => {
                names_fit(schema.as_deref(), &table).then_some(Self::Structure { schema, table })
            }
            Self::Editor { draft } => Some(Self::Editor { draft }),
        }
    }
}

fn names_fit(schema: Option<&str>, table: &str) -> bool {
    !table.is_empty() && table.len() <= MAX_NAME_BYTES && schema.is_none_or(|schema| schema.len() <= MAX_NAME_BYTES)
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
    fn a_record_naming_no_possible_table_is_dropped() {
        assert_eq!(table("", 1_000).clamped(), None);
        assert_eq!(table(&"t".repeat(MAX_NAME_BYTES + 1), 1_000).clamped(), None);
        let structure = TabRecord::Structure {
            schema: Some("s".repeat(MAX_NAME_BYTES + 1)),
            table: "users".to_owned(),
        };
        assert_eq!(structure.clamped(), None);
    }
}

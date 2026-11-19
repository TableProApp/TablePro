use std::ops::RangeInclusive;

use gtk4::glib::{self, Unichar};
use serde::{Deserialize, Serialize};
use tablepro_core::FilterSet;
use tablepro_storage::DraftId;
use unicode_segmentation::UnicodeSegmentation;

use super::{DiagramPlace, EditorFileRecord, SortRecord};

/// What the page size preference allows.
const PAGE_SIZES: RangeInclusive<u64> = 100..=100_000;
const DEFAULT_PAGE_SIZE: u64 = 1_000;

const TAB_NAME_GRAPHEMES: usize = 100;

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
        /// apart. `None` opens on the table's remembered filter.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        filter: Option<FilterSet>,
    },
    Structure {
        schema: Option<String>,
        table: String,
    },
    /// A schema's ER diagram. Its tables are read again when it opens,
    /// and those the user moved go back where they were put; with none
    /// moved, the automatic layout places them all.
    Diagram {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        schema: Option<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        places: Vec<DiagramPlace>,
    },
    /// The text lives in the draft store, so a script of any length
    /// costs the record one id.
    Editor {
        draft: DraftId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        file: Option<EditorFileRecord>,
        /// The database the editor bar moved the tab to. `None` keeps the
        /// connection's own.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        database: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ordinal: Option<u32>,
        // The sample text a new tab shows is not blank, so only this says the tab is still `Query N`.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        untitled: bool,
    },
    /// A key-value engine's key, by the name the sidebar lists it as.
    Key {
        key: String,
    },
}

impl TabRecord {
    /// How large the state a tab can be saved without is, encoded, or
    /// `None` with none to leave out.
    pub(super) fn optional_size(&self) -> Option<usize> {
        let encoded = match self {
            Self::Table {
                filter: Some(filter), ..
            } => serde_json::to_vec(filter),
            Self::Diagram { places, .. } if !places.is_empty() => serde_json::to_vec(places),
            Self::Editor { name: Some(name), .. } => serde_json::to_vec(name),
            _ => return None,
        };
        Some(encoded.map_or(usize::MAX, |json| json.len()))
    }

    // `shrink_to_fit` loops until nothing is counted, so this drops everything `optional_size` counts.
    pub(super) fn drop_optional(&mut self) {
        match self {
            Self::Table { filter, .. } => *filter = None,
            Self::Diagram { places, .. } => places.clear(),
            Self::Editor { name, .. } => *name = None,
            Self::Structure { .. } | Self::Key { .. } => {}
        }
    }

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
            Self::Diagram { schema, places } => Some(Self::Diagram { schema, places }),
            // The file can be edited by hand, and a file's name always wins over a typed one.
            Self::Editor {
                draft,
                file,
                database,
                name,
                ordinal,
                untitled,
            } => Some(Self::Editor {
                name: name
                    .filter(|_| file.is_none())
                    .and_then(|name| normalized_tab_name(&name)),
                ordinal: ordinal.filter(|ordinal| *ordinal > 0),
                draft,
                file,
                database,
                untitled,
            }),
            // A key's name can be empty, as Redis lets one be.
            Self::Key { key } => Some(Self::Key { key }),
        }
    }
}

pub(crate) fn normalized_tab_name(text: &str) -> Option<String> {
    let mut spaced = String::with_capacity(text.len());
    let mut in_break = false;
    for character in text.chars() {
        let breaks = breaks_line(character);
        if breaks && !in_break {
            spaced.push(' ');
        } else if !breaks {
            spaced.push(character);
        }
        in_break = breaks;
    }
    let cut: String = spaced.trim().graphemes(true).take(TAB_NAME_GRAPHEMES).collect();
    let name = cut.trim_end();
    // A blank tab label reads as no tab at all, and emoji need ZWJ, so only a wholly invisible name is empty.
    (!name.chars().all(invisible)).then(|| name.to_owned())
}

fn breaks_line(character: char) -> bool {
    matches!(
        character.unicode_type(),
        glib::UnicodeType::Control | glib::UnicodeType::LineSeparator | glib::UnicodeType::ParagraphSeparator
    )
}

fn invisible(character: char) -> bool {
    character.is_whitespace() || character.unicode_type() == glib::UnicodeType::Format
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

    fn editor(name: Option<&str>, file: Option<EditorFileRecord>) -> TabRecord {
        TabRecord::Editor {
            draft: DraftId::new(),
            file,
            database: None,
            name: name.map(str::to_owned),
            ordinal: Some(3),
            untitled: true,
        }
    }

    fn daily_sql() -> Option<EditorFileRecord> {
        Some(EditorFileRecord {
            uri: "file:///home/ada/daily.sql".to_owned(),
            modified: false,
        })
    }

    #[test]
    fn an_editor_record_writes_its_name_number_and_untitled_mark_only_when_it_has_them() {
        let draft = DraftId::new();
        let plain = TabRecord::Editor {
            draft,
            file: None,
            database: None,
            name: None,
            ordinal: None,
            untitled: false,
        };
        let named = TabRecord::Editor {
            draft,
            file: None,
            database: None,
            name: Some("Revenue".to_owned()),
            ordinal: Some(2),
            untitled: true,
        };

        let plain_json = serde_json::to_string(&plain).unwrap();
        let named_json = serde_json::to_string(&named).unwrap();

        assert_eq!(plain_json, format!(r#"{{"kind":"editor","draft":"{draft}"}}"#));
        assert_eq!(
            named_json,
            format!(r#"{{"kind":"editor","draft":"{draft}","name":"Revenue","ordinal":2,"untitled":true}}"#)
        );
        assert_eq!(serde_json::from_str::<TabRecord>(&named_json).unwrap(), named);
    }

    #[test]
    fn an_editor_record_from_an_earlier_build_reads_with_no_name() {
        let draft = DraftId::new();

        let read: TabRecord = serde_json::from_str(&format!(r#"{{"kind":"editor","draft":"{draft}"}}"#)).unwrap();

        assert_eq!(
            read,
            TabRecord::Editor {
                draft,
                file: None,
                database: None,
                name: None,
                ordinal: None,
                untitled: false,
            }
        );
    }

    #[test]
    fn clamped_drops_a_blank_name_a_name_on_a_file_and_number_zero() {
        let name_of = |record: TabRecord| match record.clamped() {
            Some(TabRecord::Editor { name, .. }) => name,
            _ => panic!("the editor record was dropped"),
        };

        assert_eq!(name_of(editor(Some("Revenue"), None)).as_deref(), Some("Revenue"));
        assert_eq!(name_of(editor(Some(" \t\u{200B} "), None)), None);
        assert_eq!(name_of(editor(Some("Revenue"), daily_sql())), None);
        let Some(TabRecord::Editor { ordinal, .. }) = TabRecord::Editor {
            draft: DraftId::new(),
            file: None,
            database: None,
            name: None,
            ordinal: Some(0),
            untitled: false,
        }
        .clamped() else {
            panic!("the editor record was dropped");
        };
        assert_eq!(ordinal, None);
    }

    #[test]
    fn clamped_cuts_a_name_written_by_hand_to_the_limit() {
        let Some(TabRecord::Editor { name: Some(name), .. }) = editor(Some(&"é".repeat(500)), None).clamped() else {
            panic!("the name was dropped");
        };

        assert_eq!(name.chars().count(), TAB_NAME_GRAPHEMES);
    }

    #[test]
    fn a_name_is_optional_state_and_leaves_with_it() {
        let mut named = editor(Some("Revenue"), None);
        assert_eq!(named.optional_size(), Some(r#""Revenue""#.len()));

        named.drop_optional();

        assert_eq!(named.optional_size(), None);
        assert!(matches!(
            named,
            TabRecord::Editor {
                name: None,
                ordinal: Some(3),
                untitled: true,
                ..
            }
        ));
        assert_eq!(editor(None, None).optional_size(), None);
    }

    #[test]
    fn line_breaks_and_control_characters_become_one_space() {
        assert_eq!(
            normalized_tab_name("Monthly\r\nrevenue").as_deref(),
            Some("Monthly revenue")
        );
        assert_eq!(normalized_tab_name("a\tb").as_deref(), Some("a b"));
        assert_eq!(normalized_tab_name("a\u{2028}\u{2029}b").as_deref(), Some("a b"));
        assert_eq!(normalized_tab_name("a\u{0}\u{7}b").as_deref(), Some("a b"));
        assert_eq!(normalized_tab_name("  Revenue \n").as_deref(), Some("Revenue"));
    }

    #[test]
    fn a_name_with_nothing_to_see_is_no_name() {
        assert_eq!(normalized_tab_name(""), None);
        assert_eq!(normalized_tab_name(" \n\t "), None);
        assert_eq!(normalized_tab_name("\u{200B}\u{FEFF}"), None);
        assert_eq!(normalized_tab_name("\u{200D}"), None);
        assert_eq!(normalized_tab_name("\u{00A0}\u{3000}"), None);
    }

    #[test]
    fn a_joiner_inside_a_name_stays() {
        let coder = "\u{1F469}\u{200D}\u{1F4BB}";

        assert_eq!(
            normalized_tab_name(&format!("{coder} Report")),
            Some(format!("{coder} Report"))
        );
        assert_eq!(normalized_tab_name("Query 3").as_deref(), Some("Query 3"));
    }

    #[test]
    fn a_long_name_is_cut_to_whole_characters_and_trimmed_again() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
        let long = family.repeat(150);

        let cut = normalized_tab_name(&long).expect("a name");

        assert_eq!(cut.graphemes(true).count(), TAB_NAME_GRAPHEMES);
        assert_eq!(cut, family.repeat(TAB_NAME_GRAPHEMES));
        let spaced = format!("{} tail", "x".repeat(TAB_NAME_GRAPHEMES - 1));
        assert_eq!(normalized_tab_name(&spaced), Some("x".repeat(TAB_NAME_GRAPHEMES - 1)));
    }
}

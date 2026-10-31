use serde::{Deserialize, Serialize};
use serde_json::Value;
use tablepro_storage::document::{Upgrade, VersionedDocument};

use super::TabRecord;

/// One session's saved tabs, in the order the window showed them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceRecord {
    /// An index into `tabs`, not into the window's pages: a tab that is
    /// not saved has no record to point at.
    #[serde(default)]
    pub active_tab: Option<u32>,
    #[serde(default)]
    pub tabs: Vec<TabRecord>,
}

impl VersionedDocument for WorkspaceRecord {
    const KIND: &'static str = "workspace";
    const VERSION: u32 = 2;
    const UPGRADES: &'static [Upgrade] = &[diagram_tabs];
}

/// Version 2 adds the diagram tab. Every version 1 tab reads as it was,
/// and a build that knows only version 1 says a version 2 file is from a
/// newer build rather than calling it unreadable.
fn diagram_tabs(document: Value) -> Result<Value, String> {
    Ok(document)
}

impl WorkspaceRecord {
    /// Leave out the tabs' optional state, the largest first, until the
    /// file is no larger than the store reads back: a table tab's filter
    /// and a diagram's places. A file past the cap would block every saved
    /// tab of the session.
    pub fn shrink_to_fit(&mut self) {
        loop {
            let size = tablepro_storage::document::encode_document(&*self)
                .map_or(u64::MAX, |bytes| u64::try_from(bytes.len()).unwrap_or(u64::MAX));
            if size <= super::workspace_store::MAX_FILE_BYTES {
                return;
            }
            let largest = self
                .tabs
                .iter_mut()
                .filter_map(|tab| tab.optional_size().map(|size| (size, tab)))
                .max_by_key(|(size, _)| *size);
            let Some((_, tab)) = largest else {
                return;
            };
            tab.drop_optional();
        }
    }

    /// The record as a window can rebuild it: no tab naming something
    /// that could not exist, and `active_tab` still pointing at the tab
    /// it named, or at none.
    ///
    /// The tab count is not capped: the window saves every tab it has,
    /// and an editor tab cut here would have its draft deleted as one
    /// no tab names. The store's cap on the file size bounds a load.
    pub fn clamped(self) -> Self {
        let active = self.active_tab.and_then(|index| usize::try_from(index).ok());
        let mut tabs = Vec::with_capacity(self.tabs.len());
        let mut active_tab = None;
        for (index, tab) in self.tabs.into_iter().enumerate() {
            let Some(tab) = tab.clamped() else {
                continue;
            };
            if active == Some(index) {
                active_tab = u32::try_from(tabs.len()).ok();
            }
            tabs.push(tab);
        }
        Self { active_tab, tabs }
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use tablepro_storage::DraftId;
    use tablepro_storage::document::{decode_document, encode_document};

    use super::*;
    use crate::workspace::SortRecord;

    fn table(name: &str) -> TabRecord {
        TabRecord::Table {
            schema: Some("public".to_owned()),
            table: name.to_owned(),
            offset: 0,
            page_size: 1_000,
            filter: None,
            sort: None,
        }
    }

    #[test]
    fn round_trip() {
        let record = WorkspaceRecord {
            active_tab: Some(1),
            tabs: vec![
                TabRecord::Table {
                    schema: Some("public".to_owned()),
                    table: "orders".to_owned(),
                    offset: 5_000,
                    page_size: 5_000,
                    filter: None,
                    sort: Some(SortRecord {
                        column: 2,
                        ascending: false,
                    }),
                },
                TabRecord::Structure {
                    schema: None,
                    table: "users".to_owned(),
                },
                TabRecord::Editor {
                    draft: DraftId::new(),
                    file: None,
                    database: None,
                },
                TabRecord::Diagram {
                    schema: Some("sales".to_owned()),
                    places: vec![crate::workspace::DiagramPlace {
                        table: "orders".to_owned(),
                        x: -120,
                        y: 340,
                    }],
                },
                TabRecord::Diagram {
                    schema: None,
                    places: Vec::new(),
                },
            ],
        };

        let bytes = encode_document(&record).expect("encode");
        let decoded: WorkspaceRecord = decode_document(Path::new("/tmp/w.json"), &bytes).expect("decode");

        assert_eq!(decoded, record);
        let text = String::from_utf8_lossy(&bytes);
        assert!(text.contains("\"version\": 2"), "{text}");
        assert!(!text.contains("SELECT"), "an editor record carries text: {text}");
    }

    /// A version 1 workspace file, the format 0.1.0 ships. Never edit the
    /// fixture: a format change adds an upgrade step and updates the
    /// model here.
    #[test]
    fn a_version_1_workspace_reads_as_it_was_written() {
        let bytes = include_bytes!("../../tests/fixtures/workspace-v1.json");
        let draft = uuid::Uuid::parse_str("7d0c5b1e-9a3f-4e2d-8b6c-1f0e9d8c7b6a").expect("a uuid");

        let decoded: WorkspaceRecord = decode_document(Path::new("/tmp/w.json"), bytes).expect("decode");

        assert_eq!(
            decoded,
            WorkspaceRecord {
                active_tab: Some(2),
                tabs: vec![
                    TabRecord::Table {
                        schema: Some("public".to_owned()),
                        table: "orders".to_owned(),
                        offset: 5_000,
                        page_size: 5_000,
                        filter: None,
                        sort: Some(SortRecord {
                            column: 2,
                            ascending: false,
                        }),
                    },
                    TabRecord::Table {
                        schema: None,
                        table: "events".to_owned(),
                        offset: 0,
                        page_size: 1_000,
                        filter: None,
                        sort: None,
                    },
                    TabRecord::Editor {
                        draft: DraftId::from_uuid(draft),
                        file: None,
                        database: None,
                    },
                    TabRecord::Structure {
                        schema: Some("sales".to_owned()),
                        table: "customers".to_owned(),
                    },
                    TabRecord::Structure {
                        schema: None,
                        table: "users".to_owned(),
                    },
                ],
            }
        );
        assert_eq!(
            decoded.clone().clamped(),
            decoded,
            "the fixture holds only tabs a window can open"
        );
    }

    /// A version 2 workspace file, the first with diagram tabs. Never edit
    /// the fixture.
    #[test]
    fn a_version_2_workspace_reads_as_it_was_written() {
        let bytes = include_bytes!("../../tests/fixtures/workspace-v2.json");
        let draft = uuid::Uuid::parse_str("7d0c5b1e-9a3f-4e2d-8b6c-1f0e9d8c7b6a").expect("a uuid");
        let place = |table: &str, x, y| crate::workspace::DiagramPlace {
            table: table.to_owned(),
            x,
            y,
        };

        let decoded: WorkspaceRecord = decode_document(Path::new("/tmp/w.json"), bytes).expect("decode");

        assert_eq!(
            decoded,
            WorkspaceRecord {
                active_tab: Some(3),
                tabs: vec![
                    TabRecord::Table {
                        schema: Some("public".to_owned()),
                        table: "orders".to_owned(),
                        offset: 0,
                        page_size: 1_000,
                        filter: None,
                        sort: None,
                    },
                    TabRecord::Editor {
                        draft: DraftId::from_uuid(draft),
                        file: None,
                        database: None,
                    },
                    TabRecord::Structure {
                        schema: Some("sales".to_owned()),
                        table: "customers".to_owned(),
                    },
                    TabRecord::Diagram {
                        schema: Some("sales".to_owned()),
                        places: vec![place("customers", -120, 40), place("orders", 336, 0)],
                    },
                    TabRecord::Diagram {
                        schema: None,
                        places: Vec::new(),
                    },
                    TabRecord::Key {
                        key: "user:1".to_owned(),
                    },
                ],
            }
        );
        assert_eq!(decoded.clone().clamped(), decoded);
    }

    #[test]
    fn clamped_keeps_every_tab_however_many() {
        let record = WorkspaceRecord {
            active_tab: Some(35),
            tabs: (0..40)
                .map(|index| match index % 2 {
                    0 => TabRecord::Editor {
                        draft: DraftId::new(),
                        file: None,
                        database: None,
                    },
                    _ => table(&format!("t{index}")),
                })
                .collect(),
        };

        assert_eq!(record.clone().clamped(), record);
    }

    #[test]
    fn clamped_resets_an_active_tab_past_the_end() {
        let record = WorkspaceRecord {
            active_tab: Some(3),
            tabs: vec![table("a"), table("b")],
        };

        assert_eq!(record.clamped().active_tab, None);
    }

    #[test]
    fn clamped_keeps_active_tab_on_the_tab_it_named() {
        let record = WorkspaceRecord {
            active_tab: Some(2),
            tabs: vec![table("a"), table(""), table("c")],
        };

        let clamped = record.clamped();

        assert_eq!(clamped.tabs, vec![table("a"), table("c")]);
        assert_eq!(clamped.active_tab, Some(1));
    }

    #[test]
    fn clamped_drops_an_active_tab_that_named_a_dropped_record() {
        let record = WorkspaceRecord {
            active_tab: Some(1),
            tabs: vec![table("a"), table("")],
        };

        assert_eq!(record.clamped().active_tab, None);
    }

    /// Each part under its own budget can still make a file past the cap
    /// once pretty-printed together, which would block every saved tab.
    #[test]
    fn a_record_past_the_file_cap_leaves_out_the_largest_optional_state() {
        let places = |count: usize| {
            (0..count)
                .map(|at| crate::workspace::DiagramPlace {
                    table: format!("table_{at:05}"),
                    x: 1_000,
                    y: 2_000,
                })
                .collect::<Vec<_>>()
        };
        let mut record = WorkspaceRecord {
            active_tab: Some(0),
            tabs: vec![
                TabRecord::Diagram {
                    schema: Some("public".to_owned()),
                    places: places(16_000),
                },
                TabRecord::Diagram {
                    schema: Some("audit".to_owned()),
                    places: places(3),
                },
                table("orders"),
            ],
        };

        record.shrink_to_fit();

        let bytes = encode_document(&record).expect("encode");
        assert!(bytes.len() as u64 <= super::super::workspace_store::MAX_FILE_BYTES);
        let kept: Vec<usize> = record
            .tabs
            .iter()
            .map(|tab| match tab {
                TabRecord::Diagram { places, .. } => places.len(),
                _ => usize::MAX,
            })
            .collect();
        assert_eq!(kept, [0, 3, usize::MAX], "only the largest is left out");
    }
}

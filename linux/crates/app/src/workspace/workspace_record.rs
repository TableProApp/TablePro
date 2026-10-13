use serde::{Deserialize, Serialize};
use tablepro_storage::document::VersionedDocument;

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
    const VERSION: u32 = 1;
}

impl WorkspaceRecord {
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
                    sort: Some(SortRecord {
                        column: 2,
                        ascending: false,
                    }),
                },
                TabRecord::Structure {
                    schema: None,
                    table: "users".to_owned(),
                },
                TabRecord::Editor { draft: DraftId::new() },
            ],
        };

        let bytes = encode_document(&record).expect("encode");
        let decoded: WorkspaceRecord = decode_document(Path::new("/tmp/w.json"), &bytes).expect("decode");

        assert_eq!(decoded, record);
        let text = String::from_utf8_lossy(&bytes);
        assert!(text.contains("\"version\": 1"), "{text}");
        assert!(!text.contains("SELECT"), "an editor record carries text: {text}");
    }

    #[test]
    fn clamped_keeps_every_tab_however_many() {
        let record = WorkspaceRecord {
            active_tab: Some(35),
            tabs: (0..40)
                .map(|index| match index % 2 {
                    0 => TabRecord::Editor { draft: DraftId::new() },
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
}

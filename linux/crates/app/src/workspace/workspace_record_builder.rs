use uuid::Uuid;

use super::{TabSnapshot, WorkspaceRecord};

/// The record of `pages`, in their order. The active tab is the index of
/// the selected page's record among the saved ones, not among the pages,
/// and none when the selected page saves nothing.
pub fn workspace_record(pages: &[TabSnapshot], selected: Option<Uuid>) -> WorkspaceRecord {
    let mut record = WorkspaceRecord::default();
    for page in pages {
        let Some(saved) = &page.record else {
            continue;
        };
        if selected == Some(page.id) {
            record.active_tab = u32::try_from(record.tabs.len()).ok();
        }
        record.tabs.push(saved.clone());
    }
    record
}

#[cfg(test)]
mod tests {
    use tablepro_storage::DraftId;

    use super::*;
    use crate::workspace::TabRecord;

    fn page(record: Option<TabRecord>) -> TabSnapshot {
        TabSnapshot {
            id: Uuid::new_v4(),
            record,
        }
    }

    fn table(name: &str) -> TabRecord {
        TabRecord::Table {
            schema: Some("public".to_owned()),
            table: name.to_owned(),
            offset: 0,
            page_size: 1_000,
            sort: None,
        }
    }

    fn structure(name: &str) -> TabRecord {
        TabRecord::Structure {
            schema: Some("public".to_owned()),
            table: name.to_owned(),
        }
    }

    #[test]
    fn active_tab_counts_only_persisted_records() {
        let pages = [page(None), page(Some(table("a"))), page(Some(structure("b")))];

        let record = workspace_record(&pages, Some(pages[2].id));

        assert_eq!(record.tabs, [table("a"), structure("b")]);
        assert_eq!(record.active_tab, Some(1));
    }

    #[test]
    fn selected_new_draft_gives_no_active_tab() {
        let pages = [page(Some(TabRecord::Editor { draft: DraftId::new() })), page(None)];

        let record = workspace_record(&pages, Some(pages[1].id));

        assert_eq!(record.tabs.len(), 1);
        assert_eq!(record.active_tab, None);
    }

    #[test]
    fn nothing_selected_gives_no_active_tab() {
        let pages = [page(Some(table("a")))];

        assert_eq!(workspace_record(&pages, None).active_tab, None);
    }
}

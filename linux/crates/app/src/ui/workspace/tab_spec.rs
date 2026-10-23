use tablepro_core::meta::TableRef;
use tablepro_storage::DraftId;

use super::structure_target::StructureTarget;
use crate::ui::browse_tab::TableFilter;
use crate::workspace::EditorFileRecord;

/// A tab to open. Every way a tab opens builds one of these: the sidebar,
/// the overview's new-tab button, a restore and a reopen.
#[derive(Debug, Clone)]
pub(crate) enum TabSpec {
    Editor {
        initial_query: Option<String>,
        /// The draft a restored tab keeps writing to. `None` gives a new
        /// tab a new draft, written at once.
        draft: Option<DraftId>,
        /// The `.sql` file a restored or reopened tab is saved to.
        file: Option<EditorFileRecord>,
    },
    Table {
        table: TableRef,
        page: TablePage,
        filter: TableFilter,
    },
    Structure {
        target: StructureTarget,
    },
    /// A key-value engine's key, by the name the sidebar lists it as.
    Key {
        key: String,
    },
}

/// Where a table tab opens in its rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TablePage {
    pub offset: u64,
    pub page_size: u64,
    /// The column index and whether it sorts ascending.
    pub sort: Option<(usize, bool)>,
}

impl TablePage {
    pub(crate) fn first(page_size: u64) -> Self {
        Self {
            offset: 0,
            page_size,
            sort: None,
        }
    }
}

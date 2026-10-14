use std::rc::Rc;

use gtk4::glib;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::WorkspaceTab;
use super::tab_index::TabIndex;
use super::workspace_persistence::WorkspaceTabs;
use crate::workspace::{TabDirectory, TabEntry};

/// The window's tabs as the close prompts read them: in tab bar order,
/// by the names their tabs show.
pub(super) struct WindowTabs {
    tabs: WorkspaceTabs,
    index: Rc<TabIndex>,
    /// Held weakly: the workspace owns the view, and the close prompts
    /// can outlive it.
    view: glib::WeakRef<adw::TabView>,
}

impl WindowTabs {
    pub(super) fn new(tabs: WorkspaceTabs, index: Rc<TabIndex>, view: &adw::TabView) -> Self {
        Self {
            tabs,
            index,
            view: view.downgrade(),
        }
    }
}

impl TabDirectory for WindowTabs {
    fn tabs(&self) -> Vec<TabEntry> {
        let Some(view) = self.view.upgrade() else {
            return Vec::new();
        };
        let tabs = self.tabs.borrow();
        let pages = view.pages();
        (0..pages.n_items())
            .filter_map(|index| pages.item(index).and_downcast::<adw::TabPage>())
            .filter_map(|page| {
                let id = self.index.id_of(&page)?;
                let tab = tabs.get(&id)?;
                Some(TabEntry {
                    id,
                    title: page.title().to_string(),
                    open_transaction: matches!(
                        tab,
                        WorkspaceTab::Editor(slot) if slot.editor.has_open_transaction()
                    ),
                })
            })
            .collect()
    }
}

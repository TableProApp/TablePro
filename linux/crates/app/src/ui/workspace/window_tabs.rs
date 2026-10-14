use std::cell::RefCell;

use gtk4::glib;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::workspace_persistence::WorkspaceTabs;
use super::{WorkspaceTab, read_workspace_tab_id};
use crate::workspace::{TabDirectory, TabEntry};

/// The window's tabs as the close prompts read them: in tab bar order,
/// by the names their tabs show.
pub(super) struct WindowTabs {
    tabs: WorkspaceTabs,
    view: RefCell<glib::WeakRef<adw::TabView>>,
}

impl WindowTabs {
    pub(super) fn new(tabs: WorkspaceTabs) -> Self {
        Self {
            tabs,
            view: RefCell::new(glib::WeakRef::new()),
        }
    }

    /// The tab view built for a connection, or `None` once it is torn
    /// down.
    pub(super) fn set_view(&self, view: Option<&adw::TabView>) {
        let weak = glib::WeakRef::new();
        weak.set(view);
        self.view.replace(weak);
    }
}

impl TabDirectory for WindowTabs {
    fn tabs(&self) -> Vec<TabEntry> {
        let Some(view) = self.view.borrow().upgrade() else {
            return Vec::new();
        };
        let tabs = self.tabs.borrow();
        let pages = view.pages();
        (0..pages.n_items())
            .filter_map(|index| pages.item(index).and_downcast::<adw::TabPage>())
            .filter_map(|page| {
                let id = read_workspace_tab_id(&page)?;
                let tab = tabs.get(&id)?;
                let title = page.title();
                Some(TabEntry {
                    id,
                    title: title.strip_prefix("• ").unwrap_or(&title).to_owned(),
                    open_transaction: matches!(
                        tab,
                        WorkspaceTab::Editor(slot) if slot.editor.has_open_transaction()
                    ),
                })
            })
            .collect()
    }
}

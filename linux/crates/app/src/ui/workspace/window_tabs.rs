use std::rc::Rc;

use futures::future::LocalBoxFuture;
use gtk4::glib;
use libadwaita as adw;
use libadwaita::prelude::*;
use uuid::Uuid;

use super::WorkspaceTab;
use super::tab_index::TabIndex;
use super::workspace_persistence::WorkspaceTabs;
use crate::ui::editor::SqlEditor;
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
                let editor = match tabs.get(&id)? {
                    WorkspaceTab::Editor(slot) => Some(&slot.editor),
                    WorkspaceTab::Structure(_) | WorkspaceTab::Table(_) | WorkspaceTab::Diagram(_) => None,
                };
                Some(TabEntry {
                    id,
                    title: page.title().to_string(),
                    open_transaction: editor.is_some_and(SqlEditor::has_open_transaction),
                    unsaved_file: editor.is_some_and(SqlEditor::has_unsaved_file_changes),
                })
            })
            .collect()
    }

    fn save_file(&self, tab: Uuid) -> Option<LocalBoxFuture<'static, Result<(), String>>> {
        let tabs = self.tabs.borrow();
        let WorkspaceTab::Editor(slot) = tabs.get(&tab)? else {
            return None;
        };
        slot.editor.file()?;
        Some(Box::pin(slot.editor.save_to_file()))
    }
}

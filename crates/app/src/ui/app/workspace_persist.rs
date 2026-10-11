use std::time::Duration;

use relm4::ComponentController;
use relm4::adw::prelude::*;
use relm4::gtk::glib;

use uuid::Uuid;

use crate::services::request_generation;
use crate::services::workspace_state::{self, ConnectionWorkspaceState, WorkspaceTabRecord};

use super::types::read_workspace_tab_id;
use super::{App, WorkspaceTab};

pub(super) const PERSIST_DELAY: Duration = Duration::from_millis(500);

impl App {
    pub(super) fn persist_workspace_state(&self) {
        self.replace_persist_timer();
        let generation = self.persist_generation.get();
        self.persist_pending.set(true);
        let pending = self.persist_pending.clone();
        let timeout = self.persist_timeout.clone();
        let current_generation = self.persist_generation.clone();
        let workspace_tabs = self.workspace_tabs.clone();
        let tab_view = self.workspace_tab_view.clone();
        let connection_id = self.connection_id;
        let workspace = self.workspace.clone();
        let collapsed = self.sidebar_collapsed.clone();
        let id = glib::timeout_add_local_once(PERSIST_DELAY, move || {
            timeout.borrow_mut().take();
            pending.set(false);
            if !request_generation::is_current(generation, current_generation.get()) {
                return;
            }
            do_persist_workspace_state(
                &workspace,
                connection_id,
                &workspace_tabs,
                tab_view.as_ref(),
                collapsed.borrow().keys(),
            );
        });
        *self.persist_timeout.borrow_mut() = Some(id);
    }

    pub(super) fn cancel_persist_timer(&self) {
        self.replace_persist_timer();
        self.persist_pending.set(false);
    }

    pub(super) fn do_persist_workspace_state_now(&self) {
        self.cancel_persist_timer();
        do_persist_workspace_state(
            &self.workspace,
            self.connection_id,
            &self.workspace_tabs,
            self.workspace_tab_view.as_ref(),
            self.sidebar_collapsed.borrow().keys(),
        );
    }

    fn replace_persist_timer(&self) {
        if let Some(id) = self.persist_timeout.borrow_mut().take() {
            id.remove();
        }
        self.persist_generation
            .set(self.persist_generation.get().wrapping_add(1));
    }
}

fn do_persist_workspace_state(
    workspace: &workspace_state::WorkspaceStore,
    connection_id: Option<Uuid>,
    workspace_tabs: &std::rc::Rc<std::cell::RefCell<std::collections::HashMap<Uuid, WorkspaceTab>>>,
    tab_view: Option<&relm4::adw::TabView>,
    collapsed_groups: Vec<String>,
) {
    let Some(connection_id) = connection_id else {
        return;
    };
    let tabs = workspace_tabs.borrow();
    let Some(tab_view) = tab_view else {
        return;
    };
    let pages = tab_view.pages();
    let n = pages.n_items();
    let active_page = tab_view.selected_page();
    let mut tab_records = Vec::with_capacity(n as usize);
    let mut kept = Vec::with_capacity(n as usize);
    let mut active_raw_index = None;
    for i in 0..n {
        let Some(page) = pages.item(i).and_downcast::<relm4::adw::TabPage>() else {
            kept.push(false);
            continue;
        };
        if active_page.as_ref() == Some(&page) {
            active_raw_index = Some(i as usize);
        }
        let record = read_workspace_tab_id(&page)
            .and_then(|id| tabs.get(&id).map(|slot| (id, slot)))
            .and_then(|(id, slot)| match slot {
                WorkspaceTab::Editor(s) => Some(WorkspaceTabRecord::Editor {
                    query: s.query.clone(),
                    draft_id: Some(id),
                    file: s.file.as_ref().map(|file| file.path.clone()),
                }),
                WorkspaceTab::Structure(_) => None,
                WorkspaceTab::Table(s) if s.table.is_empty() => None,
                WorkspaceTab::Table(s) => {
                    let model = s.browse.model();
                    let sort = model.current_sort();
                    Some(WorkspaceTabRecord::Table {
                        schema: s.schema.clone(),
                        table: s.table.clone(),
                        mode: workspace_state::PersistedTableMode::Data,
                        offset: model.current_offset(),
                        page_size: model.page_size(),
                        sort_col: sort.map(|(column, _)| column),
                        sort_asc: sort.map(|(_, ascending)| ascending),
                    })
                }
            });
        kept.push(record.is_some());
        if let Some(record) = record {
            tab_records.push(record);
        }
    }
    let active_idx = active_idx_among_kept(&kept, active_raw_index);
    workspace.save_connection(
        connection_id,
        ConnectionWorkspaceState {
            tabs: tab_records,
            active_idx,
            collapsed_groups,
        },
    );
}

/// `kept[i]` says whether the tab strip's raw position `i` produced a
/// persisted record -- a Structure tab or an empty-table draft never
/// does. Returns the active tab's position within the persisted list,
/// which drifts from its raw position as soon as a skipped tab appears
/// before it. Falls back to 0 when the active tab itself is one of the
/// kinds that's never persisted, since there is nothing truthful to
/// restore it to.
fn active_idx_among_kept(kept: &[bool], active_raw_index: Option<usize>) -> u32 {
    let Some(active_raw_index) = active_raw_index else {
        return 0;
    };
    if !kept.get(active_raw_index).copied().unwrap_or(false) {
        return 0;
    }
    kept[..active_raw_index].iter().filter(|&&k| k).count() as u32
}

#[cfg(test)]
mod tests {
    use super::active_idx_among_kept;

    #[test]
    fn active_idx_matches_raw_index_when_nothing_is_skipped() {
        assert_eq!(active_idx_among_kept(&[true, true, true], Some(2)), 2);
    }

    #[test]
    fn a_skipped_tab_before_the_active_one_shifts_its_index_down() {
        // Structure tab at 0, active Editor tab at raw index 2 -- only
        // one tab (at raw index 1) was actually persisted before it.
        assert_eq!(active_idx_among_kept(&[false, true, true], Some(2)), 1);
    }

    #[test]
    fn multiple_skipped_tabs_before_the_active_one_all_shift_it_down() {
        assert_eq!(active_idx_among_kept(&[false, false, true, true], Some(3)), 1);
    }

    #[test]
    fn an_active_tab_that_is_itself_skipped_falls_back_to_zero() {
        assert_eq!(active_idx_among_kept(&[true, false, true], Some(1)), 0);
    }

    #[test]
    fn no_active_page_falls_back_to_zero() {
        assert_eq!(active_idx_among_kept(&[true, true], None), 0);
    }
}

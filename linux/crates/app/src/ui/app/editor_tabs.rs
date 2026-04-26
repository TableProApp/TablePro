use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::{Component, ComponentController, ComponentSender, adw, gtk};

use uuid::Uuid;

use crate::services::database_service;
use crate::ui::editor::{SqlEditorInput, derive_tab_label};
use crate::ui::history_dialog::{HistoryDialog, HistoryDialogInit, HistoryDialogOutput};

use super::{App, AppMsg, create_editor_tab_slot, default_tab_label, read_tab_id};

impl App {
    pub(super) fn on_open_editor(&mut self, sender: ComponentSender<Self>) {
        if database_service::instance().active().is_none() {
            // The Editor ViewSwitcher tab is only visible while connected, so
            // this path is only reachable via Ctrl+E or the menu when no
            // connection is open — a toast is friendlier than swapping to a
            // status page since the user can stay on the welcome view.
            self.show_toast(&crate::tr!("Connect to a database first to run SQL."));
            return;
        }
        // ensure_editor_page is also called from on_connected so the Editor
        // tab is always present in the ViewSwitcher; this call is a no-op
        // when the page already exists.
        self.ensure_editor_page(sender);
        self.view_stack.set_visible_child_name("editor");
    }

    /// Builds editor_root + initial empty tab and registers it as the
    /// "editor" page in view_stack — idempotent.
    ///
    /// Called eagerly from on_connected so AdwViewSwitcherBar always has
    /// Browse + Editor peers, and again from on_open_editor for the
    /// keyboard-shortcut path that re-enters after a close.
    pub(super) fn ensure_editor_page(&mut self, sender: ComponentSender<Self>) {
        if self.editor_page_added.get() {
            return;
        }
        if self.editor_root.is_none() {
            self.build_editor_root(sender.clone());
            self.restore_editor_tabs(sender);
        }
        if let Some(root) = self.editor_root.as_ref() {
            self.view_stack
                .add_titled_with_icon(root, Some("editor"), &crate::tr!("Editor"), "edit-symbolic");
            self.editor_page_added.set(true);
        }
    }

    pub(super) fn build_editor_root(&mut self, sender: ComponentSender<Self>) {
        let tab_view = adw::TabView::new();
        let tab_bar = adw::TabBar::builder()
            .view(&tab_view)
            .autohide(false)
            .expand_tabs(true)
            .build();

        let overview_button = adw::TabButton::builder()
            .view(&tab_view)
            .action_name("overview.open")
            .tooltip_text(crate::tr!("View open tabs"))
            .valign(gtk::Align::Center)
            .build();
        tab_bar.set_start_action_widget(Some(&overview_button));

        let new_tab_button = gtk::Button::builder()
            .icon_name("tab-new-symbolic")
            .tooltip_text(crate::tr!("New tab"))
            .valign(gtk::Align::Center)
            .build();
        new_tab_button.add_css_class("flat");
        let new_tab_sender = sender.clone();
        new_tab_button.connect_clicked(move |_| new_tab_sender.input(AppMsg::NewEditorTab));
        tab_bar.set_end_action_widget(Some(&new_tab_button));

        let close_sender = sender.clone();
        tab_view.connect_close_page(move |_view, page| {
            if let Some(id) = read_tab_id(page) {
                close_sender.input(AppMsg::EditorTabClosed(id));
            }
            glib::Propagation::Stop
        });

        let inner = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        inner.append(&tab_bar);
        inner.append(&tab_view);

        let tab_overview = adw::TabOverview::builder()
            .view(&tab_view)
            .enable_new_tab(true)
            .enable_search(true)
            .child(&inner)
            .build();
        let tabs_for_create = self.editor_tabs.clone();
        let tab_view_for_create = tab_view.clone();
        let schema_for_create = self.schema_buffer.clone();
        let sender_for_create = sender.clone();
        tab_overview.connect_create_tab(move |_| {
            // Construct the slot first so the borrow_mut scope below stays
            // tight — the AppMsg::EditorTabsChanged dispatched after must
            // not run while a RefMut on editor_tabs is alive (relm4 input
            // is processed synchronously on the same thread, and the
            // handler calls editor_tabs.borrow()).
            let next_label = {
                let tabs = tabs_for_create.borrow();
                default_tab_label(tabs.len() + 1)
            };
            let slot = create_editor_tab_slot(
                &tab_view_for_create,
                &schema_for_create,
                None,
                &next_label,
                &sender_for_create,
            );
            let page = slot.page.clone();
            {
                let mut tabs = tabs_for_create.borrow_mut();
                tabs.insert(slot.id, slot);
            }
            sender_for_create.input(AppMsg::EditorTabsChanged);
            page
        });

        let new_tab_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("<Primary>t").expect("valid trigger"))
            .action(&gtk::CallbackAction::new({
                let s = sender.clone();
                move |_, _| {
                    s.input(AppMsg::NewEditorTab);
                    glib::Propagation::Stop
                }
            }))
            .build();
        let controller = gtk::ShortcutController::new();
        controller.set_scope(gtk::ShortcutScope::Local);
        controller.add_shortcut(new_tab_shortcut);
        inner.add_controller(controller);

        self.editor_root = Some(tab_overview);
        self.editor_tab_view = Some(tab_view);
    }

    pub(super) fn restore_editor_tabs(&mut self, sender: ComponentSender<Self>) {
        let saved = crate::services::editor_state::load();
        if saved.tabs.is_empty() {
            self.append_editor_tab(None, sender);
            return;
        }
        for tab in &saved.tabs {
            self.append_editor_tab(Some(tab.query.clone()), sender.clone());
        }
        // After restore, walk the AdwTabView's page model — that's the
        // truth source for display order — to find the page at active_idx.
        if let Some(tab_view) = self.editor_tab_view.as_ref() {
            let pages = tab_view.pages();
            if let Some(page) = pages.item(saved.active_idx).and_downcast::<adw::TabPage>() {
                tab_view.set_selected_page(&page);
            }
        }
    }

    pub(super) fn append_editor_tab(&mut self, initial_query: Option<String>, sender: ComponentSender<Self>) {
        let Some(tab_view) = self.editor_tab_view.clone() else {
            return;
        };
        let label = match &initial_query {
            Some(q) if !q.trim().is_empty() => derive_tab_label(q),
            _ => default_tab_label(self.editor_tabs.borrow().len() + 1),
        };
        let slot = create_editor_tab_slot(&tab_view, &self.schema_buffer, initial_query, &label, &sender);
        tab_view.set_selected_page(&slot.page);
        self.editor_tabs.borrow_mut().insert(slot.id, slot);
        self.rebuild_schema_buffer();
        self.persist_editor_state();
    }

    pub(super) fn close_editor_tab_by_id(&mut self, id: Uuid, sender: ComponentSender<Self>) {
        let Some(tab_view) = self.editor_tab_view.clone() else {
            return;
        };
        let Some(removed) = self.editor_tabs.borrow_mut().remove(&id) else {
            return;
        };
        let _ = removed.controller.sender().send(SqlEditorInput::Cancel);
        tab_view.close_page_finish(&removed.page, true);
        drop(removed);
        self.persist_editor_state();

        if self.editor_tabs.borrow().is_empty() {
            // The Editor ViewSwitcher tab stays present for the duration
            // of the connection (so the user always sees Browse | Editor
            // as peers). Closing the last query tab opens a fresh empty
            // tab rather than tearing down editor_root.
            self.append_editor_tab(None, sender.clone());
            self.view_stack.set_visible_child_name("browse");
        }
    }

    pub(super) fn close_active_editor_tab(&mut self, _sender: ComponentSender<Self>) {
        let Some(tab_view) = self.editor_tab_view.as_ref() else {
            self.window.close();
            return;
        };
        let Some(page) = tab_view.selected_page() else {
            return;
        };
        // Initiate via AdwTabView so the page enters the "closing" state;
        // the close-page signal handler emits EditorTabClosed(id), which then
        // calls close_page_finish to actually finalise the close.
        tab_view.close_page(&page);
    }

    pub(super) fn on_editor_tab_run_state_changed(&self, id: Uuid, running: bool) {
        if let Some(slot) = self.editor_tabs.borrow().get(&id) {
            slot.page.set_loading(running);
        }
    }

    pub(super) fn on_editor_tab_query_changed(&mut self, id: Uuid, query: String) {
        let label = if query.trim().is_empty() {
            crate::tr!("Empty query")
        } else {
            derive_tab_label(&query)
        };
        if let Some(slot) = self.editor_tabs.borrow_mut().get_mut(&id) {
            slot.page.set_title(&label);
            slot.page.set_tooltip(&label);
            slot.query = query;
        }
        self.persist_editor_state();
    }

    pub(super) fn persist_editor_state(&self) {
        // Use AdwTabView's page model as the source of display order
        // (HashMap<Uuid, …> doesn't preserve insertion order — and the
        // user's drag-to-reorder would invalidate it anyway).
        let tabs = self.editor_tabs.borrow();
        let Some(tab_view) = self.editor_tab_view.as_ref() else {
            return;
        };
        let pages = tab_view.pages();
        let n = pages.n_items();
        let active_page = tab_view.selected_page();
        let mut tab_states: Vec<crate::services::editor_state::EditorTab> = Vec::with_capacity(n as usize);
        let mut active_idx: u32 = 0;
        for i in 0..n {
            let Some(page) = pages.item(i).and_downcast::<adw::TabPage>() else {
                continue;
            };
            if active_page.as_ref() == Some(&page) {
                active_idx = i;
            }
            if let Some(id) = read_tab_id(&page)
                && let Some(slot) = tabs.get(&id)
            {
                tab_states.push(crate::services::editor_state::EditorTab {
                    query: slot.query.clone(),
                });
            }
        }
        let state = crate::services::editor_state::EditorState {
            tabs: tab_states,
            active_idx,
        };
        crate::services::editor_state::save(&state);
    }

    pub(super) fn cancel_all_editor_runs(&self) {
        for slot in self.editor_tabs.borrow().values() {
            let _ = slot.controller.sender().send(SqlEditorInput::Cancel);
        }
    }

    pub(super) fn on_show_history(&mut self, sender: ComponentSender<Self>) {
        let dialog =
            HistoryDialog::builder()
                .launch(HistoryDialogInit)
                .forward(sender.input_sender(), |out| match out {
                    HistoryDialogOutput::OpenInNewTab(text) => AppMsg::OpenHistoryQuery(text),
                    HistoryDialogOutput::ReplaceCurrentTabQuery(text) => AppMsg::ReplaceActiveTabQuery(text),
                });
        dialog.model().dialog().present(Some(&self.window));
        self.history_dialog = Some(dialog);
    }

    pub(super) fn on_replace_active_tab_query(&mut self, text: String) {
        let Some(tab_view) = self.editor_tab_view.as_ref() else {
            return;
        };
        let Some(active_page) = tab_view.selected_page() else {
            return;
        };
        let Some(id) = read_tab_id(&active_page) else {
            return;
        };
        if let Some(slot) = self.editor_tabs.borrow().get(&id) {
            let _ = slot.controller.sender().send(SqlEditorInput::ReplaceQuery(text));
        }
    }
}

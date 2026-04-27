use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::gtk::{gio, glib};
use relm4::{Component, ComponentController, ComponentSender, adw, gtk};

use uuid::Uuid;

use crate::services::database_service;
use crate::services::workspace_state::{self, ConnectionWorkspaceState, WorkspaceTabRecord};
use crate::ui::browse_tab::{BrowseTab, BrowseTabInit, BrowseTabInput, BrowseTabOutput};
use crate::ui::editor::{SqlEditor, SqlEditorInit, SqlEditorInput, SqlEditorOutput, derive_tab_label};

use super::{
    App, AppMsg, BrowseTabSlot, EditorTabSlot, OpenMode, WorkspaceTab, read_workspace_tab_id, write_workspace_tab_id,
};

impl App {
    /// Builds the unified AdwTabOverview tree once per connection.
    /// Idempotent via `workspace_root_added`.
    pub(super) fn ensure_workspace_root(&mut self, sender: ComponentSender<Self>) {
        if self.workspace_root_added.get() {
            return;
        }
        if self.workspace_root.is_none() {
            self.build_workspace_root(sender);
        }
        if let Some(root) = self.workspace_root.as_ref()
            && self.workspace_outer_stack.child_by_name("tabs").is_none()
        {
            self.workspace_outer_stack.add_named(root, Some("tabs"));
        }
        self.workspace_root_added.set(true);
    }

    fn build_workspace_root(&mut self, sender: ComponentSender<Self>) {
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

        // "+" button in the tab bar opens a new editor (query) tab —
        // this is the only way to create an editor tab from the UI.
        // Browse tabs come from sidebar clicks.
        let new_query_button = gtk::Button::builder()
            .icon_name("tab-new-symbolic")
            .tooltip_text(crate::tr!("New query"))
            .valign(gtk::Align::Center)
            .build();
        new_query_button.add_css_class("flat");
        let new_tab_sender = sender.clone();
        new_query_button.connect_clicked(move |_| new_tab_sender.input(AppMsg::NewEditorTab));
        tab_bar.set_end_action_widget(Some(&new_query_button));

        // 2-step close: TabView signals close → App message → close_finish.
        let close_sender = sender.clone();
        tab_view.connect_close_page(move |_view, page| {
            if let Some(id) = read_workspace_tab_id(page) {
                close_sender.input(AppMsg::WorkspaceTabClosed(id));
            }
            glib::Propagation::Stop
        });

        // Right-click tab → context menu. AdwTabView reads a menu model
        // and fires `connect_setup_menu` with the target page just
        // before the popover opens; we stash that page in a shared
        // Cell so the action callbacks know which tab the user
        // right-clicked. Setting `menu-model` on AdwTabView is the
        // documented way to extend the per-tab popover.
        let menu_target: Rc<RefCell<Option<adw::TabPage>>> = Rc::new(RefCell::new(None));
        let menu_target_setup = menu_target.clone();
        tab_view.connect_setup_menu(move |_view, page| {
            *menu_target_setup.borrow_mut() = page.cloned();
        });
        let action_group = gio::SimpleActionGroup::new();
        let close_others_action = gio::SimpleAction::new("close-others", None);
        let menu_target_others = menu_target.clone();
        let sender_close_others = sender.clone();
        close_others_action.connect_activate(move |_, _| {
            let target = menu_target_others.borrow().clone();
            if let Some(page) = target
                && let Some(id) = read_workspace_tab_id(&page)
            {
                sender_close_others.input(AppMsg::CloseOtherWorkspaceTabs(id));
            }
        });
        action_group.add_action(&close_others_action);
        let close_right_action = gio::SimpleAction::new("close-right", None);
        let menu_target_right = menu_target;
        let sender_close_right = sender.clone();
        close_right_action.connect_activate(move |_, _| {
            let target = menu_target_right.borrow().clone();
            if let Some(page) = target
                && let Some(id) = read_workspace_tab_id(&page)
            {
                sender_close_right.input(AppMsg::CloseWorkspaceTabsToRight(id));
            }
        });
        action_group.add_action(&close_right_action);
        tab_view.insert_action_group("tab", Some(&action_group));

        let bulk_menu = gio::Menu::new();
        bulk_menu.append(Some(&crate::tr!("Close Other Tabs")), Some("tab.close-others"));
        bulk_menu.append(Some(&crate::tr!("Close Tabs to the Right")), Some("tab.close-right"));
        tab_view.set_menu_model(Some(&bulk_menu));

        // Both selection-change AND any pages-list change (insert /
        // remove / drag-reorder) trigger persist + title-refresh.
        // Without connect_pages_notify, drag-reorder doesn't persist
        // until the next other event.
        let pages_sender = sender.clone();
        tab_view.connect_selected_page_notify(move |_| {
            pages_sender.input(AppMsg::WorkspaceTabsChanged);
        });
        let reorder_sender = sender.clone();
        tab_view.connect_pages_notify(move |_| {
            reorder_sender.input(AppMsg::WorkspaceTabsChanged);
        });

        let inner = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        inner.append(&tab_bar);
        inner.append(&tab_view);

        let tab_overview = adw::TabOverview::builder()
            .view(&tab_view)
            .enable_new_tab(true) // overview "+" → editor tab
            .enable_search(true)
            .child(&inner)
            .build();
        // Overview "+" button must return a real TabPage synchronously —
        // we build an SqlEditor inline, register the slot, and return
        // the page. Browse tabs aren't creatable from the overview
        // (they need a sidebar table target).
        // Overview "+" must return a real TabPage synchronously. We
        // construct an editor slot inline using the same label scheme
        // as `append_editor_tab` ("Query 1", "Query 2", …) so the two
        // entry points are visually indistinguishable.
        let workspace_tabs_for_create = self.workspace_tabs.clone();
        let tab_view_for_create = tab_view.clone();
        let schema_buffer_for_create = self.schema_buffer.clone();
        let sender_for_create = sender.clone();
        tab_overview.connect_create_tab(move |_| {
            let tab_id = Uuid::new_v4();
            let editor = SqlEditor::builder()
                .launch(SqlEditorInit {
                    schema_buffer: schema_buffer_for_create.clone(),
                    initial_query: None,
                })
                .forward(sender_for_create.input_sender(), move |out| match out {
                    SqlEditorOutput::RunStateChanged(running) => AppMsg::EditorTabRunStateChanged(tab_id, running),
                    SqlEditorOutput::QueryChanged(text) => AppMsg::EditorTabQueryChanged(tab_id, text),
                });
            let page = tab_view_for_create.append(editor.widget());
            let editor_count = workspace_tabs_for_create
                .borrow()
                .values()
                .filter(|t| matches!(t, WorkspaceTab::Editor(_)))
                .count();
            let label = default_editor_tab_label(editor_count + 1);
            page.set_title(&label);
            // Empty query → no tooltip; tooltip will be set on first edit
            // via on_editor_tab_query_changed.
            write_workspace_tab_id(&page, tab_id);
            let slot = EditorTabSlot {
                id: tab_id,
                controller: editor,
                page: page.clone(),
                query: String::new(),
            };
            {
                let mut tabs = workspace_tabs_for_create.borrow_mut();
                tabs.insert(tab_id, WorkspaceTab::Editor(slot));
            }
            sender_for_create.input(AppMsg::WorkspaceTabsChanged);
            page
        });

        // Ctrl+T shortcut: new editor tab. Scoped to the workspace inner
        // box so it only fires when the workspace has focus.
        let new_tab_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("<Primary>t").expect("valid trigger"))
            .action(&gtk::CallbackAction::new({
                let s = sender;
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

        self.workspace_root = Some(tab_overview);
        self.workspace_tab_view = Some(tab_view);
    }

    /// Restore workspace tabs from disk for the just-connected database.
    pub(super) fn restore_workspace_tabs(&mut self, connection_id: Uuid, sender: ComponentSender<Self>) {
        let Some(saved) = workspace_state::load_connection(connection_id) else {
            self.workspace_outer_stack.set_visible_child_name("empty");
            return;
        };
        if saved.tabs.is_empty() {
            self.workspace_outer_stack.set_visible_child_name("empty");
            return;
        }
        for record in &saved.tabs {
            match record {
                WorkspaceTabRecord::Browse {
                    schema,
                    table,
                    offset,
                    page_size,
                    sort_col,
                    sort_asc,
                } => {
                    self.append_browse_tab_inner(
                        schema.clone(),
                        table.clone(),
                        *offset,
                        *page_size,
                        match (sort_col, sort_asc) {
                            (Some(c), Some(a)) => Some((*c, *a)),
                            _ => None,
                        },
                        sender.clone(),
                    );
                }
                WorkspaceTabRecord::Editor { query } => {
                    self.append_editor_tab(Some(query.clone()), sender.clone());
                }
                WorkspaceTabRecord::Structure { schema: _, table: _ } => {
                    // Structure tabs are wired up later in the rollout
                    // (steps 11-13). For now restore is a no-op so a
                    // workspace_state.json carrying a Structure record
                    // doesn't crash on load before the UI catches up.
                }
                WorkspaceTabRecord::Unknown => {
                    // Forward-compat: silently skip unknown tab kinds.
                }
            }
        }
        if let Some(tab_view) = self.workspace_tab_view.as_ref()
            && let Some(page) = tab_view.pages().item(saved.active_idx).and_downcast::<adw::TabPage>()
        {
            tab_view.set_selected_page(&page);
        }
        self.workspace_outer_stack.set_visible_child_name("tabs");
    }

    /// Public entry: append a Browse tab for `(schema, table)` and select it.
    pub(super) fn append_browse_tab(&mut self, schema: Option<String>, table: String, sender: ComponentSender<Self>) {
        self.append_browse_tab_inner(schema, table, 0, self.default_page_size, None, sender);
    }

    fn append_browse_tab_inner(
        &mut self,
        schema: Option<String>,
        table: String,
        offset: u64,
        page_size: u64,
        sort: Option<(usize, bool)>,
        sender: ComponentSender<Self>,
    ) {
        self.ensure_workspace_root(sender.clone());
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let tab_id = Uuid::new_v4();
        let driver_id = self.driver_id().to_string();
        let connection_id = database_service::instance().active_id();
        let read_only = self.read_only;
        let init = BrowseTabInit {
            tab_id,
            schema: schema.clone(),
            table: table.clone(),
            driver_id,
            connection_id,
            read_only,
            page_size,
            initial_offset: offset,
            initial_sort: sort,
        };
        let controller = BrowseTab::builder()
            .launch(init)
            .forward(sender.input_sender(), move |out| match out {
                BrowseTabOutput::FetchPage => AppMsg::FetchBrowsePage(tab_id),
                BrowseTabOutput::FetchColumns => AppMsg::FetchBrowseColumns(tab_id),
                BrowseTabOutput::FetchRowCount => AppMsg::FetchBrowseRowCount(tab_id),
                BrowseTabOutput::StateChanged => AppMsg::WorkspaceTabsChanged,
                BrowseTabOutput::CopyRowAsInsert { row_position } => AppMsg::CopyRowAsInsert { tab_id, row_position },
                BrowseTabOutput::CopyToClipboard(text) => AppMsg::CopyToClipboard(text),
                BrowseTabOutput::SchemaWordsChanged(_words) => AppMsg::WorkspaceSchemaWordsChanged,
                BrowseTabOutput::ShowSelectionAlert { title, body } => AppMsg::ShowAlert { title, body },
                BrowseTabOutput::ShowToast(msg) => AppMsg::ShowToast(msg),
                BrowseTabOutput::DirtyChanged(dirty) => AppMsg::BrowseTabDirtyChanged(tab_id, dirty),
                BrowseTabOutput::ExecuteTransaction { statements, sources } => AppMsg::ExecuteBrowseTransaction {
                    tab_id,
                    statements,
                    sources,
                },
            });

        let page = tab_view.append(controller.widget());
        let label = qualified_browse_tab_label(self.sidebar_schemas_distinct(), schema.as_deref(), &table);
        page.set_title(&label);
        if let Some(tip) = browse_tab_tooltip(schema.as_deref(), &table, &label) {
            page.set_tooltip(&tip);
        }
        write_workspace_tab_id(&page, tab_id);

        let slot = BrowseTabSlot {
            id: tab_id,
            controller,
            page: page.clone(),
            schema,
            table,
        };
        self.workspace_tabs
            .borrow_mut()
            .insert(tab_id, WorkspaceTab::Browse(slot));
        tab_view.set_selected_page(&page);
        self.workspace_outer_stack.set_visible_child_name("tabs");
        self.refresh_window_title();
        self.persist_workspace_state();
    }

    /// Public entry: append an Editor tab with optional initial query.
    pub(super) fn append_editor_tab(&mut self, initial_query: Option<String>, sender: ComponentSender<Self>) {
        self.ensure_workspace_root(sender.clone());
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let tab_id = Uuid::new_v4();
        let query = initial_query.clone().unwrap_or_default();
        let editor = SqlEditor::builder()
            .launch(SqlEditorInit {
                schema_buffer: self.schema_buffer.clone(),
                initial_query,
            })
            .forward(sender.input_sender(), move |out| match out {
                SqlEditorOutput::RunStateChanged(running) => AppMsg::EditorTabRunStateChanged(tab_id, running),
                SqlEditorOutput::QueryChanged(text) => AppMsg::EditorTabQueryChanged(tab_id, text),
            });
        let page = tab_view.append(editor.widget());
        let label = match query.trim().is_empty() {
            true => default_editor_tab_label(self.editor_tab_count() + 1),
            false => derive_tab_label(&query),
        };
        page.set_title(&label);
        if let Some(tip) = editor_tab_tooltip(&query, &label) {
            page.set_tooltip(&tip);
        }
        write_workspace_tab_id(&page, tab_id);

        let slot = EditorTabSlot {
            id: tab_id,
            controller: editor,
            page: page.clone(),
            query,
        };
        self.workspace_tabs
            .borrow_mut()
            .insert(tab_id, WorkspaceTab::Editor(slot));
        tab_view.set_selected_page(&page);
        self.workspace_outer_stack.set_visible_child_name("tabs");
        self.refresh_window_title();
        self.rebuild_schema_buffer();
        self.persist_workspace_state();
    }

    pub(super) fn close_workspace_tab_by_id(&mut self, id: Uuid, sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };

        // If this is a Browse tab with pending changeset, intercept the
        // close with an AdwAlertDialog (Discard / Cancel). The user can
        // also cancel close, save manually, then close — no Save-and-
        // close branch keeps the async commit logic out of this path.
        let pending = self
            .workspace_tabs
            .borrow()
            .get(&id)
            .and_then(|t| match t {
                WorkspaceTab::Browse(s) => crate::services::change_tracker::with_tab_ref(s.id, |tr| tr.has_pending()),
                _ => None,
            })
            .unwrap_or(false);
        if pending {
            let page = self.workspace_tabs.borrow().get(&id).map(|t| match t {
                WorkspaceTab::Browse(s) => s.page.clone(),
                WorkspaceTab::Editor(s) => s.page.clone(),
            });
            let Some(page) = page else { return };
            // Cancel | Discard(destructive) | Save(suggested), Save is
            // default. Mirrors GNOME Text Editor's close-with-unsaved
            // template (libadwaita AdwAlertDialog reference).
            let dialog = adw::AlertDialog::new(
                Some(&crate::tr!("Save changes?")),
                Some(&crate::tr!(
                    "This tab has unsaved edits. Save commits them now, Discard throws them away."
                )),
            );
            dialog.add_response("cancel", &crate::tr!("Cancel"));
            dialog.add_response("discard", &crate::tr!("Discard"));
            dialog.add_response("save", &crate::tr!("Save"));
            dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
            dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
            dialog.set_default_response(Some("save"));
            dialog.set_close_response("cancel");
            let tab_view_for_resp = tab_view.clone();
            let page_for_resp = page.clone();
            let sender_for_resp = sender.clone();
            let close_after_save = self.close_after_save.clone();
            dialog.connect_response(None, move |dlg, response| {
                dlg.close();
                match response {
                    "discard" => {
                        crate::services::change_tracker::with_tab(id, |t| t.clear());
                        sender_for_resp.input(AppMsg::WorkspaceTabClosed(id));
                    }
                    "save" => {
                        // Mark the tab so SaveCompletedForTab will close
                        // it once the transaction commits. SaveFailed
                        // removes it and aborts the close.
                        close_after_save.borrow_mut().insert(id);
                        // Revert AdwTabView's "closing" state for now
                        // (the user might still cancel via SaveFailed).
                        tab_view_for_resp.close_page_finish(&page_for_resp, false);
                        sender_for_resp.input(AppMsg::SaveActiveBrowseTabById(id));
                    }
                    _ => {
                        // Cancel: revert AdwTabView's "closing" state
                        // so the page stays open. Without this the X
                        // click would still dismiss the page.
                        tab_view_for_resp.close_page_finish(&page_for_resp, false);
                    }
                }
            });
            dialog.present(Some(&self.window));
            return;
        }

        self.finish_close_workspace_tab(id, &tab_view);
    }

    /// Tear down a tab without prompting. Internal helper called once
    /// the close-with-pending dialog (if any) has resolved.
    fn finish_close_workspace_tab(&mut self, id: Uuid, tab_view: &adw::TabView) {
        let removed = self.workspace_tabs.borrow_mut().remove(&id);
        let Some(removed) = removed else {
            return;
        };
        match &removed {
            WorkspaceTab::Editor(slot) => {
                let _ = slot.controller.sender().send(SqlEditorInput::Cancel);
            }
            WorkspaceTab::Browse(slot) => {
                crate::services::change_tracker::close_tab(slot.id);
            }
        }
        let page = match &removed {
            WorkspaceTab::Browse(s) => s.page.clone(),
            WorkspaceTab::Editor(s) => s.page.clone(),
        };
        tab_view.close_page_finish(&page, true);
        drop(removed);
        self.persist_workspace_state();
        if self.workspace_tabs.borrow().is_empty() {
            self.workspace_outer_stack.set_visible_child_name("empty");
        }
        self.rebuild_schema_buffer();
        self.refresh_window_title();
    }

    pub(super) fn close_active_workspace_tab(&mut self, sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.as_ref() else {
            // No tabs at all (disconnected) → close window.
            self.window.close();
            return;
        };
        let Some(page) = tab_view.selected_page() else {
            self.window.close();
            return;
        };
        tab_view.close_page(&page);
        let _ = sender;
    }

    /// Close every workspace tab except `keep_id`. Each close goes
    /// through the per-tab close path so dirty browse tabs still
    /// trigger the unsaved-changes alert; the user can cancel the
    /// dialog and the tab stays open while the others continue
    /// closing in the background.
    pub(super) fn close_other_workspace_tabs(&mut self, keep_id: Uuid, _sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let pages = tab_view.pages();
        let mut targets: Vec<adw::TabPage> = Vec::with_capacity(pages.n_items() as usize);
        for i in 0..pages.n_items() {
            let Some(page) = pages.item(i).and_downcast::<adw::TabPage>() else {
                continue;
            };
            if read_workspace_tab_id(&page) == Some(keep_id) {
                continue;
            }
            targets.push(page);
        }
        for page in targets {
            tab_view.close_page(&page);
        }
    }

    /// Close every workspace tab whose display position is greater
    /// than the targeted one. Useful for rapidly trimming a long
    /// session of throwaway tabs the user accumulated.
    pub(super) fn close_workspace_tabs_to_right(&mut self, anchor_id: Uuid, _sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let pages = tab_view.pages();
        let mut anchor_idx: Option<u32> = None;
        for i in 0..pages.n_items() {
            let Some(page) = pages.item(i).and_downcast::<adw::TabPage>() else {
                continue;
            };
            if read_workspace_tab_id(&page) == Some(anchor_id) {
                anchor_idx = Some(i);
                break;
            }
        }
        let Some(anchor_idx) = anchor_idx else {
            return;
        };
        let mut targets: Vec<adw::TabPage> = Vec::new();
        for i in (anchor_idx + 1)..pages.n_items() {
            let Some(page) = pages.item(i).and_downcast::<adw::TabPage>() else {
                continue;
            };
            targets.push(page);
        }
        for page in targets {
            tab_view.close_page(&page);
        }
    }

    /// Sidebar-click dispatcher. Two behaviours:
    ///
    /// - `SwitchOrAppend` (plain click): if a Browse tab for
    ///   `(schema, table)` is already open, activate it; otherwise
    ///   append a new Browse tab. Never closes anything — tabs only
    ///   go away when the user clicks the X.
    /// - `NewTab` (Ctrl+click / right-click "Open in new tab"): always
    ///   append a new tab even if the same table is already open.
    ///
    /// The earlier "smart-replace" sub-case (close active + append new
    /// in one step) was dropped because AdwTabView's close-page
    /// animation overlapped with the append, producing a visual flash
    /// where the user briefly saw the closing tab and the new tab
    /// side by side. Always-append is what every modern DB client
    /// (TablePlus, DBeaver, DataGrip, Beekeeper) does anyway.
    pub(super) fn dispatch_select_table(
        &mut self,
        schema: Option<String>,
        name: String,
        open_mode: OpenMode,
        sender: ComponentSender<Self>,
    ) {
        if matches!(open_mode, OpenMode::SwitchOrAppend) {
            // Multiple tabs may be open for the same (schema, table)
            // pair (Ctrl+click duplicates). Prefer the currently-
            // selected tab when it matches, then any other match.
            // HashMap iteration is otherwise non-deterministic and the
            // result on duplicate matches would feel arbitrary.
            let existing = {
                let tabs = self.workspace_tabs.borrow();
                let selected_page = self.workspace_tab_view.as_ref().and_then(|tv| tv.selected_page());
                let selected_match = selected_page.and_then(|sp| {
                    let id = read_workspace_tab_id(&sp)?;
                    match tabs.get(&id)? {
                        WorkspaceTab::Browse(s) if s.schema.as_deref() == schema.as_deref() && s.table == name => {
                            Some(s.page.clone())
                        }
                        _ => None,
                    }
                });
                selected_match.or_else(|| {
                    tabs.values().find_map(|t| match t {
                        WorkspaceTab::Browse(s) if s.schema.as_deref() == schema.as_deref() && s.table == name => {
                            Some(s.page.clone())
                        }
                        _ => None,
                    })
                })
            };
            if let Some(page) = existing
                && let Some(tab_view) = self.workspace_tab_view.as_ref()
            {
                tab_view.set_selected_page(&page);
                return;
            }
        }
        self.append_browse_tab(schema, name, sender);
    }

    /// Persist workspace tabs for the active connection. Walks
    /// `tab_view.pages()` for canonical display order (HashMap is
    /// unordered; user can drag-reorder).
    /// Debounced entry point. Coalesces rapid call sites
    /// (selection-change, drag-reorder, page-size change, state-
    /// changed) into a single write 500ms after the last call.
    pub(super) fn persist_workspace_state(&self) {
        if self.persist_pending.get() {
            return;
        }
        self.persist_pending.set(true);
        let pending = self.persist_pending.clone();
        let workspace_tabs = self.workspace_tabs.clone();
        let tab_view = self.workspace_tab_view.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(500), move || {
            pending.set(false);
            do_persist_workspace_state(&workspace_tabs, tab_view.as_ref());
        });
    }

    /// Actual write. Reads the latest tab state, builds the on-disk
    /// record, hands it to `workspace_state::save_connection`. Called
    /// only via `persist_workspace_state`'s debounced timer or
    /// directly from teardown paths that need a synchronous flush.
    pub(super) fn do_persist_workspace_state_now(&self) {
        do_persist_workspace_state(&self.workspace_tabs, self.workspace_tab_view.as_ref());
    }
}

fn do_persist_workspace_state(
    workspace_tabs: &std::rc::Rc<std::cell::RefCell<std::collections::HashMap<Uuid, WorkspaceTab>>>,
    tab_view: Option<&adw::TabView>,
) {
    let Some(connection_id) = database_service::instance().active_id() else {
        return;
    };
    let tabs = workspace_tabs.borrow();
    let Some(tab_view) = tab_view else {
        return;
    };
    let pages = tab_view.pages();
    let n = pages.n_items();
    let active_page = tab_view.selected_page();
    let mut tab_records: Vec<WorkspaceTabRecord> = Vec::with_capacity(n as usize);
    let mut active_idx: u32 = 0;
    for i in 0..n {
        let Some(page) = pages.item(i).and_downcast::<adw::TabPage>() else {
            continue;
        };
        if active_page.as_ref() == Some(&page) {
            active_idx = i;
        }
        let Some(id) = read_workspace_tab_id(&page) else {
            continue;
        };
        let Some(slot) = tabs.get(&id) else { continue };
        tab_records.push(match slot {
            WorkspaceTab::Browse(s) => {
                let model = s.controller.model();
                let sort = model.current_sort();
                WorkspaceTabRecord::Browse {
                    schema: s.schema.clone(),
                    table: s.table.clone(),
                    offset: model.current_offset(),
                    page_size: model.page_size(),
                    sort_col: sort.map(|(c, _)| c),
                    sort_asc: sort.map(|(_, a)| a),
                }
            }
            WorkspaceTab::Editor(s) => WorkspaceTabRecord::Editor { query: s.query.clone() },
        });
    }
    let conn_state = ConnectionWorkspaceState {
        tabs: tab_records,
        active_idx,
    };
    workspace_state::save_connection(connection_id, conn_state);
}

impl App {
    /// Single handler for `WorkspaceTabsChanged`. Persists tab state,
    /// refreshes the window title (so tab switches update the subtitle),
    /// and syncs the sidebar selection to the active Browse tab's table.
    pub(super) fn on_workspace_tabs_changed(&self) {
        self.persist_workspace_state();
        self.refresh_window_title();
        self.sync_sidebar_selection();
    }

    /// Highlight the sidebar row matching the active Browse tab's
    /// `(schema, table)`. When the active tab is an Editor (or there
    /// are no tabs), clear the sidebar selection — leaving a stale
    /// row highlighted while the user is in the editor would imply
    /// the editor is showing that table's data, which it isn't.
    fn sync_sidebar_selection(&self) {
        let listbox = self.sidebar_factory.widget();
        let Some((schema, table)) = self.selected_browse_slot_table() else {
            listbox.unselect_all();
            return;
        };
        let schemas = self.sidebar_schemas.borrow();
        let mut idx = 0_i32;
        while let Some(row) = listbox.row_at_index(idx) {
            // The factory builds one row per TableInfo, in the same order
            // as `sidebar_schemas`, so we can pair each row with its
            // schema-Option by index. SidebarRow stashes its table name
            // in widget-name (no CSS conflict, no qdata machinery).
            let row_table = row.widget_name();
            let row_schema = schemas.get(idx as usize).cloned().unwrap_or(None);
            if row_table.as_str() == table && row_schema.as_deref() == schema.as_deref() {
                // select_row doesn't trigger row-activated (user-only
                // signal), so this won't recurse into SelectTable.
                listbox.select_row(Some(&row));
                return;
            }
            idx += 1;
        }
    }

    pub(super) fn selected_workspace_tab_id(&self) -> Option<Uuid> {
        let tab_view = self.workspace_tab_view.as_ref()?;
        let page = tab_view.selected_page()?;
        read_workspace_tab_id(&page)
    }

    pub(super) fn selected_browse_tab_id(&self) -> Option<Uuid> {
        let id = self.selected_workspace_tab_id()?;
        let tabs = self.workspace_tabs.borrow();
        match tabs.get(&id)? {
            WorkspaceTab::Browse(_) => Some(id),
            _ => None,
        }
    }

    pub(super) fn selected_browse_slot_table(&self) -> Option<(Option<String>, String)> {
        let id = self.selected_browse_tab_id()?;
        let tabs = self.workspace_tabs.borrow();
        match tabs.get(&id)? {
            WorkspaceTab::Browse(s) => Some((s.schema.clone(), s.table.clone())),
            _ => None,
        }
    }

    pub(super) fn rebuild_schema_buffer(&self) {
        let mut words: Vec<String> = self.table_names.clone();
        let tabs = self.workspace_tabs.borrow();
        for tab in tabs.values() {
            if let WorkspaceTab::Browse(s) = tab {
                for col in s.controller.model().columns() {
                    words.push(col.name.clone());
                }
            }
        }
        words.sort_unstable();
        words.dedup();
        crate::ui::editor::update_schema_buffer(&self.schema_buffer, &words);
    }

    fn sidebar_schemas_distinct(&self) -> usize {
        let schemas = self.sidebar_schemas.borrow();
        let distinct: std::collections::BTreeSet<&str> = schemas.iter().filter_map(|s| s.as_deref()).collect();
        distinct.len()
    }

    /// Refresh a browse tab's title based on its tracker dirty state.
    /// Mirrors GNOME Text Editor's leading "•" prefix convention for
    /// unsaved buffers. The base label is recomputed (not stored) so
    /// schema disambiguation stays correct if other tabs change.
    ///
    /// Also flips `set_needs_attention` on the AdwTabPage so the tab
    /// bar's pulsing dot appears for background tabs that have unsaved
    /// edits — matches AdwTabView's intended use and surfaces the
    /// dirty state when the user is in another tab. The flag is
    /// suppressed for the currently-selected tab since the user is
    /// actively looking at it (the "•" title prefix is enough cue).
    pub(super) fn refresh_browse_tab_dirty(&self, tab_id: uuid::Uuid, dirty: bool) {
        let schemas_count = self.sidebar_schemas_distinct();
        let tabs = self.workspace_tabs.borrow();
        let Some(super::WorkspaceTab::Browse(slot)) = tabs.get(&tab_id) else {
            return;
        };
        let base = qualified_browse_tab_label(schemas_count, slot.schema.as_deref(), &slot.table);
        let title = if dirty { format!("• {base}") } else { base };
        slot.page.set_title(&title);
        let is_selected = self
            .workspace_tab_view
            .as_ref()
            .and_then(|tv| tv.selected_page())
            .map(|p| p == slot.page)
            .unwrap_or(false);
        slot.page.set_needs_attention(dirty && !is_selected);
        self.refresh_window_title();
    }

    pub(super) fn teardown_workspace_tabs(&mut self) {
        // Synchronous flush — debouncer would skip the write since
        // teardown drops state before the 500ms timer would fire.
        self.do_persist_workspace_state_now();
        self.cancel_all_editor_runs();
        // Drop per-tab pending-change trackers — disconnecting wipes
        // the connection and its row identities, so any pending edits
        // would no longer be commitable.
        for tab in self.workspace_tabs.borrow().values() {
            if let WorkspaceTab::Browse(slot) = tab {
                crate::services::change_tracker::close_tab(slot.id);
            }
        }
        if let Some(root) = self.workspace_root.take()
            && self.workspace_root_added.get()
        {
            if self.workspace_outer_stack.child_by_name("tabs").is_some() {
                self.workspace_outer_stack.remove(&root);
            }
            self.workspace_root_added.set(false);
        }
        self.workspace_outer_stack.set_visible_child_name("empty");
        self.workspace_tab_view = None;
        self.workspace_tabs.borrow_mut().clear();
    }

    pub(super) fn cancel_all_editor_runs(&self) {
        for tab in self.workspace_tabs.borrow().values() {
            if let WorkspaceTab::Editor(s) = tab {
                let _ = s.controller.sender().send(SqlEditorInput::Cancel);
            }
        }
    }

    /// Forward a per-tab Browse input to the right slot.
    pub(super) fn dispatch_to_tab(&self, tab_id: Uuid, msg: BrowseTabInput) {
        if let Some(WorkspaceTab::Browse(slot)) = self.workspace_tabs.borrow().get(&tab_id) {
            let _ = slot.controller.sender().send(msg);
        }
    }

    /// Editor tab title update on query change. Mirrors what was on
    /// editor_tabs.rs::on_editor_tab_query_changed; lives here now since
    /// editor tabs are first-class workspace tabs.
    pub(super) fn on_editor_tab_query_changed(&self, id: Uuid, query: String) {
        let label = if query.trim().is_empty() {
            crate::tr!("Empty query")
        } else {
            derive_tab_label(&query)
        };
        if let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow_mut().get_mut(&id) {
            slot.page.set_title(&label);
            // Pass empty when no extra info to clear any prior tooltip;
            // libadwaita treats empty-string as no tooltip.
            let tooltip = editor_tab_tooltip(&query, &label).unwrap_or_default();
            slot.page.set_tooltip(&tooltip);
            slot.query = query;
        }
        self.persist_workspace_state();
    }

    pub(super) fn on_editor_tab_run_state_changed(&self, id: Uuid, running: bool) {
        if let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow().get(&id) {
            slot.page.set_loading(running);
        }
    }

    pub(super) fn on_replace_active_tab_query(&mut self, text: String, sender: ComponentSender<Self>) {
        // If an editor tab is active, replace its buffer in-place. If a
        // browse tab is active (or no tab at all), fall back to opening
        // a new editor tab with the query — silent no-op was the prior
        // (annoying) behaviour for users invoking from history while
        // browsing.
        if let Some(id) = self.selected_workspace_tab_id()
            && let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow().get(&id)
        {
            let _ = slot.controller.sender().send(SqlEditorInput::ReplaceQuery(text));
            return;
        }
        self.append_editor_tab(Some(text), sender);
    }

    fn editor_tab_count(&self) -> usize {
        self.workspace_tabs
            .borrow()
            .values()
            .filter(|t| matches!(t, WorkspaceTab::Editor(_)))
            .count()
    }
}

fn qualified_browse_tab_label(schemas_count: usize, schema: Option<&str>, table: &str) -> String {
    if schemas_count >= 2
        && let Some(s) = schema
    {
        format!("{s}.{table}")
    } else {
        table.to_string()
    }
}

fn default_editor_tab_label(n: usize) -> String {
    crate::tr!("Query {n}").replace("{n}", &n.to_string())
}

/// Returns a tooltip for a Browse tab, but only when it would add info
/// beyond the visible label. When the label is already
/// `schema.table`, or there is no schema, the tooltip would just
/// duplicate the tab title and we skip it.
fn browse_tab_tooltip(schema: Option<&str>, table: &str, label: &str) -> Option<String> {
    let s = schema?;
    let qualified = format!("{s}.{table}");
    if qualified == label { None } else { Some(qualified) }
}

/// Returns a tooltip for an Editor tab. Empty for blank queries; for
/// non-empty queries, a 200-char preview — but only when distinct from
/// the (truncated) label, so non-truncated labels don't get a redundant
/// hover popup.
fn editor_tab_tooltip(query: &str, label: &str) -> Option<String> {
    let q = query.trim();
    if q.is_empty() {
        return None;
    }
    let preview: String = q.chars().take(200).collect();
    let preview = if q.chars().count() > 200 {
        format!("{preview}…")
    } else {
        preview
    };
    if preview == label { None } else { Some(preview) }
}

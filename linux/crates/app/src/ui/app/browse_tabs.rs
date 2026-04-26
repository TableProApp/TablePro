use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::{Component, ComponentController, ComponentSender, adw, gtk};

use uuid::Uuid;

use crate::services::browse_state::{self, BrowseTabRecord, ConnectionBrowseState};
use crate::services::database_service;
use crate::ui::browse_tab::{BrowseTab, BrowseTabInit, BrowseTabInput, BrowseTabOutput};

use super::{App, AppMsg, BrowseTabSlot, OpenMode, qualified_label, read_browse_tab_id, write_browse_tab_id};

impl App {
    /// Builds the Browse AdwTabOverview tree once per connection. Idempotent
    /// via `browse_root_added`; matches `ensure_editor_page` precisely.
    pub(super) fn ensure_browse_root(&mut self, sender: ComponentSender<Self>) {
        if self.browse_root_added.get() {
            return;
        }
        if self.browse_root.is_none() {
            self.build_browse_root(sender);
        }
        // The browse_outer_stack is already in view_stack as the "browse"
        // page. We swap its visible child to "tabs" once the root is built.
        if let Some(root) = self.browse_root.as_ref() {
            // Re-parent root into outer_stack as the "tabs" child.
            if self.browse_outer_stack.child_by_name("tabs").is_none() {
                self.browse_outer_stack.add_named(root, Some("tabs"));
            }
        }
        self.browse_root_added.set(true);
    }

    fn build_browse_root(&mut self, sender: ComponentSender<Self>) {
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

        // The Browse "+" button can't usefully open a blank tab (browse
        // tabs need a target table) so we don't add one — sidebar click
        // is the new-tab affordance per Q2.

        // 2-step close: TabView signals close → App message → close_finish.
        let close_sender = sender.clone();
        tab_view.connect_close_page(move |_view, page| {
            if let Some(id) = read_browse_tab_id(page) {
                close_sender.input(AppMsg::BrowseTabClosed(id));
            }
            glib::Propagation::Stop
        });

        // Selection / order changes trigger persistence (drag-reorder, tab
        // activation). Same pattern as editor_tabs.
        let pages_sender = sender.clone();
        tab_view.connect_selected_page_notify(move |_| {
            pages_sender.input(AppMsg::BrowseTabsChanged);
        });

        let inner = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        inner.append(&tab_bar);
        inner.append(&tab_view);

        let tab_overview = adw::TabOverview::builder()
            .view(&tab_view)
            .enable_new_tab(false)
            .enable_search(true)
            .child(&inner)
            .build();

        self.browse_root = Some(tab_overview);
        self.browse_tab_view = Some(tab_view);
    }

    /// Restore browse tabs from disk for the just-connected database.
    pub(super) fn restore_browse_tabs(&mut self, connection_id: Uuid, sender: ComponentSender<Self>) {
        let Some(saved) = browse_state::load_connection(connection_id) else {
            self.browse_outer_stack.set_visible_child_name("empty");
            return;
        };
        if saved.tabs.is_empty() {
            self.browse_outer_stack.set_visible_child_name("empty");
            return;
        }
        for record in &saved.tabs {
            self.append_browse_tab_from_record(record.clone(), sender.clone());
        }
        if let Some(tab_view) = self.browse_tab_view.as_ref()
            && let Some(page) = tab_view.pages().item(saved.active_idx).and_downcast::<adw::TabPage>()
        {
            tab_view.set_selected_page(&page);
        }
        self.browse_outer_stack.set_visible_child_name("tabs");
    }

    /// Append a new browse tab for `(schema, table)` and select it.
    pub(super) fn append_browse_tab(
        &mut self,
        schema: Option<String>,
        table: String,
        sender: ComponentSender<Self>,
    ) -> Option<Uuid> {
        let record = BrowseTabRecord {
            schema,
            table,
            offset: 0,
            page_size: self.default_page_size,
            sort_col: None,
            sort_asc: None,
        };
        Some(self.append_browse_tab_from_record(record, sender))
    }

    fn append_browse_tab_from_record(&mut self, record: BrowseTabRecord, sender: ComponentSender<Self>) -> Uuid {
        self.ensure_browse_root(sender.clone());
        let Some(tab_view) = self.browse_tab_view.clone() else {
            // Should never happen — ensure_browse_root just built it.
            return Uuid::nil();
        };

        let tab_id = Uuid::new_v4();
        let driver_id = self.driver_id().to_string();
        let connection_id = database_service::instance().active_id();
        let read_only = self.read_only;
        let init = BrowseTabInit {
            tab_id,
            schema: record.schema.clone(),
            table: record.table.clone(),
            driver_id,
            connection_id,
            read_only,
            page_size: record.page_size,
            initial_offset: record.offset,
            initial_sort: match (record.sort_col, record.sort_asc) {
                (Some(c), Some(a)) => Some((c, a)),
                _ => None,
            },
        };

        let controller = BrowseTab::builder()
            .launch(init)
            .forward(sender.input_sender(), move |out| match out {
                BrowseTabOutput::FetchPage => AppMsg::FetchBrowsePage(tab_id),
                BrowseTabOutput::FetchColumns => AppMsg::FetchBrowseColumns(tab_id),
                BrowseTabOutput::FetchRowCount => AppMsg::FetchBrowseRowCount(tab_id),
                BrowseTabOutput::StateChanged => AppMsg::BrowseStateChanged,
                BrowseTabOutput::OpenInsertDialog {
                    columns,
                    table,
                    driver_id,
                } => AppMsg::ShowInsertDialog {
                    tab_id,
                    table,
                    columns,
                    driver_id,
                },
                BrowseTabOutput::OpenEditDialog {
                    columns,
                    row,
                    table,
                    driver_id,
                } => AppMsg::ShowEditDialog {
                    tab_id,
                    table,
                    columns,
                    driver_id,
                    row,
                },
                BrowseTabOutput::DeleteSelected {
                    columns,
                    table,
                    driver_id,
                    positions,
                    rows,
                } => AppMsg::ConfirmDeleteSelected {
                    tab_id,
                    table,
                    columns,
                    driver_id,
                    positions,
                    rows,
                },
                BrowseTabOutput::CellEdited {
                    table,
                    row_position,
                    col_index,
                    new_value,
                } => AppMsg::CellEdited {
                    tab_id,
                    table,
                    row_position,
                    col_index,
                    new_value,
                },
                BrowseTabOutput::SetCellNull {
                    table,
                    row_position,
                    col_index,
                } => AppMsg::SetCellNull {
                    tab_id,
                    table,
                    row_position,
                    col_index,
                },
                BrowseTabOutput::DeleteRowAt { table, row_position } => AppMsg::DeleteRowAt {
                    tab_id,
                    table,
                    row_position,
                },
                BrowseTabOutput::CopyRowAsInsert { row_position } => AppMsg::CopyRowAsInsert { tab_id, row_position },
                BrowseTabOutput::CopyToClipboard(text) => AppMsg::CopyToClipboard(text),
                BrowseTabOutput::SchemaWordsChanged(_words) => AppMsg::BrowseSchemaWordsChanged,
                BrowseTabOutput::ShowSelectionAlert { title, body } => AppMsg::ShowAlert { title, body },
            });

        let page = tab_view.append(controller.widget());
        let label =
            qualified_browse_tab_label(self.sidebar_schemas_distinct(), record.schema.as_deref(), &record.table);
        page.set_title(&label);
        page.set_tooltip(&label);
        write_browse_tab_id(&page, tab_id);

        let slot = BrowseTabSlot {
            id: tab_id,
            controller,
            page: page.clone(),
            schema: record.schema,
            table: record.table,
        };
        self.browse_tabs.borrow_mut().insert(tab_id, slot);
        tab_view.set_selected_page(&page);
        self.browse_outer_stack.set_visible_child_name("tabs");
        // Refresh window title to pick up the newly active tab.
        self.refresh_window_title();
        self.persist_browse_state();
        tab_id
    }

    pub(super) fn close_browse_tab_by_id(&mut self, id: Uuid, _sender: ComponentSender<Self>) {
        let Some(tab_view) = self.browse_tab_view.clone() else {
            return;
        };
        let Some(removed) = self.browse_tabs.borrow_mut().remove(&id) else {
            return;
        };
        tab_view.close_page_finish(&removed.page, true);
        drop(removed);
        self.persist_browse_state();
        if self.browse_tabs.borrow().is_empty() {
            self.browse_outer_stack.set_visible_child_name("empty");
        }
        self.rebuild_schema_buffer();
        self.refresh_window_title();
    }

    pub(super) fn close_active_browse_tab(&mut self, sender: ComponentSender<Self>) {
        let Some(tab_view) = self.browse_tab_view.as_ref() else {
            return;
        };
        let Some(page) = tab_view.selected_page() else {
            return;
        };
        // Initiate via TabView so the close_page signal fires and we go
        // through the normal close-finish path.
        tab_view.close_page(&page);
        let _ = sender;
    }

    /// Smart-switch dispatcher for sidebar clicks. Q1: if a tab for
    /// `(schema, name)` already exists, activate it; otherwise replace
    /// the active tab (or append the first when none exist).
    pub(super) fn dispatch_select_table(
        &mut self,
        schema: Option<String>,
        name: String,
        open_mode: OpenMode,
        sender: ComponentSender<Self>,
    ) {
        match open_mode {
            OpenMode::NewTab => {
                self.append_browse_tab(schema, name, sender);
            }
            OpenMode::SmartSwitchOrReplace => {
                // Already-open tab? Activate it.
                let existing = self
                    .browse_tabs
                    .borrow()
                    .values()
                    .find(|s| s.schema.as_deref() == schema.as_deref() && s.table == name)
                    .map(|s| s.page.clone());
                if let Some(page) = existing
                    && let Some(tab_view) = self.browse_tab_view.as_ref()
                {
                    tab_view.set_selected_page(&page);
                    return;
                }
                // No existing tab. Empty browse → append; else replace
                // active tab in place to honor "single click = replace".
                if self.browse_tabs.borrow().is_empty() {
                    self.append_browse_tab(schema, name, sender);
                } else if let Some(active_id) = self.selected_browse_tab_id() {
                    self.close_browse_tab_by_id(active_id, sender.clone());
                    self.append_browse_tab(schema, name, sender);
                } else {
                    self.append_browse_tab(schema, name, sender);
                }
            }
        }
    }

    /// Persist all open browse tabs for the active connection.
    pub(super) fn persist_browse_state(&self) {
        let Some(connection_id) = database_service::instance().active_id() else {
            return;
        };
        let tabs_map = self.browse_tabs.borrow();
        let Some(tab_view) = self.browse_tab_view.as_ref() else {
            return;
        };
        let pages = tab_view.pages();
        let n = pages.n_items();
        let active_page = tab_view.selected_page();
        let mut tab_records: Vec<BrowseTabRecord> = Vec::with_capacity(n as usize);
        let mut active_idx: u32 = 0;
        for i in 0..n {
            let Some(page) = pages.item(i).and_downcast::<adw::TabPage>() else {
                continue;
            };
            if active_page.as_ref() == Some(&page) {
                active_idx = i;
            }
            let Some(id) = read_browse_tab_id(&page) else {
                continue;
            };
            let Some(slot) = tabs_map.get(&id) else { continue };
            let model = slot.controller.model();
            let sort = model.current_sort();
            tab_records.push(BrowseTabRecord {
                schema: slot.schema.clone(),
                table: slot.table.clone(),
                offset: model.current_offset(),
                page_size: model.page_size(),
                sort_col: sort.map(|(c, _)| c),
                sort_asc: sort.map(|(_, a)| a),
            });
        }
        let conn_state = ConnectionBrowseState {
            tabs: tab_records,
            active_idx,
        };
        browse_state::save_connection(connection_id, conn_state);
    }

    pub(super) fn selected_browse_tab_id(&self) -> Option<Uuid> {
        let tab_view = self.browse_tab_view.as_ref()?;
        let page = tab_view.selected_page()?;
        read_browse_tab_id(&page)
    }

    pub(super) fn selected_browse_slot_table(&self) -> Option<(Option<String>, String)> {
        let id = self.selected_browse_tab_id()?;
        let tabs = self.browse_tabs.borrow();
        let slot = tabs.get(&id)?;
        Some((slot.schema.clone(), slot.table.clone()))
    }

    /// Rebuilds the editor's autocomplete word list as the union of
    /// all currently-open browse tabs' columns + sidebar table names.
    pub(super) fn rebuild_schema_buffer(&self) {
        let mut words: Vec<String> = self.table_names.clone();
        let tabs = self.browse_tabs.borrow();
        for slot in tabs.values() {
            for col in slot.controller.model().columns() {
                words.push(col.name.clone());
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

    /// Tear down the entire browse tab tree on disconnect. Persists
    /// state first so a fresh connection's tabs aren't lost.
    pub(super) fn teardown_browse_tabs(&mut self) {
        self.persist_browse_state();
        if let Some(root) = self.browse_root.take()
            && self.browse_root_added.get()
        {
            // Remove from outer_stack — keeps the "empty" StatusPage as
            // the only child for the disconnected state.
            if self.browse_outer_stack.child_by_name("tabs").is_some() {
                self.browse_outer_stack.remove(&root);
            }
            self.browse_root_added.set(false);
        }
        self.browse_outer_stack.set_visible_child_name("empty");
        self.browse_tab_view = None;
        self.browse_tabs.borrow_mut().clear();
    }

    /// Forward a per-tab input message to the right BrowseTab slot.
    /// Used by the dispatcher in update() for tab-scoped messages.
    pub(super) fn dispatch_to_tab(&self, tab_id: Uuid, msg: BrowseTabInput) {
        if let Some(slot) = self.browse_tabs.borrow().get(&tab_id) {
            let _ = slot.controller.sender().send(msg);
        }
    }
}

/// Tab title format: `schema.table` if multiple schemas exist in the
/// sidebar (matches header_func behavior), else just `table`.
fn qualified_browse_tab_label(schemas_count: usize, schema: Option<&str>, table: &str) -> String {
    if schemas_count >= 2
        && let Some(s) = schema
    {
        format!("{s}.{table}")
    } else {
        table.to_string()
    }
}

// Quiet warnings when the App-level helper isn't yet wired up.
#[allow(dead_code)]
fn _qualified_label_unused(schema: Option<&str>, table: &str) -> String {
    qualified_label(schema, table)
}

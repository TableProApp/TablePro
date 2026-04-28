//! App-side handlers for the Structure (DDL) workspace tab.
//!
//! Each `on_*` method mirrors the equivalent Browse-tab path in
//! `browse.rs` / `row_ops.rs`: dispatch by tab id, take a slot
//! reference, run async work via `sender.command`, route results
//! back through `AppMsg::Structure*Loaded` / `Structure*Completed`
//! variants. Window-close is gated by the shared `in_flight_saves`
//! counter so a Structure DDL transaction can't commit after the
//! window has been torn down.

use relm4::adw::prelude::*;
use relm4::{ComponentController, ComponentSender, adw};
use uuid::Uuid;

use tablepro_core::ColumnInfo;

use crate::services::database_service;
use crate::services::structure_tracker;
use crate::ui::app::{App, AppMsg, WorkspaceTab};
use crate::ui::structure_tab::{StructureMode, StructureTabInput};

impl App {
    /// Sidebar right-click → "New Table…" or schema-header "+" button.
    pub(super) fn on_new_table_tab(&mut self, schema: Option<String>, sender: ComponentSender<Self>) {
        if !self.connected {
            self.show_toast(&crate::tr!("Connect to a database first."));
            return;
        }
        self.append_structure_tab(schema, String::new(), StructureMode::New, sender);
    }

    /// Sidebar right-click → "Edit Structure". Switches to an existing
    /// Edit-mode Structure tab when one matches `(schema, table)`,
    /// otherwise appends a new one.
    pub(super) fn on_edit_structure_tab(
        &mut self,
        schema: Option<String>,
        table: String,
        sender: ComponentSender<Self>,
    ) {
        if !self.connected {
            self.show_toast(&crate::tr!("Connect to a database first."));
            return;
        }
        // Look for an existing Edit-mode Structure tab pointing at the
        // same (schema, table). HashMap iteration order isn't stable,
        // so prefer the currently-selected page when multiple match.
        let selected_page = self.workspace_tab_view.as_ref().and_then(|tv| tv.selected_page());
        let mut existing: Option<adw::TabPage> = None;
        for tab in self.workspace_tabs.borrow().values() {
            if let WorkspaceTab::Structure(slot) = tab
                && slot.mode == StructureMode::Edit
                && slot.schema == schema
                && slot.table == table
            {
                if Some(&slot.page) == selected_page.as_ref() {
                    existing = Some(slot.page.clone());
                    break;
                }
                if existing.is_none() {
                    existing = Some(slot.page.clone());
                }
            }
        }
        if let Some(page) = existing
            && let Some(tab_view) = self.workspace_tab_view.as_ref()
        {
            tab_view.set_selected_page(&page);
            return;
        }
        self.append_structure_tab(schema, table, StructureMode::Edit, sender);
    }

    /// Right-click → "Drop Table…", or in-tab destructive button.
    pub(super) fn on_drop_table_prompt(
        &mut self,
        schema: Option<String>,
        table: String,
        sender: ComponentSender<Self>,
    ) {
        let title = crate::tr!("Drop {table}?").replace("{table}", &table);
        let body =
            crate::tr!("All rows and the table definition will be removed. This can't be undone from inside TablePro.");
        let dialog = adw::AlertDialog::new(Some(&title), Some(&body));
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("drop", &crate::tr!("Drop"));
        dialog.set_response_appearance("drop", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let sender_for_resp = sender.clone();
        let schema_for_resp = schema.clone();
        let table_for_resp = table.clone();
        dialog.connect_response(None, move |dlg, response| {
            dlg.close();
            if response == "drop" {
                sender_for_resp.input(AppMsg::DropTableConfirmed {
                    schema: schema_for_resp.clone(),
                    table: table_for_resp.clone(),
                });
            }
        });
        dialog.present(Some(&self.window));
    }

    /// User confirmed the drop. Run DROP TABLE async; only close any
    /// open Browse / Structure tabs for the table after the DROP
    /// returns Ok. Tabs stay open if DROP fails (FK violation,
    /// privileges) so the user doesn't lose their state on a failed
    /// destructive action.
    pub(super) fn on_drop_table_confirmed(
        &mut self,
        schema: Option<String>,
        table: String,
        sender: ComponentSender<Self>,
    ) {
        let Some(driver_id) = self.current_driver_id.clone() else {
            return;
        };
        let sql = match tablepro_core::sql_ddl::build_drop_table(&driver_id, schema.as_deref(), &table, true, false) {
            Ok(s) => s,
            Err(e) => {
                self.show_error_alert(&crate::tr!("Cannot drop table"), &format!("{e}"));
                return;
            }
        };
        let schema_for_msg = schema.clone();
        let table_for_msg = table.clone();
        let sender_for_cmd = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let Some(conn) = database_service::instance().active() else {
                        sender_for_cmd.input(AppMsg::ShowAlert {
                            title: crate::tr!("Cannot drop table"),
                            body: crate::tr!("No active connection."),
                        });
                        return;
                    };
                    match conn.execute(&sql).await {
                        Ok(_) => {
                            sender_for_cmd.input(AppMsg::DropTableSucceeded {
                                schema: schema_for_msg.clone(),
                                table: table_for_msg.clone(),
                            });
                        }
                        Err(e) => {
                            sender_for_cmd.input(AppMsg::ShowAlert {
                                title: crate::tr!("Drop failed"),
                                body: format!("{e}"),
                            });
                        }
                    }
                })
                .drop_on_shutdown()
        });
    }

    /// Targeted save: commit a specific Structure tab's pending DDL
    /// without requiring it to be the active tab. Used by the
    /// close-with-pending dialog's "Save" branch — the user might be
    /// closing a background tab via its X button.
    pub(super) fn save_structure_tab_by_id(&mut self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let driver_id = self.driver_id().to_string();
        let result = structure_tracker::with_tab_ref(tab_id, |t| t.materialize(&driver_id));
        match result {
            Some(Ok(statements)) if !statements.is_empty() => {
                self.on_execute_structure_transaction(tab_id, statements, sender);
            }
            Some(Ok(_)) => {
                // Nothing to save — short-circuit so close-after-save
                // can proceed.
                sender.input(AppMsg::StructureSaveCompleted {
                    tab_id,
                    new_table_name: None,
                });
            }
            Some(Err(e)) => {
                sender.input(AppMsg::StructureSaveFailed(tab_id, format!("{e}")));
            }
            None => {}
        }
    }

    /// Drop succeeded on the driver — now close any open tabs for
    /// the dropped table and refresh sidebar. Run synchronously on
    /// the GTK main thread so the close + sidebar refresh appear
    /// atomic to the user.
    pub(super) fn on_drop_table_succeeded(
        &mut self,
        schema: Option<String>,
        table: String,
        sender: ComponentSender<Self>,
    ) {
        self.close_tabs_for_table(schema.as_deref(), &table);
        sender.input(AppMsg::SchemaChanged {
            schema,
            table: Some(table),
        });
    }

    /// Walk the tab map and force-close any Browse / Structure tabs
    /// pointing at `(schema, table)`. Skips the per-tab pending-changes
    /// dialog because the underlying table is gone.
    pub(super) fn close_tabs_for_table(&mut self, schema: Option<&str>, table: &str) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let mut targets: Vec<Uuid> = Vec::new();
        for (id, tab) in self.workspace_tabs.borrow().iter() {
            match tab {
                WorkspaceTab::Browse(s) if s.schema.as_deref() == schema && s.table == table => targets.push(*id),
                WorkspaceTab::Structure(s) if s.schema.as_deref() == schema && s.table == table => targets.push(*id),
                _ => {}
            }
        }
        for id in targets {
            self.finish_close_workspace_tab(id, &tab_view);
        }
    }

    /// Structure tab Save → run ordered DDL statements. Postgres wraps
    /// in BEGIN / COMMIT for atomicity (DDL is transactional in PG);
    /// MySQL / SQLite execute sequentially because their DDL is
    /// auto-committed per-statement and a wrapping transaction would
    /// either be ignored or error out on the first DDL.
    pub(super) fn on_execute_structure_transaction(
        &mut self,
        tab_id: Uuid,
        statements: Vec<String>,
        sender: ComponentSender<Self>,
    ) {
        let Some(driver_id) = self.current_driver_id.clone() else {
            sender.input(AppMsg::StructureSaveFailed(tab_id, crate::tr!("No active connection.")));
            return;
        };
        let (schema, prev_table, mode) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(WorkspaceTab::Structure(slot)) = tabs.get(&tab_id) else {
                return;
            };
            (slot.schema.clone(), slot.table.clone(), slot.mode)
        };
        // For New mode we need the user-typed table name. Today the
        // stub UI doesn't expose a name field yet, so pull it from
        // the first CreateTable op in the tracker.
        let new_table_name = if matches!(mode, StructureMode::New) {
            structure_tracker::with_tab_ref(tab_id, |t| {
                t.ops().iter().find_map(|op| {
                    if let crate::services::structure_tracker::StructureOp::CreateTable { table, .. } = op {
                        Some(table.clone())
                    } else {
                        None
                    }
                })
            })
            .flatten()
        } else {
            None
        };

        self.in_flight_saves.set(self.in_flight_saves.get() + 1);
        let sender_for_cmd = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let Some(conn) = database_service::instance().active() else {
                        sender_for_cmd.input(AppMsg::StructureSaveFailed(tab_id, crate::tr!("No active connection.")));
                        return;
                    };
                    let wrap_tx = driver_id == "postgres";
                    if wrap_tx && let Err(e) = conn.execute("BEGIN").await {
                        sender_for_cmd.input(AppMsg::StructureSaveFailed(tab_id, format!("{e}")));
                        return;
                    }
                    for sql in &statements {
                        if let Err(e) = conn.execute(sql).await {
                            if wrap_tx {
                                let _ = conn.execute("ROLLBACK").await;
                            }
                            sender_for_cmd.input(AppMsg::StructureSaveFailed(tab_id, format!("{e}")));
                            return;
                        }
                    }
                    if wrap_tx && let Err(e) = conn.execute("COMMIT").await {
                        sender_for_cmd.input(AppMsg::StructureSaveFailed(tab_id, format!("{e}")));
                        return;
                    }
                    sender_for_cmd.input(AppMsg::StructureSaveCompleted {
                        tab_id,
                        new_table_name: new_table_name.clone(),
                    });
                })
                .drop_on_shutdown()
        });
        let _ = (schema, prev_table);
    }

    /// Save resolved successfully. Tell the tab so it can clear the
    /// tracker + (in New mode) promote to Edit; refresh sidebar +
    /// any open Browse tabs for the affected table.
    pub(super) fn on_structure_save_completed(
        &mut self,
        tab_id: Uuid,
        new_table_name: Option<String>,
        sender: ComponentSender<Self>,
    ) {
        if self.in_flight_saves.get() > 0 {
            self.in_flight_saves.set(self.in_flight_saves.get() - 1);
        }
        let mut affected_table: Option<String> = None;
        let mut affected_schema: Option<String> = None;
        if let Some(WorkspaceTab::Structure(slot)) = self.workspace_tabs.borrow_mut().get_mut(&tab_id) {
            affected_schema = slot.schema.clone();
            if let Some(new_name) = new_table_name.clone() {
                slot.table = new_name.clone();
                slot.mode = StructureMode::Edit;
                slot.page.set_title(&new_name);
                affected_table = Some(new_name);
            } else {
                affected_table = Some(slot.table.clone());
            }
        }
        // Forward to the tab so it clears + (if needed) promotes to
        // Edit and refetches.
        if let Some(WorkspaceTab::Structure(slot)) = self.workspace_tabs.borrow().get(&tab_id) {
            let _ = slot
                .controller
                .sender()
                .send(StructureTabInput::SaveCompleted { new_table_name });
        }
        if let Some(table) = affected_table {
            sender.input(AppMsg::SchemaChanged {
                schema: affected_schema,
                table: Some(table),
            });
        }
    }

    pub(super) fn on_structure_save_failed(&mut self, tab_id: Uuid, message: String) {
        if self.in_flight_saves.get() > 0 {
            self.in_flight_saves.set(self.in_flight_saves.get() - 1);
        }
        if let Some(WorkspaceTab::Structure(slot)) = self.workspace_tabs.borrow().get(&tab_id) {
            let _ = slot.controller.sender().send(StructureTabInput::SaveFailed(message));
        }
    }

    /// Edit-mode init asks for introspection. Fetch columns / indexes /
    /// FKs in one async block and dispatch a single StructureLoaded
    /// carrying all three so the tab only rebuilds its UI once. The
    /// previous fan-out (3 messages, 3 rebuilds) was visible as
    /// flicker on Edit-mode tab open.
    pub(super) fn on_fetch_structure_data(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let (schema, table) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(WorkspaceTab::Structure(slot)) = tabs.get(&tab_id) else {
                return;
            };
            (slot.schema.clone(), slot.table.clone())
        };
        let sender_for_cmd = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let Some(conn) = database_service::instance().active() else {
                        sender_for_cmd.input(AppMsg::StructureLoadFailed {
                            tab_id,
                            message: crate::tr!("No active connection."),
                        });
                        return;
                    };
                    let columns = match conn.fetch_columns(schema.as_deref(), &table).await {
                        Ok(c) => c,
                        Err(e) => {
                            sender_for_cmd.input(AppMsg::StructureLoadFailed {
                                tab_id,
                                message: format!("{e}"),
                            });
                            return;
                        }
                    };
                    let indexes = conn.fetch_indexes(schema.as_deref(), &table).await.unwrap_or_default();
                    let fks = conn
                        .fetch_foreign_keys(schema.as_deref(), &table)
                        .await
                        .unwrap_or_default();
                    sender_for_cmd.input(AppMsg::StructureDataLoaded {
                        tab_id,
                        columns,
                        indexes,
                        fks,
                    });
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_structure_data_loaded(
        &self,
        tab_id: Uuid,
        columns: Vec<ColumnInfo>,
        indexes: Vec<tablepro_core::IndexInfo>,
        fks: Vec<tablepro_core::ForeignKeyInfo>,
    ) {
        if let Some(WorkspaceTab::Structure(slot)) = self.workspace_tabs.borrow().get(&tab_id) {
            let _ = slot
                .controller
                .sender()
                .send(StructureTabInput::StructureLoaded { columns, indexes, fks });
        }
    }

    pub(super) fn on_structure_load_failed(&self, tab_id: Uuid, message: String) {
        if let Some(WorkspaceTab::Structure(slot)) = self.workspace_tabs.borrow().get(&tab_id) {
            let _ = slot.controller.sender().send(StructureTabInput::LoadFailed(message));
        }
    }

    /// Schema state changed somewhere — reload the table list, then
    /// refetch any open Browse tab pointing at the affected table so
    /// its grid reflects post-DDL schema (column adds / drops / type
    /// changes / renames).
    pub(super) fn on_schema_changed(
        &self,
        schema: Option<String>,
        table: Option<String>,
        sender: ComponentSender<Self>,
    ) {
        // Refetch the affected Browse tab(s) immediately. Tab-id
        // collection happens under a short-lived borrow; the sender
        // dispatches happen after drop so the input handlers can
        // re-borrow workspace_tabs without panic.
        if let Some(table_name) = table.as_deref() {
            let mut affected: Vec<Uuid> = Vec::new();
            for (id, tab) in self.workspace_tabs.borrow().iter() {
                if let WorkspaceTab::Browse(slot) = tab
                    && slot.schema.as_deref() == schema.as_deref()
                    && slot.table == table_name
                {
                    affected.push(*id);
                }
            }
            for id in affected {
                sender.input(AppMsg::FetchBrowseColumns(id));
                sender.input(AppMsg::FetchBrowsePage(id));
                sender.input(AppMsg::FetchBrowseRowCount(id));
            }
        }
        // Sidebar refresh: re-list tables and rebuild the factory.
        let sender_for_cmd = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let Some(conn) = database_service::instance().active() else {
                        return;
                    };
                    if let Ok(tables) = conn.list_tables().await {
                        sender_for_cmd.input(AppMsg::TablesReloaded(tables));
                    }
                })
                .drop_on_shutdown()
        });
        // Refetching individual Browse tabs is wired in the next
        // milestone alongside the sidebar refresh path; the
        // TablesReloaded handler below covers the sidebar side.
    }

    pub(super) fn on_tables_reloaded(&mut self, tables: Vec<tablepro_core::TableInfo>) {
        // Rebuild the sidebar factory the same way `Connected` does.
        // The connection.rs helper exposes `repopulate_sidebar` for
        // exactly this use case.
        self.repopulate_sidebar(&tables);
    }

    pub(super) fn refresh_structure_tab_dirty(&self, tab_id: Uuid, dirty: bool) {
        let schemas_count = self.sidebar_schemas_distinct();
        let tabs = self.workspace_tabs.borrow();
        let Some(WorkspaceTab::Structure(slot)) = tabs.get(&tab_id) else {
            return;
        };
        let base = if slot.table.is_empty() {
            crate::tr!("New Table")
        } else {
            super::workspace_tabs::qualified_browse_tab_label(schemas_count, slot.schema.as_deref(), &slot.table)
        };
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

    pub(super) fn undo_active_structure_tab(&self) {
        if let Some(id) = self.selected_structure_tab_id() {
            structure_tracker::with_tab(id, |t| t.undo());
        }
    }

    pub(super) fn redo_active_structure_tab(&self) {
        if let Some(id) = self.selected_structure_tab_id() {
            structure_tracker::with_tab(id, |t| t.redo());
        }
    }

    pub(super) fn selected_structure_tab_id(&self) -> Option<Uuid> {
        let tab_view = self.workspace_tab_view.as_ref()?;
        let page = tab_view.selected_page()?;
        let id = crate::ui::app::read_workspace_tab_id(&page)?;
        if let WorkspaceTab::Structure(_) = self.workspace_tabs.borrow().get(&id)? {
            Some(id)
        } else {
            None
        }
    }
}

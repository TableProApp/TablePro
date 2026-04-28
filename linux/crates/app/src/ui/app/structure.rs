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
        self.append_new_structure_tab(schema, sender);
    }

    /// Sidebar right-click → "Edit Structure". Routes to the unified
    /// Table tab (M-1): if a Table tab already exists for this
    /// (schema, table), select it and flip its `AdwViewSwitcher` to
    /// Structure mode. Otherwise append a new Table tab opened
    /// directly to Structure mode. Legacy `Browse` / `Structure` slots
    /// from older sessions are also considered a match so the user
    /// doesn't end up with both a legacy tab and a fresh Table tab.
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
        let selected_page = self.workspace_tab_view.as_ref().and_then(|tv| tv.selected_page());
        let mut existing_table: Option<(uuid::Uuid, adw::TabPage)> = None;
        let mut existing_legacy: Option<adw::TabPage> = None;
        for (id, tab) in self.workspace_tabs.borrow().iter() {
            match tab {
                WorkspaceTab::Table(slot) if slot.schema == schema && slot.table == table => {
                    if Some(&slot.page) == selected_page.as_ref() {
                        existing_table = Some((*id, slot.page.clone()));
                        break;
                    }
                    if existing_table.is_none() {
                        existing_table = Some((*id, slot.page.clone()));
                    }
                }
                WorkspaceTab::Structure(slot)
                    if slot.mode == StructureMode::Edit && slot.schema == schema && slot.table == table =>
                {
                    if existing_legacy.is_none() {
                        existing_legacy = Some(slot.page.clone());
                    }
                }
                _ => {}
            }
        }
        if let Some((id, page)) = existing_table {
            if let Some(tab_view) = self.workspace_tab_view.as_ref() {
                tab_view.set_selected_page(&page);
            }
            if let Some(WorkspaceTab::Table(slot)) = self.workspace_tabs.borrow_mut().get_mut(&id) {
                slot.view_stack.set_visible_child_name("structure");
                slot.mode = super::TableMode::Structure;
            }
            return;
        }
        if let Some(page) = existing_legacy
            && let Some(tab_view) = self.workspace_tab_view.as_ref()
        {
            tab_view.set_selected_page(&page);
            return;
        }
        super::App::append_table_tab(
            self,
            schema,
            table,
            super::TableMode::Structure,
            0,
            self.default_page_size,
            None,
            sender,
        );
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
                WorkspaceTab::Structure(s) if s.schema.as_deref() == schema && s.table == table => targets.push(*id),
                WorkspaceTab::Table(s) if s.schema.as_deref() == schema && s.table == table => targets.push(*id),
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
        // Reject re-entry: a second Ctrl+S (or rapid double-click on
        // Save) while the first DDL transaction is still mid-flight
        // would dispatch a parallel async command and potentially
        // commit the same statements twice. Mark the tab and bail.
        if !self.structure_saves_in_flight.borrow_mut().insert(tab_id) {
            tracing::debug!(?tab_id, "structure save already in flight; ignoring duplicate");
            return;
        }
        let Some(driver_id) = self.current_driver_id.clone() else {
            self.structure_saves_in_flight.borrow_mut().remove(&tab_id);
            sender.input(AppMsg::StructureSaveFailed(tab_id, crate::tr!("No active connection.")));
            return;
        };
        let (schema, prev_table, mode) = {
            let tabs = self.workspace_tabs.borrow();
            let Some(slot) = tabs.get(&tab_id) else {
                self.structure_saves_in_flight.borrow_mut().remove(&tab_id);
                return;
            };
            match slot {
                WorkspaceTab::Structure(s) => (s.schema.clone(), s.table.clone(), s.mode),
                WorkspaceTab::Table(s) => (s.schema.clone(), s.table.clone(), s.structure_mode),
                _ => {
                    self.structure_saves_in_flight.borrow_mut().remove(&tab_id);
                    return;
                }
            }
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

    /// Save resolved successfully. Two cases post-M-1 cleanup:
    ///
    /// 1. **New-Table draft (`Structure` slot)**: CreateTable
    ///    succeeded so the table now exists. Close the draft and
    ///    append a fresh `Table` tab pointed at the new name in
    ///    Structure mode so the user keeps editing in the canonical
    ///    UI.
    /// 2. **Table tab Save**: the slot stays put; just forward
    ///    `SaveCompleted` to the structure controller so it clears
    ///    the tracker + refetches introspection.
    pub(super) fn on_structure_save_completed(
        &mut self,
        tab_id: Uuid,
        new_table_name: Option<String>,
        sender: ComponentSender<Self>,
    ) {
        if self.in_flight_saves.get() > 0 {
            self.in_flight_saves.set(self.in_flight_saves.get() - 1);
        }
        self.structure_saves_in_flight.borrow_mut().remove(&tab_id);

        // Inspect slot kind first so we can branch — promote-and-close
        // vs. in-place clear — without borrowing across mutation.
        enum SaveKind {
            PromoteNewToTable(Option<String>, String),
            UpdateInPlace(Option<String>, String),
            Skip,
        }
        // Post-M-1 cleanup: `WorkspaceTab::Structure` only exists for
        // New-Table drafts. Edit-mode DDL flows through Table tabs
        // exclusively. Match accordingly.
        let kind = {
            let tabs = self.workspace_tabs.borrow();
            match tabs.get(&tab_id) {
                Some(WorkspaceTab::Structure(slot)) => match new_table_name.clone() {
                    Some(name) => SaveKind::PromoteNewToTable(slot.schema.clone(), name),
                    None => SaveKind::Skip,
                },
                Some(WorkspaceTab::Table(slot)) => SaveKind::UpdateInPlace(slot.schema.clone(), slot.table.clone()),
                _ => SaveKind::Skip,
            }
        };

        match kind {
            SaveKind::PromoteNewToTable(schema, name) => {
                if let Some(tab_view) = self.workspace_tab_view.clone() {
                    self.finish_close_workspace_tab(tab_id, &tab_view);
                }
                super::App::append_table_tab(
                    self,
                    schema.clone(),
                    name.clone(),
                    super::TableMode::Structure,
                    0,
                    self.default_page_size,
                    None,
                    sender.clone(),
                );
                sender.input(AppMsg::SchemaChanged {
                    schema,
                    table: Some(name),
                });
            }
            SaveKind::UpdateInPlace(schema, table) => {
                if let Some(controller) = self
                    .workspace_tabs
                    .borrow()
                    .get(&tab_id)
                    .and_then(|t| t.structure_controller())
                {
                    let _ = controller
                        .sender()
                        .send(StructureTabInput::SaveCompleted { new_table_name });
                }
                sender.input(AppMsg::SchemaChanged {
                    schema,
                    table: Some(table),
                });
            }
            SaveKind::Skip => {}
        }
    }

    pub(super) fn on_structure_save_failed(&mut self, tab_id: Uuid, message: String) {
        if self.in_flight_saves.get() > 0 {
            self.in_flight_saves.set(self.in_flight_saves.get() - 1);
        }
        self.structure_saves_in_flight.borrow_mut().remove(&tab_id);
        if let Some(controller) = self
            .workspace_tabs
            .borrow()
            .get(&tab_id)
            .and_then(|t| t.structure_controller())
        {
            let _ = controller.sender().send(StructureTabInput::SaveFailed(message));
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
            let Some(slot) = tabs.get(&tab_id) else {
                return;
            };
            let Some((schema, table)) = slot.schema_table() else {
                return;
            };
            (schema.map(str::to_owned), table.to_string())
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
        if let Some(controller) = self
            .workspace_tabs
            .borrow()
            .get(&tab_id)
            .and_then(|t| t.structure_controller())
        {
            let _ = controller
                .sender()
                .send(StructureTabInput::StructureLoaded { columns, indexes, fks });
        }
    }

    pub(super) fn on_structure_load_failed(&self, tab_id: Uuid, message: String) {
        if let Some(controller) = self
            .workspace_tabs
            .borrow()
            .get(&tab_id)
            .and_then(|t| t.structure_controller())
        {
            let _ = controller.sender().send(StructureTabInput::LoadFailed(message));
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
                if let WorkspaceTab::Table(slot) = tab
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
        let Some(slot) = tabs.get(&tab_id) else {
            return;
        };
        let (page, schema, table_name, combined_dirty) = match slot {
            WorkspaceTab::Structure(s) => (&s.page, s.schema.as_deref(), s.table.clone(), dirty),
            WorkspaceTab::Table(s) => {
                // Combine with the data-side dirty state — either
                // mode contributing pending changes prefixes the tab
                // with the "•" GNOME convention.
                let data = crate::services::change_tracker::with_tab_ref(s.id, |tr| tr.has_pending()).unwrap_or(false);
                (&s.page, s.schema.as_deref(), s.table.clone(), dirty || data)
            }
            _ => return,
        };
        let base = if table_name.is_empty() {
            crate::tr!("New Table")
        } else {
            super::workspace_tabs::qualified_browse_tab_label(schemas_count, schema, &table_name)
        };
        let title = if combined_dirty { format!("• {base}") } else { base };
        page.set_title(&title);
        let is_selected = self
            .workspace_tab_view
            .as_ref()
            .and_then(|tv| tv.selected_page())
            .map(|p| &p == page)
            .unwrap_or(false);
        page.set_needs_attention(combined_dirty && !is_selected);
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
        let tabs = self.workspace_tabs.borrow();
        let slot = tabs.get(&id)?;
        // For Table tabs, only count as "structure tab" when the
        // user is actually viewing the Structure axis — Ctrl+Z on a
        // Data-mode tab should hit the data-side undo, not DDL undo.
        match slot {
            WorkspaceTab::Structure(_) => Some(id),
            WorkspaceTab::Table(s) if s.mode == super::TableMode::Structure => Some(id),
            _ => None,
        }
    }
}

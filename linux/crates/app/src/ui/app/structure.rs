//! App-side handlers for the Structure (DDL) workspace tab.
//!
//! Each `on_*` method mirrors the equivalent Browse-tab path in
//! `browse.rs` / `row_ops.rs`: dispatch by tab id, take a slot
//! reference, run the work through the session on the app runtime,
//! route results back through `AppMsg::Structure*Loaded` /
//! `Structure*Completed` variants. Window-close is gated by the shared
//! `in_flight_saves` counter so a Structure DDL write can't commit
//! after the window has been torn down.

use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::{ComponentController, ComponentSender, adw};
use uuid::Uuid;

use tablepro_core::ddl::TableDefinition;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{ObjectInfo, ObjectScope, TableRef};
use tablepro_core::sql_ddl::{BuildDdlError, DraftColumn, StructureOp, materialize_ops};
use tablepro_core::statement::{GuardedStatement, StatementBuilder};
use tablepro_core::{ForeignKeyMode, WriteBatch, WriteKind, WriteReport};
use tablepro_session::runtime::TaskFailure;
use tablepro_session::{OperationError, OperationKind, Session};

use crate::services::structure_tracker;
use crate::ui::app::{App, AppMsg, WorkspaceTab};
use crate::ui::error_text;
use crate::ui::structure_tab::{StructureMode, StructureTabInput};

impl App {
    /// Sidebar right-click → "New Table…" or schema-header "+" button.
    pub(super) fn on_new_table_tab(&mut self, schema: Option<String>, sender: ComponentSender<Self>) {
        if !self.connected {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        }
        self.append_new_structure_tab(schema, sender);
        // A draft has no table to read the dialect back with, so the
        // session's current one is handed over for its SQL preview.
        let dialect = self.context.active.get().and_then(|session| session.current_dialect());
        if let (Some(tab_id), Some(dialect)) = (self.selected_workspace_tab_id(), dialect)
            && let Some(controller) = self
                .workspace_tabs
                .borrow()
                .get(&tab_id)
                .and_then(|tab| tab.structure_controller())
        {
            let _ = controller.sender().send(StructureTabInput::DialectReady(dialect));
        }
    }

    /// Sidebar right-click → "Edit Structure". Opens a dedicated
    /// Structure tab (separate AdwTabPage). If one already exists for
    /// this `(schema, table)` it's just re-selected; otherwise a new
    /// `WorkspaceTab::Structure` is appended via
    /// `append_existing_structure_tab`. The Data-side Browse tab (if
    /// any) is independent — both can stay open side by side.
    pub(super) fn on_edit_structure_tab(
        &mut self,
        schema: Option<String>,
        table: String,
        sender: ComponentSender<Self>,
    ) {
        if !self.connected {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        }
        let existing_structure = self.workspace_tabs.borrow().iter().find_map(|(_, tab)| match tab {
            WorkspaceTab::Structure(slot)
                if slot.mode == StructureMode::Edit && slot.schema == schema && slot.table == table =>
            {
                Some(slot.page.clone())
            }
            _ => None,
        });
        if let Some(page) = existing_structure
            && let Some(tab_view) = self.workspace_tab_view.as_ref()
        {
            tab_view.set_selected_page(&page);
            return;
        }
        self.append_existing_structure_tab(schema, table, sender);
    }

    /// Right-click → "Drop Table…", or in-tab destructive button.
    pub(super) fn on_drop_table_prompt(
        &mut self,
        schema: Option<String>,
        table: String,
        sender: ComponentSender<Self>,
    ) {
        let title = crate::i18n::gettext_f("Drop {table}?", &[("table", &table)]);
        let body = crate::i18n::gettext(
            "All rows and the table definition will be removed. This can't be undone from inside TablePro.",
        );
        let dialog = adw::AlertDialog::new(Some(&title), Some(&body));
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("drop", &crate::i18n::gettext("Drop"));
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
                self.show_error_alert(&crate::i18n::gettext("Cannot drop table"), &format!("{e}"));
                return;
            }
        };
        let Some(session) = self.context.active.get() else {
            self.show_error_alert(
                &crate::i18n::gettext("Cannot drop table"),
                &crate::i18n::gettext("No active connection."),
            );
            return;
        };
        let batch = schema_write(TableRef::new(schema.clone(), table.clone()), &[sql]);
        crate::runtime::spawn_and_deliver(&self.context.tasks, run_schema_write(session, batch), move |result| {
            match settled(result) {
                Ok(_) => sender.input(AppMsg::DropTableSucceeded { schema, table }),
                Err(error) => sender.input(AppMsg::ShowAlert {
                    title: crate::i18n::gettext("Drop failed"),
                    body: error_text::operation_error_message(&error),
                }),
            }
        });
    }

    /// Targeted save: commit a specific Structure tab's pending DDL
    /// without requiring it to be the active tab. Used by the
    /// close-with-pending dialog's "Save" branch — the user might be
    /// closing a background tab via its X button.
    pub(super) fn save_structure_tab_by_id(&mut self, tab_id: Uuid, sender: ComponentSender<Self>) {
        // If a save is already in flight for this tab, do nothing —
        // calling `on_execute_structure_transaction` would silently
        // early-return on the duplicate insert, never firing a
        // completion. The in-flight save's `on_structure_save_completed`
        // (or _failed) drains `close_after_save` for `tab_id`, so the
        // close-with-pending flow still resolves through that path.
        if self.structure_saves_in_flight.borrow().contains(&tab_id) {
            tracing::debug!(
                ?tab_id,
                "save_structure_tab_by_id: save already in flight; deferring to first dispatch"
            );
            return;
        }
        let Some(dialect) = self.context.active.get().and_then(|session| session.current_dialect()) else {
            sender.input(AppMsg::StructureSaveFailed(
                tab_id,
                crate::i18n::gettext("No active connection."),
            ));
            return;
        };
        let driver_id = self.driver_id().to_string();
        let result = structure_tracker::with_tab_ref(tab_id, |t| t.materialize(&driver_id, &*dialect));
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

    /// Structure tab Save → run the ordered DDL as one schema write.
    /// The driver decides how it is wrapped: a transaction where the
    /// engine's DDL is transactional, statement by statement where it
    /// is not, and the error says which of the two the user got.
    pub(super) fn on_execute_structure_transaction(
        &mut self,
        tab_id: Uuid,
        statements: Vec<String>,
        sender: ComponentSender<Self>,
    ) {
        // Reject re-entry: a second Ctrl+S (or rapid double-click on
        // Save) while the first DDL write is still mid-flight would
        // dispatch a parallel write and potentially commit the same
        // statements twice. Mark the tab and bail.
        if !self.structure_saves_in_flight.borrow_mut().insert(tab_id) {
            tracing::debug!(?tab_id, "structure save already in flight; ignoring duplicate");
            return;
        }
        let Some(session) = self.context.active.get() else {
            self.structure_saves_in_flight.borrow_mut().remove(&tab_id);
            sender.input(AppMsg::StructureSaveFailed(
                tab_id,
                crate::i18n::gettext("No active connection."),
            ));
            return;
        };
        let (mode, schema, slot_table) = {
            let tabs = self.workspace_tabs.borrow();
            match tabs.get(&tab_id) {
                Some(WorkspaceTab::Structure(s)) => (s.mode, s.schema.clone(), s.table.clone()),
                // Only a Structure tab hosts the DDL editor, so a save
                // for any other id is a stale queued message.
                _ => {
                    self.structure_saves_in_flight.borrow_mut().remove(&tab_id);
                    return;
                }
            }
        };
        let ops = structure_tracker::with_tab_ref(tab_id, |t| t.ops().to_vec()).unwrap_or_default();
        let new_table_name = saved_table_name(mode, &ops);
        // The batch names the table as it is before the write: a new
        // table by the name it is being created under.
        let batch_table = match mode {
            StructureMode::New => new_table_name.clone().unwrap_or_default(),
            StructureMode::Edit => slot_table,
        };
        let batch = schema_write(TableRef::new(schema, batch_table), &statements);

        self.in_flight_saves.set(self.in_flight_saves.get() + 1);
        // Structure edits change the database too, so the history
        // shows the DDL that did it and not only editor statements.
        let ran = super::ran_statements::RanStatements::starting(
            self.history.store(),
            self.context.active.metadata(),
            statements,
        );
        let work = async move {
            let result = run_schema_write(session, batch).await;
            let outcome = match &result {
                Ok(_) => tablepro_storage::query_history::Outcome::Success,
                Err(error) => {
                    tablepro_storage::query_history::Outcome::Error(error_text::operation_error_message(error))
                }
            };
            ran.finished(None, outcome).await;
            result
        };
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| match settled(result) {
            Ok(_) => sender.input(AppMsg::StructureSaveCompleted { tab_id, new_table_name }),
            Err(error) => sender.input(AppMsg::StructureSaveFailed(
                tab_id,
                error_text::operation_error_message(&error),
            )),
        });
    }

    /// Save resolved successfully. Two cases:
    ///
    /// 1. **New-Table draft**: CreateTable succeeded so the table now
    ///    exists. Close the draft and open a Browse tab on the new
    ///    table.
    /// 2. **Edit-mode tab**: the slot stays put, taking the new name
    ///    when the save renamed the table; `SaveCompleted` makes the
    ///    tab clear its pending ops and read the table again.
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
        let kind = {
            let mut tabs = self.workspace_tabs.borrow_mut();
            match tabs.get_mut(&tab_id) {
                Some(WorkspaceTab::Structure(slot)) => match (slot.mode, new_table_name.clone()) {
                    (StructureMode::New, Some(name)) => SaveKind::PromoteNewToTable(slot.schema.clone(), name),
                    (StructureMode::New, None) => SaveKind::Skip,
                    (StructureMode::Edit, renamed) => {
                        // The refetch that follows reads the table by
                        // the slot's name, which a rename just changed.
                        if let Some(name) = renamed {
                            slot.table = name;
                        }
                        SaveKind::UpdateInPlace(slot.schema.clone(), slot.table.clone())
                    }
                },
                _ => SaveKind::Skip,
            }
        };

        let kind_promoted = matches!(kind, SaveKind::PromoteNewToTable(..));
        match kind {
            SaveKind::PromoteNewToTable(schema, name) => {
                if let Some(tab_view) = self.workspace_tab_view.clone() {
                    self.finish_close_workspace_tab(tab_id, &tab_view);
                }
                // After the CREATE TABLE lands, drop the user into a
                // Browse tab on the freshly-created table — they just
                // designed it, so showing Data (empty grid) is the
                // natural next step. If they want to keep editing the
                // schema, sidebar right-click → "Edit Structure"
                // reopens a Structure tab.
                super::App::append_table_tab(
                    self,
                    schema.clone(),
                    name.clone(),
                    0,
                    u64::from(self.settings.default_page_size()),
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

        // A close-with-pending dialog that picked "Save" put this tab
        // in close_after_save and waits for the save to drain it. A
        // promoted draft is already closed, so only a tab that is still
        // open is closed here; the window-close check runs either way
        // because the counter entry was consumed.
        let drained = super::dec_close_after_save(&mut self.close_after_save.borrow_mut(), &tab_id);
        if drained && !kind_promoted {
            sender.input(AppMsg::WorkspaceTabClosed(tab_id));
        }
        if self.close_window_after_save.get() && self.close_after_save.borrow().is_empty() {
            self.close_window_after_save.set(false);
            self.window.close();
        }
    }

    pub(super) fn on_structure_save_failed(&mut self, tab_id: Uuid, message: String) {
        if self.in_flight_saves.get() > 0 {
            self.in_flight_saves.set(self.in_flight_saves.get() - 1);
        }
        self.structure_saves_in_flight.borrow_mut().remove(&tab_id);
        // Match the Browse-side `SaveFailedForTab` handler: a save
        // that started from the close-with-pending dialog left this
        // tab in `close_after_save`, and the window-close-after-save
        // intent in `close_window_after_save`. Both must be cleared
        // on failure or the next unrelated SaveCompleted on another
        // tab will spuriously close the window.
        self.close_after_save.borrow_mut().remove(&tab_id);
        self.close_window_after_save.set(false);
        if let Some(controller) = self
            .workspace_tabs
            .borrow()
            .get(&tab_id)
            .and_then(|t| t.structure_controller())
        {
            let _ = controller.sender().send(StructureTabInput::SaveFailed(message));
        }
    }

    /// Sidebar "Show CREATE TABLE": synthesise the canonical CREATE
    /// statement for an existing table from its definition, through the
    /// same `materialize_ops` the Structure tab saves with. The result
    /// lands in a fresh editor tab; no Structure tab is touched.
    pub(super) fn on_show_create_table(&self, schema: Option<String>, table: String, sender: ComponentSender<Self>) {
        let Some(session) = self.context.active.get() else {
            self.show_toast(&crate::i18n::gettext("No active connection."));
            return;
        };
        let driver_id = self.driver_id().to_string();
        let work = read_definition(session, TableRef::new(schema, table.clone()));
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| {
            let message = match settled(result) {
                Ok((definition, dialect)) => match create_table_sql(&definition, &driver_id, &*dialect) {
                    Ok(Some(sql)) => {
                        sender.input(AppMsg::ShowCreateTableLoaded { sql });
                        return;
                    }
                    Ok(None) => crate::i18n::gettext_f("Table {table} has no columns.", &[("table", &table)]),
                    Err(error) => {
                        crate::i18n::gettext_f("Couldn't build SQL: {error}", &[("error", &error.to_string())])
                    }
                },
                Err(error) => crate::i18n::gettext_f(
                    "Couldn't read the table: {error}",
                    &[("error", &error_text::operation_error_message(&error))],
                ),
            };
            sender.input(AppMsg::ShowToast(message));
        });
    }

    /// Edit-mode init asks for introspection. The definition comes back
    /// in one read, so the tab rebuilds its UI once with columns,
    /// indexes and foreign keys from the same moment.
    pub(super) fn on_fetch_structure_data(&self, tab_id: Uuid, sender: ComponentSender<Self>) {
        let table = {
            let tabs = self.workspace_tabs.borrow();
            let Some(slot) = tabs.get(&tab_id) else {
                return;
            };
            let Some((schema, table)) = slot.schema_table() else {
                return;
            };
            TableRef::new(schema.map(str::to_owned), table)
        };
        let Some(session) = self.context.active.get() else {
            sender.input(AppMsg::StructureLoadFailed {
                tab_id,
                message: crate::i18n::gettext("No active connection."),
            });
            return;
        };
        crate::runtime::spawn_and_deliver(&self.context.tasks, read_definition(session, table), move |result| {
            match settled(result) {
                Ok((definition, dialect)) => sender.input(AppMsg::StructureDataLoaded {
                    tab_id,
                    definition: Box::new(definition),
                    dialect,
                }),
                Err(error) => sender.input(AppMsg::StructureLoadFailed {
                    tab_id,
                    message: error_text::operation_error_message(&error),
                }),
            }
        });
    }

    pub(super) fn on_structure_data_loaded(
        &self,
        tab_id: Uuid,
        definition: TableDefinition,
        dialect: Arc<dyn SqlDialect>,
    ) {
        if let Some(controller) = self
            .workspace_tabs
            .borrow()
            .get(&tab_id)
            .and_then(|t| t.structure_controller())
        {
            let _ = controller.sender().send(StructureTabInput::StructureLoaded {
                definition: Box::new(definition),
                dialect,
            });
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
        // Sidebar refresh: re-list the objects and rebuild the factory.
        let Some(session) = self.context.active.get() else {
            return;
        };
        let work = async move {
            session
                .run(OperationKind::Metadata, |lease, options| async move {
                    Ok(lease.list_objects(&ObjectScope::DefaultSchema, options).await?)
                })
                .await
        };
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| match settled(result) {
            Ok(objects) => sender.input(AppMsg::TablesReloaded(objects)),
            // The sidebar keeps the list it has rather than going empty.
            Err(error) => tracing::warn!(%error, "could not reload the table list"),
        });
    }

    pub(super) fn on_tables_reloaded(&mut self, objects: Vec<ObjectInfo>) {
        self.repopulate_sidebar(&objects);
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
            crate::i18n::gettext("New Table")
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
}

/// The table name a save leaves the tab on, when it is not the one the
/// tab already shows: the created table for a draft, the new name for
/// a rename.
fn saved_table_name(mode: StructureMode, ops: &[StructureOp]) -> Option<String> {
    ops.iter().find_map(|op| match (mode, op) {
        (StructureMode::New, StructureOp::CreateTable { table, .. }) => Some(table.clone()),
        (StructureMode::Edit, StructureOp::RenameTable { new_name, .. }) => Some(new_name.clone()),
        _ => None,
    })
}

/// DDL as one schema write. Each statement is the builder's own text
/// with nothing bound, and none of them has a row count to prove.
fn schema_write(table: TableRef, statements: &[String]) -> WriteBatch {
    let steps = statements
        .iter()
        .map(|sql| {
            let mut builder = StatementBuilder::new();
            builder.push_sql(sql);
            GuardedStatement::unguarded(builder.finish())
        })
        .collect();
    WriteBatch::new(WriteKind::SchemaChanges, table, steps, ForeignKeyMode::Enforced)
}

async fn run_schema_write(session: Arc<Session>, batch: WriteBatch) -> Result<WriteReport, OperationError> {
    session
        .run(OperationKind::Save(WriteKind::SchemaChanges), move |lease, options| {
            let batch = batch.clone();
            async move { Ok(lease.write_batch(&batch, options).await?) }
        })
        .await
}

/// The table's definition and the dialect of the connection that read
/// it, so the DDL built from it is spelled for that same server.
async fn read_definition(
    session: Arc<Session>,
    table: TableRef,
) -> Result<(TableDefinition, Arc<dyn SqlDialect>), OperationError> {
    session
        .run(OperationKind::Metadata, move |lease, options| {
            let table = table.clone();
            async move {
                let definition = lease.fetch_table_definition(&table, options).await?;
                Ok((definition, lease.dialect()))
            }
        })
        .await
}

/// The CREATE statements for a table as it is defined now, joined so
/// the editor shows each on its own. `None` for a table with no
/// columns, which has nothing to create.
fn create_table_sql(
    definition: &TableDefinition,
    driver_id: &str,
    dialect: &dyn SqlDialect,
) -> Result<Option<String>, BuildDdlError> {
    if definition.columns.is_empty() {
        return Ok(None);
    }
    let op = StructureOp::CreateTable {
        schema: definition.table.schema.clone(),
        table: definition.table.name.clone(),
        columns: definition
            .columns
            .iter()
            .cloned()
            .map(DraftColumn::from_definition)
            .collect(),
        indexes: definition.indexes.clone(),
        fks: definition.foreign_keys.clone(),
    };
    let statements = materialize_ops(&[op], driver_id, dialect)?;
    Ok((!statements.is_empty()).then(|| statements.join(";\n\n") + ";"))
}

/// A task that never answered is reported like the operation it ran: a
/// panic as the bug it is, an abort as the app stopping the work.
fn settled<T>(result: Result<Result<T, OperationError>, TaskFailure>) -> Result<T, OperationError> {
    result.unwrap_or_else(|failure| {
        Err(match failure {
            TaskFailure::Panicked(panic) => {
                tracing::error!(%panic, "a structure task panicked");
                OperationError::Panicked(panic)
            }
            TaskFailure::Aborted => OperationError::Cancelled,
        })
    })
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{
        CatalogType, ColumnDefault, ColumnKind, ColumnType, ReadForm, SqlTypeExpr, TextLength,
    };
    use tablepro_core::ddl::{ColumnAttributes, ColumnDefinition};
    use tablepro_core::{ColumnInfo, ForeignKeyInfo};

    use super::*;

    fn draft(name: &str) -> DraftColumn {
        DraftColumn {
            original: None,
            name: name.to_owned(),
            data_type: "text".to_owned(),
            nullable: true,
            primary_key: false,
            auto_increment: false,
            default_value: None,
            comment: None,
        }
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "a test stands in for the catalogue a driver would read"
    )]
    fn text_column(name: &str) -> ColumnDefinition {
        ColumnDefinition::new(
            ColumnInfo {
                name: name.to_owned(),
                column_type: ColumnType {
                    name: "text".to_owned(),
                    kind: ColumnKind::Text {
                        length: TextLength::Unbounded,
                    },
                    catalog: Some(CatalogType {
                        declaration: SqlTypeExpr::from_catalog_text("text"),
                        cast_target: SqlTypeExpr::from_catalog_text("text"),
                    }),
                    dynamic_storage: false,
                    read_form: ReadForm::Native,
                },
                nullable: false,
                primary_key: true,
                is_auto_increment: false,
                is_generated: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes::default(),
        )
    }

    fn definition(columns: Vec<ColumnDefinition>) -> TableDefinition {
        TableDefinition {
            table: TableRef::new(Some("public".to_owned()), "users"),
            columns,
            primary_key: None,
            indexes: Vec::new(),
            foreign_keys: Vec::<ForeignKeyInfo>::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
        }
    }

    #[test]
    fn a_draft_saves_under_the_name_it_creates() {
        let ops = [StructureOp::CreateTable {
            schema: None,
            table: "orders".to_owned(),
            columns: vec![draft("id")],
            indexes: Vec::new(),
            fks: Vec::new(),
        }];

        assert_eq!(saved_table_name(StructureMode::New, &ops).as_deref(), Some("orders"));
        assert_eq!(saved_table_name(StructureMode::Edit, &ops), None);
    }

    #[test]
    fn an_edit_that_renames_the_table_moves_the_tab_to_the_new_name() {
        let ops = [
            StructureOp::RenameTable {
                schema: None,
                old_name: "users".to_owned(),
                new_name: "accounts".to_owned(),
            },
            StructureOp::AddColumn {
                schema: None,
                table: "accounts".to_owned(),
                column: draft("email"),
            },
        ];

        assert_eq!(saved_table_name(StructureMode::Edit, &ops).as_deref(), Some("accounts"));
        assert_eq!(saved_table_name(StructureMode::Edit, &ops[1..]), None);
    }

    #[test]
    fn a_schema_write_carries_each_statement_unguarded_and_unbound() {
        let table = TableRef::new(None, "users");
        let statements = [
            "ALTER TABLE users ADD COLUMN a text".to_owned(),
            "DROP INDEX i".to_owned(),
        ];

        let batch = schema_write(table.clone(), &statements);

        assert_eq!(batch.kind, WriteKind::SchemaChanges);
        assert_eq!(batch.table, table);
        assert!(batch.foreign_keys.is_enforced());
        let sql: Vec<&str> = batch.steps.iter().map(|step| step.statement.sql()).collect();
        assert_eq!(sql, ["ALTER TABLE users ADD COLUMN a text", "DROP INDEX i"]);
        assert!(batch.steps.iter().all(|step| step.statement.params().is_empty()));
    }

    #[test]
    fn create_table_sql_restates_the_definition() {
        let dialect = tablepro_core::dialect::dialect_for("postgres");

        let sql = create_table_sql(&definition(vec![text_column("id")]), "postgres", dialect)
            .expect("the SQL builds")
            .expect("a table with columns");

        assert!(sql.starts_with("CREATE TABLE"), "{sql}");
        assert!(sql.contains("\"users\""), "{sql}");
        assert!(sql.ends_with(';'), "{sql}");
    }

    #[test]
    fn a_table_without_columns_has_nothing_to_create() {
        let dialect = tablepro_core::dialect::dialect_for("postgres");

        assert!(matches!(
            create_table_sql(&definition(Vec::new()), "postgres", dialect),
            Ok(None)
        ));
    }

    #[test]
    fn an_aborted_task_reads_as_cancelled() {
        let aborted: Result<Result<(), OperationError>, TaskFailure> = Err(TaskFailure::Aborted);

        assert_eq!(settled(aborted), Err(OperationError::Cancelled));
        assert_eq!(settled(Ok(Ok(5))), Ok(5));
    }
}

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
use relm4::{ComponentSender, adw};
use uuid::Uuid;

use tablepro_core::ddl::{BuildDdlError, DdlDialect, DdlOperation, DdlPlan, DropTableOptions, TableDefinition};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_core::statement::SqlBuildError;
use tablepro_core::{WriteKind, WriteReport};
use tablepro_session::runtime::TaskFailure;
use tablepro_session::{OperationError, OperationKind, Session};

use crate::services::from_session::FromSession;
use crate::services::pending_structure::PendingStructure;
use crate::ui::app::{App, AppMsg, WorkspaceTab};
use crate::ui::error_text;
use crate::ui::structure_tab::{StructureMode, StructureTabInput, save_blocker_text};

impl App {
    /// Sidebar right-click → "New Table…" or schema-header "+" button.
    pub(super) fn on_new_table_tab(&mut self, schema: Option<String>, sender: ComponentSender<Self>) {
        if !self.connected {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        }
        let creates_tables = self
            .context
            .active
            .get()
            .and_then(|session| session.current_dialect())
            .and_then(|dialect| dialect.ddl().map(|ddl| ddl.capabilities().create_table))
            .unwrap_or(false);
        if !creates_tables {
            self.show_toast(&crate::i18n::gettext(
                "Tables on this database are created in the SQL editor.",
            ));
            return;
        }
        self.append_new_structure_tab(schema, sender);
    }

    /// Select the table's Structure tab, or open one. Its Table tab
    /// stays open beside it.
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
        let Some(session) = self.context.active.get() else {
            self.show_error_alert(
                &crate::i18n::gettext("Cannot drop table"),
                &crate::i18n::gettext("No active connection."),
            );
            return;
        };
        let dropped = TableRef::new(schema, table);
        let options = DropTableOptions {
            if_exists: true,
            cascade: false,
        };
        let origin = Arc::downgrade(&session);
        let work = run_schema_plan(session, dropped.clone(), DdlOperation::DropTable, move |ddl, table| {
            ddl.plan_drop_table(table, options)
        });
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| {
            match settled(result).and_then(|(_, written)| written) {
                Ok(_) => sender.input(AppMsg::DropTableSucceeded(FromSession::new(origin, dropped))),
                Err(error) => sender.input(AppMsg::ShowAlert {
                    title: crate::i18n::gettext("Drop failed"),
                    body: error_text::operation_error_message(&error),
                }),
            }
        });
    }

    /// Save one Structure tab, whether or not it is the active tab: what
    /// its tracker holds, planned with the connection that runs it.
    pub(super) fn save_structure_tab_by_id(&mut self, tab_id: Uuid, sender: ComponentSender<Self>) {
        // The save in flight settles `close_after_save` for this tab;
        // a second one would return without ever completing.
        if self.structure_saves_in_flight.borrow().contains(&tab_id) {
            tracing::debug!(
                ?tab_id,
                "save_structure_tab_by_id: save already in flight; deferring to first dispatch"
            );
            return;
        }
        let Some(tracker) = self.structure_trackers.get(tab_id) else {
            return;
        };
        match tracker.begin_save().map(|pending| (pending.check(), pending)) {
            Some((Ok(()), pending)) => self.run_structure_save(tab_id, pending, sender),
            Some((Err(blocker), _)) => self.refuse_structure_save(tab_id, save_blocker_text(&blocker)),
            // Nothing to save, so a close waiting on this save can go
            // ahead.
            None => sender.input(AppMsg::StructureSaveCompleted {
                tab_id,
                new_table_name: None,
            }),
        }
    }

    pub(super) fn on_drop_table_succeeded(&mut self, table: TableRef, sender: ComponentSender<Self>) {
        self.close_tabs_for_table(table.schema.as_deref(), &table.name);
        sender.input(AppMsg::SchemaChanged {
            schema: table.schema,
            table: Some(table.name),
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

    /// Run a structure save as one schema write. The driver decides how
    /// it is wrapped: a transaction where the engine's DDL is
    /// transactional, statement by statement where it is not, and the
    /// error says which of the two the user got.
    fn run_structure_save(&mut self, tab_id: Uuid, pending: PendingStructure, sender: ComponentSender<Self>) {
        // A second Ctrl+S, or a quick double-click on Save, while the
        // first write is still running would commit the same statements
        // twice.
        if !self.structure_saves_in_flight.borrow_mut().insert(tab_id) {
            tracing::debug!(?tab_id, "structure save already in flight; ignoring duplicate");
            return;
        }
        let Some(session) = self.context.active.get() else {
            self.refuse_structure_save(tab_id, crate::i18n::gettext("No active connection."));
            return;
        };
        // Only a Structure tab hosts the DDL editor, so a save for any
        // other id is a stale queued message.
        if !matches!(
            self.workspace_tabs.borrow().get(&tab_id),
            Some(WorkspaceTab::Structure(_))
        ) {
            self.structure_saves_in_flight.borrow_mut().remove(&tab_id);
            return;
        }
        let new_table_name = pending.saved_table_name();

        self.in_flight_saves.set(self.in_flight_saves.get() + 1);
        let history = self.history.store();
        let metadata = self.context.active.metadata();
        let work = async move {
            let table = pending.table();
            let operation = pending.operation();
            let (statements, written) =
                run_schema_plan(session, table, operation, move |ddl, _| pending.plan(ddl)).await?;
            // Structure edits change the database too, so the history
            // shows the DDL that did it and not only editor statements.
            let ran = super::ran_statements::RanStatements::starting(history, metadata, statements);
            let outcome = match &written {
                Ok(_) => tablepro_storage::query_history::Outcome::Success,
                Err(error) => {
                    tablepro_storage::query_history::Outcome::Error(error_text::operation_error_message(error))
                }
            };
            ran.finished(None, outcome).await;
            written
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

        // Decided first, so the tabs are not borrowed while they change.
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
                // A table just designed is filled in next.
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
                self.send_to_structure_tab(tab_id, StructureTabInput::SaveCompleted { new_table_name });
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
        self.refuse_structure_save(tab_id, message);
    }

    /// End a save with `message`. A save refused before it ran never
    /// counted itself in `in_flight_saves`, so only a failed run gives
    /// one back, in `on_structure_save_failed`.
    fn refuse_structure_save(&mut self, tab_id: Uuid, message: String) {
        self.structure_saves_in_flight.borrow_mut().remove(&tab_id);
        // Match the Browse-side `SaveFailedForTab` handler: a save
        // that started from the close-with-pending dialog left this
        // tab in `close_after_save`, and the window-close-after-save
        // intent in `close_window_after_save`. Both must be cleared
        // on failure or the next unrelated SaveCompleted on another
        // tab will spuriously close the window.
        self.close_after_save.borrow_mut().remove(&tab_id);
        self.close_window_after_save.set(false);
        self.send_to_structure_tab(tab_id, StructureTabInput::SaveFailed(message));
    }

    /// Sidebar "Show CREATE TABLE": the statements that recreate the
    /// table as it is defined now, from the dialect's
    /// `create_table_script`. The result lands in a fresh editor tab; no
    /// Structure tab is touched.
    pub(super) fn on_show_create_table(&self, schema: Option<String>, table: String, sender: ComponentSender<Self>) {
        let Some(session) = self.context.active.get() else {
            self.show_toast(&crate::i18n::gettext("No active connection."));
            return;
        };
        let origin = Arc::downgrade(&session);
        let work = read_definition(session, TableRef::new(schema, table.clone()));
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| {
            let message = match settled(result) {
                Ok((definition, dialect)) => match create_table_sql(&definition, &*dialect) {
                    Ok(Some(sql)) => {
                        sender.input(AppMsg::ShowCreateTableLoaded(FromSession::new(origin, sql)));
                        return;
                    }
                    Ok(None) => crate::i18n::gettext_f("Table {table} has no columns.", &[("table", &table)]),
                    Err(error) => crate::i18n::gettext_f(
                        "Couldn't build SQL: {error}",
                        &[("error", &crate::ui::structure_tab::build_error_text(&error))],
                    ),
                },
                Err(error) => crate::i18n::gettext_f(
                    "Couldn't read the table: {error}",
                    &[("error", &error_text::operation_error_message(&error))],
                ),
            };
            sender.input(AppMsg::ShowToast(message));
        });
    }

    fn send_to_structure_tab(&self, tab_id: Uuid, msg: StructureTabInput) {
        let structure = self
            .workspace_tabs
            .borrow()
            .get(&tab_id)
            .and_then(|tab| tab.structure_tab())
            .cloned();
        if let Some(structure) = structure {
            structure.send(msg);
        }
    }

    /// The schema changed under the window. The catalog forgets the
    /// table's columns and reads the sidebar's list again, and every tab
    /// open on the table reads it again through its own requests, which
    /// share the catalog's one column fetch.
    pub(super) fn on_schema_changed(&self, schema: Option<String>, table: Option<String>) {
        let Some(session) = self.context.active.get() else {
            return;
        };
        if let Some(table) = table {
            session.invalidate_table(&TableRef::new(schema.clone(), table.clone()));
            let (browse_tabs, structure_tabs): (Vec<_>, Vec<_>) = self
                .workspace_tabs
                .borrow()
                .values()
                .filter_map(|tab| match tab {
                    WorkspaceTab::Table(slot) if slot.schema == schema && slot.table == table => {
                        Some((Some(slot.browse.clone()), None))
                    }
                    WorkspaceTab::Structure(slot) if slot.schema == schema && slot.table == table => {
                        Some((None, Some(slot.structure.clone())))
                    }
                    _ => None,
                })
                .unzip();
            for browse in browse_tabs.into_iter().flatten() {
                browse.send(crate::ui::browse_tab::BrowseTabInput::SchemaChanged);
            }
            for structure in structure_tabs.into_iter().flatten() {
                structure.send(StructureTabInput::SchemaChanged);
            }
        }
        // The catalog watch takes the new list to the sidebar, and logs
        // the error of one that could not be read.
        self.context.tasks.spawn_task(async move {
            let _ = session.refresh_objects(ObjectScope::DefaultSchema).await;
        });
    }

    /// The sidebar follows the session's object list. A failed refresh
    /// keeps it as it was.
    pub(super) fn on_catalog_changed(&mut self, snapshot: &tablepro_session::ObjectListSnapshot) {
        self.show_objects(&snapshot.objects);
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
                let data = self
                    .change_trackers
                    .get(s.id)
                    .is_some_and(|tracker| tracker.pending_count() > 0);
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

/// Plan a schema change with the dialect of the connection that runs
/// it, and run the plan as one write. The statements come back whether
/// or not the write went through, for the history. `operation` is what
/// a connection with no DDL dialect refuses.
async fn run_schema_plan<P>(
    session: Arc<Session>,
    table: TableRef,
    operation: DdlOperation,
    plan: P,
) -> Result<(Vec<String>, Result<WriteReport, OperationError>), OperationError>
where
    P: Fn(&dyn DdlDialect, &TableRef) -> Result<DdlPlan, BuildDdlError> + Send + Sync,
{
    session
        .run(OperationKind::Save(WriteKind::SchemaChanges), move |lease, options| {
            let table = table.clone();
            let dialect = lease.dialect();
            let planned = match dialect.ddl() {
                Some(ddl) => plan(ddl, &table).map_err(SqlBuildError::from),
                None => Err(SqlBuildError::from(BuildDdlError::Unsupported(operation))),
            };
            async move {
                let plan = planned?;
                let statements: Vec<String> = plan.sql().into_iter().map(str::to_owned).collect();
                let written = lease.write_batch(&plan.into_write_batch(table), options).await;
                Ok((statements, written.map_err(OperationError::from)))
            }
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
fn create_table_sql(definition: &TableDefinition, dialect: &dyn SqlDialect) -> Result<Option<String>, BuildDdlError> {
    if definition.columns.is_empty() {
        return Ok(None);
    }
    let ddl = dialect
        .ddl()
        .ok_or(BuildDdlError::Unsupported(DdlOperation::CreateTable))?;
    let script = ddl.create_table_script(definition)?;
    Ok((!script.is_empty()).then(|| script.preview()))
}

/// A task that never answered is reported like the operation it ran: a
/// panic as the bug it is, an abort as the app stopping the work.
fn settled<T>(result: Result<Result<T, OperationError>, TaskFailure>) -> Result<T, OperationError> {
    result.unwrap_or_else(|failure| {
        if failure.is_panic() {
            tracing::error!(%failure, "a structure task panicked");
        }
        Err(failure.into())
    })
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{
        CatalogType, ColumnDefault, ColumnKind, ColumnType, ReadForm, SqlTypeExpr, TextLength,
    };
    use tablepro_core::ddl::{ColumnAttributes, ColumnDefinition, TableSource};
    use tablepro_core::{ColumnInfo, ForeignKeyInfo};

    use super::*;

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

    fn postgres_dialect() -> drivers_postgres::PgDialect {
        drivers_postgres::PgDialect::new(&tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0))
    }

    #[test]
    fn create_table_sql_restates_the_definition() {
        let dialect = postgres_dialect();

        let sql = create_table_sql(&definition(vec![text_column("id")]), &dialect)
            .expect("the SQL builds")
            .expect("a table with columns");

        assert!(sql.starts_with("CREATE TABLE \"public\".\"users\""), "{sql}");
        assert!(sql.ends_with(';'), "{sql}");
    }

    #[test]
    fn create_table_sql_is_the_servers_own_text_where_it_keeps_one() {
        let dialect = drivers_mysql::MySqlDialect::new(
            drivers_mysql::MySqlFlavour::MySql,
            &tablepro_core::ServerInfo::new("MySQL", "8.4.3", 8, 4, 3),
        );
        let mut table = definition(vec![text_column("id")]);
        table.source = Some(TableSource {
            create_statement: "CREATE TABLE `users` (`id` text) ENGINE=InnoDB".to_owned(),
            dependents: Vec::new(),
        });

        assert_eq!(
            create_table_sql(&table, &dialect),
            Ok(Some("CREATE TABLE `users` (`id` text) ENGINE=InnoDB;".to_owned()))
        );
    }

    #[test]
    fn a_table_without_columns_has_nothing_to_create() {
        let dialect = postgres_dialect();

        assert!(matches!(create_table_sql(&definition(Vec::new()), &dialect), Ok(None)));
    }

    #[test]
    fn an_aborted_task_reads_as_cancelled() {
        let aborted: Result<Result<(), OperationError>, TaskFailure> = Err(TaskFailure::Aborted);

        assert_eq!(settled(aborted), Err(OperationError::Cancelled));
        assert_eq!(settled(Ok(Ok(5))), Ok(5));
    }
}

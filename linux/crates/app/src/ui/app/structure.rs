//! App-side handlers for the Structure (DDL) workspace tab: opening
//! one, dropping a table, and following a save that landed. The save
//! itself runs through the workspace handle, like a row save.

use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::{ComponentSender, adw};
use uuid::Uuid;

use tablepro_core::ddl::{BuildDdlError, DdlOperation, DropTableOptions, TableDefinition};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_session::runtime::TaskFailure;
use tablepro_session::{OperationError, OperationKind, Session};
use tokio_util::sync::CancellationToken;

use crate::services::from_session::FromSession;
use crate::ui::app::{App, AppMsg, WorkspaceTab};
use crate::ui::error_text;
use crate::ui::structure_tab::{StructureMode, StructureTabInput};
use crate::workspace::run_schema_plan;

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
        let table = dropped.clone();
        let work = async move {
            run_schema_plan(
                session,
                table,
                DdlOperation::DropTable,
                &CancellationToken::new(),
                move |ddl, table| ddl.plan_drop_table(table, options),
            )
            .await
        };
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

    pub(super) fn send_to_structure_tab(&self, tab_id: Uuid, msg: StructureTabInput) {
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

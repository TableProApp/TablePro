//! Workspace handlers for the Structure (DDL) tab: opening
//! one, dropping a table, and following a save that landed. The save
//! itself runs through the workspace handle, like a row save.

use std::sync::Arc;

use libadwaita as adw;
use libadwaita::prelude::*;
use uuid::Uuid;

use tablepro_core::ddl::{BuildDdlError, DdlOperation, DropTableOptions, InboundForeignKey, TableDefinition};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_core::{DriverError, SafeModeLevel, WriteKind};
use tablepro_session::runtime::TaskFailure;
use tablepro_session::{OperationError, OperationKind, Session};

use crate::runtime::DeliverInput;
use crate::ui::error_text;
use crate::ui::structure_tab::{LoadInput, SaveInput, StructureMode, StructureTabInput};
use crate::ui::workspace::{WorkspaceInput, WorkspaceModel, WorkspaceTab};

use super::structure_target::StructureTarget;
use super::tab_spec::{TabSpec, TablePage};
use crate::workspace::run_schema_plan;

/// The drop the prompt shows is the drop that runs.
const DROP_OPTIONS: DropTableOptions = DropTableOptions {
    if_exists: true,
    cascade: false,
};

impl WorkspaceModel {
    /// Sidebar right-click → "New Table…" or schema-header "+" button.
    pub(super) fn on_new_table_tab(&mut self, schema: Option<String>) {
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
        self.open_tab(TabSpec::Structure {
            target: StructureTarget::NewDraft { schema },
        });
    }

    /// Select the table's Structure tab, or open one. Its Table tab
    /// stays open beside it.
    pub(super) fn on_edit_structure_tab(&mut self, schema: Option<String>, table: String) {
        let existing_structure = self.workspace_tabs.borrow().iter().find_map(|(_, tab)| match tab {
            WorkspaceTab::Structure(slot)
                if slot.mode == StructureMode::Edit && slot.schema == schema && slot.table == table =>
            {
                Some(slot.page.clone())
            }
            _ => None,
        });
        if let Some(page) = existing_structure {
            self.tab_view.set_selected_page(&page);
            return;
        }
        self.open_tab(TabSpec::Structure {
            target: StructureTarget::Existing(TableRef::new(schema, table)),
        });
    }

    /// Right-click → "Drop Table…", or in-tab destructive button. The
    /// table's definition is read first, so a table other tables point
    /// at is refused before the user is asked.
    pub(super) fn on_drop_table_prompt(&mut self, schema: Option<String>, table: String) {
        let table = TableRef::new(schema, table);
        let Some(session) = self.context.active.get() else {
            self.present_drop_prompt(&table);
            return;
        };
        let work = read_definition(session, table.clone());
        let input = self.input.clone();
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| {
            // A definition that cannot be read leaves the refusal to the
            // server, or to the precondition SQLite's plan carries.
            let referencing = match settled(result) {
                Ok((definition, _)) => referencing_keys(&definition),
                Err(error) => {
                    tracing::debug!(%error, "the table's foreign keys could not be read before a drop");
                    Vec::new()
                }
            };
            input.deliver(WorkspaceInput::DropTableChecked { table, referencing });
        });
    }

    pub(super) fn on_drop_table_checked(&mut self, table: TableRef, referencing: &[InboundForeignKey]) {
        if referencing.is_empty() {
            self.present_drop_prompt(&table);
            return;
        }
        self.show_error_alert(
            &crate::i18n::gettext("Cannot Drop Table"),
            &crate::i18n::gettext_f(
                "Foreign keys on other tables point at {table}: {keys}. Drop those foreign keys first.",
                &[
                    ("table", &display_name(&table)),
                    ("keys", &key_list(&table, referencing)),
                ],
            ),
        );
    }

    fn present_drop_prompt(&self, table: &TableRef) {
        let title = crate::i18n::gettext_f("Drop {table}?", &[("table", &display_name(table))]);
        let body = crate::i18n::gettext(
            "All rows and the table definition will be removed. This can't be undone from inside TablePro.",
        );
        let dialog = adw::AlertDialog::new(Some(&title), Some(&body));
        if let Some((connection, sql)) = self.drop_asked_first(table) {
            let asks = crate::ui::write_confirmation::asks_before_writes(&connection);
            dialog.set_body(&format!("{asks}\n{body}"));
            dialog.set_prefer_wide_layout(true);
            dialog.set_extra_child(Some(&crate::ui::review_dialog::sql_view(&sql, &dialog)));
        }
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("drop", &crate::i18n::gettext("Drop"));
        dialog.set_response_appearance("drop", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let input = self.input.clone();
        let table = table.clone();
        dialog.connect_response(None, move |_, response| {
            if response == "drop" {
                input.deliver(WorkspaceInput::DropTableConfirmed {
                    schema: table.schema.clone(),
                    table: table.name.clone(),
                });
            }
        });
        dialog.present(self.dialog_parent().as_ref());
    }

    /// The connection and the DROP it would run, when its Safe Mode asks
    /// before every write and so shows the statement too.
    fn drop_asked_first(&self, table: &TableRef) -> Option<(String, String)> {
        let session = self
            .context
            .active
            .get()
            .filter(|session| session.safe_mode() == SafeModeLevel::ConfirmWrites)?;
        let dialect = session.current_dialect()?;
        let plan = dialect.ddl()?.plan_drop_table(table, DROP_OPTIONS).ok()?;
        Some((session.metadata().name.clone(), plan.preview()))
    }

    /// User confirmed the drop. Run DROP TABLE async; only close any
    /// open Browse / Structure tabs for the table after the DROP
    /// returns Ok. Tabs stay open if DROP fails (FK violation,
    /// privileges) so the user doesn't lose their state on a failed
    /// destructive action.
    ///
    /// The drop runs as a save of its own: a window close waits for it
    /// or stops it, and a quit keeps the process until it answers.
    pub(super) fn on_drop_table_confirmed(&mut self, schema: Option<String>, table: String) {
        let Some(session) = self.context.active.get() else {
            self.show_error_alert(
                &crate::i18n::gettext("Cannot Drop Table"),
                &crate::i18n::gettext("No active connection."),
            );
            return;
        };
        let handle = self.workspace_handle.clone();
        let Some(ticket) = handle
            .ledger()
            .begin(&*self.context.hold, Uuid::new_v4(), WriteKind::SchemaChanges)
        else {
            return;
        };
        let dropped = TableRef::new(schema, table);
        let options = DROP_OPTIONS;
        let table = dropped.clone();
        let cancel = ticket.cancel.clone();
        let work = async move {
            run_schema_plan(session, table, DdlOperation::DropTable, &cancel, move |ddl, table| {
                ddl.plan_drop_table(table, options)
            })
            .await
        };
        // The answer goes through the workspace's input, so one that
        // lands after a disconnect is dropped with the workspace.
        let input = self.input.clone();
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| {
            match settled(result).and_then(|(_, written)| written) {
                Ok(_) => input.deliver(WorkspaceInput::DropTableSucceeded(dropped)),
                // The only guard a drop plan carries is SQLite's count of
                // the keys pointing at the table, which one added since
                // the prompt read them fails.
                Err(OperationError::Driver(DriverError::RowGuardFailed { .. })) => {
                    input.deliver(WorkspaceInput::ShowAlert {
                        title: crate::i18n::gettext("Drop Failed"),
                        body: crate::i18n::gettext_f(
                            "A foreign key on another table points at {table}, so it was not dropped. Drop that foreign key first.",
                            &[("table", &display_name(&dropped))],
                        ),
                    })
                }
                Err(error) => input.deliver(WorkspaceInput::ShowAlert {
                    title: crate::i18n::gettext("Drop Failed"),
                    body: error_text::operation_error_message(&error),
                }),
            }
            handle.ledger().settle(ticket.id);
        });
    }

    pub(super) fn on_drop_table_succeeded(&mut self, table: TableRef) {
        self.close_tabs_for_table(table.schema.as_deref(), &table.name);
        self.input.deliver(WorkspaceInput::SchemaChanged {
            schema: table.schema,
            table: Some(table.name),
        });
    }

    /// Walk the tab map and force-close any Browse / Structure tabs
    /// pointing at `(schema, table)`. Skips the per-tab pending-changes
    /// dialog because the underlying table is gone.
    pub(super) fn close_tabs_for_table(&mut self, schema: Option<&str>, table: &str) {
        let tab_view = self.tab_view.clone();
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
    pub(super) fn on_structure_save_completed(&mut self, tab_id: Uuid, new_table_name: Option<String>) {
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
                let tab_view = self.tab_view.clone();
                self.finish_close_workspace_tab(tab_id, &tab_view);
                // A table just designed is filled in next.
                let page_size = u64::from(self.settings.default_page_size());
                self.open_tab(TabSpec::Table {
                    table: TableRef::new(schema.clone(), name.clone()),
                    page: TablePage::first(page_size),
                    filter: crate::ui::browse_tab::TableFilter::Remembered,
                });
                self.input.deliver(WorkspaceInput::SchemaChanged {
                    schema,
                    table: Some(name),
                });
            }
            SaveKind::UpdateInPlace(schema, table) => {
                if new_table_name.is_some() {
                    self.retitle_tab(tab_id);
                }
                self.send_to_structure_tab(tab_id, SaveInput::SaveCompleted { new_table_name });
                self.input.deliver(WorkspaceInput::SchemaChanged {
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
    /// Structure tab is touched. A failure can carry a long server
    /// error, so it is an alert, which stays until it is read.
    pub(super) fn on_show_create_table(&self, schema: Option<String>, table: String) {
        let title = crate::i18n::gettext("Could Not Show CREATE TABLE");
        let Some(session) = self.context.active.get() else {
            self.show_error_alert(&title, &crate::i18n::gettext("No active connection."));
            return;
        };
        let work = read_definition(session, TableRef::new(schema, table.clone()));
        let input = self.input.clone();
        crate::runtime::spawn_and_deliver(&self.context.tasks, work, move |result| {
            let message = match settled(result) {
                Ok((definition, dialect)) => match create_table_sql(&definition, &*dialect) {
                    Ok(Some(sql)) => {
                        input.deliver(WorkspaceInput::ShowCreateTableLoaded(sql));
                        return;
                    }
                    Ok(None) => crate::i18n::gettext_f("Table {table} has no columns.", &[("table", &table)]),
                    Err(error) => crate::i18n::gettext_f(
                        "Couldn't build SQL: {error}",
                        &[("error", &error_text::build_error_text(&error))],
                    ),
                },
                Err(error) => crate::i18n::gettext_f(
                    "Couldn't read the table: {error}",
                    &[("error", &error_text::operation_error_message(&error))],
                ),
            };
            input.deliver(WorkspaceInput::ShowAlert { title, body: message });
        });
    }

    pub(super) fn send_to_structure_tab(&self, tab_id: Uuid, msg: impl Into<StructureTabInput>) {
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
                browse.send(crate::ui::browse_tab::DataInput::SchemaChanged);
            }
            for structure in structure_tabs.into_iter().flatten() {
                structure.send(LoadInput::SchemaChanged);
            }
        }
        // The catalog watch takes the new list to the sidebar, and a
        // failure to it as a toast. The default schema's list, which the
        // editor's completion reads, follows, one read at a time.
        self.context.tasks.spawn_task(async move {
            let _ = session.refresh_objects(ObjectScope::AllSchemas).await;
            let _ = session.refresh_objects(ObjectScope::DefaultSchema).await;
        });
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

/// The sidebar lists every schema, so two tables can share a name.
fn display_name(table: &TableRef) -> String {
    match &table.schema {
        Some(schema) => format!("{schema}.{}", table.name),
        None => table.name.clone(),
    }
}

/// The keys of other tables that point at the table. A table's key on
/// itself goes with it, so it does not stop a drop.
fn referencing_keys(definition: &TableDefinition) -> Vec<InboundForeignKey> {
    definition
        .inbound_foreign_keys
        .iter()
        .filter(|key| key.table != definition.table)
        .cloned()
        .collect()
}

/// Each key as its table and columns, the table qualified only where it
/// sits in another schema than the dropped one.
fn key_list(dropped: &TableRef, keys: &[InboundForeignKey]) -> String {
    keys.iter()
        .map(|key| {
            let table = match key.table.schema == dropped.schema {
                true => key.table.name.clone(),
                false => display_name(&key.table),
            };
            format!("{table} ({})", key.columns.join(", "))
        })
        .collect::<Vec<_>>()
        .join(", ")
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

    fn postgres_dialect() -> tablepro_driver_postgres::PgDialect {
        tablepro_driver_postgres::PgDialect::new(&tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0))
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
        let dialect = tablepro_driver_mysql::MySqlDialect::new(
            tablepro_driver_mysql::MySqlFlavour::MySql,
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

    #[gtk4::test]
    fn the_drop_prompt_closes_once() {
        use crate::test_support::wait_until;
        use crate::ui::session_window::tests::{TestWindow, WAIT};
        use crate::workspace::{answer, visible_alert};

        let test = TestWindow::connected("DropPromptClosedOnce");
        test.workspace()
            .with_model(|model| model.on_drop_table_prompt(None, "users".to_owned()));
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the drop prompt");

        // With animations off, closing the alert after its click already
        // closed it logs a critical, which this makes abort the test.
        let previous = gtk4::glib::log_set_always_fatal(gtk4::glib::LogLevels::LEVEL_CRITICAL);
        let answered = answer(&test.window, "cancel");
        crate::test_support::drain_main_context();
        gtk4::glib::log_set_always_fatal(previous);

        assert!(answered, "the prompt has no Cancel button");
        assert!(visible_alert(&test.window).is_none(), "the prompt stayed open");
    }

    #[gtk4::test]
    fn the_drop_prompt_names_the_schema() {
        use crate::test_support::wait_until;
        use crate::ui::session_window::tests::{TestWindow, WAIT};
        use crate::workspace::{answer, visible_alert};

        let test = TestWindow::connected("DropPromptNamesSchema");
        test.workspace()
            .with_model(|model| model.on_drop_table_prompt(Some("sales".to_owned()), "orders".to_owned()));
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("the drop prompt");

        let heading = visible_alert(&test.window).and_then(|alert| alert.heading());

        assert_eq!(heading.as_deref(), Some("Drop sales.orders?"));
        assert!(answer(&test.window, "cancel"), "the prompt has no Cancel button");
    }

    /// A server's reason can be longer than a toast's one line.
    #[gtk4::test]
    fn a_create_table_that_cannot_be_read_says_why_in_an_alert() {
        use tablepro_core::DriverError;
        use tablepro_test_support::FakeReply;

        use crate::test_support::wait_until;
        use crate::ui::session_window::tests::{TestWindow, WAIT};
        use crate::workspace::{answer, visible_alert};

        let test = TestWindow::connected_with("ShowCreateFails", |script| {
            script
                .fetch_table_definition
                .always(FakeReply::err(DriverError::server("permission denied for table users")));
        });
        test.workspace()
            .with_model(|model| model.on_show_create_table(None, "users".to_owned()));

        wait_until(WAIT, || {
            visible_alert(&test.window)
                .is_some_and(|alert| alert.heading().as_deref() == Some("Could Not Show CREATE TABLE"))
        })
        .expect("an alert for the failed read");
        let body = visible_alert(&test.window)
            .map(|alert| alert.body().to_string())
            .unwrap_or_default();
        assert!(body.contains("permission denied for table users"), "{body}");
        assert!(answer(&test.window, "close"));
    }

    #[gtk4::test]
    fn a_table_other_tables_point_at_is_refused_before_the_prompt() {
        use crate::test_support::wait_until;
        use crate::ui::session_window::tests::{TestWindow, WAIT};
        use crate::workspace::{answer, visible_alert};
        use tablepro_core::ddl::InboundForeignKey;
        use tablepro_test_support::FakeReply;

        let mut users = definition(vec![text_column("id")]);
        let key = |name: &str, table: TableRef, column: &str| InboundForeignKey {
            name: name.to_owned(),
            table,
            columns: vec![column.to_owned()],
            referenced_columns: vec!["id".to_owned()],
        };
        users.inbound_foreign_keys = vec![
            key(
                "orders_user",
                TableRef::new(Some("public".to_owned()), "orders"),
                "user_id",
            ),
            key("audit_user", TableRef::new(Some("audit".to_owned()), "log"), "actor_id"),
            key("users_parent", users.table.clone(), "parent_id"),
        ];
        let test = TestWindow::connected_with("DropRefusedForInboundKeys", |script| {
            script.fetch_table_definition.always(FakeReply::ok(users.clone()));
        });

        test.workspace()
            .with_model(|model| model.on_drop_table_prompt(Some("public".to_owned()), "users".to_owned()));
        wait_until(WAIT, || visible_alert(&test.window).is_some()).expect("an alert");

        let alert = visible_alert(&test.window).expect("the alert");
        assert_eq!(alert.heading().as_deref(), Some("Cannot Drop Table"));
        let body = alert.body();
        assert!(body.contains("orders (user_id), audit.log (actor_id)"), "{body}");
        assert!(
            !body.contains("parent_id"),
            "a key of the table on itself was named: {body}"
        );
        assert!(!alert.has_response("drop"), "the refusal offered the drop");
        assert!(answer(&test.window, "close"), "the refusal has no Close button");
    }

    #[gtk4::test]
    fn a_drop_runs_as_a_save_that_holds_the_process() {
        use std::sync::Arc;

        use crate::test_support::wait_until;
        use crate::ui::session_window::tests::{TestWindow, WAIT};
        use tablepro_core::WriteReport;
        use tablepro_test_support::FakeReply;
        use tokio_util::sync::CancellationToken;

        let release = CancellationToken::new();
        let script_release = release.clone();
        let test = TestWindow::connected_with("DropHeld", |script| {
            script.dialect = Arc::new(postgres_dialect());
            script.write_batch.once(FakeReply::UntilReleased {
                release: script_release,
                outcome: Ok(WriteReport::new(vec![None])),
            });
        });
        wait_until(WAIT, || test.hold.live() == 0).expect("nothing else to hold the process");
        let handle = test.workspace().handle().expect("the workspace handle");

        test.workspace()
            .with_model(|model| model.on_drop_table_confirmed(Some("public".to_owned()), "users".to_owned()));

        assert_eq!(handle.ledger().in_flight(), 1, "a close would not wait for the drop");
        assert_eq!(test.hold.live(), 1, "the drop started without holding the process");
        release.cancel();
        wait_until(WAIT, || handle.ledger().in_flight() == 0).expect("the drop to settle");
        assert_eq!(test.hold.live(), 0, "the settled drop still held the process");
    }
}

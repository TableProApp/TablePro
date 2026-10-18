use std::path::PathBuf;
use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::gtk;
use relm4::gtk::gio;
use relm4::{ComponentController, ComponentSender};
use tablepro_core::import::{
    CsvFormat, DEFAULT_IMPORT_BATCH_ROWS, ImportTarget, InsertPlan, MAX_FILE_BYTES, PlanError, build_insert_plan,
    detect_format, read_csv,
};
use tablepro_core::sql_ddl::build_create_table;
use tablepro_core::{ColumnInfo, Connection, DriverError, OperationControl};
use tablepro_policy::{BulkBatch, BulkInsertEnd, BulkInsertRequest, PolicyGuard};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::services::csv_import_mappings::CsvMappingScope;
use crate::ui::error_text;
use crate::ui::import_dialog::{ImportChoice, ImportMode, ImportRequest};

use super::browse::{RefreshDecision, refresh_decision};
use super::types::WorkspaceTab;
use super::{App, AppMsg, BrowseTabInput};

/// Everything the file dialog collected, handed back to the GTK thread.
#[derive(Debug)]
pub struct CsvImportPreparation {
    pub connection_id: uuid::Uuid,
    pub database: String,
    pub schema: Option<String>,
    /// The existing table, or `None` when the import is creating one.
    pub table: Option<String>,
    pub path: PathBuf,
    pub bytes: Vec<u8>,
    pub format: CsvFormat,
    pub columns: Vec<ColumnInfo>,
    pub driver_id: String,
}

/// How an import ended, as the GTK thread hears it.
#[derive(Debug)]
pub struct CsvImportReport {
    pub schema: Option<String>,
    pub table: String,
    pub committed: u64,
    pub total: u64,
    pub error: Option<String>,
}

impl App {
    pub(super) fn on_import_csv_into_table(
        &self,
        schema: Option<String>,
        table: String,
        sender: ComponentSender<Self>,
    ) {
        self.choose_csv_file(schema, Some(table), sender);
    }

    pub(super) fn on_create_table_from_csv(&self, schema: Option<String>, sender: ComponentSender<Self>) {
        if !tablepro_core::import::supports_table_creation(self.driver_id()) {
            self.show_error_alert(
                &crate::tr!("Can't create a table"),
                &crate::tr!(
                    "This connection type cannot create a table from a file. Import into an existing table instead."
                ),
            );
            return;
        }
        self.choose_csv_file(schema, None, sender);
    }

    fn choose_csv_file(&self, schema: Option<String>, table: Option<String>, sender: ComponentSender<Self>) {
        if let Some(message) = self.import_refusal() {
            self.show_error_alert(&crate::tr!("Can't import"), &message);
            return;
        }
        let filter = gtk::FileFilter::new();
        filter.set_name(Some(&crate::tr!("CSV files")));
        filter.add_mime_type("text/csv");
        filter.add_suffix("csv");
        filter.add_suffix("tsv");
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let dialog = gtk::FileDialog::builder()
            .title(crate::tr!("Import CSV"))
            .modal(true)
            .default_filter(&filter)
            .filters(&filters)
            .build();
        dialog.open(Some(&self.window), gio::Cancellable::NONE, move |outcome| {
            let Some(path) = outcome.ok().and_then(|file| file.path()) else {
                return;
            };
            sender.input(AppMsg::CsvFileChosen {
                schema: schema.clone(),
                table: table.clone(),
                path,
            });
        });
    }

    /// Why an import cannot start at all. Checked before the user picks a
    /// file, so a refusal never arrives after the work looks under way.
    fn import_refusal(&self) -> Option<String> {
        if self.connection_id.is_none() || self.current_driver_id.is_none() {
            return Some(crate::tr!("No active connection."));
        }
        if self.read_only {
            return Some(crate::tr!("This connection is open read-only."));
        }
        if !self.database.policy_available() {
            return Some(crate::tr!(
                "The policy rules could not be loaded, so writes are not permitted."
            ));
        }
        if self
            .connection_id
            .is_some_and(|id| self.database.governed_writes_disabled(id))
        {
            return Some(crate::tr!(
                "A previous operation's audit record could not be written, so writes are not permitted."
            ));
        }
        None
    }

    pub(super) fn on_csv_file_chosen(
        &self,
        schema: Option<String>,
        table: Option<String>,
        path: PathBuf,
        sender: ComponentSender<Self>,
    ) {
        let (Some(connection_id), Some(driver_id)) = (self.connection_id, self.current_driver_id.clone()) else {
            return;
        };
        let Some(conn) = self.database.get(connection_id) else {
            return;
        };
        let timeout_secs =
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id);
        let database = self
            .saved_connections
            .iter()
            .find(|saved| saved.id == connection_id)
            .map(|saved| saved.database.clone())
            .unwrap_or_default();
        sender.clone().command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let control = crate::services::operation_control::bounded(timeout_secs);
                    match prepare_import(
                        conn,
                        &control,
                        Prepare {
                            schema,
                            table,
                            path,
                            driver_id,
                            connection_id,
                            database,
                        },
                    )
                    .await
                    {
                        Ok(preparation) => sender.input(AppMsg::CsvImportPrepared(Box::new(preparation))),
                        Err(message) => sender.input(AppMsg::ShowAlert {
                            title: crate::tr!("Can't import"),
                            body: message,
                        }),
                    }
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_csv_import_prepared(&self, preparation: CsvImportPreparation, sender: ComponentSender<Self>) {
        if self.connection_id != Some(preparation.connection_id)
            || self.current_driver_id.as_deref() != Some(preparation.driver_id.as_str())
            || self
                .saved_connections
                .iter()
                .find(|saved| saved.id == preparation.connection_id)
                .is_none_or(|saved| saved.database != preparation.database)
        {
            return;
        }
        let mapping_scope = preparation.table.as_ref().map(|table| CsvMappingScope {
            connection_id: preparation.connection_id,
            database: preparation.database.clone(),
            driver_id: preparation.driver_id.clone(),
            schema: preparation.schema.clone(),
            table: table.clone(),
        });
        let mode = match preparation.table {
            Some(table) => ImportMode::ExistingTable {
                driver_id: preparation.driver_id.clone(),
                table,
                columns: preparation.columns,
            },
            None => ImportMode::NewTable {
                driver_id: preparation.driver_id,
                suggested_table: suggested_table_name(&preparation.path),
            },
        };
        let request = ImportRequest {
            schema: preparation.schema,
            path: preparation.path,
            bytes: preparation.bytes,
            format: preparation.format,
            mode,
            mapping_store: self.persistence.csv_import_mappings.clone(),
            mapping_scope,
        };
        crate::ui::import_dialog::present(&self.window, request, move |choice| {
            sender.input(AppMsg::StartCsvImport(Box::new(choice)));
        });
    }

    pub(super) fn on_start_csv_import(&mut self, choice: ImportChoice, sender: ComponentSender<Self>) {
        if let Some(message) = self.import_refusal() {
            self.show_error_alert(&crate::tr!("Can't import"), &message);
            return;
        }
        let (Some(connection_id), Some(driver_id)) = (self.connection_id, self.current_driver_id.clone()) else {
            return;
        };
        let plan = match plan_for(&driver_id, &choice) {
            Ok(plan) => plan,
            Err(message) => {
                self.show_error_alert(&crate::tr!("Can't import"), &message);
                return;
            }
        };
        let create_sql = match create_statement(&driver_id, &choice) {
            Ok(sql) => sql,
            Err(message) => {
                self.show_error_alert(&crate::tr!("Can't import"), &message);
                return;
            }
        };
        let Some(guard) = self
            .database
            .guard(connection_id, tablepro_policy::Principal::human_gui())
        else {
            self.show_error_alert(&crate::tr!("Can't import"), &crate::tr!("No active connection."));
            return;
        };
        let progress = crate::ui::import_dialog::present_progress(&self.window, &choice.table, plan.row_count());
        let token = progress.cancel_token();
        self.csv_import_progress = Some(progress);
        self.run_import(guard, plan, create_sql, choice, token, sender);
    }

    fn run_import(
        &self,
        guard: Arc<PolicyGuard>,
        plan: InsertPlan,
        create_sql: Option<String>,
        choice: ImportChoice,
        token: CancellationToken,
        sender: ComponentSender<Self>,
    ) {
        let timeout_secs =
            crate::services::operation_control::timeout_for(&self.preferences, &self.database, self.connection_id);
        let sender_for_cmd = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let run = ImportRun {
                        guard,
                        plan,
                        create_sql,
                        schema: choice.schema,
                        table: choice.table,
                        token,
                        timeout_secs,
                    };
                    let report = run.execute(&sender_for_cmd).await;
                    sender_for_cmd.input(AppMsg::CsvImportFinished(Box::new(report)));
                })
                .drop_on_shutdown()
        });
    }

    pub(super) fn on_csv_import_progress(&self, committed: u64) {
        if let Some(progress) = &self.csv_import_progress {
            progress.set_committed(committed);
        }
    }

    pub(super) fn on_csv_import_finished(&mut self, report: CsvImportReport, _sender: ComponentSender<Self>) {
        if let Some(progress) = self.csv_import_progress.take() {
            progress.close();
        }
        self.refresh_import_targets(report.schema.as_deref(), &report.table);
        let Some(error) = report.error else {
            self.show_toast(
                &crate::tr!("Imported {done} rows into {table}")
                    .replace("{done}", &report.committed.to_string())
                    .replace("{table}", &report.table),
            );
            return;
        };
        self.show_error_alert(
            &crate::tr!("Import stopped"),
            &crate::tr!("{done} of {total} rows were written to {table} before the import stopped. {error}")
                .replace("{done}", &report.committed.to_string())
                .replace("{total}", &report.total.to_string())
                .replace("{table}", &report.table)
                .replace("{error}", &error),
        );
    }
}

impl App {
    fn refresh_import_targets(&self, schema: Option<&str>, table: &str) {
        let targets: Vec<Uuid> = self
            .workspace_tabs
            .borrow()
            .iter()
            .filter_map(|(id, tab)| match tab {
                WorkspaceTab::Table(slot)
                    if import_targets_table(slot.schema.as_deref(), &slot.table, schema, table) =>
                {
                    Some(*id)
                }
                _ => None,
            })
            .collect();
        for id in targets {
            let save_in_flight = self
                .workspace_tabs
                .borrow()
                .get(&id)
                .and_then(|tab| tab.browse_controller())
                .is_some_and(|controller| controller.model().save_in_flight());
            let dirty = crate::services::change_tracker::with_tab_ref(id, |tr| tr.has_pending()).unwrap_or(false);
            if refresh_decision(dirty, save_in_flight) == RefreshDecision::Refresh {
                self.dispatch_to_tab(id, BrowseTabInput::Refresh);
            }
        }
    }
}

fn import_targets_table(tab_schema: Option<&str>, tab_table: &str, schema: Option<&str>, table: &str) -> bool {
    tab_schema == schema && tab_table == table
}

#[cfg(test)]
mod refresh_tests {
    use super::*;
    use crate::ui::app::browse::{RefreshDecision, refresh_decision};

    #[test]
    fn only_the_imported_schema_and_table_are_refreshed() {
        assert!(import_targets_table(Some("public"), "people", Some("public"), "people"));
        assert!(!import_targets_table(
            Some("public"),
            "orders",
            Some("public"),
            "people"
        ));
        assert!(!import_targets_table(
            Some("archive"),
            "people",
            Some("public"),
            "people"
        ));
        assert!(!import_targets_table(None, "people", Some("public"), "people"));
    }

    #[test]
    fn a_dirty_matching_tab_is_not_refreshed_by_an_import() {
        assert_eq!(refresh_decision(false, false), RefreshDecision::Refresh);
        assert_ne!(refresh_decision(true, false), RefreshDecision::Refresh);
        assert_ne!(refresh_decision(false, true), RefreshDecision::Refresh);
    }
}

struct ImportRun {
    guard: Arc<PolicyGuard>,
    plan: InsertPlan,
    /// The CREATE TABLE this import runs first, as its own governed
    /// statement. It is classified, decided and audited on its own.
    create_sql: Option<String>,
    schema: Option<String>,
    table: String,
    token: CancellationToken,
    timeout_secs: u32,
}

impl ImportRun {
    async fn execute(self, sender: &ComponentSender<App>) -> CsvImportReport {
        let total = self.plan.row_count();
        if let Err(message) = self.create_table().await {
            return CsvImportReport {
                schema: self.schema.clone(),
                table: self.table,
                committed: 0,
                total,
                error: Some(message),
            };
        }
        let request = BulkInsertRequest {
            schema: self.schema.clone(),
            table: self.table.clone(),
            statement: self.plan.statement.clone(),
            row_budget: total,
            sequence_columns: if self.guard.context().driver_id.eq_ignore_ascii_case("postgres") {
                self.plan
                    .columns
                    .iter()
                    .filter(|column| column.is_auto_increment)
                    .map(|column| column.name.clone())
                    .collect()
            } else {
                Vec::new()
            },
        };
        let mut scope = match self.guard.begin_bulk_insert(request).await {
            Ok(scope) => scope,
            Err(error) => {
                return CsvImportReport {
                    schema: self.schema.clone(),
                    table: self.table,
                    committed: 0,
                    total,
                    error: Some(error_text::driver_message(&error)),
                };
            }
        };
        let outcome = self.run_batches(&mut scope, sender).await;
        let end = match &outcome {
            Ok(()) => BulkInsertEnd::Completed,
            Err(BatchStop::Cancelled) => BulkInsertEnd::Cancelled,
            Err(BatchStop::Failed(error)) => BulkInsertEnd::Failed(error),
        };
        let committed = self
            .guard
            .finish_bulk_insert(&mut scope, end)
            .await
            .unwrap_or_else(|_| scope.committed_rows());
        CsvImportReport {
            schema: self.schema.clone(),
            table: self.table,
            committed,
            total,
            error: stop_message(outcome),
        }
    }

    async fn create_table(&self) -> Result<(), String> {
        let Some(sql) = &self.create_sql else {
            return Ok(());
        };
        let control = self.control();
        self.guard
            .execute_controlled(sql, &control)
            .await
            .map(|_| ())
            .map_err(|error| error_text::driver_message(&error))
    }

    async fn run_batches(
        &self,
        scope: &mut tablepro_policy::BulkInsertScope,
        sender: &ComponentSender<App>,
    ) -> Result<(), BatchStop> {
        let mut committed = 0;
        for rows in self.plan.batches(DEFAULT_IMPORT_BATCH_ROWS) {
            if self.token.is_cancelled() {
                return Err(BatchStop::Cancelled);
            }
            let control = self.control();
            let batch = BulkBatch {
                schema: self.schema.as_deref(),
                table: &self.table,
                statement: &self.plan.statement,
                rows,
            };
            match self.guard.execute_bulk_batch(scope, batch, &control).await {
                Ok(written) => committed += written,
                Err(DriverError::Cancelled) => return Err(BatchStop::Cancelled),
                Err(error) => return Err(BatchStop::Failed(error)),
            }
            sender.input(AppMsg::CsvImportProgress(committed));
        }
        Ok(())
    }

    fn control(&self) -> OperationControl {
        crate::services::operation_control::bounded_with(self.timeout_secs, self.token.clone())
    }
}

enum BatchStop {
    Cancelled,
    Failed(DriverError),
}

fn stop_message(outcome: Result<(), BatchStop>) -> Option<String> {
    match outcome {
        Ok(()) => None,
        Err(BatchStop::Cancelled) => Some(crate::tr!("The import was cancelled.")),
        Err(BatchStop::Failed(error)) => Some(error_text::driver_message(&error)),
    }
}

struct Prepare {
    schema: Option<String>,
    table: Option<String>,
    path: PathBuf,
    driver_id: String,
    connection_id: uuid::Uuid,
    database: String,
}

async fn prepare_import(
    conn: Arc<dyn Connection>,
    control: &OperationControl,
    prepare: Prepare,
) -> Result<CsvImportPreparation, String> {
    let bytes = read_file(&prepare.path)?;
    let format = detect_format(&bytes);
    let columns = match &prepare.table {
        None => Vec::new(),
        Some(table) => existing_columns(conn, control, prepare.schema.as_deref(), table).await?,
    };
    Ok(CsvImportPreparation {
        connection_id: prepare.connection_id,
        database: prepare.database,
        schema: prepare.schema,
        table: prepare.table,
        path: prepare.path,
        bytes,
        format,
        columns,
        driver_id: prepare.driver_id,
    })
}

async fn existing_columns(
    conn: Arc<dyn Connection>,
    control: &OperationControl,
    schema: Option<&str>,
    table: &str,
) -> Result<Vec<ColumnInfo>, String> {
    let columns = conn
        .fetch_columns_controlled(schema, table, control)
        .await
        .map_err(|error| error_text::driver_message(&error))?;
    if columns.is_empty() {
        return Err(crate::tr!("The table has no columns to import into."));
    }
    Ok(columns)
}

/// The CREATE the import runs before its first row, or nothing when the
/// table is already there.
fn create_statement(driver_id: &str, choice: &ImportChoice) -> Result<Option<String>, String> {
    let Some(drafts) = &choice.create else {
        return Ok(None);
    };
    let statements = build_create_table(driver_id, choice.schema.as_deref(), &choice.table, drafts, &[], &[])
        .map_err(|error| error.to_string())?;
    statements
        .into_iter()
        .next()
        .map(Some)
        .ok_or_else(|| crate::tr!("The table could not be built from the file."))
}

fn suggested_table_name(path: &std::path::Path) -> String {
    let stem = path.file_stem().map(|stem| stem.to_string_lossy().to_string());
    let cleaned: String = stem
        .unwrap_or_default()
        .chars()
        .map(|character| if character.is_alphanumeric() { character } else { '_' })
        .collect();
    let cleaned = cleaned.trim_matches('_').to_lowercase();
    if cleaned.is_empty() {
        return "imported_table".to_owned();
    }
    cleaned
}

fn read_file(path: &std::path::Path) -> Result<Vec<u8>, String> {
    let size = std::fs::metadata(path)
        .map_err(|_| crate::tr!("The file could not be opened."))?
        .len();
    if size > MAX_FILE_BYTES {
        return Err(crate::tr!("The file is larger than the {limit} MB import limit.")
            .replace("{limit}", &(MAX_FILE_BYTES / (1024 * 1024)).to_string()));
    }
    std::fs::read(path).map_err(|_| crate::tr!("The file could not be read."))
}

fn plan_for(driver_id: &str, choice: &ImportChoice) -> Result<InsertPlan, String> {
    let sheet = read_csv(&choice.bytes, &choice.options, None).map_err(|error| error.to_string())?;
    let target = ImportTarget {
        driver_id,
        schema: choice.schema.as_deref(),
        table: &choice.table,
        columns: &choice.columns,
        mapping: &choice.mapping,
    };
    build_insert_plan(&target, &sheet, &choice.options).map_err(plan_error_text)
}

/// A plan failure names the rows it could not read, never their contents.
fn plan_error_text(error: PlanError) -> String {
    let PlanError::Rows { first, .. } = &error else {
        return error.to_string();
    };
    let lines: Vec<String> = first
        .iter()
        .map(|row| {
            crate::tr!("Line {line}, column {column}: {reason}")
                .replace("{line}", &row.line.to_string())
                .replace("{column}", &row.column)
                .replace("{reason}", &row.reason.to_string())
        })
        .collect();
    format!("{}\n\n{}", error, lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tablepro_core::import::CsvImportOptions;
    use tablepro_core::sql_ddl::DraftColumn;
    use tablepro_core::{ConnectOptions, DatabaseDriver, Environment, Value};
    use tablepro_policy::{
        AuditError, AuditEvent, AuditSink, AuditState, AutoApproveSink, BulkBatch, BulkInsertEnd, BulkInsertRequest,
        GuardContext, PolicyConfig, Principal,
    };
    use uuid::Uuid;

    struct TestAudit;

    #[async_trait::async_trait]
    impl AuditSink for TestAudit {
        async fn record(&self, _event: AuditEvent) -> Result<(), AuditError> {
            Ok(())
        }
    }

    fn draft(name: &str, data_type: &str) -> DraftColumn {
        DraftColumn {
            original: None,
            name: name.to_owned(),
            data_type: data_type.to_owned(),
            nullable: true,
            primary_key: false,
            auto_increment: false,
            default_value: None,
            comment: None,
            collation: None,
        }
    }

    fn choice(create: Option<Vec<DraftColumn>>) -> ImportChoice {
        ImportChoice {
            schema: None,
            table: "people".into(),
            bytes: Vec::new(),
            options: CsvImportOptions::default(),
            mapping: Vec::new(),
            columns: Vec::new(),
            create,
        }
    }

    #[tokio::test]
    async fn generated_csv_column_is_skipped_in_preview_and_database_supplies_its_value() {
        let raw: Arc<dyn Connection> = drivers_sqlite::SqliteDriver
            .connect(ConnectOptions {
                database: ":memory:".into(),
                ..Default::default()
            })
            .await
            .expect("connect to SQLite")
            .into();
        let guard = PolicyGuard::new(
            raw,
            GuardContext {
                connection_id: Uuid::new_v4(),
                connection_name: "CSV import preview test".into(),
                driver_id: "sqlite".into(),
                environment: Environment::Local,
                read_only: false,
                principal: Principal::human_gui(),
                policy: Arc::new(PolicyConfig::default()),
                approval: Arc::new(AutoApproveSink),
                audit: Arc::new(TestAudit),
                audit_state: Arc::new(AuditState::new()),
            },
        );
        let control = OperationControl::with_timeout(Duration::from_secs(5));
        guard
            .execute_controlled("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)", &control)
            .await
            .expect("create table");
        let columns = guard
            .fetch_columns_controlled(None, "people", &control)
            .await
            .expect("read table columns");
        let bytes = b"id,name\n51,Ada\n52,Grace\n".to_vec();
        let options = CsvImportOptions::default();
        let sheet = read_csv(&bytes, &options, None).expect("read CSV");
        let mapping = crate::ui::import_dialog::suggested_existing_mapping("sqlite", &sheet.headers, &columns);
        assert_eq!(mapping, [Some(0), Some(1)]);
        let choice = ImportChoice {
            schema: None,
            table: "people".into(),
            bytes,
            options,
            mapping,
            columns,
            create: None,
        };
        let plan = plan_for("sqlite", &choice).expect("build import plan");
        assert_eq!(
            plan.columns
                .iter()
                .map(|column| column.name.as_str())
                .collect::<Vec<_>>(),
            ["id", "name"]
        );
        let mut scope = guard
            .begin_bulk_insert(BulkInsertRequest {
                schema: None,
                table: choice.table.clone(),
                statement: plan.statement.clone(),
                row_budget: plan.row_count(),
                sequence_columns: Vec::new(),
            })
            .await
            .expect("approve import");
        for rows in plan.batches(10) {
            guard
                .execute_bulk_batch(
                    &mut scope,
                    BulkBatch {
                        schema: None,
                        table: &choice.table,
                        statement: &plan.statement,
                        rows,
                    },
                    &control,
                )
                .await
                .expect("insert rows");
        }
        assert_eq!(
            guard
                .finish_bulk_insert(&mut scope, BulkInsertEnd::Completed)
                .await
                .expect("finish import"),
            2
        );
        let result = guard
            .query_controlled("SELECT id, name FROM people ORDER BY id", &control)
            .await
            .expect("verify imported rows");
        assert_eq!(
            result.rows,
            [
                vec![Value::Int(51), Value::Text("Ada".into())],
                vec![Value::Int(52), Value::Text("Grace".into())]
            ]
        );
    }

    #[test]
    fn an_import_into_an_existing_table_creates_nothing() {
        assert_eq!(create_statement("postgres", &choice(None)), Ok(None));
    }

    #[test]
    fn a_new_table_is_created_by_one_statement_with_quoted_identifiers() {
        let drafts = vec![draft("id", "BIGINT"), draft("na\"me", "TEXT")];

        let sql = create_statement("postgres", &choice(Some(drafts)))
            .expect("built")
            .expect("a statement");

        assert!(sql.starts_with("CREATE TABLE \"people\""));
        assert!(sql.contains("\"na\"\"me\" TEXT"));
        assert!(!sql.contains(';'));
    }

    #[test]
    fn a_file_name_becomes_a_table_name_that_can_be_an_identifier() {
        assert_eq!(
            suggested_table_name(std::path::Path::new("/tmp/People List 2024.csv")),
            "people_list_2024"
        );
        assert_eq!(
            suggested_table_name(std::path::Path::new("/tmp/---.csv")),
            "imported_table"
        );
    }
}

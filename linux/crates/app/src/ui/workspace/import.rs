use std::sync::Arc;

use gtk4 as gtk;
use gtk4::{gio, glib};
use libadwaita::prelude::*;
use relm4::{Component, ComponentController};

use std::ops::Range;
use std::time::Duration;

use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::CellInput;
use tablepro_core::import::{ImportColumn, ImportPlan, plan_import};
use tablepro_core::meta::TableRef;
use tablepro_core::{CallOptions, DriverError, WriteKind};
use tablepro_session::runtime::Tasks;
use tablepro_session::{OperationError, OperationKind, Session};
use tokio_util::sync::CancellationToken;

use crate::services::history_service::HistoryService;
use crate::ui::error_text::{driver_message, operation_error_message};
use crate::ui::file_read::{FileReadError, read_capped_file};
use crate::ui::import_dialog::{CsvImport, MAX_CSV_FILE_BYTES};

use super::{WorkspaceInput, WorkspaceModel};
use crate::runtime::DeliverInput;
use crate::workspace::RanStatements;

/// How many of an import's statements go into the log line that
/// announces it, so a failed import has something to read back.
const IMPORT_LOG_SAMPLE: usize = 3;

/// What each statement of an import adds to the save deadline. A
/// statement carries up to a thousand rows, so this bounds a server that
/// stopped answering rather than one that is merely slow.
const IMPORT_TIME_PER_STATEMENT: Duration = Duration::from_secs(5);

impl WorkspaceModel {
    /// Ask for a CSV, then read it and the table's columns together so
    /// the mapping dialog opens with both.
    pub(super) fn on_import_csv_requested(&self, schema: Option<String>, table: String) {
        let Some(session) = self.context.active.get() else {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        };
        if session.read_only() {
            self.show_toast(&crate::i18n::gettext("This connection is read-only."));
            return;
        }

        let filter = gtk::FileFilter::new();
        filter.set_name(Some(&crate::i18n::gettext("CSV files")));
        filter.add_suffix("csv");
        filter.add_suffix("tsv");
        filter.add_mime_type("text/csv");
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let dialog = gtk::FileDialog::builder()
            .title(crate::i18n::gettext("Import CSV"))
            .modal(true)
            .default_filter(&filter)
            .filters(&filters)
            .build();

        let input = self.input.clone();
        let tasks = self.context.tasks.clone();
        dialog.open(self.window().as_ref(), gio::Cancellable::NONE, move |outcome| {
            let Ok(file) = outcome else { return };
            let input = input.clone();
            let schema = schema.clone();
            let table = table.clone();
            let session = session.clone();
            let tasks = tasks.clone();
            glib::spawn_future_local(async move {
                let bytes = match read_csv_file(&file).await {
                    Ok(bytes) => bytes,
                    Err(message) => {
                        input.deliver(WorkspaceInput::ShowToast(message));
                        return;
                    }
                };
                // The mapping is against the table's own columns, so the
                // dialog cannot open until they are read. The read runs
                // on the runtime: a driver future polled here has no
                // tokio context to run in.
                let table_ref = TableRef::new(schema.clone(), table.clone());
                let columns = match tasks.spawn_task(read_columns(session, table_ref)).await {
                    Ok(Ok(columns)) => columns,
                    Ok(Err(error)) => {
                        tracing::warn!(%error, "could not read the table to import into");
                        input.deliver(WorkspaceInput::ShowToast(crate::i18n::gettext(
                            "The table's columns could not be read.",
                        )));
                        return;
                    }
                    Err(failure) => {
                        tracing::warn!(%failure, "the column read did not finish");
                        return;
                    }
                };
                input.deliver(WorkspaceInput::ImportCsvReady {
                    schema,
                    table,
                    columns,
                    bytes,
                });
            });
        });
    }

    pub(super) fn on_import_csv_ready(
        &mut self,
        schema: Option<String>,
        table: String,
        columns: Vec<ImportColumn>,
        bytes: Vec<u8>,
    ) {
        use crate::ui::import_dialog::{ImportCsvDialog, ImportCsvDialogInit, ImportCsvDialogOutput};

        let dialog = ImportCsvDialog::builder()
            .launch(ImportCsvDialogInit {
                schema,
                table,
                columns,
                bytes,
            })
            .connect_receiver({
                let input = self.input.clone();
                move |_, out| {
                    input.deliver(match out {
                        ImportCsvDialogOutput::Import(import) => WorkspaceInput::ImportCsvRun(import),
                        ImportCsvDialogOutput::ShowToast(text) => WorkspaceInput::ShowToast(text),
                    });
                }
            });
        dialog.model().dialog().present(self.dialog_parent().as_ref());
        self.import_dialog = Some(dialog);
    }

    /// Read the whole file, turn its rows into INSERTs and write them as
    /// one batch, so a file either lands whole or not at all. The file
    /// is read and planned on the blocking pool, never on this thread.
    pub(super) fn on_import_csv_run(&self, import: CsvImport) {
        let Some((session, dialect)) = self
            .context
            .active
            .get()
            .and_then(|session| session.current_dialect().map(|dialect| (session, dialect)))
        else {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        };
        let Some(ticket) = self.imports.begin() else {
            return;
        };
        let history = Some(self.history.clone());
        let connection = self.context.active.metadata();
        let tasks = self.context.tasks.clone();
        let work = run_import(ImportRun {
            session,
            dialect,
            import,
            cancel: ticket.cancel.clone(),
            tasks: tasks.clone(),
            history,
            connection,
        });
        let imports = self.imports.clone();
        let input = self.input.clone();
        let _delivery = crate::runtime::spawn_and_deliver(&tasks, work, move |finished| {
            imports.settle(ticket.id);
            match finished {
                Ok(Ok(rows)) => {
                    input.deliver(WorkspaceInput::RefreshPage);
                    input.deliver(WorkspaceInput::ShowToast(crate::i18n::ngettext_f(
                        "Imported {n} row.",
                        "Imported {n} rows.",
                        u32::try_from(rows).unwrap_or(u32::MAX),
                        &[("n", &rows.to_string())],
                    )));
                }
                Ok(Err(ImportEnd::Empty)) => input.deliver(WorkspaceInput::ShowToast(crate::i18n::gettext(
                    "That file has no rows to import.",
                ))),
                Ok(Err(ImportEnd::Stopped)) => {
                    input.deliver(WorkspaceInput::RefreshPage);
                    input.deliver(WorkspaceInput::ShowToast(crate::i18n::gettext("Import stopped.")));
                }
                Ok(Err(ImportEnd::Failed(message))) => input.deliver(WorkspaceInput::ShowAlert {
                    title: crate::i18n::gettext("Couldn't Import"),
                    body: message,
                }),
                Err(failure) => input.deliver(WorkspaceInput::ShowAlert {
                    title: crate::i18n::gettext("Couldn't Import"),
                    body: crate::ui::error_text::task_failure_message(&failure),
                }),
            }
        });
    }
}

/// Everything an import needs once it leaves the GTK thread.
struct ImportRun {
    session: Arc<Session>,
    dialect: Arc<dyn SqlDialect>,
    import: CsvImport,
    cancel: CancellationToken,
    tasks: Tasks,
    history: Option<HistoryService>,
    connection: Option<tablepro_session::ConnectionMetadata>,
}

/// Why an import wrote nothing, or not everything.
#[derive(Debug)]
enum ImportEnd {
    Empty,
    Stopped,
    Failed(String),
}

/// Read and plan the file on the blocking pool, then write the plan.
/// Gives back how many rows landed.
async fn run_import(run: ImportRun) -> Result<usize, ImportEnd> {
    let ImportRun {
        session,
        dialect,
        import,
        cancel,
        tasks,
        history,
        connection,
    } = run;
    let first_line = first_data_line(&import);
    let planning_dialect = dialect.clone();
    let planned = tasks
        .spawn_blocking_task(move || plan_file(&import, &*planning_dialect))
        .await
        .map_err(|failure| ImportEnd::Failed(crate::ui::error_text::task_failure_message(&failure)))??;
    let Some((plan, rows)) = planned else {
        return Err(ImportEnd::Empty);
    };
    if cancel.is_cancelled() {
        return Err(ImportEnd::Stopped);
    }
    let sql: Vec<String> = plan
        .batch
        .steps
        .iter()
        .map(|step| step.statement.sql().to_owned())
        .collect();
    tracing::info!(
        rows,
        statements = sql.len(),
        sample = ?sql.iter().take(IMPORT_LOG_SAMPLE).collect::<Vec<_>>(),
        "importing a CSV"
    );
    let batch = Arc::new(plan.batch);
    let written = session
        .run_cancellable(
            OperationKind::Save(WriteKind::RowChanges),
            &cancel,
            move |lease, options| {
                let batch = batch.clone();
                let options = import_call(options, batch.len());
                async move { Ok(lease.write_batch(&batch, options).await?) }
            },
        )
        .await;
    match written {
        Ok(report) => {
            // An import changes the database, so it belongs in the same
            // history as a statement run from the editor.
            let touched = report.total_rows().and_then(|rows| i64::try_from(rows).ok());
            RanStatements::starting(history, connection, Some(dialect), sql)
                .finished(touched, tablepro_storage::query_history::Outcome::Success)
                .await;
            Ok(rows)
        }
        Err(OperationError::Cancelled) => Err(ImportEnd::Stopped),
        Err(error) => Err(ImportEnd::Failed(import_failure_text(
            &error,
            &plan.step_rows,
            first_line,
        ))),
    }
}

/// The call the write runs under: the save deadline, and as long again
/// as every statement may take on top of it, so a large file is not cut
/// off by the deadline a single edit gets.
fn import_call(options: CallOptions, statements: usize) -> CallOptions {
    let extra = IMPORT_TIME_PER_STATEMENT.saturating_mul(u32::try_from(statements).unwrap_or(u32::MAX));
    CallOptions::new(
        options.deadline().map(|deadline| deadline + extra),
        options.cancel().clone(),
    )
}

/// The header takes the first line when there is one, so the first data
/// row is line 2 in the file the user is looking at.
fn first_data_line(import: &CsvImport) -> usize {
    match import.options.has_header {
        true => 2,
        false => 1,
    }
}

/// The plan for the whole file and how many rows it writes, `None` for
/// a file with no rows, or what to tell the user about the file instead.
fn plan_file(import: &CsvImport, dialect: &dyn SqlDialect) -> Result<Option<(ImportPlan, usize)>, ImportEnd> {
    let rows = import_rows(import).map_err(ImportEnd::Failed)?;
    if rows.is_empty() {
        return Ok(None);
    }
    let count = rows.len();
    let table = TableRef::new(import.schema.clone(), import.table.clone());
    let plan = plan_import(dialect, &table, &import.columns, rows).map_err(|error| {
        ImportEnd::Failed(crate::ui::error_text::operation_error_message(&OperationError::Build(
            error,
        )))
    })?;
    Ok(Some((plan, count)))
}

/// Why the write failed, told as the lines of the file the failing
/// statement held rather than as a statement number the user never saw.
fn import_failure_text(error: &OperationError, step_rows: &[Range<usize>], first_line: usize) -> String {
    let lines = |index: usize| {
        step_rows
            .get(index)
            .map(|rows| (first_line + rows.start, first_line + rows.end.saturating_sub(1)))
    };
    match error {
        OperationError::Driver(DriverError::RolledBack {
            statement_index,
            source,
        }) => match lines(*statement_index) {
            Some((first, last)) if first == last => crate::i18n::gettext_f(
                "Line {line} could not be written: {error}. The import was rolled back, so no rows were added.",
                &[("line", &first.to_string()), ("error", &driver_message(source))],
            ),
            Some((first, last)) => crate::i18n::gettext_f(
                "Lines {first} to {last} could not be written: {error}. The import was rolled back, so no rows were added.",
                &[
                    ("first", &first.to_string()),
                    ("last", &last.to_string()),
                    ("error", &driver_message(source)),
                ],
            ),
            None => operation_error_message(error),
        },
        OperationError::Driver(DriverError::PartiallyApplied {
            statement_index,
            source,
            ..
        }) => {
            let written: usize = step_rows
                .iter()
                .take(*statement_index)
                .map(ExactSizeIterator::len)
                .sum();
            let count = u32::try_from(written).unwrap_or(u32::MAX);
            match lines(*statement_index) {
                Some((first, last)) if first == last => crate::i18n::ngettext_f(
                    "Line {line} could not be written: {error}. The {written} row before it stays in the table, which has no transaction to undo it.",
                    "Line {line} could not be written: {error}. The {written} rows before it stay in the table, which has no transaction to undo them.",
                    count,
                    &[
                        ("line", &first.to_string()),
                        ("error", &driver_message(source)),
                        ("written", &written.to_string()),
                    ],
                ),
                // A table without transactions can keep the rows of a
                // multi-row statement that came before the one it
                // refused.
                Some((first, last)) => crate::i18n::ngettext_f(
                    "Lines {first} to {last} could not be written: {error}. The table has no transaction to undo the import, so the {written} row before them stays, and some of these lines may have been written too.",
                    "Lines {first} to {last} could not be written: {error}. The table has no transaction to undo the import, so the {written} rows before them stay, and some of these lines may have been written too.",
                    count,
                    &[
                        ("first", &first.to_string()),
                        ("last", &last.to_string()),
                        ("error", &driver_message(source)),
                        ("written", &written.to_string()),
                    ],
                ),
                None => operation_error_message(error),
            }
        }
        _ => operation_error_message(error),
    }
}

/// The chosen CSV, whole, or what to tell the user instead.
async fn read_csv_file(file: &gio::File) -> Result<Vec<u8>, String> {
    read_capped_file(file, MAX_CSV_FILE_BYTES)
        .await
        .map_err(|error| match error {
            FileReadError::NotRegular => crate::i18n::gettext("Only regular files can be imported."),
            FileReadError::TooLarge => crate::i18n::gettext("That file is too large to import in one go."),
            FileReadError::Io(error) => {
                tracing::warn!(%error, "could not read the CSV to import");
                crate::i18n::gettext("That file could not be read.")
            }
        })
}

/// The table's columns with what the engine lets an insert write, so
/// the mapping never offers a column the server fills.
async fn read_columns(session: Arc<Session>, table: TableRef) -> Result<Vec<ImportColumn>, OperationError> {
    session
        .run(OperationKind::Metadata, move |lease, options| {
            let table = table.clone();
            async move {
                let definition = lease.fetch_table_definition(&table, options).await?;
                Ok(definition.columns.iter().map(ImportColumn::from_definition).collect())
            }
        })
        .await
}

/// Every row of the file as the cells to insert, or the first row that
/// could not be read.
///
/// The whole file is read here rather than in the dialog, which only
/// ever saw the preview.
fn import_rows(import: &CsvImport) -> Result<Vec<Vec<CellInput>>, String> {
    use tablepro_core::import::{read_csv, row_to_cells};

    let sheet = read_csv(&import.bytes, &import.options, None).map_err(|error| error.to_string())?;
    let first_line = first_data_line(import);
    sheet
        .rows
        .iter()
        .enumerate()
        .map(|(index, row)| {
            row_to_cells(
                row,
                &import.mapping,
                &import.columns,
                &import.options,
                first_line + index,
            )
            .map_err(|error| {
                crate::i18n::gettext_f(
                    "Line {line}, column {column}: {reason} (the value was “{text}”)",
                    &[
                        ("line", &error.line.to_string()),
                        ("column", &error.column),
                        ("reason", &error.reason),
                        ("text", &error.text),
                    ],
                )
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnKind, ColumnType, TextLength};
    use tablepro_core::ddl::{ColumnAttributes, ColumnDefinition, IdentityStyle, TableDefinition};
    use tablepro_core::{ColumnInfo, LivenessPolicy, Value, WriteReport};
    use tablepro_session::fakes::{FakeConnector, FakeCredentialSource};
    use tablepro_session::operation::DefaultDeadlines;
    use tablepro_session::{SessionDeps, SessionHealth};
    use tablepro_test_support::{CallCounters, ConnectionScript, FakeConnection, FakeReply};

    use super::*;

    fn info(name: &str) -> ColumnInfo {
        let mut column_type = ColumnType::untyped_text("text");
        column_type.kind = ColumnKind::Text {
            length: TextLength::Unbounded,
        };
        ColumnInfo {
            name: name.to_owned(),
            column_type,
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn column(name: &str) -> ImportColumn {
        ImportColumn {
            info: info(name),
            server_filled: false,
        }
    }

    fn definition(name: &str, identity: IdentityStyle) -> ColumnDefinition {
        ColumnDefinition::new(
            info(name),
            ColumnAttributes {
                identity,
                ..ColumnAttributes::default()
            },
        )
    }

    fn session(script: ConnectionScript) -> (Arc<Session>, Arc<FakeConnection>) {
        let (pending, connection) = FakeConnector::pending_session(FakeConnector::request().unwrap(), script);
        let session = Session::start(
            pending,
            SessionDeps {
                connector: Arc::new(FakeConnector::new([])),
                credentials: Arc::new(FakeCredentialSource::new()),
                deadlines: Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
                tasks: crate::test_support::paused_tasks(),
                prompter: None,
            },
        );
        (session, connection)
    }

    fn import(bytes: &str) -> CsvImport {
        CsvImport {
            schema: None,
            table: "people".to_owned(),
            columns: vec![column("name"), column("city")],
            mapping: vec![Some(0), Some(1)],
            options: tablepro_core::import::CsvImportOptions::default(),
            bytes: bytes.as_bytes().to_vec(),
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn csv_import_reads_columns_through_session() {
        let mut script = ConnectionScript::default();
        script.fetch_table_definition.always(FakeReply::ok(TableDefinition {
            table: TableRef::unqualified("people"),
            columns: vec![
                definition("id", IdentityStyle::MssqlIdentity),
                definition("name", IdentityStyle::None),
            ],
            primary_key: None,
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
        }));
        let (session, connection) = session(script);

        let columns = crate::test_support::paused_tasks()
            .spawn_task(read_columns(session.clone(), TableRef::unqualified("people")))
            .await
            .unwrap()
            .unwrap();

        assert_eq!(
            columns.iter().map(|column| column.server_filled).collect::<Vec<_>>(),
            vec![true, false],
            "an identity that refuses a value was offered to the file"
        );
        assert_eq!(CallCounters::get(&connection.counters().fetch_table_definition), 1);
        assert_eq!(*session.health().borrow(), SessionHealth::Online);
    }

    fn run(session: Arc<Session>, import: CsvImport, cancel: CancellationToken) -> ImportRun {
        ImportRun {
            session,
            dialect: Arc::new(tablepro_test_support::FakeDialect),
            import,
            cancel,
            tasks: crate::test_support::paused_tasks(),
            history: None,
            connection: None,
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn an_import_writes_its_rows_as_one_multi_row_statement() {
        let mut script = ConnectionScript::default();
        script
            .write_batch
            .always(FakeReply::ok(WriteReport::new(vec![Some(2)])));
        let (session, connection) = session(script);
        let started = tokio::time::Instant::now();

        let rows = run_import(run(
            session,
            import("name,city\nAda,London\nGrace,\n"),
            CancellationToken::new(),
        ))
        .await
        .unwrap();

        assert_eq!(rows, 2);
        assert_eq!(CallCounters::get(&connection.counters().write_batch), 1);
        let sql = connection.observed_sql("write_batch");
        assert!(
            sql.iter()
                .flatten()
                .any(|sql| sql.contains("VALUES (") && sql.contains("), (")),
            "the rows went one statement each: {sql:?}"
        );
        let deadline = connection.observed_deadlines("write_batch")[0].expect("a deadline");
        assert!(
            deadline >= started + DefaultDeadlines::ROW_CHANGES + IMPORT_TIME_PER_STATEMENT,
            "the deadline did not grow with the import"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn a_stopped_import_says_it_stopped() {
        let mut script = ConnectionScript::default();
        script.write_batch.always(FakeReply::UntilStopped);
        let (session, connection) = session(script);
        let cancel = CancellationToken::new();
        let stop = cancel.clone();

        let running = crate::test_support::paused_tasks().spawn_task(run_import(run(
            session,
            import("name,city\nAda,London\n"),
            cancel,
        )));
        while CallCounters::get(&connection.counters().write_batch) == 0 {
            tokio::task::yield_now().await;
        }
        stop.cancel();

        assert!(matches!(running.await.unwrap(), Err(ImportEnd::Stopped)));
    }

    #[test]
    fn a_failed_statement_is_told_as_the_lines_it_held() {
        let steps = vec![0..1_000, 1_000..1_500];
        let rolled_back = OperationError::Driver(DriverError::RolledBack {
            statement_index: 1,
            source: Box::new(DriverError::server("null value in column \"city\"")),
        });
        let partial = OperationError::Driver(DriverError::PartiallyApplied {
            applied: 1,
            statement_index: 1,
            failed_outcome: tablepro_core::StatementOutcome::Failed,
            source: Box::new(DriverError::server("null value in column \"city\"")),
        });

        let rolled_back = import_failure_text(&rolled_back, &steps, 2);
        let partial = import_failure_text(&partial, &steps, 2);

        assert!(
            rolled_back.starts_with("Lines 1002 to 1501 could not be written: "),
            "{rolled_back}"
        );
        assert!(
            rolled_back.ends_with("The import was rolled back, so no rows were added."),
            "{rolled_back}"
        );
        assert!(
            partial.contains("so the 1000 rows before them stay, and some of these lines may"),
            "{partial}"
        );
    }

    #[test]
    fn a_bad_row_names_its_line_in_the_file() {
        let mut bad = import("name,city\nAda,London\n");
        bad.columns[1].info.column_type.kind = ColumnKind::Integer(tablepro_core::column::IntegerKind {
            width: tablepro_core::column::IntegerWidth::W32,
            signed: true,
        });

        let message = import_rows(&bad).unwrap_err();

        assert!(message.contains('2'), "{message}");
        assert!(message.contains("London"), "{message}");
    }

    fn read(path: &std::path::Path) -> Result<Vec<u8>, String> {
        let file = gio::File::for_path(path);
        crate::test_support::finish_on_main(
            std::time::Duration::from_secs(10),
            async move { read_csv_file(&file).await },
        )
        .expect("the read to end")
    }

    #[gtk4::test]
    fn a_pipe_is_refused_without_waiting_for_a_writer() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("people.csv");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&path)
                .status()
                .unwrap()
                .success()
        );

        let refused = read(&path).unwrap_err();

        assert!(refused.contains("regular files"), "{refused}");
    }

    #[gtk4::test]
    fn a_device_is_refused_before_it_is_read() {
        let refused = read(std::path::Path::new("/dev/zero")).unwrap_err();

        assert!(refused.contains("regular files"), "{refused}");
    }

    #[gtk4::test]
    fn a_csv_is_read_whole() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("people.csv");
        std::fs::write(&path, "name,city\nAda,London\n").unwrap();

        assert_eq!(read(&path).unwrap(), b"name,city\nAda,London\n");
    }

    #[test]
    fn an_empty_field_is_kept_as_what_the_file_said() {
        let rows = import_rows(&import("name,city\nGrace,\n")).unwrap();

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0][0], CellInput::Value(Value::Text("Grace".to_owned())));
    }
}

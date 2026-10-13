use std::sync::Arc;

use relm4::adw::prelude::*;
use relm4::gtk::{gio, glib};
use relm4::{Component, ComponentController, ComponentSender, gtk};

use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::TableRef;
use tablepro_core::statement::GuardedStatement;
use tablepro_core::{ColumnInfo, ForeignKeyMode, WriteBatch, WriteKind, WriteReport};
use tablepro_session::{OperationError, OperationKind, Session};

use crate::ui::file_read::{FileReadError, read_capped_file};
use crate::ui::import_dialog::{CsvImport, MAX_CSV_FILE_BYTES};

use super::{App, AppMsg};
use crate::workspace::RanStatements;

/// How many of an import's statements go into the log line that
/// announces it, so a failed import has something to read back.
const IMPORT_LOG_SAMPLE: usize = 3;

impl App {
    /// Ask for a CSV, then read it and the table's columns together so
    /// the mapping dialog opens with both.
    pub(super) fn on_import_csv_requested(&self, schema: Option<String>, table: String, sender: ComponentSender<Self>) {
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

        let input = sender.input_sender().clone();
        let tasks = self.context.tasks.clone();
        dialog.open(Some(&self.window), gio::Cancellable::NONE, move |outcome| {
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
                        let _ = input.send(AppMsg::ShowToast(message));
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
                        let _ = input.send(AppMsg::ShowToast(crate::i18n::gettext(
                            "The table's columns could not be read.",
                        )));
                        return;
                    }
                    Err(failure) => {
                        tracing::warn!(%failure, "the column read did not finish");
                        return;
                    }
                };
                let _ = input.send(AppMsg::ImportCsvReady {
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
        columns: Vec<tablepro_core::ColumnInfo>,
        bytes: Vec<u8>,
        sender: ComponentSender<Self>,
    ) {
        use crate::ui::import_dialog::{ImportCsvDialog, ImportCsvDialogInit, ImportCsvDialogOutput};

        let dialog = ImportCsvDialog::builder()
            .launch(ImportCsvDialogInit {
                schema,
                table,
                columns,
                bytes,
            })
            .forward(sender.input_sender(), |out| match out {
                ImportCsvDialogOutput::Import(import) => AppMsg::ImportCsvRun(import),
                ImportCsvDialogOutput::ShowToast(text) => AppMsg::ShowToast(text),
            });
        dialog.model().dialog().present(Some(&self.window));
        self.import_dialog = Some(dialog);
    }

    /// Read the whole file, turn every row into an INSERT and write them
    /// as one batch, so a file either lands whole or not at all.
    pub(super) fn on_import_csv_run(&self, import: CsvImport, sender: ComponentSender<Self>) {
        let Some(session) = self.context.active.get() else {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        };
        let rows = match import_rows(&import) {
            Ok(rows) => rows,
            Err(message) => {
                self.show_error_alert(&crate::i18n::gettext("Couldn't import"), &message);
                return;
            }
        };
        if rows.is_empty() {
            self.show_toast(&crate::i18n::gettext("That file has no rows to import."));
            return;
        }

        let count = rows.len();
        let table = TableRef::new(import.schema.clone(), import.table.clone());
        let history = self.history.store();
        let connection = self.context.active.metadata();
        self.context.tasks.spawn_task(async move {
            let written = write_import(&session, table, import.columns, rows).await;
            match written {
                Ok((sql, report)) => {
                    // An import changes the database, so it belongs in
                    // the same history as a statement run from the editor.
                    let touched = report.total_rows().and_then(|rows| i64::try_from(rows).ok());
                    RanStatements::starting(history, connection, sql)
                        .finished(touched, tablepro_storage::query_history::Outcome::Success)
                        .await;
                    sender.input(AppMsg::RefreshPage);
                    sender.input(AppMsg::ShowToast(crate::i18n::ngettext_f(
                        "Imported {n} row.",
                        "Imported {n} rows.",
                        u32::try_from(count).unwrap_or(u32::MAX),
                        &[("n", &count.to_string())],
                    )));
                }
                Err(error) => {
                    let message = crate::ui::error_text::operation_error_message(&error);
                    sender.input(AppMsg::ShowAlert {
                        title: crate::i18n::gettext("Couldn't import"),
                        body: message,
                    });
                }
            }
        });
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

async fn read_columns(session: Arc<Session>, table: TableRef) -> Result<Vec<ColumnInfo>, OperationError> {
    session
        .run(OperationKind::Metadata, move |lease, options| {
            let table = table.clone();
            async move { Ok(lease.fetch_columns(&table, options).await?) }
        })
        .await
}

/// Write the rows as one batch on the connection that runs it, giving
/// back the SQL it ran for the history.
async fn write_import(
    session: &Session,
    table: TableRef,
    columns: Vec<ColumnInfo>,
    rows: Vec<Vec<CellInput>>,
) -> Result<(Vec<String>, WriteReport), OperationError> {
    let rows = Arc::new(rows);
    session
        .run(OperationKind::Save(WriteKind::RowChanges), move |lease, options| {
            let table = table.clone();
            let columns = columns.clone();
            let rows = rows.clone();
            async move {
                let batch = import_batch(&*lease.dialect(), &table, &columns, &rows)?;
                let sql: Vec<String> = batch.steps.iter().map(|step| step.statement.sql().to_owned()).collect();
                tracing::info!(
                    rows = rows.len(),
                    sample = ?sql.iter().take(IMPORT_LOG_SAMPLE).collect::<Vec<_>>(),
                    "importing a CSV"
                );
                let report = lease.write_batch(&batch, options).await?;
                Ok((sql, report))
            }
        })
        .await
}

/// One INSERT per row, as a single batch so the engine runs them in
/// one transaction where it has one.
fn import_batch(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    rows: &[Vec<CellInput>],
) -> Result<WriteBatch, tablepro_core::dml::BuildSqlError> {
    let steps = rows
        .iter()
        .map(|cells| tablepro_core::dml::build_insert(dialect, table, columns, cells).map(GuardedStatement::unguarded))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(WriteBatch::new(
        WriteKind::RowChanges,
        table.clone(),
        steps,
        ForeignKeyMode::Enforced,
    ))
}

/// Every row of the file as the cells to insert, or the first row that
/// could not be read.
///
/// The whole file is read here rather than in the dialog, which only
/// ever saw the preview.
fn import_rows(import: &CsvImport) -> Result<Vec<Vec<CellInput>>, String> {
    use tablepro_core::import::{read_csv, row_to_cells};

    let sheet = read_csv(&import.bytes, &import.options, None).map_err(|error| error.to_string())?;
    // The header takes the first line when there is one, so the first
    // data row is line 2 in the file the user is looking at.
    let first_line = if import.options.has_header { 2 } else { 1 };
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
    use tablepro_core::{LivenessPolicy, Value};
    use tablepro_session::fakes::{FakeConnector, FakeCredentialSource};
    use tablepro_session::operation::DefaultDeadlines;
    use tablepro_session::{SessionDeps, SessionHealth};
    use tablepro_test_support::{CallCounters, ConnectionScript, FakeConnection, FakeReply};

    use super::*;

    fn column(name: &str) -> ColumnInfo {
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
        script
            .fetch_columns
            .always(FakeReply::ok(vec![column("name"), column("city")]));
        let (session, connection) = session(script);

        let columns = crate::test_support::paused_tasks()
            .spawn_task(read_columns(session.clone(), TableRef::unqualified("people")))
            .await
            .unwrap()
            .unwrap();

        assert_eq!(columns.len(), 2);
        assert_eq!(CallCounters::get(&connection.counters().fetch_columns), 1);
        assert_eq!(*session.health().borrow(), SessionHealth::Online);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn an_import_is_one_batch_with_an_insert_per_row() {
        let mut script = ConnectionScript::default();
        script
            .write_batch
            .always(FakeReply::ok(WriteReport::new(vec![Some(1), Some(1)])));
        let (session, connection) = session(script);
        let import = import("name,city\nAda,London\nGrace,\n");
        let rows = import_rows(&import).unwrap();

        let (sql, report) = write_import(&session, TableRef::unqualified("people"), import.columns, rows)
            .await
            .unwrap();

        assert_eq!(sql.len(), 2);
        assert!(sql.iter().all(|statement| statement.starts_with("INSERT")), "{sql:?}");
        assert_eq!(report.total_rows(), Some(2));
        assert_eq!(CallCounters::get(&connection.counters().write_batch), 1);
    }

    #[test]
    fn a_bad_row_names_its_line_in_the_file() {
        let mut bad = import("name,city\nAda,London\n");
        bad.columns[1].column_type.kind = ColumnKind::Integer(tablepro_core::column::IntegerKind {
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

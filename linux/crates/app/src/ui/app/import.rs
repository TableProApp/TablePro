use relm4::adw::prelude::*;
use relm4::gtk::{gio, glib};
use relm4::{Component, ComponentController, ComponentSender, gtk};

use crate::services::database_service;
use crate::ui::import_dialog::CsvImport;

use super::ran_statements::RanStatements;
use super::{App, AppMsg};

/// How many of an import's statements go into the log line that
/// announces it, so a failed import has something to read back.
const IMPORT_LOG_SAMPLE: usize = 3;

impl App {
    /// Ask for a CSV, then read it and the table's columns together so
    /// the mapping dialog opens with both.
    pub(super) fn on_import_csv_requested(&self, schema: Option<String>, table: String, sender: ComponentSender<Self>) {
        if database_service::instance().active().is_none() {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        }
        if database_service::instance().is_active_read_only() {
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
        dialog.open(Some(&self.window), gio::Cancellable::NONE, move |outcome| {
            let Ok(file) = outcome else { return };
            let too_big = file
                .query_info("standard::size", gio::FileQueryInfoFlags::NONE, gio::Cancellable::NONE)
                .map(|info| info.size() as u64 > crate::ui::import_dialog::MAX_CSV_FILE_BYTES)
                .unwrap_or(false);
            if too_big {
                let _ = input.send(AppMsg::ShowToast(crate::i18n::gettext(
                    "That file is too large to import in one go.",
                )));
                return;
            }
            let input = input.clone();
            let schema = schema.clone();
            let table = table.clone();
            glib::spawn_future_local(async move {
                let Ok((bytes, _etag)) = file.load_contents_future().await else {
                    let _ = input.send(AppMsg::ShowToast(crate::i18n::gettext("That file could not be read.")));
                    return;
                };
                let Some(connection) = database_service::instance().active() else {
                    return;
                };
                // The mapping is against the table's own columns, so
                // the dialog cannot open until they are read.
                match connection.fetch_columns(schema.as_deref(), &table).await {
                    Ok(columns) => {
                        let _ = input.send(AppMsg::ImportCsvReady {
                            schema,
                            table,
                            columns,
                            bytes: bytes.to_vec(),
                        });
                    }
                    Err(error) => {
                        tracing::warn!(%error, "could not read the table to import into");
                        let _ = input.send(AppMsg::ShowToast(crate::i18n::gettext(
                            "The table's columns could not be read.",
                        )));
                    }
                }
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

    /// Read the whole file, turn every row into an INSERT and run them
    /// as one transaction, so a file either lands whole or not at all.
    pub(super) fn on_import_csv_run(&self, import: CsvImport, sender: ComponentSender<Self>) {
        let Some(connection) = database_service::instance().active() else {
            self.show_toast(&crate::i18n::gettext("Connect to a database first."));
            return;
        };
        let Some(driver_id) = self.current_driver_id.clone() else {
            return;
        };
        let statements = match build_import_statements(&import, &driver_id) {
            Ok(statements) => statements,
            Err(message) => {
                self.show_error_alert(&crate::i18n::gettext("Couldn't import"), &message);
                return;
            }
        };
        if statements.is_empty() {
            self.show_toast(&crate::i18n::gettext("That file has no rows to import."));
            return;
        }

        let count = statements.len();
        tracing::info!(
            rows = count,
            sample = ?statements.iter().take(IMPORT_LOG_SAMPLE).map(|(sql, _)| sql).collect::<Vec<_>>(),
            "importing a CSV"
        );
        // An import changes the database, so it belongs in the same
        // history as a statement run from the editor.
        let ran = RanStatements::starting(
            self.history.store(),
            statements.iter().map(|(sql, _)| sql.clone()).collect::<Vec<_>>(),
        );
        let sender_for_cmd = sender.clone();
        sender.command(move |_, shutdown| {
            shutdown
                .register(async move {
                    match connection.execute_in_transaction(&statements).await {
                        Ok(affected) => {
                            let touched: u64 = affected.iter().copied().sum();
                            ran.finished(
                                i64::try_from(touched).ok(),
                                tablepro_storage::query_history::Outcome::Success,
                            )
                            .await;
                            sender_for_cmd.input(AppMsg::RefreshPage);
                            sender_for_cmd.input(AppMsg::ShowToast(crate::i18n::ngettext_f(
                                "Imported {n} row.",
                                "Imported {n} rows.",
                                count as u32,
                                &[("n", &count.to_string())],
                            )));
                        }
                        Err(error) => {
                            let message = crate::ui::error_text::driver_message(&error);
                            ran.finished(None, tablepro_storage::query_history::Outcome::Error(message.clone()))
                                .await;
                            sender_for_cmd.input(AppMsg::ShowAlert {
                                title: crate::i18n::gettext("Couldn't import"),
                                body: message,
                            });
                        }
                    }
                })
                .drop_on_shutdown()
        });
    }
}

/// Every row of the file as an INSERT, or the first row that could not
/// be turned into one.
///
/// The whole file is read here rather than in the dialog, which only
/// ever saw the preview.
fn build_import_statements(
    import: &CsvImport,
    driver_id: &str,
) -> Result<Vec<(String, Vec<tablepro_core::Value>)>, String> {
    use tablepro_core::import::{read_csv, row_to_cells};

    let sheet = read_csv(&import.bytes, &import.options, None).map_err(|error| error.to_string())?;
    let dialect = tablepro_core::dialect::dialect_for(driver_id);
    let table_ref = tablepro_core::meta::TableRef {
        schema: import.schema.clone(),
        name: import.table.clone(),
    };
    // The header takes the first line when there is one, so the first
    // data row is line 2 in the file the user is looking at.
    let first_line = if import.options.has_header { 2 } else { 1 };
    let mut statements = Vec::with_capacity(sheet.rows.len());
    for (index, row) in sheet.rows.iter().enumerate() {
        let cells = row_to_cells(
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
        })?;
        let statement = tablepro_core::dml::build_insert(dialect, &table_ref, &import.columns, &cells)
            .map_err(|error| error.to_string())?;
        // `execute_in_transaction` takes plain values; the types the
        // builder bound are already spelled out in the SQL it wrote.
        let (sql, params) = statement.into_parts();
        statements.push((sql, params.into_iter().map(|param| param.value().clone()).collect()));
    }
    Ok(statements)
}

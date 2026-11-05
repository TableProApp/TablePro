use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::ErrorCategory;
use tablepro_core::dump::{DumpObjectKind, DumpReport, DumpSkipReason};
use tablepro_core::export::{EncodeError, RenderError};
use tablepro_session::OperationError;
use tablepro_session::runtime::TaskFailure;

use super::{AbortOutcome, ExpectedRows, ExportFailure, ExportOutcome, ExportStreamFailure};
use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::ui::error_text::operation_error_message;
use crate::ui::file_reveal::{FileRevealer, reveal_failure_toast};
use crate::ui::format::{format_thousands, plural_count};

pub(crate) fn exported_text(rows: u64, name: &str) -> String {
    ngettext_f(
        "Exported {rows} row to {name}",
        "Exported {rows} rows to {name}",
        plural_count(rows),
        &[("rows", &format_thousands(rows)), ("name", name)],
    )
}

pub(crate) fn stopped_text(outcome: AbortOutcome, name: &str) -> String {
    match outcome {
        AbortOutcome::Removed | AbortOutcome::Untouched => gettext("Export stopped"),
        AbortOutcome::Incomplete => gettext_f("Export stopped. {name} is incomplete.", &[("name", name)]),
    }
}

/// How far a database export has got.
pub(crate) fn tables_progress_text(done: usize, total: usize, rows: u64) -> String {
    let rows_text = ngettext_f(
        "{rows} row",
        "{rows} rows",
        plural_count(rows),
        &[("rows", &format_thousands(rows))],
    );
    ngettext_f(
        "{done} of {total} table, {rows_text}",
        "{done} of {total} tables, {rows_text}",
        plural_count(total as u64),
        &[
            ("done", &format_thousands(done as u64)),
            ("total", &format_thousands(total as u64)),
            ("rows_text", &rows_text),
        ],
    )
}

/// What a database export wrote, for its toast.
pub(crate) fn dumped_text(report: &DumpReport, name: &str) -> String {
    ngettext_f(
        "Exported {tables} table to {name}",
        "Exported {tables} tables to {name}",
        plural_count(report.tables as u64),
        &[("tables", &format_thousands(report.tables as u64)), ("name", name)],
    )
}

/// What a database export could not carry, one line each, or `None`
/// when it carried everything.
pub(crate) fn dump_warnings(report: &DumpReport) -> Option<String> {
    let mut lines = Vec::new();
    for omitted in &report.omitted {
        lines.push(ngettext_f(
            "{count} value in {table}.{column} has no SQL form and was written as NULL.",
            "{count} values in {table}.{column} have no SQL form and were written as NULL.",
            plural_count(omitted.count),
            &[
                ("count", &format_thousands(omitted.count)),
                ("table", &omitted.table.name),
                ("column", &omitted.column),
            ],
        ));
    }
    for skipped in &report.skipped {
        let special = match skipped.reason {
            DumpSkipReason::RowsNotCarried => Some(gettext_f(
                "{name} is in the file without the rows it stores: a materialized view fills only from rows inserted after it.",
                &[("name", &skipped.name)],
            )),
            DumpSkipReason::RowsFiltered => Some(gettext_f(
                "{name} is in the file without its rows: row-level security shows this login only some of them.",
                &[("name", &skipped.name)],
            )),
            DumpSkipReason::NotReadable if skipped.kind == DumpObjectKind::SequenceValue => Some(gettext_f(
                "The position of sequence {name} could not be read, so it starts over when the file loads.",
                &[("name", &skipped.name)],
            )),
            _ => None,
        };
        if let Some(line) = special {
            lines.push(line);
            continue;
        }
        let reason = match skipped.reason {
            DumpSkipReason::NoDefinition => gettext("the server gave no SQL for it"),
            DumpSkipReason::Encrypted => gettext("its code is encrypted"),
            DumpSkipReason::ClrRoutine => gettext("its code is a .NET assembly"),
            DumpSkipReason::HiddenSecret => gettext("the server hides a secret in its SQL"),
            DumpSkipReason::SplitsApart => gettext("its code holds a line that is only GO"),
            DumpSkipReason::NotReadable => gettext("this login may not read it"),
            DumpSkipReason::RemoteRows => {
                gettext("its rows live on another server, which loading the file would write to")
            }
            _ => gettext("the export writes no object of its kind"),
        };
        lines.push(gettext_f(
            "{name} was left out: {reason}.",
            &[("name", &skipped.name), ("reason", &reason)],
        ));
    }
    if !report.unordered.is_empty() {
        let names: Vec<&str> = report.unordered.iter().map(|table| table.name.as_str()).collect();
        lines.push(gettext_f(
            "The foreign keys of {tables} point at each other, so their rows may need foreign key checks off to load.",
            &[("tables", &names.join(", "))],
        ));
    }
    (!lines.is_empty()).then(|| lines.join("\n"))
}

/// How far a running export has got, for its row in the operations
/// popover.
pub(crate) fn progress_text(rows: u64, expected: Option<ExpectedRows>) -> String {
    let count = format_thousands(rows);
    match expected {
        Some(ExpectedRows::Exact(total)) => ngettext_f(
            "{rows} of {total} row",
            "{rows} of {total} rows",
            plural_count(total),
            &[("rows", &count), ("total", &format_thousands(total))],
        ),
        Some(ExpectedRows::About(total)) => ngettext_f(
            "{rows} of about {total} row",
            "{rows} of about {total} rows",
            plural_count(total),
            &[("rows", &count), ("total", &format_thousands(total))],
        ),
        None => ngettext_f("{rows} row", "{rows} rows", plural_count(rows), &[("rows", &count)]),
    }
}

/// Why an export failed, as the alert says it, and what it left of the
/// file.
pub(crate) fn failure_text(failure: &ExportFailure, file: Option<AbortOutcome>, name: &str) -> String {
    let reason = match failure {
        ExportFailure::Stream(ExportStreamFailure::Encode(error)) => encode_text(error),
        ExportFailure::Stream(ExportStreamFailure::MultipleResultSets) => {
            gettext("This statement returned more than one result, so it can't be exported as one file.")
        }
        ExportFailure::Stream(ExportStreamFailure::NoResultSet) => {
            gettext("This statement returned no rows to export.")
        }
        ExportFailure::Stream(ExportStreamFailure::Document(error)) => document_text(error),
        ExportFailure::Stream(ExportStreamFailure::SheetFull { limit }) => gettext_f(
            "An Excel sheet holds {limit} rows, and this result has more. Export it as CSV instead.",
            &[("limit", &format_thousands(*limit as u64))],
        ),
        ExportFailure::Table(error) => operation_error_message(error),
        ExportFailure::Statement(error) => rerun_text(error),
        ExportFailure::File(error) => gettext_f(
            "Writing {name} failed: {error}",
            &[("name", name), ("error", error.message())],
        ),
        ExportFailure::InUse => gettext_f(
            "An export to {name} is already running. Wait for it to finish, or export to another file.",
            &[("name", name)],
        ),
        ExportFailure::Image(_) => gettext("The image couldn't be drawn."),
        ExportFailure::Dump(error) => crate::ui::error_text::dump_error_message(error),
        ExportFailure::DumpSession(error) => operation_error_message(error),
        ExportFailure::Task(TaskFailure::Panicked(_) | TaskFailure::Aborted)
        | ExportFailure::Stream(ExportStreamFailure::Task(_)) => gettext("The export stopped unexpectedly."),
    };
    match file {
        Some(AbortOutcome::Incomplete) => {
            format!("{reason}\n\n{}", gettext_f("{name} is incomplete.", &[("name", name)]))
        }
        _ => reason,
    }
}

/// Why Export All's run of the statement failed. It ran on a connection
/// of its own, read-only, which is behind most of the ways it can fail
/// where the editor's own run did not.
fn rerun_text(error: &OperationError) -> String {
    match error.category() {
        Some(ErrorCategory::ReadOnly) => {
            gettext("Export All only runs statements that read data. This statement changes data.")
        }
        Some(ErrorCategory::Server) => format!(
            "{}\n\n{}",
            gettext(
                "Export All runs the statement again on a separate connection, so temporary tables, session settings and uncommitted changes from this editor aren't available."
            ),
            operation_error_message(error)
        ),
        _ => operation_error_message(error),
    }
}

/// Why a value could not go into the file, whichever format refused it.
fn encode_text(error: &EncodeError) -> String {
    match error {
        EncodeError::Undecodable { column } => gettext_f(
            "The column “{column}” holds a value TablePro couldn't read, so it can't be written to the file.",
            &[("column", column)],
        ),
        EncodeError::NotXmlText { column } => gettext_f(
            "The column “{column}” holds a control character XML can't carry. Export it as CSV or JSON instead.",
            &[("column", column)],
        ),
    }
}

fn document_text(error: &RenderError) -> String {
    match error {
        RenderError::Encode(error) => encode_text(error),
        RenderError::TextTooLong { column, limit } => gettext_f(
            "The column “{column}” holds a value longer than the {limit} characters an Excel cell holds. Export it as CSV instead.",
            &[("column", column), ("limit", &format_thousands(*limit as u64))],
        ),
        RenderError::TooManyRows { got, limit } => gettext_f(
            "An Excel sheet holds {limit} rows, and this result has {got}.",
            &[
                ("limit", &format_thousands(*limit as u64)),
                ("got", &format_thousands(*got as u64)),
            ],
        ),
        RenderError::TooManyColumns { got, limit } => gettext_f(
            "An Excel sheet holds {limit} columns, and this result has {got}.",
            &[
                ("limit", &format_thousands(*limit as u64)),
                ("got", &format_thousands(*got as u64)),
            ],
        ),
        // The encoder libraries' text is English only; the reporter logs it.
        RenderError::Xlsx(_) | RenderError::Csv(_) | RenderError::Flush(_) | RenderError::Utf8(_) => {
            gettext("The file couldn't be built.")
        }
    }
}

/// Where an export's outcome is told: a toast on the workspace, or an
/// alert over its window for a failure.
#[derive(Clone)]
pub(crate) struct ExportReporter {
    parent: glib::WeakRef<gtk::Widget>,
    toasts: glib::WeakRef<adw::ToastOverlay>,
    revealer: Rc<dyn FileRevealer>,
}

impl std::fmt::Debug for ExportReporter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExportReporter").finish_non_exhaustive()
    }
}

impl ExportReporter {
    pub(crate) fn new(
        parent: &impl IsA<gtk::Widget>,
        toasts: &adw::ToastOverlay,
        revealer: Rc<dyn FileRevealer>,
    ) -> Self {
        Self {
            parent: parent.as_ref().downgrade(),
            toasts: toasts.downgrade(),
            revealer,
        }
    }

    pub(crate) fn report(&self, file: &gio::File, name: &str, outcome: &ExportOutcome) {
        match outcome {
            ExportOutcome::Dumped(report) => {
                let toast = crate::ui::plain_toast(&dumped_text(report, name));
                toast.set_button_label(Some(&gettext("Show in Files")));
                let (shown, reporter) = (file.clone(), self.clone());
                toast.connect_button_clicked(move |_| reporter.show_in_files(&shown));
                self.toast(toast);
                if let Some(warnings) = dump_warnings(report)
                    && let Some(parent) = self.parent.upgrade()
                {
                    let alert = adw::AlertDialog::new(Some(&gettext("Exported with Warnings")), Some(&warnings));
                    alert.set_body_use_markup(false);
                    alert.add_response("close", &gettext("_Close"));
                    alert.set_default_response(Some("close"));
                    alert.set_close_response("close");
                    alert.present(Some(&parent));
                }
            }
            ExportOutcome::Exported { .. } | ExportOutcome::Saved => {
                let text = match outcome {
                    ExportOutcome::Exported { rows } => exported_text(*rows, name),
                    _ => gettext_f("Exported {name}", &[("name", name)]),
                };
                let toast = crate::ui::plain_toast(&text);
                toast.set_button_label(Some(&gettext("Show in Files")));
                let (file, reporter) = (file.clone(), self.clone());
                toast.connect_button_clicked(move |_| reporter.show_in_files(&file));
                self.toast(toast);
            }
            ExportOutcome::Stopped(left) => self.toast(crate::ui::plain_toast(&stopped_text(*left, name))),
            ExportOutcome::Failed { failure, file: left } => {
                tracing::warn!(%failure, "an export failed");
                let Some(parent) = self.parent.upgrade() else {
                    return;
                };
                let alert = adw::AlertDialog::new(
                    Some(&gettext("Couldn't Export")),
                    Some(&failure_text(failure, *left, name)),
                );
                alert.add_response("close", &gettext("_Close"));
                alert.set_default_response(Some("close"));
                alert.set_close_response("close");
                alert.present(Some(&parent));
            }
        }
    }

    fn toast(&self, toast: adw::Toast) {
        if let Some(toasts) = self.toasts.upgrade() {
            toasts.add_toast(toast);
        }
    }

    /// A file manager that could not show the file is said in a toast,
    /// as Preferences and History do.
    pub(crate) fn show_in_files(&self, file: &gio::File) {
        let window = self
            .parent
            .upgrade()
            .and_then(|parent| parent.root())
            .and_downcast::<gtk::Window>();
        let revealing = self.revealer.reveal(file.clone(), window);
        let reporter = self.clone();
        glib::spawn_future_local(async move {
            if let Some(toast) = reveal_failure_toast(&revealing.await) {
                reporter.toast(toast);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{DriverError, LossPhase, ReadOnlyRefusal};

    use super::*;

    fn statement(error: DriverError) -> ExportFailure {
        ExportFailure::Statement(OperationError::Driver(error))
    }

    #[test]
    fn editor_rerun_failure_text_per_category() {
        let missing = || DriverError::server("relation \"scratch\" does not exist");
        let read_only = failure_text(
            &statement(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)),
            None,
            "rows.csv",
        );
        let server = failure_text(&statement(missing()), None, "rows.csv");
        let lost = failure_text(
            &statement(DriverError::ConnectionLost {
                during: LossPhase::Statement,
            }),
            None,
            "rows.csv",
        );
        let table = failure_text(
            &ExportFailure::Table(OperationError::Driver(missing())),
            None,
            "rows.csv",
        );
        let multiple = failure_text(
            &ExportFailure::Stream(ExportStreamFailure::MultipleResultSets),
            None,
            "rows.csv",
        );

        assert_eq!(
            read_only,
            "Export All only runs statements that read data. This statement changes data."
        );
        let (why, said) = server
            .split_once("\n\n")
            .expect("a blank line before the server's words");
        assert_eq!(
            why,
            "Export All runs the statement again on a separate connection, so temporary tables, session settings and uncommitted changes from this editor aren't available."
        );
        assert_eq!(said, "Query failed: relation \"scratch\" does not exist");
        assert_eq!(lost, "The connection was closed. Try reconnecting.");
        assert_eq!(table, said, "a table read has no statement to explain");
        assert_eq!(
            multiple,
            "This statement returned more than one result, so it can't be exported as one file."
        );
    }

    #[gtk4::test]
    fn a_failed_show_in_files_is_said_in_a_toast() {
        adw::init().expect("libadwaita initialises under the test backend");
        let toasts = adw::ToastOverlay::new();
        let window = adw::Window::new();
        window.set_content(Some(&toasts));
        let window = crate::test_support::OwnedWindow::presented(window);
        let reporter = ExportReporter::new(
            &*window,
            &toasts,
            Rc::new(crate::ui::file_reveal::RecordingRevealer::failing()),
        );

        reporter.show_in_files(&gio::File::for_path("/tmp/rows.csv"));

        crate::test_support::wait_until(std::time::Duration::from_secs(10), || {
            crate::test_support::descendants(&toasts)
                .iter()
                .filter_map(|widget| widget.downcast_ref::<gtk::Label>())
                .any(|label| label.label() == "Could not show the file in Files")
        })
        .expect("a toast said the file could not be shown");
    }

    #[test]
    fn progress_against_an_estimate_says_about() {
        assert_eq!(
            progress_text(12, Some(ExpectedRows::About(500))),
            "12 of about 500 rows"
        );
        assert_eq!(progress_text(12, Some(ExpectedRows::Exact(500))), "12 of 500 rows");
        assert_eq!(progress_text(1, None), "1 row");
    }

    #[test]
    fn a_full_sheet_says_how_many_rows_it_holds() {
        let text = failure_text(
            &ExportFailure::Stream(ExportStreamFailure::SheetFull { limit: 100 }),
            Some(AbortOutcome::Removed),
            "rows.xlsx",
        );

        assert_eq!(
            text,
            "An Excel sheet holds 100 rows, and this result has more. Export it as CSV instead."
        );
    }

    fn document(error: RenderError) -> String {
        failure_text(
            &ExportFailure::Stream(ExportStreamFailure::Document(error)),
            None,
            "rows.xlsx",
        )
    }

    #[test]
    fn a_sheet_names_the_column_it_could_not_write() {
        let unreadable = document(RenderError::Encode(EncodeError::Undecodable {
            column: "body".to_owned(),
        }));
        let long = document(RenderError::TextTooLong {
            column: "body".to_owned(),
            limit: 32_767,
        });

        assert_eq!(
            unreadable,
            "The column “body” holds a value TablePro couldn't read, so it can't be written to the file."
        );
        assert_eq!(
            long,
            format!(
                "The column “body” holds a value longer than the {} characters an Excel cell holds. Export it as CSV instead.",
                format_thousands(32_767)
            )
        );
    }

    #[test]
    fn an_encoder_failure_shows_the_apps_sentence_and_not_the_librarys() {
        let errors = [
            RenderError::Xlsx("Worksheet name 'x' already in use".to_owned()),
            RenderError::Flush(std::io::Error::other("failed to write whole buffer")),
        ];

        for error in errors {
            assert_eq!(document(error), "The file couldn't be built.");
        }
    }

    #[test]
    fn xml_names_the_column_with_a_control_character() {
        let text = failure_text(
            &ExportFailure::Stream(ExportStreamFailure::Encode(EncodeError::NotXmlText {
                column: "note".to_owned(),
            })),
            None,
            "rows.xml",
        );

        assert_eq!(
            text,
            "The column “note” holds a control character XML can't carry. Export it as CSV or JSON instead."
        );
    }
}

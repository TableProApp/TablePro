use gtk4::prelude::*;
use gtk4::{self as gtk, gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::ErrorCategory;
use tablepro_core::export::{EncodeError, RenderError};
use tablepro_session::OperationError;
use tablepro_session::runtime::TaskFailure;

use super::{AbortOutcome, ExpectedRows, ExportFailure, ExportOutcome, ExportStreamFailure};
use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::ui::error_text::operation_error_message;
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
        ExportFailure::Stream(ExportStreamFailure::Encode(EncodeError::Undecodable { column })) => gettext_f(
            "The column “{column}” holds a value TablePro couldn't read, so it can't be written to the file.",
            &[("column", column)],
        ),
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

fn document_text(error: &RenderError) -> String {
    match error {
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
        RenderError::Xlsx(_) | RenderError::Csv(_) | RenderError::Flush(_) | RenderError::Utf8(_) => {
            gettext_f("The file couldn't be built: {error}", &[("error", &error.to_string())])
        }
    }
}

/// Where an export's outcome is told: a toast on the workspace, or an
/// alert over its window for a failure.
#[derive(Debug, Clone)]
pub(crate) struct ExportReporter {
    parent: glib::WeakRef<gtk::Widget>,
    toasts: glib::WeakRef<adw::ToastOverlay>,
}

impl ExportReporter {
    pub(crate) fn new(parent: &impl IsA<gtk::Widget>, toasts: &adw::ToastOverlay) -> Self {
        Self {
            parent: parent.as_ref().downgrade(),
            toasts: toasts.downgrade(),
        }
    }

    pub(crate) fn report(&self, file: &gio::File, name: &str, outcome: &ExportOutcome) {
        match outcome {
            ExportOutcome::Exported { rows } => {
                let toast = adw::Toast::new(&exported_text(*rows, name));
                toast.set_button_label(Some(&gettext("Show in Files")));
                let (file, parent) = (file.clone(), self.parent.clone());
                toast.connect_button_clicked(move |_| show_in_files(&file, &parent));
                self.toast(toast);
            }
            ExportOutcome::Stopped(left) => self.toast(adw::Toast::new(&stopped_text(*left, name))),
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
}

fn show_in_files(file: &gio::File, parent: &glib::WeakRef<gtk::Widget>) {
    let window = parent
        .upgrade()
        .and_then(|parent| parent.root())
        .and_downcast::<gtk::Window>();
    let launcher = gtk::FileLauncher::new(Some(file));
    glib::spawn_future_local(async move {
        if let Err(error) = launcher.open_containing_folder_future(window.as_ref()).await {
            tracing::warn!(%error, "the export's folder could not be shown");
        }
    });
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
}

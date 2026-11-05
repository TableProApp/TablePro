mod imp;
mod preview_text;
#[cfg(test)]
mod tests;

use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::export::CsvDelimiter;
use tablepro_core::import::{
    CsvImportOptions, CsvSheet, ImportColumn, ImportError, MAX_PREVIEW_ROWS, read_csv, suggest_mapping,
};
use tablepro_session::runtime::{TaskFailure, Tasks};

use crate::i18n::gettext;
use crate::runtime::{RequestStamp, RequestTicket};
use crate::ui::error_text::task_failure_message;
pub(crate) use preview_text::import_error_text;
use preview_text::{field_label, qualified, sample_text, summary_text};

glib::wrapper! {
    pub struct ImportCsvDialog(ObjectSubclass<imp::ImportCsvDialog>)
        @extends adw::Dialog, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub(crate) struct ImportCsvDialogInit {
    pub schema: Option<String>,
    pub table: String,
    pub columns: Vec<ImportColumn>,
    pub bytes: Arc<[u8]>,
    pub tasks: Tasks,
}

// The mapping only means anything against these columns, read under these options, so they travel together.
#[derive(Debug, Clone, glib::Boxed)]
#[boxed_type(name = "TableProCsvImport")]
pub struct CsvImport {
    pub schema: Option<String>,
    pub table: String,
    pub columns: Vec<ImportColumn>,
    // One per table column: the field it takes, or None for Skip and for a column the server fills.
    pub mapping: Vec<Option<usize>>,
    pub options: CsvImportOptions,
    pub bytes: Arc<[u8]>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(super) enum CsvRequest {
    PreviewRead,
}

// None when the read was replaced or its dialog closed before it started.
type PreviewRead = Option<Result<CsvSheet, ImportError>>;

pub(super) struct DialogParts {
    schema: Option<String>,
    table: String,
    columns: Vec<ImportColumn>,
    bytes: Arc<[u8]>,
    tasks: Tasks,
}

impl ImportCsvDialog {
    pub(crate) fn new(init: ImportCsvDialogInit) -> Self {
        let dialog: Self = glib::Object::new();
        let imp = dialog.imp();
        imp.window_title
            .set_subtitle(&qualified(init.schema.as_deref(), &init.table));
        let _ = imp.parts.set(DialogParts {
            schema: init.schema,
            table: init.table,
            columns: init.columns,
            bytes: init.bytes,
            tasks: init.tasks,
        });
        dialog.connect_inputs();
        dialog.read_preview();
        dialog
    }

    pub(crate) fn connect_import<F: Fn(&Self, CsvImport) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "import",
            false,
            glib::closure_local!(move |dialog: &Self, import: CsvImport| f(dialog, import)),
        )
    }

    fn connect_inputs(&self) {
        let imp = self.imp();
        let dialog = self.downgrade();
        imp.import_button.connect_clicked(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.import();
            }
        });
        let dialog = self.downgrade();
        imp.delimiter_row.connect_selected_notify(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.read_preview();
            }
        });
        let dialog = self.downgrade();
        imp.header_row.connect_active_notify(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.read_preview();
            }
        });
        // The marker decides what imports as NULL, not how the file splits, so the preview stands.
        let dialog = self.downgrade();
        imp.null_row.connect_changed(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.redraw();
            }
        });
    }

    fn read_options(&self) -> CsvImportOptions {
        let imp = self.imp();
        CsvImportOptions {
            delimiter: match imp.delimiter_row.selected() {
                1 => CsvDelimiter::Semicolon,
                2 => CsvDelimiter::Tab,
                3 => CsvDelimiter::Pipe,
                _ => CsvDelimiter::Comma,
            },
            has_header: imp.header_row.is_active(),
            null_marker: imp.null_row.text().to_string(),
        }
    }

    fn reading(&self) -> bool {
        self.imp().sequencer.borrow().is_pending(CsvRequest::PreviewRead)
    }

    // The mapping rows are named after the file's own fields, so a new delimiter or header switch reads it again.
    fn read_preview(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let RequestTicket { stamp, cancel } = imp.sequencer.borrow_mut().issue(CsvRequest::PreviewRead);
        let bytes = parts.bytes.clone();
        let options = self.read_options();
        let reading = parts.tasks.spawn_blocking_task(move || {
            if cancel.is_cancelled() {
                return None;
            }
            Some(read_csv(&bytes, &options, Some(MAX_PREVIEW_ROWS)))
        });
        let dialog = self.downgrade();
        glib::spawn_future_local(async move {
            let read = reading.await;
            if let Some(dialog) = dialog.upgrade() {
                dialog.read_landed(stamp, read);
            }
        });
        self.show_summary();
    }

    fn read_landed(&self, stamp: RequestStamp, read: Result<PreviewRead, TaskFailure>) {
        let preview = match read {
            Ok(Some(Ok(sheet))) => Ok(sheet),
            Ok(Some(Err(error))) => Err(import_error_text(&error)),
            Err(failure) => Err(task_failure_message(&failure)),
            Ok(None) => return,
        };
        let imp = self.imp();
        let current = imp.sequencer.borrow_mut().accept(CsvRequest::PreviewRead, stamp);
        if !current {
            return;
        }
        let (sheet, error) = match preview {
            Ok(sheet) => (sheet, None),
            Err(error) => (CsvSheet::default(), Some(error)),
        };
        imp.sheet.replace(sheet);
        imp.read_error.replace(error);
        self.rebuild_mapping();
        self.show_summary();
    }

    fn rebuild_mapping(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        for row in imp.mapping_rows.take() {
            imp.mapping_group.remove(&row);
        }
        let (choices, suggested) = {
            let sheet = imp.sheet.borrow();
            let labels: Vec<String> = std::iter::once(gettext("Skip"))
                .chain(
                    sheet
                        .headers
                        .iter()
                        .enumerate()
                        .map(|(index, header)| field_label(index, header)),
                )
                .collect();
            let labels: Vec<&str> = labels.iter().map(String::as_str).collect();
            // One list for every row: each row keeps its own selection, and a wide file is held once.
            (
                gtk::StringList::new(&labels),
                suggest_mapping(&sheet.headers, &parts.columns),
            )
        };
        let rows: Vec<adw::ComboRow> = parts
            .columns
            .iter()
            .zip(suggested)
            .map(|(column, field)| self.mapping_row(column, field, &choices))
            .collect();
        for row in &rows {
            imp.mapping_group.add(row);
        }
        imp.mapping_rows.replace(rows);
        self.show_samples();
    }

    fn mapping_row(&self, column: &ImportColumn, field: Option<usize>, choices: &gtk::StringList) -> adw::ComboRow {
        // The subtitle shows values from the file, which may hold & or <.
        let row = adw::ComboRow::builder()
            .use_markup(false)
            .title(column.info.name.as_str())
            .model(choices)
            .sensitive(!column.server_filled)
            .build();
        row.set_selected(field.and_then(|index| u32::try_from(index + 1).ok()).unwrap_or(0));
        let dialog = self.downgrade();
        row.connect_selected_notify(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                dialog.redraw();
            }
        });
        row
    }

    fn redraw(&self) {
        self.show_samples();
        self.show_summary();
    }

    fn show_samples(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        let options = self.read_options();
        let sheet = imp.sheet.borrow();
        let rows = imp.mapping_rows.borrow();
        for ((row, field), column) in rows.iter().zip(self.mapping()).zip(&parts.columns) {
            row.set_subtitle(&match field {
                _ if column.server_filled => gettext("The database fills this column"),
                Some(index) => sample_text(&sheet, index, &options),
                None => gettext("Uses the column's own default"),
            });
        }
    }

    fn blocker(&self) -> Option<String> {
        let imp = self.imp();
        if let Some(error) = imp.read_error.borrow().as_ref() {
            return Some(error.clone());
        }
        if imp.sheet.borrow().rows.is_empty() {
            return Some(gettext("The file has no rows to import."));
        }
        if self.mapping().iter().all(Option::is_none) {
            return Some(gettext(
                "Every column is set to Skip. Pick a field for at least one column to import.",
            ));
        }
        None
    }

    fn show_summary(&self) {
        let imp = self.imp();
        let reading = self.reading();
        let (text, problem) = match (reading, self.blocker()) {
            (true, _) => (gettext("Reading the file…"), false),
            (false, Some(blocker)) => (blocker, true),
            (false, None) => {
                let sheet = imp.sheet.borrow();
                (
                    summary_text(sheet.headers.len(), sheet.rows.len(), sheet.truncated),
                    false,
                )
            }
        };
        imp.import_button.set_sensitive(!reading && !problem);
        let summary = &imp.summary;
        match problem {
            true => {
                summary.remove_css_class("dim-label");
                summary.add_css_class("error");
            }
            false => {
                summary.remove_css_class("error");
                summary.add_css_class("dim-label");
            }
        }
        summary.set_label(&text);
    }

    fn mapping(&self) -> Vec<Option<usize>> {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return Vec::new();
        };
        imp.mapping_rows
            .borrow()
            .iter()
            .zip(&parts.columns)
            .map(|(row, column)| match row.selected() {
                _ if column.server_filled => None,
                0 | gtk::INVALID_LIST_POSITION => None,
                position => usize::try_from(position - 1).ok(),
            })
            .collect()
    }

    fn import(&self) {
        let imp = self.imp();
        let Some(parts) = imp.parts.get() else {
            return;
        };
        if self.reading() || self.blocker().is_some() {
            return;
        }
        let import = CsvImport {
            schema: parts.schema.clone(),
            table: parts.table.clone(),
            columns: parts.columns.clone(),
            mapping: self.mapping(),
            options: self.read_options(),
            bytes: parts.bytes.clone(),
        };
        self.emit_by_name::<()>("import", &[&import]);
        self.close();
    }
}

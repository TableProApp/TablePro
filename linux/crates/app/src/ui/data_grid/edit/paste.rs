use gtk4::prelude::*;
use gtk4::{gdk, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::edit::{CellInput, EditParseError};
use tablepro_core::import::{CsvRowError, ImportError, PastedRows, PastedTable};
use tablepro_core::{ColumnInfo, Value};

use super::{EditController, catalog_columns, edit_start, on_answer, ticket_after};
use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::services::grid::{cell_presets, parse_cell_text};
use crate::ui::data_grid::{DataGrid, PinnedRow};
use crate::ui::error_text::{edit_parse_message, row_error_message};
use crate::ui::format::{format_thousands, plural_count};

/// A paste of more rows asks first: each becomes a pending row, and
/// Import CSV is the tool for a lot of data.
pub(crate) const PASTE_CONFIRM_ROWS: usize = 1_000;

struct PasteRequest {
    ticket: u64,
    /// The cell the paste starts at: one value goes into it, and rows
    /// fill the columns from its column on.
    at: Option<(PinnedRow, usize)>,
    columns: Vec<ColumnInfo>,
    /// The columns values fill one after another, by their place in a
    /// row: as the grid shows them, from the one the paste starts at.
    in_order: Vec<usize>,
}

#[derive(Debug)]
enum PasteOutcome {
    /// No text, or text with no rows in it.
    Nothing,
    /// One value alone, for the cell the paste started at. `None` is a
    /// NULL.
    Value(Option<String>),
    Rows(PastedRows),
    Unreadable(ImportError),
    Refused(CsvRowError),
    /// Reading failed in a way the user can only retry.
    Failed,
    /// More than a paste reads at once.
    TooLarge,
}

/// The cells a grid copy offers beside its text, or text alone.
#[derive(Debug)]
enum PasteSource {
    Cells(Vec<u8>),
    Text(String),
}

impl EditController {
    pub(super) fn paste(&self, grid: &DataGrid) {
        if self.policy().is_none_or(|policy| policy.paste.is_err()) {
            return;
        }
        let (Some(columns), Some(config)) = (catalog_columns(grid), grid.config()) else {
            tracing::debug!("a paste reached a grid with a column the catalogue does not know");
            return;
        };
        if columns.is_empty() {
            return;
        }
        let at = grid
            .target()
            .and_then(|target| target.cell)
            .map(|(row, column)| (row.pin(), column));
        let in_order = columns_from(grid, at.as_ref().map(|(_, column)| *column));
        let request = PasteRequest {
            ticket: ticket_after(&self.paste_ticket),
            at,
            columns,
            in_order,
        };
        let tasks = config.tasks.clone();
        let clipboard = grid.clipboard();
        let weak = grid.downgrade();
        glib::spawn_future_local(async move {
            let outcome = match read_clipboard(&clipboard).await {
                Ok(source) => {
                    let (columns, in_order, at_cell) =
                        (request.columns.clone(), request.in_order.clone(), request.at.is_some());
                    tasks
                        .spawn_blocking_task(move || read_pasted(&source, &columns, &in_order, at_cell))
                        .await
                        .unwrap_or_else(|failure| {
                            tracing::warn!(%failure, "pasted text could not be read");
                            PasteOutcome::Failed
                        })
                }
                Err(outcome) => outcome,
            };
            if let Some(grid) = weak.upgrade() {
                grid.edit().paste_read(&grid, request, outcome);
            }
        });
    }

    fn paste_read(&self, grid: &DataGrid, request: PasteRequest, outcome: PasteOutcome) {
        if request.ticket != self.paste_ticket.get() {
            return;
        }
        if catalog_columns(grid).as_ref() != Some(&request.columns) {
            grid.toast(changed_while_pasting());
            return;
        }
        match outcome {
            PasteOutcome::Nothing => grid.toast(gettext("The clipboard has no rows to paste.")),
            PasteOutcome::Failed => grid.toast(gettext("Couldn't read the clipboard.")),
            PasteOutcome::TooLarge => grid.toast(gettext(
                "The clipboard holds too much to paste. Import CSV takes large amounts of data.",
            )),
            PasteOutcome::Unreadable(error) => self.alert(grid, &gettext("Couldn't Paste"), &unreadable_text(&error)),
            PasteOutcome::Refused(error) => self.alert(grid, &gettext("Couldn't Paste"), &row_error_message(&error)),
            PasteOutcome::Value(text) => match request.at {
                Some(at) => self.paste_value(grid, at, text.as_deref()),
                None => tracing::error!("a single value came back for a paste with no cell"),
            },
            PasteOutcome::Rows(rows) if rows.rows.len() > PASTE_CONFIRM_ROWS => {
                self.confirm_paste(grid, rows, request.columns);
            }
            PasteOutcome::Rows(rows) => self.insert_pasted(grid, rows),
        }
    }

    /// One value goes into the cell as if typed there, and a NULL as Set
    /// to NULL puts it.
    fn paste_value(&self, grid: &DataGrid, at: (PinnedRow, usize), text: Option<&str>) {
        let (pinned, column) = at;
        let Some(row) = pinned.get().cloned() else {
            grid.toast(changed_while_pasting());
            return;
        };
        let Some(grid_column) = grid.grid_columns().get(column).cloned() else {
            return;
        };
        if let Some(lock) = self.tracked().lock(&grid_column, &row) {
            grid.toast(lock.explanation(edit_parse_message));
            return;
        }
        let Some(catalog) = grid_column.catalog.as_ref() else {
            return;
        };
        let dialect = grid.sql_dialect();
        let input = match text {
            None if cell_presets(&grid_column, &row.id(), dialect.as_deref()).null => Ok(CellInput::Value(Value::Null)),
            None => Err(EditParseError::Required),
            Some(text) => parse_cell_text(text, catalog, &row.id(), dialect.as_deref()),
        };
        match input {
            Ok(input) => {
                grid.commit_editors();
                let start = edit_start(&self.tracked(), &row, column);
                self.commit_input(grid, &grid_column, &start, input);
            }
            Err(error) => grid.toast(edit_parse_message(&error)),
        }
    }

    fn insert_pasted(&self, grid: &DataGrid, pasted: PastedRows) {
        let PastedRows { rows, skipped } = pasted;
        let count = rows.len();
        if count == 0 {
            grid.toast(gettext("The clipboard has no rows to paste."));
            return;
        }
        if self.insert_drafts(grid, rows).is_none() {
            return;
        }
        self.select_top_rows_soon(grid, u32::try_from(count).unwrap_or(u32::MAX));
        let n = count as u64;
        grid.toast(ngettext_f(
            "Pasted {n} row",
            "Pasted {n} rows",
            plural_count(n),
            &[("n", &format_thousands(n))],
        ));
        if skipped > 0 {
            let n = skipped as u64;
            grid.toast(ngettext_f(
                "Left out {n} value no column could take",
                "Left out {n} values no column could take",
                plural_count(n),
                &[("n", &format_thousands(n))],
            ));
        }
    }

    fn confirm_paste(&self, grid: &DataGrid, rows: PastedRows, columns: Vec<ColumnInfo>) {
        let count = rows.rows.len() as u64;
        let title = ngettext_f(
            "Paste {n} Row?",
            "Paste {n} Rows?",
            plural_count(count),
            &[("n", &format_thousands(count))],
        );
        let body = gettext(
            "Each one is added as a new row that waits until you save. Import CSV, in the table's menu in the sidebar, writes large amounts of data straight to the table.",
        );
        let dialog = adw::AlertDialog::new(Some(&title), Some(&body));
        dialog.add_response("cancel", &gettext("Cancel"));
        dialog.add_response("paste", &gettext("Paste"));
        dialog.set_response_appearance("paste", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("paste"));
        dialog.set_close_response("cancel");
        let ticket = self.ask(&dialog);
        on_answer(grid, dialog, ticket, move |grid, response| {
            if response != "paste" {
                return;
            }
            if catalog_columns(grid).as_ref() != Some(&columns) {
                grid.toast(changed_while_pasting());
                return;
            }
            grid.edit().insert_pasted(grid, rows);
        });
    }
}

/// The columns as the grid shows them, left to right after any drag of
/// a header, from `start` on.
fn columns_from(grid: &DataGrid, start: Option<usize>) -> Vec<usize> {
    let shown = grid.shown_columns();
    let first = start
        .and_then(|start| shown.iter().position(|index| *index == start))
        .unwrap_or_default();
    shown.get(first..).unwrap_or_default().to_vec()
}

/// What the clipboard holds: the cells a grid copy offers, which keep
/// each value and NULL as they were, or else its text. Either is read
/// only up to the import's limit, since another program's clipboard can
/// hold anything.
async fn read_clipboard(clipboard: &gdk::Clipboard) -> Result<PasteSource, PasteOutcome> {
    use crate::ui::clipboard::CELLS_MIME_TYPE;
    use crate::ui::file_read::{FileReadError, read_capped};

    let cells = clipboard.formats().contain_mime_type(CELLS_MIME_TYPE);
    let wanted: &[&str] = match cells {
        true => &[CELLS_MIME_TYPE],
        false => &["text/plain;charset=utf-8", "text/plain"],
    };
    let stream = match clipboard.read_future(wanted, glib::Priority::DEFAULT).await {
        Ok((stream, _)) => stream,
        Err(error) => {
            tracing::debug!(%error, "the clipboard holds nothing to paste");
            return Err(PasteOutcome::Nothing);
        }
    };
    let bytes = match read_capped(&stream, tablepro_core::import::MAX_CSV_FILE_BYTES).await {
        Ok(bytes) => bytes,
        Err(FileReadError::TooLarge) => return Err(PasteOutcome::TooLarge),
        Err(error) => {
            tracing::warn!(?error, "the clipboard could not be read");
            return Err(PasteOutcome::Failed);
        }
    };
    match cells {
        true => Ok(PasteSource::Cells(bytes)),
        false => String::from_utf8(bytes).map(PasteSource::Text).map_err(|error| {
            PasteOutcome::Unreadable(ImportError::NotUtf8 {
                offset: error.utf8_error().valid_up_to(),
            })
        }),
    }
}

/// Read what the clipboard held against `columns`. With a cell to start
/// at, one value alone is that cell's.
fn read_pasted(source: &PasteSource, columns: &[ColumnInfo], in_order: &[usize], at_cell: bool) -> PasteOutcome {
    let read = match source {
        PasteSource::Cells(json) => PastedTable::from_cells(json),
        PasteSource::Text(text) => PastedTable::read(text),
    };
    let table = match read {
        Ok(table) => table,
        Err(error) => return PasteOutcome::Unreadable(error),
    };
    if table.is_empty() {
        return PasteOutcome::Nothing;
    }
    if table.too_large_for(columns.len()) {
        return PasteOutcome::TooLarge;
    }
    if at_cell && let Some(value) = table.single_value() {
        return PasteOutcome::Value(value.map(str::to_owned));
    }
    match table.rows(columns, in_order) {
        Ok(rows) => PasteOutcome::Rows(rows),
        Err(error) => PasteOutcome::Refused(error),
    }
}

fn changed_while_pasting() -> String {
    gettext("The table changed while pasting. Paste again.")
}

fn unreadable_text(error: &ImportError) -> String {
    match error {
        ImportError::TooManyFields { line, limit } => gettext_f(
            "Line {line} of the pasted text has more than {limit} values, more than any table holds.",
            &[("line", &line.to_string()), ("limit", &limit.to_string())],
        ),
        ImportError::NotUtf8 { .. } | ImportError::Malformed { .. } | ImportError::NoColumns => {
            gettext("The pasted text couldn't be read as rows.")
        }
    }
}

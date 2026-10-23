use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::edit::parse_edit_text;
use tablepro_core::import::{ImportError, PastedRows};

use super::confirming_paste::ConfirmingPaste;
use super::paste_at::PasteAt;
use super::paste_read::{PasteOutcome, PasteRead, PasteRequest};
use super::{BrowseModel, BrowseTabOutput, ClipboardInput, EditInput, Effects};
use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::services::change_tracker::pk_identity;
use crate::services::tracker_edit::TrackerEdit;
use crate::ui::format::{format_thousands, plural_count};
use crate::ui::grid::{
    CellPreset, CommitResult, EditSnapshot, GridCell, cell_editability, commit_input, data_columns, edit_context,
    select_top_rows,
};

/// A paste of more rows asks first: each becomes a pending row, and
/// Import CSV is the tool for a lot of data.
pub(crate) const PASTE_CONFIRM_ROWS: usize = 1_000;

impl BrowseModel {
    pub(super) fn paste(&mut self, at: Option<PasteAt>, fx: &mut Effects) {
        if self.read_only {
            fx.output(BrowseTabOutput::ShowToast(gettext("This connection is read-only.")));
            return;
        }
        if self.current_columns.is_empty() || self.grid_is_stale() {
            return;
        }
        if !self.has_primary_key() {
            fx.output(BrowseTabOutput::ShowToast(gettext(
                "Rows can only be pasted into a table with a primary key.",
            )));
            return;
        }
        self.next_paste += 1;
        let in_order = self.columns_from(at.as_ref().map(|at| at.column));
        fx.output(BrowseTabOutput::ReadClipboard(PasteRequest {
            ticket: self.next_paste,
            at,
            columns: self.current_columns.clone(),
            in_order,
        }));
    }

    /// The columns as the grid shows them, left to right after any drag
    /// of a header, from `start` on, each by its place in a row.
    fn columns_from(&self, start: Option<usize>) -> Vec<usize> {
        let Some(view) = self.current_column_view.as_ref() else {
            return Vec::new();
        };
        let shown: Vec<usize> = data_columns(view)
            .iter()
            .filter(|column| column.is_visible())
            .filter_map(|column| self.view_columns.iter().position(|cell_column| cell_column == column))
            .collect();
        let first = start
            .and_then(|start| shown.iter().position(|index| *index == start))
            .unwrap_or_default();
        shown.get(first..).unwrap_or_default().to_vec()
    }

    pub(super) fn focused_cell(&self) -> Option<PasteAt> {
        let view = self.current_column_view.as_ref()?;
        let window = view.root().and_downcast::<gtk::Window>()?;
        let focus = gtk::prelude::GtkWindowExt::focus(&window)?;
        if !focus.is_ancestor(view) {
            return None;
        }
        let cell = GridCell::from_focus(&focus)?;
        Some(PasteAt {
            row: cell.row()?,
            column: cell.column(),
        })
    }

    pub(super) fn paste_read(&mut self, read: PasteRead, fx: &mut Effects) {
        let PasteRead { request, outcome } = read;
        if request.ticket != self.next_paste {
            return;
        }
        if request.columns != self.current_columns || self.grid_is_stale() {
            fx.output(BrowseTabOutput::ShowToast(gettext(
                "The table changed while pasting. Paste again.",
            )));
            return;
        }
        match outcome {
            PasteOutcome::Nothing => {
                fx.output(BrowseTabOutput::ShowToast(gettext(
                    "The clipboard has no rows to paste.",
                )));
            }
            PasteOutcome::Failed => fx.output(BrowseTabOutput::ShowToast(gettext("Couldn't read the clipboard."))),
            PasteOutcome::TooLarge => fx.output(BrowseTabOutput::ShowToast(gettext(
                "The clipboard holds too much to paste. Import CSV takes large amounts of data.",
            ))),
            PasteOutcome::Unreadable(error) => paste_alert(unreadable_text(&error), fx),
            PasteOutcome::Refused(error) => paste_alert(crate::ui::error_text::row_error_message(&error), fx),
            PasteOutcome::Value(text) => match request.at {
                Some(at) => self.paste_value(at, text.as_deref(), fx),
                None => tracing::error!("a single value came back for a paste with no cell"),
            },
            PasteOutcome::Rows(rows) if rows.rows.len() > PASTE_CONFIRM_ROWS => self.confirm_paste(rows),
            PasteOutcome::Rows(rows) => self.insert_pasted(rows, fx),
        }
    }

    /// One value goes into the cell, as if typed there, and a NULL as
    /// Set to NULL puts it.
    fn paste_value(&mut self, at: PasteAt, text: Option<&str>, fx: &mut Effects) {
        let PasteAt { row, column } = at;
        // A page read while the clipboard answered replaces the row's
        // object, and the old one holds the values it had then.
        let Some(row) = row.id().tracker_key().and_then(|key| self.row_index.get(&key)) else {
            fx.output(BrowseTabOutput::ShowToast(gettext(
                "The table changed while pasting. Paste again.",
            )));
            return;
        };
        let Some(info) = self.current_columns.get(column) else {
            return;
        };
        if let Err(lock) = cell_editability(info, row.id(), &pk_identity(&self.current_columns), self.read_only) {
            fx.output(BrowseTabOutput::ShowToast(lock.explanation()));
            return;
        }
        let Some(text) = text else {
            fx.input(EditInput::GridSetCellValue {
                row,
                column,
                preset: CellPreset::Null,
            });
            return;
        };
        let input = match parse_edit_text(text, info, edit_context(row.id())) {
            Ok(input) => input,
            Err(error) => {
                return fx.output(BrowseTabOutput::ShowToast(crate::ui::error_text::edit_parse_message(
                    &error,
                )));
            }
        };
        // As a typed edit commits, so a value equal to the cell's, in
        // the spelling the column keeps, changes nothing.
        let snapshot = EditSnapshot {
            original: self.grid_context().edit_input(&row, column),
            row,
            column,
        };
        match commit_input(info, &snapshot, input) {
            CommitResult::Edit(edit) => self.apply_edit(edit, fx),
            CommitResult::Unchanged => {}
            CommitResult::Rejected(message) => fx.output(BrowseTabOutput::ShowToast(message)),
        }
    }

    fn insert_pasted(&mut self, pasted: PastedRows, fx: &mut Effects) {
        let PastedRows { rows, skipped } = pasted;
        let count = rows.len();
        if count == 0 {
            fx.output(BrowseTabOutput::ShowToast(gettext(
                "The clipboard has no rows to paste.",
            )));
            return;
        }
        self.apply_edit(TrackerEdit::InsertDrafts { rows }, fx);
        fx.input(EditInput::SelectPastedDrafts(u32::try_from(count).unwrap_or(u32::MAX)));
        let n = count as u64;
        fx.output(BrowseTabOutput::ShowToast(ngettext_f(
            "Pasted {n} row",
            "Pasted {n} rows",
            plural_count(n),
            &[("n", &format_thousands(n))],
        )));
        if skipped > 0 {
            let n = skipped as u64;
            fx.output(BrowseTabOutput::ShowToast(ngettext_f(
                "Left out {n} value no column could take",
                "Left out {n} values no column could take",
                plural_count(n),
                &[("n", &format_thousands(n))],
            )));
        }
    }

    /// Select the rows a paste added, which sit on top, once the grid
    /// has drawn them.
    pub(super) fn select_pasted_drafts(&self, count: u32) {
        let Some(view) = self.current_column_view.clone() else {
            return;
        };
        glib::idle_add_local_once(move || {
            if view.is_mapped() {
                select_top_rows(&view, count);
            }
        });
    }

    fn confirm_paste(&mut self, rows: PastedRows) {
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
        if let Some(pending) = self.confirming_paste.take() {
            pending.dialog.force_close();
        }
        let ticket = self.next_paste;
        let tab = self.this.clone();
        dialog.connect_response(None, move |_, response| {
            if let Some(tab) = tab.upgrade() {
                tab.send(ClipboardInput::PasteAnswered {
                    ticket,
                    confirmed: response == "paste",
                });
            }
        });
        dialog.present(Some(&self.widgets.inner_stack));
        self.confirming_paste = Some(ConfirmingPaste {
            ticket,
            rows,
            columns: self.current_columns.clone(),
            dialog,
        });
    }

    pub(super) fn paste_answered(&mut self, ticket: u64, confirmed: bool, fx: &mut Effects) {
        if self
            .confirming_paste
            .as_ref()
            .is_none_or(|pending| pending.ticket != ticket)
        {
            return;
        }
        let Some(pending) = self.confirming_paste.take() else {
            return;
        };
        if !confirmed {
            return;
        }
        if pending.columns != self.current_columns {
            fx.output(BrowseTabOutput::ShowToast(gettext(
                "The table changed while pasting. Paste again.",
            )));
            return;
        }
        self.insert_pasted(pending.rows, fx);
    }
}

fn paste_alert(body: String, fx: &mut Effects) {
    fx.output(BrowseTabOutput::ShowSelectionAlert {
        title: gettext("Couldn't Paste"),
        body,
    });
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

//! Every change a grid makes to its rows: the inline editor, toggles,
//! presets, new and duplicated rows, deletes, pastes, undo and redo.
//! Each goes through the tracker, and each delta reaches the store here.

mod actions;
mod cell_editor;
mod deletion;
mod paste;
mod row_edits;
#[cfg(test)]
mod tests;

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::{ColumnInfo, Value};

use self::cell_editor::OpenEdit;
pub(crate) use self::deletion::BULK_DELETE_CONFIRM_THRESHOLD;
use super::selection::Resolved;
use super::{DataGrid, EditRules, GridCell, GridRequest, GridRow, PinnedRow, RowData, TrackedValues};
use crate::i18n::gettext;
use crate::services::grid::{CommitResult, EditPolicy, EditRefusal, EditStart};
use crate::services::tracker_delta::TrackerDelta;
use crate::services::tracker_edit::TrackerEdit;

#[derive(Debug, Default)]
pub struct EditController {
    grid: glib::WeakRef<DataGrid>,
    tracked: RefCell<TrackedValues>,
    policy: Cell<Option<EditPolicy>>,
    open: RefCell<Option<Rc<OpenEdit>>>,
    edits_opened: Cell<u64>,
    /// Only the latest paste lands: another program's clipboard can take
    /// any time to answer, or never.
    paste_ticket: Cell<u64>,
    question: RefCell<Option<Question>>,
    questions_asked: Cell<u64>,
    #[cfg(test)]
    alerts: RefCell<Vec<String>>,
}

/// A bulk delete or a large paste waiting for the user's answer.
#[derive(Debug)]
struct Question {
    ticket: u64,
    dialog: adw::AlertDialog,
}

impl EditController {
    pub fn attach(&self, grid: &DataGrid) {
        self.grid.set(Some(grid));
    }

    /// A grid edits only with a tracker and the rules of its column set.
    pub fn set_rules(&self, grid: &DataGrid, rules: Option<EditRules>) {
        let tracker = grid.config().and_then(|config| config.tracker.clone());
        let (tracked, policy) = match (tracker, rules) {
            (Some(tracker), Some(rules)) => {
                let read_only = rules.policy.cells == Err(EditRefusal::ReadOnly);
                let tracked = TrackedValues::tracked(tracker, rules.identity).on_read_only_connection(read_only);
                (tracked, Some(rules.policy))
            }
            _ => (TrackedValues::untracked(), None),
        };
        self.tracked.replace(tracked);
        self.policy.set(policy);
    }

    pub fn tracked(&self) -> TrackedValues {
        self.tracked.borrow().clone()
    }

    /// The tracker keeps drafts bottom up, and the newest shows on top.
    pub fn draft_rows(&self) -> Vec<RowData> {
        self.tracked()
            .tracker()
            .map(|tracker| {
                tracker
                    .drafts()
                    .iter()
                    .rev()
                    .map(|draft| RowData::draft(draft.draft_id))
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn install_actions(&self, grid: &DataGrid) {
        actions::install(grid);
    }

    pub fn refresh_actions(&self, grid: &DataGrid, target: Option<&Resolved>) {
        actions::refresh(self, grid, target);
    }

    /// Bring the store in line with a tracker change: drafts come or go,
    /// and each changed row draws again in its own slot.
    pub fn apply_delta(&self, delta: &TrackerDelta) {
        let Some(grid) = self.grid.upgrade() else {
            return;
        };
        if !delta.inserted_drafts.is_empty() || !delta.removed_drafts.is_empty() {
            grid.commit_editors();
        }
        let store = grid.store();
        store.remove_drafts(&delta.removed_drafts);
        store.insert_drafts(&delta.inserted_drafts);
        for key in &delta.changed {
            if let Some(row) = store.row_for(key) {
                row.bump_revision();
            }
        }
        grid.show_rows_or_empty();
        grid.refresh_actions();
        grid.request(GridRequest::PendingChanged);
    }

    pub fn undo(&self) {
        self.step(|tracked| tracked.tracker().and_then(|tracker| tracker.undo()));
    }

    pub fn redo(&self) {
        self.step(|tracked| tracked.tracker().and_then(|tracker| tracker.redo()));
    }

    pub fn discard(&self) {
        self.step(|tracked| tracked.tracker().map(|tracker| tracker.discard()));
    }

    /// What was typed counts first, so an undo takes back the latest
    /// change, typed text included.
    fn step(&self, change: impl FnOnce(&TrackedValues) -> Option<TrackerDelta>) {
        let Some(grid) = self.grid.upgrade() else {
            return;
        };
        grid.commit_editors();
        if let Some(delta) = change(&self.tracked()) {
            self.apply_delta(&delta);
        }
    }

    /// Commit `typed` as an edit of the cell `row` and `column` name, as
    /// the detail pane's editor does. `None` when nothing was committed:
    /// the row left its slot, or the cell is locked now.
    pub fn commit_value(&self, row: &PinnedRow, column: usize, start: &EditStart, typed: &str) -> Option<CommitResult> {
        let grid = self.grid.upgrade()?;
        let result = self.evaluate(&grid, row, column, start, typed)?;
        if let CommitResult::Edit(edit) = &result {
            self.apply_edit(&grid, edit.clone());
        }
        Some(result)
    }

    fn policy(&self) -> Option<EditPolicy> {
        self.policy.get()
    }

    /// Every tracker write but undo, redo and discard goes through here.
    fn apply_edit(&self, grid: &DataGrid, edit: TrackerEdit) {
        let Some(tracker) = self.tracked().tracker().cloned() else {
            return;
        };
        if tracker.refuses(&edit) {
            grid.toast(gettext(
                "This row is being saved. Change it again once the save finishes.",
            ));
        }
        let delta = tracker.apply(edit);
        self.apply_delta(&delta);
    }

    /// Ask `dialog`, replacing a question still open.
    fn ask(&self, dialog: &adw::AlertDialog) -> u64 {
        let ticket = ticket_after(&self.questions_asked);
        let previous = self.question.replace(Some(Question {
            ticket,
            dialog: dialog.clone(),
        }));
        if let Some(previous) = previous {
            previous.dialog.force_close();
        }
        ticket
    }

    /// Whether `ticket` is still the open question, which it then no
    /// longer is.
    fn answered(&self, ticket: u64) -> bool {
        let current = self
            .question
            .borrow()
            .as_ref()
            .is_some_and(|question| question.ticket == ticket);
        if current {
            self.question.take();
        }
        current
    }

    /// A dismiss-only alert, for what a toast is too short to say.
    fn alert(&self, grid: &DataGrid, title: &str, body: &str) {
        #[cfg(test)]
        self.alerts.borrow_mut().push(format!("{title}: {body}"));
        let dialog = adw::AlertDialog::new(Some(title), Some(body));
        dialog.add_response("close", &gettext("Close"));
        dialog.set_default_response(Some("close"));
        dialog.set_close_response("close");
        dialog.present(Some(grid));
    }

    #[cfg(test)]
    pub(crate) fn question(&self) -> Option<adw::AlertDialog> {
        self.question.borrow().as_ref().map(|question| question.dialog.clone())
    }

    #[cfg(test)]
    pub(crate) fn take_alerts(&self) -> Vec<String> {
        self.alerts.take()
    }
}

/// Each column's catalogue entry, in row order. `None` when one is
/// missing: a paste or a delete check needs every column.
fn catalog_columns(grid: &DataGrid) -> Option<Vec<ColumnInfo>> {
    grid.grid_columns()
        .iter()
        .map(|column| column.catalog.clone())
        .collect()
}

/// The cell as it stands now, for an edit that begins now.
fn edit_start(tracked: &TrackedValues, row: &GridRow, column: usize) -> EditStart {
    EditStart {
        row: row.id(),
        read: row
            .cells()
            .and_then(|cells| cells.get(column).cloned())
            .unwrap_or(Value::Null),
        original: tracked.edit_input(row, column),
    }
}

/// The widget a cell action works on: the focused cell when it shows
/// `row` and `column`, else that cell, focused.
fn cell_widget(grid: &DataGrid, row: &GridRow, column: usize) -> Option<GridCell> {
    if let Some(cell) = grid.focused_cell()
        && cell.row().as_ref() == Some(row)
        && cell.column() == column
    {
        return Some(cell);
    }
    grid.focus_cell(grid.view_position(row)?, column)
}

fn ticket_after(counter: &Cell<u64>) -> u64 {
    let ticket = counter.get().wrapping_add(1);
    counter.set(ticket);
    ticket
}

/// Present `dialog` on the grid and hand its answer to `answer` once the
/// grid still holds the question.
fn on_answer(grid: &DataGrid, dialog: adw::AlertDialog, ticket: u64, answer: impl FnOnce(&DataGrid, &str) + 'static) {
    let parent: gtk::Widget = grid.clone().upcast();
    let weak = grid.downgrade();
    glib::spawn_future_local(async move {
        let response = crate::workspace::respond(&dialog, &parent).await;
        drop(parent);
        if let Some(grid) = weak.upgrade()
            && grid.edit().answered(ticket)
        {
            answer(&grid, &response);
        }
    });
}

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, gdk, glib};
use tablepro_core::edit::{CellInput, EditParseError, EditText, edit_text};

use super::{EditController, edit_start, ticket_after};
use crate::application::component_matches;
use crate::i18n::{gettext, gettext_f};
use crate::services::grid::{
    CellEditorKind, CommitResult, EDIT_MAX_BYTES, EditDirection, EditStart, GridColumn, TextPurpose, commit_edit,
    empty_placeholder, next_edit_target,
};
use crate::ui::data_grid::grid_cell::holds_window_focus;
use crate::ui::data_grid::{DataGrid, GridCell, GridRow, PinnedRow};
use crate::ui::error_text::edit_parse_message;

/// The inline editor open in a cell, and the edit it holds. The edit
/// names its row by a pin, so it commits to the row it opened on
/// whatever the cell shows by then.
#[derive(Debug)]
pub(super) struct OpenEdit {
    id: u64,
    cell: glib::WeakRef<GridCell>,
    row: PinnedRow,
    column: usize,
    start: EditStart,
    text: gtk::Text,
    /// An input method is composing in the field.
    composing: Cell<bool>,
    /// The focus left mid-composition, so the commit waits for the end.
    commit_when_composed: Cell<bool>,
}

/// What editing a cell comes to.
pub(super) enum Plan {
    Inline(Box<InlineStart>),
    /// A menu of the column's labels. Typing, Tab and a new row edit its
    /// text in place instead, where it fits a one-line editor.
    Choice {
        start: Box<InlineStart>,
        in_place: bool,
    },
    Toggle,
    /// The value is edited in the detail pane.
    Details,
    /// Nothing opens, for this reason.
    Refused(String),
    Locked,
}

pub(super) struct InlineStart {
    pub(super) column: GridColumn,
    pub(super) row: GridRow,
    pub(super) start: EditStart,
    text: String,
    accepts_line_breaks: bool,
    purpose: TextPurpose,
}

impl Plan {
    /// Where the cell's text can be edited in place.
    pub(super) fn in_place(self) -> Option<Box<InlineStart>> {
        match self {
            Self::Inline(start) | Self::Choice { start, in_place: true } => Some(start),
            Self::Choice { in_place: false, .. } | Self::Toggle | Self::Details | Self::Refused(_) | Self::Locked => {
                None
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Opened {
    /// The whole value, selected, so the first key replaces it.
    ToEdit,
    /// Empty, for the key that opened it to land in.
    ByTyping,
}

/// How a commit treats a value the column refuses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Refusal {
    /// The editor stays open with the text (D7).
    Keep,
    /// Before a reload, a save or a close: the value was never pending,
    /// so it goes.
    Drop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CloseWhen {
    Now,
    /// Hidden now, out of the cell once the main loop is idle. GTK 4.22
    /// ends a focus change by walking up from the widget that lost the
    /// focus and loops forever when that widget has no parent by then.
    AfterFocusChange,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ended {
    Closed,
    Kept,
    Nothing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum EditorKey {
    Cancel,
    /// Commit, then edit the next editable cell that way.
    Move(EditDirection),
}

impl EditController {
    /// Edit `cell` the way its column and value call for. `false` for a
    /// locked cell, whose value the caller shows in the detail pane.
    pub fn edit_cell(&self, cell: &GridCell) -> bool {
        let (Some(grid), Some(row)) = (self.grid.upgrade(), cell.row()) else {
            return false;
        };
        if let Some(edit) = self.open_in(cell) {
            edit.text.grab_focus();
            return true;
        }
        match self.plan(&grid, &row, cell.column()) {
            Plan::Locked => false,
            Plan::Refused(why) => {
                grid.toast(why);
                true
            }
            Plan::Toggle => {
                self.toggle(&grid, &row, cell.column());
                true
            }
            Plan::Details => {
                grid.show_details_for(cell.column());
                true
            }
            Plan::Inline(start) => {
                self.open_inline(&grid, cell, start, Opened::ToEdit);
                true
            }
            Plan::Choice { start, .. } => {
                self.open_choice(&grid, cell, &start);
                true
            }
        }
    }

    /// Open an empty editor on the focused cell for a typed key, when
    /// the cell edits inline.
    pub fn open_for_typing(&self) -> Option<gtk::Text> {
        let grid = self.grid.upgrade()?;
        let cell = grid.focused_cell()?;
        if self.open_in(&cell).is_some() {
            return None;
        }
        match self.plan(&grid, &cell.row()?, cell.column()) {
            Plan::Refused(why) => {
                grid.toast(why);
                None
            }
            plan => plan
                .in_place()
                .map(|start| self.open_inline(&grid, &cell, start, Opened::ByTyping)),
        }
    }

    /// Commit the open edit, as Return does, before the grid writes its
    /// slots or a save reads the tracker.
    pub fn commit_open_edit(&self) {
        let held = self.editor_has_focus();
        let cell = self.open_cell();
        if self.commit_open(Refusal::Drop, CloseWhen::Now) == Ended::Closed && held {
            self.return_focus(cell.as_ref());
        }
    }

    pub fn cancel_open_edit(&self) {
        let held = self.editor_has_focus();
        let cell = self.open_cell();
        if self.cancel_open() && held {
            self.return_focus(cell.as_ref());
        }
    }

    /// A cell given another row while its editor is open commits the
    /// edit to the row it opened on.
    pub fn cell_unbinding(&self, cell: &GridCell) {
        if self.open_in(cell).is_some() {
            self.commit_open(Refusal::Drop, CloseWhen::Now);
        }
    }

    /// GTK detaches a removed row before it unbinds it, and moves a focus
    /// left inside only after the next frame; a window focus-in between
    /// the two crashes GTK 4.22 on the detached row. So the focus goes
    /// before the edit ends, and the grid takes it back after the frame.
    pub fn cell_detaching(&self, cell: &GridCell) {
        let window = cell.root().and_downcast::<gtk::Window>();
        let held = window
            .as_ref()
            .and_then(gtk::prelude::GtkWindowExt::focus)
            .is_some_and(|focus| row_holds(cell, &focus));
        let editing = self.open_in(cell).is_some();
        if !held && !editing {
            return;
        }
        // Out of the slot first, so the focus leaving finds no edit to
        // commit on its own.
        let edit = editing.then(|| self.open.take()).flatten();
        if let Some(window) = window.as_ref().filter(|_| held) {
            gtk::prelude::GtkWindowExt::set_focus(window, None::<&gtk::Widget>);
        }
        if let Some(edit) = edit {
            self.open.replace(Some(edit));
            // Not out of a cell GTK is unrooting: the field goes once
            // the unroot is over.
            self.commit_open(Refusal::Drop, CloseWhen::AfterFocusChange);
        }
        if let (Some(window), true, Some(grid)) = (window, held, self.grid.upgrade()) {
            grab_after_paint(&window, &grid.column_view());
        }
    }

    pub(super) fn plan(&self, grid: &DataGrid, row: &GridRow, index: usize) -> Plan {
        let (Some(column), Some(policy)) = (grid.grid_columns().get(index).cloned(), self.policy()) else {
            return Plan::Locked;
        };
        if policy.cells.is_err() {
            return Plan::Locked;
        }
        let tracked = self.tracked();
        let kind = CellEditorKind::for_cell(&column, tracked.lock(&column, row).map_or(Ok(()), Err));
        let (accepts_line_breaks, purpose) = match kind {
            CellEditorKind::ReadOnly(_) => return Plan::Locked,
            CellEditorKind::Toggle => return Plan::Toggle,
            CellEditorKind::Details(_) => return Plan::Details,
            CellEditorKind::Choice => (false, TextPurpose::FreeForm),
            CellEditorKind::Inline {
                accepts_line_breaks,
                purpose,
            } => (accepts_line_breaks, purpose),
        };
        let start = edit_start(&tracked, row, index);
        // From the whole value with any pending edit, never from the text
        // the cell draws, which is cut short or stands in for the value.
        let text = match &start.original {
            CellInput::Value(value) => edit_text(value, column.value_type()),
            CellInput::Default => EditText::Editable(String::new()),
        };
        let refusal = match &text {
            EditText::ReadOnly(reason) => {
                return Plan::Refused(edit_parse_message(&EditParseError::NotEditable(*reason)));
            }
            // A GTK editor holds text only up to a NUL, and committing it
            // would cut the value there.
            EditText::Editable(editable) if editable.contains('\0') => {
                Some(gettext("Values with a NUL character can't be edited here"))
            }
            EditText::Editable(editable) if editable.len() > EDIT_MAX_BYTES => Some(too_large_to_edit()),
            EditText::Editable(_) => None,
        };
        let one_line = CellEditorKind::Inline {
            accepts_line_breaks,
            purpose,
        };
        let in_place = refusal.is_none() && matches!(one_line.for_text(&text), CellEditorKind::Inline { .. });
        let EditText::Editable(text) = text else {
            return Plan::Locked;
        };
        let start = Box::new(InlineStart {
            column,
            row: row.clone(),
            start,
            text,
            accepts_line_breaks,
            purpose,
        });
        match (kind, refusal) {
            // The menu holds no text, so any value opens it.
            (CellEditorKind::Choice, _) => Plan::Choice { start, in_place },
            (_, Some(why)) => Plan::Refused(why),
            _ if in_place => Plan::Inline(start),
            _ => Plan::Details,
        }
    }

    /// Edit `cell`'s text in place, as Tab and a new row do, a cell that
    /// picks from a menu included.
    pub(super) fn edit_in_place(&self, cell: &GridCell) {
        let (Some(grid), Some(row)) = (self.grid.upgrade(), cell.row()) else {
            return;
        };
        if self.open_in(cell).is_some() {
            return;
        }
        if let Some(start) = self.plan(&grid, &row, cell.column()).in_place() {
            self.open_inline(&grid, cell, start, Opened::ToEdit);
        }
    }

    fn open_inline(&self, grid: &DataGrid, cell: &GridCell, plan: Box<InlineStart>, opened: Opened) -> gtk::Text {
        self.commit_open(Refusal::Drop, CloseWhen::Now);
        let text = gtk::Text::new();
        text.set_hexpand(true);
        text.set_truncate_multiline(!plan.accepts_line_breaks);
        text.set_input_purpose(input_purpose(plan.purpose));
        text.set_placeholder_text(empty_placeholder(&plan.column, &plan.start.row).as_deref());
        if opened == Opened::ToEdit {
            text.set_text(&plan.text);
        }
        // The header that names the column takes no focus, and Tab moves
        // an edit across columns.
        text.update_property(&[gtk::accessible::Property::Label(&plan.column.name)]);
        cell.open_editor(&text);
        let id = ticket_after(&self.edits_opened);
        self.open.replace(Some(Rc::new(OpenEdit {
            id,
            cell: cell.downgrade(),
            row: plan.row.pin(),
            column: plan.column.index,
            start: plan.start,
            text: text.clone(),
            composing: Cell::new(false),
            commit_when_composed: Cell::new(false),
        })));
        connect(grid, &text, id);
        text.grab_focus();
        if opened == Opened::ToEdit {
            text.select_region(0, -1);
        }
        grid.set_editing(true);
        text
    }

    /// Commit the open edit. `Kept` when the column refused the value and
    /// the editor stays open with it.
    fn commit_open(&self, refusal: Refusal, close: CloseWhen) -> Ended {
        let Some(edit) = self.open.take() else {
            return Ended::Nothing;
        };
        let Some(grid) = self.grid.upgrade() else {
            return Ended::Nothing;
        };
        let typed = edit.text.text();
        let result = self.evaluate(&grid, &edit.row, edit.column, &edit.start, typed.as_str());
        if let Some(CommitResult::Rejected(error)) = &result
            && refusal == Refusal::Keep
        {
            edit.text.add_css_class("error");
            self.open.replace(Some(edit));
            grid.toast(edit_parse_message(error));
            return Ended::Kept;
        }
        self.close(&grid, &edit, close);
        match result {
            Some(CommitResult::Edit(change)) => self.apply_edit(&grid, change),
            Some(CommitResult::Rejected(error)) => grid.toast(edit_parse_message(&error)),
            Some(CommitResult::Unchanged) | None => {}
        }
        Ended::Closed
    }

    fn cancel_open(&self) -> bool {
        let Some(edit) = self.open.take() else {
            return false;
        };
        if let Some(grid) = self.grid.upgrade() {
            self.close(&grid, &edit, CloseWhen::Now);
        }
        true
    }

    fn close(&self, grid: &DataGrid, edit: &OpenEdit, when: CloseWhen) {
        edit.text.remove_css_class("error");
        if let Some(cell) = edit.cell.upgrade() {
            match when {
                CloseWhen::Now => cell.close_editor(),
                CloseWhen::AfterFocusChange => {
                    edit.text.set_visible(false);
                    if let Some(display) = cell.display() {
                        display.set_visible(true);
                    }
                    close_when_idle(grid, &cell);
                }
            }
        }
        grid.set_editing(false);
    }

    /// The lock is read again: a key or a late event can reach a cell
    /// locked since its edit began.
    pub(super) fn evaluate(
        &self,
        grid: &DataGrid,
        row: &PinnedRow,
        column: usize,
        start: &EditStart,
        typed: &str,
    ) -> Option<CommitResult> {
        let row = row.get()?;
        let column = grid.grid_columns().get(column).cloned()?;
        let locked = self.tracked().lock(&column, row).is_some() || self.policy()?.cells.is_err();
        if locked {
            tracing::debug!(column = column.index, "refused an edit to a locked cell");
            return None;
        }
        Some(commit_edit(&column, start, typed))
    }

    fn current(&self, id: u64) -> Option<Rc<OpenEdit>> {
        self.open.borrow().as_ref().filter(|edit| edit.id == id).cloned()
    }

    fn open_in(&self, cell: &GridCell) -> Option<Rc<OpenEdit>> {
        self.open
            .borrow()
            .as_ref()
            .filter(|edit| edit.cell.upgrade().as_ref() == Some(cell))
            .cloned()
    }

    fn open_cell(&self) -> Option<GridCell> {
        self.open.borrow().as_ref().and_then(|edit| edit.cell.upgrade())
    }

    /// The keys a focused cell takes in the capture phase stay off while
    /// the editor has the focus, so the editor gets them.
    pub(crate) fn editor_has_focus(&self) -> bool {
        self.open
            .borrow()
            .as_ref()
            .is_some_and(|edit| holds_window_focus(edit.text.upcast_ref()))
    }

    fn return_focus(&self, cell: Option<&GridCell>) {
        if let (Some(grid), Some(cell)) = (self.grid.upgrade(), cell) {
            grid.return_focus(cell);
        }
    }

    fn on_activate(&self, id: u64) {
        let Some(edit) = self.current(id) else {
            return;
        };
        if self.commit_open(Refusal::Keep, CloseWhen::Now) == Ended::Closed {
            self.return_focus(edit.cell.upgrade().as_ref());
        }
    }

    fn on_key(&self, id: u64, keyval: gdk::Key, state: gdk::ModifierType) -> glib::Propagation {
        let Some(edit) = self.current(id) else {
            return glib::Propagation::Proceed;
        };
        // While a preedit is open, both keys are the input method's.
        if edit.composing.get() {
            return glib::Propagation::Proceed;
        }
        match editor_key(keyval, state) {
            Some(EditorKey::Cancel) => {
                self.cancel_open();
                self.return_focus(edit.cell.upgrade().as_ref());
            }
            Some(EditorKey::Move(direction)) => {
                if self.commit_open(Refusal::Keep, CloseWhen::Now) == Ended::Closed {
                    self.edit_next(&edit, direction);
                }
            }
            None => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    }

    /// Focus moving to an input method's popover ends the edit mid
    /// composition, and committing then would send the text from before
    /// it, so the commit waits for the preedit to clear.
    fn on_preedit(&self, id: u64, preedit: &str) {
        let Some(edit) = self.current(id) else {
            return;
        };
        edit.composing.set(!preedit.is_empty());
        if preedit.is_empty() && edit.commit_when_composed.replace(false) {
            self.commit_open(Refusal::Keep, CloseWhen::Now);
        }
    }

    fn on_focus_leave(&self, id: u64, field: &gtk::Widget) {
        let Some(edit) = self.current(id) else {
            return;
        };
        // Another window taking the focus leaves it in the field, so the
        // edit stays open for when the window is back. A focus moving
        // within the window is unset while the leave runs.
        if holds_window_focus(field) {
            return;
        }
        if edit.composing.get() {
            edit.commit_when_composed.set(true);
            return;
        }
        self.commit_open(Refusal::Keep, CloseWhen::AfterFocusChange);
    }

    /// Edit the cell Tab or Shift+Tab goes to. With none left on the
    /// page, the focus stays where the edit was.
    fn edit_next(&self, edit: &OpenEdit, direction: EditDirection) {
        let (Some(grid), Some(row)) = (self.grid.upgrade(), edit.row.get().cloned()) else {
            return;
        };
        let Some(position) = grid.view_position(&row) else {
            return;
        };
        let shown = grid.shown_columns();
        let Some(from) = shown.iter().position(|column| *column == edit.column) else {
            return;
        };
        let selection = grid.selection();
        let opens_inline = |position: u32, at: usize| {
            shown
                .get(at)
                .zip(selection.item(position).and_downcast::<GridRow>())
                .is_some_and(|(column, row)| self.plan(&grid, &row, *column).in_place().is_some())
        };
        let target = next_edit_target(
            opens_inline,
            shown.len(),
            from,
            position,
            selection.n_items(),
            direction,
        )
        .and_then(|(position, at)| Some((position, *shown.get(at)?)));
        match target {
            Some((position, column)) => {
                if let Some(cell) = grid.focus_cell(position, column) {
                    self.edit_in_place(&cell);
                }
            }
            None => {
                grid.focus_cell(position, edit.column);
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn open_text(&self) -> Option<gtk::Text> {
        self.open.borrow().as_ref().map(|edit| edit.text.clone())
    }

    #[cfg(test)]
    pub(crate) fn editing_cell(&self) -> Option<GridCell> {
        self.open_cell()
    }
}

/// The field is the cell's child, so its handlers hold the grid weakly
/// and find the edit by its number.
fn connect(grid: &DataGrid, text: &gtk::Text, id: u64) {
    let weak = grid.downgrade();
    text.connect_activate(move |_| {
        if let Some(grid) = weak.upgrade() {
            grid.edit().on_activate(id);
        }
    });
    text.connect_changed(|text| text.remove_css_class("error"));
    // Capture phase, so Escape cancels before the GtkText takes it to
    // clear its own buffer, and Tab commits before the window moves the
    // focus.
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = grid.downgrade();
    keys.connect_key_pressed(move |_, keyval, _, state| match weak.upgrade() {
        Some(grid) => grid.edit().on_key(id, keyval, state),
        None => glib::Propagation::Proceed,
    });
    text.add_controller(keys);
    let weak = grid.downgrade();
    text.connect_preedit_changed(move |_, preedit| {
        if let Some(grid) = weak.upgrade() {
            grid.edit().on_preedit(id, preedit);
        }
    });
    let focus = gtk::EventControllerFocus::new();
    let weak = grid.downgrade();
    focus.connect_leave(move |focus| {
        if let (Some(grid), Some(field)) = (weak.upgrade(), focus.widget()) {
            grid.edit().on_focus_leave(id, &field);
        }
    });
    text.add_controller(focus);
}

/// The keys an open editor reads itself, to leave them to an open
/// preedit. GDK sends Shift+Tab as ISO_Left_Tab, which the table spells
/// as Tab with Shift.
pub(super) fn editor_key(keyval: gdk::Key, state: gdk::ModifierType) -> Option<EditorKey> {
    let (keyval, state) = match keyval {
        gdk::Key::ISO_Left_Tab => (gdk::Key::Tab, state | gdk::ModifierType::SHIFT_MASK),
        gdk::Key::KP_Tab => (gdk::Key::Tab, state),
        other => (other, state),
    };
    if component_matches("cell-editor.cancel", keyval, state) {
        return Some(EditorKey::Cancel);
    }
    if component_matches("cell-editor.next", keyval, state) {
        return Some(EditorKey::Move(EditDirection::Forward));
    }
    if component_matches("cell-editor.previous", keyval, state) {
        return Some(EditorKey::Move(EditDirection::Backward));
    }
    None
}

fn input_purpose(purpose: TextPurpose) -> gtk::InputPurpose {
    match purpose {
        TextPurpose::FreeForm => gtk::InputPurpose::FreeForm,
        TextPurpose::Number => gtk::InputPurpose::Number,
        TextPurpose::Digits => gtk::InputPurpose::Digits,
    }
}

fn too_large_to_edit() -> String {
    let size = glib::format_size(EDIT_MAX_BYTES as u64);
    gettext_f("Values over {size} can't be edited here", &[("size", size.as_str())])
}

/// A field that closed from its focus-leave leaves the cell once the
/// focus change is over, unless an edit opened in the cell since.
fn close_when_idle(grid: &DataGrid, cell: &GridCell) {
    let (grid, cell) = (grid.downgrade(), cell.downgrade());
    glib::idle_add_local_once(move || {
        if let (Some(grid), Some(cell)) = (grid.upgrade(), cell.upgrade())
            && grid.edit().open_in(&cell).is_none()
            && cell.is_editing()
        {
            cell.close_editor();
        }
    });
}

/// Whether `focus` is in `cell`'s row: in the cell or its editor, or on
/// the list's own cell or row widget above it, where the keyboard sits
/// while nothing is being edited.
fn row_holds(cell: &GridCell, focus: &gtk::Widget) -> bool {
    if focus == cell.upcast_ref::<gtk::Widget>() || focus.is_ancestor(cell) {
        return true;
    }
    cell.ancestor(gtk::ListView::static_type())
        .is_some_and(|list| cell.is_ancestor(focus) && focus.is_ancestor(&list))
}

fn grab_after_paint(window: &gtk::Window, view: &gtk::ColumnView) {
    let Some(clock) = window.frame_clock() else {
        return;
    };
    let view = view.downgrade();
    let handler: Rc<RefCell<Option<glib::SignalHandlerId>>> = Rc::default();
    let slot = handler.clone();
    let id = clock.connect_after_paint(move |clock| {
        if let Some(id) = slot.borrow_mut().take() {
            clock.disconnect(id);
        }
        if let Some(view) = view.upgrade()
            && view.root().is_some()
        {
            view.grab_focus();
        }
    });
    handler.replace(Some(id));
}

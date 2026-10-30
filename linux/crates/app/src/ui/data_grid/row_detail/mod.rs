//! The row detail pane: every field of the grid's focused row, and an
//! editor for the whole value of one of them.

mod calendar;
mod clock;
mod fields;
mod imp;
#[cfg(test)]
mod tests;
mod value_editor;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gio, glib};
use libadwaita as adw;

use self::value_editor::Commit;
use super::tracked_values::RowPendingState;
use super::{DataGrid, GridRow, PinnedRow};
use crate::i18n::{gettext, gettext_f};
use crate::ui::handler_guard::HandlerGuard;

/// The row the pane shows and the handler that redraws it.
#[derive(Debug)]
pub struct Shown {
    row: GridRow,
    pin: PinnedRow,
    handler: glib::SignalHandlerId,
}

glib::wrapper! {
    pub struct RowDetailPane(ObjectSubclass<imp::RowDetailPane>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl RowDetailPane {
    pub fn attach(&self, grid: &DataGrid) {
        self.imp().grid.set(Some(grid));
        self.connect_fields(grid);
        self.connect_value_editor(grid);
        self.connect_value_menu(grid);
        self.connect_choices();
        self.connect_calendar();
        self.connect_clock();
        self.connect_close(grid);
        self.watch_details(grid);
        self.watch_rows(grid);
        self.show_nothing();
    }

    /// The grid's focused cell or its selection moved.
    pub fn follow_focus(&self) {
        let Some(grid) = self.grid() else {
            return;
        };
        match grid.focused_cell().and_then(|cell| Some((cell.row()?, cell.column()))) {
            Some((row, column)) => self.show_row(Some(row), Some(column)),
            None => {
                let row = self.row_in_selection(&grid);
                self.show_row(row, None);
            }
        }
    }

    /// Show the field of data column `column`, as the grid asks when it
    /// opens the pane on a cell.
    pub fn select_field(&self, column: usize) {
        if self.current_row().is_none() {
            self.follow_focus();
        }
        self.set_field(column);
    }

    /// Move the keyboard focus to the value editor.
    pub fn focus_value(&self) {
        if self.current_row().is_none() {
            return;
        }
        self.render();
        let view = self.imp().value_view.get();
        // The pane may only now be on its way to the screen.
        if !view.grab_focus() {
            glib::idle_add_local_once(move || {
                view.grab_focus();
            });
        }
    }

    /// Commit what was typed in the value editor before the grid writes
    /// its rows. A value the column refuses goes, since it was never a
    /// pending change.
    pub fn commit_open_edit(&self) {
        self.commit(Commit::Teardown);
    }

    pub fn cancel_open_edit(&self) {
        self.cancel_edit();
    }

    fn grid(&self) -> Option<DataGrid> {
        self.imp().grid.upgrade()
    }

    /// The row shown, while its slot still holds it.
    fn current_row(&self) -> Option<GridRow> {
        self.imp()
            .shown
            .borrow()
            .as_ref()
            .and_then(|shown| shown.pin.get().cloned())
    }

    fn current_pin(&self) -> Option<PinnedRow> {
        self.imp()
            .shown
            .borrow()
            .as_ref()
            .filter(|shown| shown.pin.is_current())
            .map(|shown| shown.pin.clone())
    }

    /// With no focused cell, the row shown while it stays selected, else
    /// the first selected row.
    fn row_in_selection(&self, grid: &DataGrid) -> Option<GridRow> {
        let selection = grid.selection();
        if let Some(row) = self.current_row()
            && grid
                .view_position(&row)
                .is_some_and(|position| selection.is_selected(position))
        {
            return Some(row);
        }
        let selected = selection.selection();
        if selected.is_empty() {
            return None;
        }
        selection.item(selected.minimum()).and_downcast()
    }

    /// Show `row`, with `column`'s field when the grid's focus is on one.
    /// What was typed for another row is committed first.
    fn show_row(&self, row: Option<GridRow>, column: Option<usize>) {
        let same = match (self.imp().shown.borrow().as_ref(), row.as_ref()) {
            (Some(shown), Some(row)) => shown.row == *row && shown.pin.is_current(),
            (None, None) => true,
            _ => false,
        };
        if !same {
            self.imp().calendar_popover.popdown();
            self.imp().clock_popover.popdown();
            self.commit(Commit::Teardown);
            self.watch_row(row.as_ref());
        }
        if let Some(column) = column {
            self.take_field(column);
        }
        self.render();
        if column.is_some() {
            self.select_in_list(column);
        }
    }

    fn watch_row(&self, row: Option<&GridRow>) {
        if let Some(old) = self.imp().shown.take() {
            old.row.disconnect(old.handler);
        }
        let Some(row) = row else {
            return;
        };
        let handler = row.connect_revision_notify(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| pane.row_changed()
        ));
        self.imp().shown.replace(Some(Shown {
            row: row.clone(),
            pin: row.pin(),
            handler,
        }));
    }

    /// The row's values or pending state changed, or its slot was given
    /// another row.
    fn row_changed(&self) {
        let replaced = self
            .imp()
            .shown
            .borrow()
            .as_ref()
            .is_some_and(|shown| !shown.pin.is_current());
        match replaced {
            true => self.follow_focus(),
            false => self.render(),
        }
    }

    fn is_open(&self) -> bool {
        self.grid()
            .and_then(|grid| grid.actions().action_state("show-details"))
            .and_then(|state| state.get::<bool>())
            .unwrap_or(false)
    }

    /// A closed pane loads nothing, so it draws once it opens.
    fn watch_details(&self, grid: &DataGrid) {
        let Some(action) = grid
            .actions()
            .lookup_action("show-details")
            .and_downcast::<gio::SimpleAction>()
        else {
            return;
        };
        action.connect_state_notify(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| pane.render()
        ));
    }

    /// A clear, a shorter page, a new result or an undone draft takes
    /// rows away without a selection change or a write into their slots.
    fn watch_rows(&self, grid: &DataGrid) {
        let rows = grid.store().list().clone();
        let handler = rows.connect_items_changed(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_, _, _, _| pane.rows_changed()
        ));
        self.imp().guards.borrow_mut().push(HandlerGuard::new(&rows, handler));
    }

    fn rows_changed(&self) {
        let Some(grid) = self.grid() else {
            return;
        };
        let gone = self
            .imp()
            .shown
            .borrow()
            .as_ref()
            .is_some_and(|shown| grid.store().position_of(&shown.row).is_none());
        if gone {
            self.follow_focus();
        }
    }

    fn connect_close(&self, grid: &DataGrid) {
        let button = self.imp().close_button.get();
        crate::ui::a11y::announce_key_shortcuts(&button, "grid.show-details");
        button.connect_clicked(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            #[weak]
            grid,
            move |_| {
                // Before the pane hides, or GTK sends the focus to the
                // window's first control.
                crate::ui::a11y::pass_focus(&pane, &grid.column_view());
                if let Some(details) = grid.actions().lookup_action("show-details") {
                    details.change_state(&false.to_variant());
                }
            }
        ));
    }

    /// Draw the shown row, while the pane is open.
    fn render(&self) {
        if !self.is_open() {
            return;
        }
        let Some(row) = self.current_row() else {
            self.show_nothing();
            return;
        };
        self.imp().stack.set_visible_child_name("row");
        self.render_header(&row);
        self.sync_fields();
        self.redraw_fields();
        self.load_value();
    }

    fn show_nothing(&self) {
        self.imp().stack.set_visible_child_name("empty");
        self.imp().loaded.take();
    }

    fn render_header(&self, row: &GridRow) {
        let Some(grid) = self.grid() else {
            return;
        };
        let imp = self.imp();
        let title = match row_number(&grid, row) {
            Some(number) => gettext_f("Row {number}", &[("number", &number.to_string())]),
            None if row.draft_id().is_some() => gettext("New row"),
            None => gettext("Row Details"),
        };
        imp.title_label.set_label(&title);
        let state = grid.tracked().row_state(row);
        // A new row's title says so already.
        let text = match state {
            RowPendingState::Inserted => None,
            other => other.text(),
        };
        imp.state_icon.set_icon_name(state.icon());
        imp.state_label.set_label(text.as_deref().unwrap_or_default());
        imp.state_box.set_visible(text.is_some());
    }
}

/// The number the grid's gutter shows for `row`: a draft has none.
fn row_number(grid: &DataGrid, row: &GridRow) -> Option<u64> {
    if row.draft_id().is_some() {
        return None;
    }
    let position = grid.view_position(row)?;
    let drafts = grid.store().draft_count();
    Some(grid.row_base() + u64::from(position.saturating_sub(drafts)) + 1)
}

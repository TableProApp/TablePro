use std::collections::HashSet;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib, pango};
use tablepro_core::Value;

use super::RowDetailPane;
use crate::services::change_tracker::CellState;
use crate::services::grid::{GridColumn, auto_filled_sentinel, display_text};
use crate::ui::data_grid::tracked_values::cell_description;
use crate::ui::data_grid::{DataGrid, GridRow, TrackedValues};
use crate::ui::handler_guard::HandlerGuard;

/// The data columns in the order the fields list shows them: the ones on
/// screen as the grid shows them, then the hidden ones.
pub fn field_order(shown: &[usize], count: usize) -> Vec<usize> {
    let on_screen: HashSet<usize> = shown.iter().copied().collect();
    shown
        .iter()
        .copied()
        .filter(|index| *index < count)
        .chain((0..count).filter(|index| !on_screen.contains(index)))
        .collect()
}

/// The data column a fields list item stands for.
fn field_of(item: Option<glib::Object>) -> Option<usize> {
    let boxed = item.and_downcast::<glib::BoxedAnyObject>()?;
    boxed.try_borrow::<usize>().ok().map(|index| *index)
}

/// One field's value as its row in the list draws it.
#[derive(Debug, Clone, PartialEq)]
pub struct FieldValue {
    pub text: String,
    pub placeholder: bool,
    pub null: bool,
    pub modified: bool,
    pub deleted: bool,
}

pub fn field_value(tracked: &TrackedValues, row: &GridRow, column: &GridColumn) -> FieldValue {
    let mark = tracked.mark(row, column.index);
    let (text, placeholder, null) = tracked.with_value(row, column.index, |value, default| match (default, value) {
        (true, _) if column.auto_filled() => (auto_filled_sentinel(), true, false),
        (true, _) => ("DEFAULT".to_owned(), true, false),
        (false, Value::Null) => ("NULL".to_owned(), true, true),
        (false, value) => {
            let mut scratch = String::new();
            let shown = display_text(value, &column.column_type, &mut scratch);
            (shown.text.to_owned(), shown.placeholder, false)
        }
    });
    FieldValue {
        text,
        placeholder,
        null,
        modified: mark.state == CellState::Modified && !mark.row_deleted,
        deleted: mark.row_deleted,
    }
}

/// A field's row: its name and type on one line, its value on the next.
fn field_row() -> gtk::Box {
    let name = gtk::Label::builder()
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    let kind = gtk::Label::builder()
        .xalign(1.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    kind.add_css_class("caption");
    kind.add_css_class("dimmed");
    let top = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    top.append(&name);
    top.append(&kind);
    let value = gtk::Inscription::builder()
        .hexpand(true)
        .min_chars(1)
        .text_overflow(gtk::InscriptionOverflow::EllipsizeEnd)
        .build();
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .margin_top(6)
        .margin_bottom(6)
        .margin_start(12)
        .margin_end(12)
        .build();
    row.append(&top);
    row.append(&value);
    row
}

fn set_class(widget: &impl IsA<gtk::Widget>, class: &str, on: bool) {
    match on {
        true => widget.as_ref().add_css_class(class),
        false => widget.as_ref().remove_css_class(class),
    }
}

/// Italic for a stand-in, bold for a pending value and struck through on
/// a row marked for deletion, so each reads without colour.
fn value_attributes(value: &FieldValue) -> pango::AttrList {
    let attributes = pango::AttrList::new();
    if value.placeholder {
        attributes.insert(pango::AttrInt::new_style(pango::Style::Italic));
    }
    if value.modified {
        attributes.insert(pango::AttrInt::new_weight(pango::Weight::Bold));
    }
    if value.deleted {
        attributes.insert(pango::AttrInt::new_strikethrough(true));
    }
    attributes
}

impl RowDetailPane {
    pub(super) fn connect_fields(&self, grid: &DataGrid) {
        let imp = self.imp();
        imp.selection.set_autoselect(false);
        imp.selection.set_can_unselect(true);
        imp.selection.set_model(Some(&imp.fields.0));
        imp.field_list.set_model(Some(&imp.selection));
        imp.field_list.set_factory(Some(&self.field_factory()));
        imp.selection.connect_selected_notify(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| pane.field_picked()
        ));
        imp.field_list.connect_activate(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_, _| pane.focus_value()
        ));
        let columns = grid.column_view().columns();
        let reordered = columns.connect_items_changed(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_, _, _, _| pane.schedule_field_sync()
        ));
        imp.guards.borrow_mut().push(HandlerGuard::new(&columns, reordered));
    }

    fn field_factory(&self) -> gtk::SignalListItemFactory {
        let factory = gtk::SignalListItemFactory::new();
        factory.connect_setup(|_, item| {
            if let Some(item) = item.downcast_ref::<gtk::ListItem>() {
                item.set_child(Some(&field_row()));
            }
        });
        factory.connect_bind(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_, item| {
                if let Some(item) = item.downcast_ref::<gtk::ListItem>() {
                    pane.imp().bound.borrow_mut().push(item.clone());
                    pane.draw_field(item);
                }
            }
        ));
        factory.connect_unbind(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_, item| pane
                .imp()
                .bound
                .borrow_mut()
                .retain(|bound| bound.upcast_ref::<glib::Object>() != item)
        ));
        factory
    }

    pub(super) fn redraw_fields(&self) {
        let bound: Vec<gtk::ListItem> = self.imp().bound.borrow().clone();
        for item in &bound {
            self.draw_field(item);
        }
    }

    fn draw_field(&self, item: &gtk::ListItem) {
        let (Some(grid), Some(index)) = (self.grid(), field_of(item.item())) else {
            return;
        };
        let Some(column) = grid.grid_columns().get(index).cloned() else {
            return;
        };
        let Some(row_box) = item.child() else {
            return;
        };
        let top = row_box.first_child();
        let (Some(name), Some(kind), Some(shown)) = (
            top.as_ref()
                .and_then(|top| top.first_child())
                .and_downcast::<gtk::Label>(),
            top.as_ref()
                .and_then(|top| top.last_child())
                .and_downcast::<gtk::Label>(),
            row_box.last_child().and_downcast::<gtk::Inscription>(),
        ) else {
            return;
        };
        name.set_label(&column.name);
        kind.set_label(&column.value_type().name);
        item.set_accessible_label(&column.name);
        let Some(row) = self.current_row() else {
            shown.set_text(None);
            return;
        };
        let value = field_value(&grid.tracked(), &row, &column);
        shown.set_text(Some(&value.text));
        shown.set_attributes(Some(&value_attributes(&value)));
        set_class(&shown, "dimmed", value.placeholder || value.deleted);
        // Adwaita's own warning colour beside the bold, as the grid's
        // cells mark a pending value.
        set_class(&shown, "warning", value.modified);
        let state = match value.modified {
            true => CellState::Modified,
            false => CellState::Clean,
        };
        let description = match (cell_description(state, value.null), value.null) {
            (Some(said), true) => said,
            (Some(said), false) => format!("{}, {said}", value.text),
            (None, _) => value.text.clone(),
        };
        item.set_accessible_description(&description);
    }

    fn field_picked(&self) {
        let imp = self.imp();
        if imp.syncing.get() {
            return;
        }
        let Some(column) = field_of(imp.selection.selected_item()) else {
            return;
        };
        self.take_field(column);
        self.load_value();
        self.move_grid_focus(column);
    }

    /// Show `column`'s field, selected in the list, as the grid asks.
    pub(super) fn set_field(&self, column: usize) {
        self.take_field(column);
        self.select_in_list(Some(column));
        self.load_value();
    }

    /// Make `column` the selected field. What was typed in another field
    /// is committed first.
    pub(super) fn take_field(&self, column: usize) {
        if self.imp().field.get() == Some(column) {
            return;
        }
        self.commit(super::value_editor::Commit::Teardown);
        self.imp().field.set(Some(column));
    }

    pub(super) fn select_in_list(&self, column: Option<usize>) {
        let imp = self.imp();
        let store = &imp.fields.0;
        let position = column
            .and_then(|column| (0..store.n_items()).find(|position| field_of(store.item(*position)) == Some(column)))
            .unwrap_or(gtk::INVALID_LIST_POSITION);
        if imp.selection.selected() == position {
            return;
        }
        imp.syncing.set(true);
        imp.selection.set_selected(position);
        imp.syncing.set(false);
        if position != gtk::INVALID_LIST_POSITION {
            imp.field_list.scroll_to(position, gtk::ListScrollFlags::NONE, None);
        }
    }

    /// Move the grid's focused cell to `column` of the shown row. The
    /// list holds the keyboard, and `scroll_to` only marks the cell the
    /// grid focuses next while the grid does not, so the keyboard stays
    /// in the pane.
    fn move_grid_focus(&self, column: usize) {
        let (Some(grid), Some(row)) = (self.grid(), self.current_row()) else {
            return;
        };
        let Some(position) = grid.view_position(&row) else {
            return;
        };
        let Some(view_column) = grid.data_view_column(column).filter(gtk::ColumnViewColumn::is_visible) else {
            return;
        };
        grid.column_view()
            .scroll_to(position, Some(&view_column), gtk::ListScrollFlags::FOCUS, None);
    }

    /// A header drag, a hidden column or a new column set reorders the
    /// fields once the grid has finished changing its columns.
    fn schedule_field_sync(&self) {
        if self.imp().sync_queued.replace(true) {
            return;
        }
        glib::idle_add_local_once(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move || {
                pane.imp().sync_queued.set(false);
                pane.watch_column_visibility();
                if pane.sync_fields() {
                    pane.render();
                }
            }
        ));
    }

    /// Put the fields in the grid's column order. `true` when it changed.
    pub(super) fn sync_fields(&self) -> bool {
        let Some(grid) = self.grid() else {
            return false;
        };
        let imp = self.imp();
        let wanted = field_order(&grid.shown_columns(), grid.grid_columns().len());
        let store = &imp.fields.0;
        let held: Vec<usize> = (0..store.n_items())
            .filter_map(|position| field_of(store.item(position)))
            .collect();
        if held == wanted {
            return false;
        }
        let items: Vec<glib::BoxedAnyObject> = wanted.into_iter().map(glib::BoxedAnyObject::new).collect();
        imp.syncing.set(true);
        store.splice(0, store.n_items(), &items);
        imp.syncing.set(false);
        // A column set without the field's column shows none.
        if imp.field.get().is_some_and(|field| field >= items.len()) {
            imp.field.set(None);
        }
        self.select_in_list(imp.field.get());
        true
    }

    fn watch_column_visibility(&self) {
        self.stop_watching_columns();
        let Some(grid) = self.grid() else {
            return;
        };
        let columns = grid.column_view().columns();
        let watches = (0..columns.n_items())
            .filter_map(|position| columns.item(position).and_downcast::<gtk::ColumnViewColumn>())
            .map(|column| {
                let handler = column.connect_visible_notify(glib::clone!(
                    #[weak(rename_to = pane)]
                    self,
                    move |_| pane.schedule_field_sync()
                ));
                (column.downgrade(), handler)
            })
            .collect();
        self.imp().column_watches.replace(watches);
    }

    pub(super) fn stop_watching_columns(&self) {
        for (column, handler) in self.imp().column_watches.take() {
            if let Some(column) = column.upgrade() {
                column.disconnect(handler);
            }
        }
    }
}

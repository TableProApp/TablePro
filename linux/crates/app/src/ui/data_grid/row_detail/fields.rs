use std::collections::HashSet;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib, pango};
use tablepro_core::Value;

use super::RowDetailPane;
use crate::i18n::gettext;
use crate::services::change_tracker::CellState;
use crate::services::grid::{GridColumn, auto_filled_sentinel, display_text};
use crate::ui::data_grid::tracked_values::cell_description;
use crate::ui::data_grid::{DataGrid, GridRow, ServerValue, TrackedValues};
use crate::ui::handler_guard::HandlerGuard;
use crate::ui::icons;

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

pub fn field_value(tracked: &TrackedValues, row: &GridRow, column: &GridColumn, null_display: &str) -> FieldValue {
    let mark = tracked.mark(row, column.index);
    let (text, placeholder, null) = tracked.with_value(row, column.index, |value, computed| match (computed, value) {
        (Some(ServerValue::Default), _) if column.auto_filled() => (auto_filled_sentinel(), true, false),
        (Some(ServerValue::Default), _) => ("DEFAULT".to_owned(), true, false),
        (Some(ServerValue::Expression(expression)), _) => (expression.sql.to_owned(), true, false),
        (None, Value::Null) => (null_display.to_owned(), true, true),
        (None, value) => {
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

fn is_primary_key(column: &GridColumn) -> bool {
    column.catalog.as_ref().is_some_and(|catalog| catalog.primary_key)
}

// The key has no role of its own, so the label is where a screen reader hears it.
pub(super) fn field_label(column: &GridColumn) -> String {
    let mut parts = vec![column.name.clone()];
    let type_name = &column.value_type().name;
    if !type_name.is_empty() {
        parts.push(type_name.clone());
    }
    if is_primary_key(column) {
        parts.push(gettext("primary key"));
    }
    parts.join(", ")
}

fn marker(icon: &str) -> gtk::Image {
    let image = gtk::Image::builder().icon_name(icon).visible(false).build();
    image.set_accessible_role(gtk::AccessibleRole::Presentation);
    image
}

fn field_row() -> gtk::Box {
    let key = marker(icons::PRIMARY_KEY);
    // Dimmed as a libadwaita property row's title, so the eye lands on the value.
    let name = gtk::Label::builder()
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(pango::EllipsizeMode::Middle)
        .build();
    name.add_css_class("dimmed");
    let edited = marker(icons::DOCUMENT_EDIT);
    // Match the pending value beneath the marker.
    edited.add_css_class("warning");
    let kind = gtk::Label::builder()
        .xalign(1.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    kind.add_css_class("caption");
    kind.add_css_class("dimmed");
    let type_icon = marker(icons::TEXT_X_GENERIC);
    type_icon.set_visible(true);
    type_icon.add_css_class("dimmed");
    let type_box = gtk::Box::new(gtk::Orientation::Horizontal, 3);
    type_box.append(&type_icon);
    type_box.append(&kind);
    let top = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    top.append(&key);
    top.append(&name);
    top.append(&edited);
    top.append(&type_box);
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

struct FieldParts {
    key: gtk::Image,
    name: gtk::Label,
    edited: gtk::Image,
    kind: gtk::Label,
    value: gtk::Inscription,
}

fn field_parts(row: &gtk::Widget) -> Option<FieldParts> {
    let top = row.first_child()?;
    let key = top.first_child()?;
    let name = key.next_sibling()?;
    let edited = name.next_sibling()?;
    let kind = edited.next_sibling()?.last_child()?;
    Some(FieldParts {
        key: key.downcast().ok()?,
        name: name.downcast().ok()?,
        edited: edited.downcast().ok()?,
        kind: kind.downcast().ok()?,
        value: row.last_child()?.downcast().ok()?,
    })
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
        imp.filtered.set_model(Some(&imp.fields.0));
        imp.filtered.set_filter(Some(&imp.field_filter));
        imp.selection.set_model(Some(&imp.filtered));
        imp.field_filter.set_filter_func(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            #[upgrade_or]
            false,
            move |item| pane.field_shown(field_of(Some(item.clone())))
        ));
        imp.field_search.connect_search_changed(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| pane.refilter_fields()
        ));
        imp.field_search.set_key_capture_widget(Some(&imp.field_list.get()));
        imp.field_search.connect_search_started(|entry| {
            entry.grab_focus();
        });
        imp.field_search.connect_stop_search(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |entry| {
                if !entry.text().is_empty() {
                    entry.set_text("");
                } else if pane.grid().is_some_and(|grid| grid.imp().split_view.is_collapsed()) {
                    pane.imp().close_button.emit_clicked();
                }
            }
        ));
        imp.field_search.connect_activate(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| {
                pane.refilter_fields();
                if pane.imp().filtered.n_items() > 0 {
                    pane.imp().selection.set_selected(0);
                    pane.focus_value();
                }
            }
        ));
        imp.edited_toggle.connect_toggled(glib::clone!(
            #[weak(rename_to = pane)]
            self,
            move |_| pane.refilter_fields()
        ));
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
        self.refilter_fields();
        let bound: Vec<gtk::ListItem> = self.imp().bound.borrow().clone();
        for item in &bound {
            self.draw_field(item);
        }
    }

    pub(super) fn refilter_fields(&self) {
        let imp = self.imp();
        let has_edits = self.grid().zip(self.current_row()).is_some_and(|(grid, row)| {
            grid.grid_columns().iter().any(|column| {
                let mark = grid.tracked().mark(&row, column.index);
                mark.state == CellState::Modified && !mark.row_deleted
            })
        });
        imp.edited_toggle
            .set_sensitive(has_edits || imp.edited_toggle.is_active());
        // A changed filter may move the selected position without a user picking a field.
        let syncing = imp.syncing.replace(true);
        imp.field_filter.changed(gtk::FilterChange::Different);
        self.select_in_list(imp.field.get());
        imp.syncing.set(syncing);
        imp.field_results.set_visible_child_name(match imp.filtered.n_items() {
            0 => "empty",
            _ => "fields",
        });
    }

    fn field_shown(&self, column: Option<usize>) -> bool {
        let imp = self.imp();
        let (Some(grid), Some(column), Some(row)) = (self.grid(), column, self.current_row()) else {
            return false;
        };
        let Some(column) = grid.grid_columns().get(column).cloned() else {
            return false;
        };
        if imp.edited_toggle.is_active() {
            let mark = grid.tracked().mark(&row, column.index);
            if mark.state != CellState::Modified || mark.row_deleted {
                return false;
            }
        }
        let wanted = imp.field_search.text().to_lowercase();
        if wanted.is_empty() || column.name.to_lowercase().contains(&wanted) {
            return true;
        }
        let value = field_value(&grid.tracked(), &row, &column, "");
        !value.null && value.text.to_lowercase().contains(&wanted)
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
        let Some(FieldParts {
            key,
            name,
            edited,
            kind,
            value: shown,
        }) = field_parts(&row_box)
        else {
            return;
        };
        key.set_visible(is_primary_key(&column));
        name.set_label(&column.name);
        kind.set_label(&column.value_type().name);
        item.set_accessible_label(&field_label(&column));
        let Some(row) = self.current_row() else {
            edited.set_visible(false);
            shown.set_text(None);
            return;
        };
        let Some(config) = grid.config() else {
            return;
        };
        let preferences = config.settings.grid_preferences().snapshot();
        let value = field_value(&grid.tracked(), &row, &column, &preferences.null_display);
        edited.set_visible(value.modified);
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
        let shown = &imp.selection;
        let position = column
            .and_then(|column| (0..shown.n_items()).find(|position| field_of(shown.item(*position)) == Some(column)))
            .unwrap_or(gtk::INVALID_LIST_POSITION);
        if imp.selection.selected() == position {
            return;
        }
        let syncing = imp.syncing.replace(true);
        imp.selection.set_selected(position);
        imp.syncing.set(syncing);
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
                pane.sync_fields();
                pane.render();
            }
        ));
    }

    pub(super) fn sync_fields(&self) {
        let Some(grid) = self.grid() else {
            return;
        };
        let imp = self.imp();
        let wanted = field_order(&grid.shown_columns(), grid.grid_columns().len());
        let store = &imp.fields.0;
        let held: Vec<usize> = (0..store.n_items())
            .filter_map(|position| field_of(store.item(position)))
            .collect();
        if held == wanted {
            return;
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

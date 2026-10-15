use std::cell::RefCell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, gio, glib};
use tablepro_core::{ColumnInfo, QueryResult, Value};

use super::GridMsg;
use super::display::{FULL_EDIT_KIND_SLOT, FULL_EDIT_TEXT_SLOT, IS_NULL_SLOT, POSITION_SLOT, ROW_KEY_SLOT};
use super::editing::enter_edit_mode;
use super::export;
use super::local_filter::LocalResultView;
use super::value_viewer;

const CELL_MENU_TRIGGER: &str = "Menu|<Shift>F10";

#[derive(Clone)]
struct CellContext {
    widget: gtk::Widget,
    col_index: usize,
    column_name: String,
}

#[derive(Clone)]
pub(super) struct GridMenus {
    context: Rc<RefCell<Option<CellContext>>>,
    editable_popover: gtk::PopoverMenu,
    readonly_popover: gtk::PopoverMenu,
    edit_action: gio::SimpleAction,
    edit_full_value_action: gio::SimpleAction,
    reference_action: gio::SimpleAction,
    foreign_key_columns: Rc<std::collections::HashSet<String>>,
}

pub(super) struct GridMenuOptions {
    pub(super) filterable: bool,
    pub(super) foreign_key_columns: std::collections::HashSet<String>,
    pub(super) local_result_view: Option<LocalResultView>,
}

pub(super) fn install_grid_context_menus(
    column_view: &gtk::ColumnView,
    sender: relm4::Sender<GridMsg>,
    result_columns: &[ColumnInfo],
    truncated: bool,
    driver_id: String,
    options: GridMenuOptions,
) -> GridMenus {
    let context: Rc<RefCell<Option<CellContext>>> = Rc::new(RefCell::new(None));
    let columns = Rc::new(result_columns.to_vec());
    let local_result = options.local_result_view.is_some();
    let editable_menu = build_menu(true, true, true, options.filterable, local_result);
    let readonly_menu = build_menu(false, false, true, options.filterable, local_result);
    let empty_menu = gio::Menu::new();
    empty_menu.append(Some(&crate::tr!("Insert row")), Some("cell.insert-row"));
    empty_menu.append(Some(&crate::tr!("Jump to Column…")), Some("grid.jump-column"));

    let group = gio::SimpleActionGroup::new();
    let edit_action = gio::SimpleAction::new("edit", None);
    {
        let context = context.clone();
        edit_action.connect_activate(move |_, _| {
            if let Some(slot) = context.borrow().as_ref()
                && let Ok(label) = slot.widget.clone().downcast::<crate::ui::cell_editor::CellEditor>()
            {
                enter_edit_mode(&label);
            }
        });
    }
    let edit_full_value_action = gio::SimpleAction::new("edit-full-value", None);
    {
        let context = context.clone();
        let view = column_view.downgrade();
        let columns = columns.clone();
        let sender = sender.clone();
        edit_full_value_action.connect_activate(move |_, _| {
            let context = context.borrow();
            let Some(slot) = context.as_ref() else { return };
            let Some(view) = view.upgrade() else { return };
            let Some(column) = columns.get(slot.col_index) else {
                return;
            };
            if !super::full_value_editor::is_full_value_column(&column.data_type) {
                return;
            }
            let Some(row) = row_object_at(&view, position(slot)) else {
                return;
            };
            let (_, row_key) = cell_row_identity(&slot.widget);
            if row.draft_id().is_none() && !has_persisted_row_key(&row_key) {
                return;
            }
            let (initial_text, kind) = match full_value_seed(&slot.widget, &row, slot.col_index, &column.data_type) {
                TextSeed::Value(text, kind) => (text, kind),
                TextSeed::TooLarge => {
                    super::full_value_editor::present_too_large(&view);
                    return;
                }
                TextSeed::Unsupported => return,
            };
            super::full_value_editor::present(
                &view,
                &slot.column_name,
                &initial_text,
                super::full_value_editor::EditContext {
                    row_position: position(slot),
                    col_index: slot.col_index,
                    row_key,
                    nullable: column.nullable,
                    kind,
                    sender: sender.clone(),
                },
            );
        });
    }
    let copy_value_action = {
        let context = context.clone();
        let sender = sender.clone();
        let view = column_view.downgrade();
        gio::ActionEntry::builder("copy-value")
            .activate(move |_, _, _| {
                if let Some(slot) = context.borrow().as_ref() {
                    let row = view.upgrade().and_then(|view| row_object_at(&view, position(slot)));
                    let text = copy_value_text(&slot.widget, row.as_ref(), slot.col_index);
                    sender.send(GridMsg::CopyToClipboard(text)).ok();
                }
            })
            .build()
    };
    let copy_column_name_action = {
        let context = context.clone();
        let sender = sender.clone();
        gio::ActionEntry::builder("copy-column-name")
            .activate(move |_, _, _| {
                if let Some(slot) = context.borrow().as_ref() {
                    sender.send(GridMsg::CopyToClipboard(slot.column_name.clone())).ok();
                }
            })
            .build()
    };
    let copy_rows_entry = copy_rows_action(
        "copy-rows",
        context.clone(),
        sender.clone(),
        column_view,
        columns.clone(),
        |columns, rows| export::render_tsv(columns, rows, false),
    );
    let copy_rows_headers_entry = copy_rows_action(
        "copy-rows-headers",
        context.clone(),
        sender.clone(),
        column_view,
        columns.clone(),
        |columns, rows| export::render_tsv(columns, rows, true),
    );
    let copy_json_entry = copy_rows_action(
        "copy-json",
        context.clone(),
        sender.clone(),
        column_view,
        columns.clone(),
        export::render_json,
    );
    let copy_csv_entry = copy_rows_action(
        "copy-csv",
        context.clone(),
        sender.clone(),
        column_view,
        columns.clone(),
        |columns, rows| export::render_csv(columns, rows, false),
    );
    let copy_csv_headers_entry = copy_rows_action(
        "copy-csv-headers",
        context.clone(),
        sender.clone(),
        column_view,
        columns.clone(),
        |columns, rows| export::render_csv(columns, rows, true),
    );
    let copy_markdown_entry = copy_rows_action(
        "copy-markdown",
        context.clone(),
        sender.clone(),
        column_view,
        columns.clone(),
        export::render_markdown,
    );
    let supports_sql = tablepro_core::export::supports_sql_literals(&driver_id);
    let copy_in_clause_action = {
        let context = context.clone();
        let sender = sender.clone();
        let view = column_view.downgrade();
        gio::ActionEntry::builder("copy-in-clause")
            .activate(move |_, _, _| {
                let context = context.borrow();
                let Some(slot) = context.as_ref() else { return };
                let Some(view) = view.upgrade() else { return };
                let Some(rows) = values_for_column_menu(&view, position(slot), slot.col_index) else {
                    sender.send(GridMsg::IncompleteRowData).ok();
                    return;
                };
                let clause = export::render_in_clause(&driver_id, &rows, 0);
                if clause.skipped > 0 {
                    let message = crate::tr!("Skipped {n} NULL, binary or unsupported values.")
                        .replace("{n}", &clause.skipped.to_string());
                    let alert = libadwaita::AlertDialog::new(Some(&crate::tr!("Copy as IN clause")), Some(&message));
                    use libadwaita::prelude::*;
                    alert.add_response("close", &crate::tr!("Close"));
                    alert.set_close_response("close");
                    alert.present(Some(&view));
                }
                if !clause.sql.is_empty() {
                    sender.send(GridMsg::CopyToClipboard(clause.sql)).ok();
                }
            })
            .build()
    };
    let view_value_action = {
        let context = context.clone();
        let sender = sender.clone();
        let view = column_view.downgrade();
        gio::ActionEntry::builder("view-value")
            .activate(move |_, _, _| {
                let context = context.borrow();
                let Some(slot) = context.as_ref() else { return };
                let Some(view) = view.upgrade() else { return };
                let row = row_object_at(&view, position(slot));
                if let Some(value) = pending_cell_value(&slot.widget) {
                    let copy_text = copy_value_text(&slot.widget, row.as_ref(), slot.col_index);
                    value_viewer::present(&view, &slot.column_name, &value, copy_text);
                    return;
                }
                if row
                    .as_ref()
                    .is_some_and(|row| row.cell_preview(slot.col_index).is_some())
                {
                    let (_, row_key) = cell_row_identity(&slot.widget);
                    if row_key.is_empty() {
                        let Some(value) = view
                            .model()
                            .and_then(|model| model.downcast::<gtk::MultiSelection>().ok())
                            .and_then(|selection| selection.model())
                            .and_then(|model| model.downcast::<crate::ui::row_store::RowStore>().ok())
                            .and_then(|store| store.source_value_at(position(slot), slot.col_index))
                        else {
                            return;
                        };
                        let copy_text = super::display::value_to_full_edit_text(&value);
                        value_viewer::present(&view, &slot.column_name, &value, copy_text);
                    } else {
                        sender
                            .send(GridMsg::FetchCellValue {
                                col_index: slot.col_index,
                                column_name: slot.column_name.clone(),
                                row_key,
                            })
                            .ok();
                    }
                    return;
                }
                let Some(value) = row_at(&view, position(slot)).and_then(|row| row.into_iter().nth(slot.col_index))
                else {
                    return;
                };
                let copy_text = super::display::value_to_full_edit_text(&value);
                value_viewer::present(&view, &slot.column_name, &value, copy_text);
            })
            .build()
    };
    let show_row_json_action = {
        let context = context.clone();
        let sender = sender.clone();
        let view = column_view.downgrade();
        let columns = columns.clone();
        gio::ActionEntry::builder("show-row-json")
            .activate(move |_, _, _| {
                let context = context.borrow();
                let Some(slot) = context.as_ref() else { return };
                let Some(view) = view.upgrade() else { return };
                let Some(row) = complete_row_at(&view, position(slot)) else {
                    sender.send(GridMsg::IncompleteRowData).ok();
                    return;
                };
                let json = export::render_row_json(&columns, &row);
                sender.send(GridMsg::ShowRowAsJson(json)).ok();
            })
            .build()
    };
    let export_action = {
        let sender = sender.clone();
        let view = column_view.downgrade();
        let columns = columns.clone();
        gio::ActionEntry::builder("export")
            .activate(move |_, _, _| {
                let Some(view) = view.upgrade() else { return };
                if let Some(result) = export_snapshot(&view, &columns, truncated) {
                    sender.send(GridMsg::ExportResults(result)).ok();
                } else {
                    sender.send(GridMsg::IncompleteRowData).ok();
                }
            })
            .build()
    };
    let copy_row_action = {
        let context = context.clone();
        let sender = sender.clone();
        let view = column_view.downgrade();
        gio::ActionEntry::builder("copy-row-insert")
            .activate(move |_, _, _| {
                if let Some(slot) = context.borrow().as_ref() {
                    let Some(view) = view.upgrade() else { return };
                    if complete_row_at(&view, position(slot)).is_none() {
                        sender.send(GridMsg::IncompleteRowData).ok();
                        return;
                    }
                    sender
                        .send(GridMsg::CopyRowAsInsert {
                            row_position: position(slot),
                        })
                        .ok();
                }
            })
            .build()
    };
    let insert_row_action = {
        let sender = sender.clone();
        gio::ActionEntry::builder("insert-row")
            .activate(move |_, _, _| {
                sender.send(GridMsg::InsertRow).ok();
            })
            .build()
    };
    let set_null_action = {
        let context = context.clone();
        let sender = sender.clone();
        gio::ActionEntry::builder("set-null")
            .activate(move |_, _, _| {
                if let Some(slot) = context.borrow().as_ref() {
                    let (row_position, row_key) = cell_row_identity(&slot.widget);
                    sender
                        .send(GridMsg::SetCellNull {
                            row_position,
                            col_index: slot.col_index,
                            row_key,
                        })
                        .ok();
                }
            })
            .build()
    };
    let delete_row_action = {
        let context = context.clone();
        let sender = sender.clone();
        gio::ActionEntry::builder("delete-row")
            .activate(move |_, _, _| {
                if let Some(slot) = context.borrow().as_ref() {
                    let (row_position, row_key) = cell_row_identity(&slot.widget);
                    sender.send(GridMsg::DeleteRowAt { row_position, row_key }).ok();
                }
            })
            .build()
    };
    let filter_action = filter_by_value_action(
        context.clone(),
        sender.clone(),
        column_view,
        columns.clone(),
        options.local_result_view,
    );
    let reference_action = go_to_reference_action(context.clone(), sender.clone(), column_view, columns.clone());
    let duplicate_row_action = {
        let context = context.clone();
        let sender = sender.clone();
        let view = column_view.downgrade();
        gio::ActionEntry::builder("duplicate-row")
            .activate(move |_, _, _| {
                if let Some(slot) = context.borrow().as_ref() {
                    let Some(view) = view.upgrade() else { return };
                    if complete_row_at(&view, position(slot)).is_none() {
                        sender.send(GridMsg::IncompleteRowData).ok();
                        return;
                    }
                    sender
                        .send(GridMsg::DuplicateRow {
                            row_position: position(slot),
                        })
                        .ok();
                }
            })
            .build()
    };
    group.add_action(&edit_action);
    group.add_action(&edit_full_value_action);
    group.add_action_entries([
        copy_value_action,
        copy_column_name_action,
        copy_rows_entry,
        copy_rows_headers_entry,
        copy_json_entry,
        copy_csv_entry,
        copy_csv_headers_entry,
        copy_markdown_entry,
        copy_in_clause_action,
        view_value_action,
        show_row_json_action,
        export_action,
        copy_row_action,
        insert_row_action,
        set_null_action,
        delete_row_action,
        duplicate_row_action,
        filter_action,
    ]);
    group.add_action(&reference_action);
    column_view.insert_action_group("cell", Some(&group));
    if let Some(action) = group
        .lookup_action("copy-in-clause")
        .and_then(|action| action.downcast::<gio::SimpleAction>().ok())
    {
        action.set_enabled(supports_sql);
    }

    let editable_popover = gtk::PopoverMenu::from_model_full(&editable_menu, gtk::PopoverMenuFlags::NESTED);
    editable_popover.set_has_arrow(true);
    editable_popover.set_parent(column_view);
    let readonly_popover = gtk::PopoverMenu::from_model_full(&readonly_menu, gtk::PopoverMenuFlags::NESTED);
    readonly_popover.set_has_arrow(true);
    readonly_popover.set_parent(column_view);
    let empty_popover = gtk::PopoverMenu::from_model(Some(&empty_menu));
    empty_popover.set_has_arrow(true);
    empty_popover.set_parent(column_view);
    let editable_for_destroy = editable_popover.clone();
    let readonly_for_destroy = readonly_popover.clone();
    let empty_for_destroy = empty_popover.clone();
    column_view.connect_destroy(move |_| {
        editable_for_destroy.unparent();
        readonly_for_destroy.unparent();
        empty_for_destroy.unparent();
    });
    let view = column_view.clone();
    let gesture = gtk::GestureClick::builder().button(3).build();
    gesture.connect_pressed(move |gesture, _, x, y| {
        let widget: gtk::Widget = view.clone().upcast();
        if let Some(picked) = view.pick(x, y, gtk::PickFlags::DEFAULT)
            && picked != widget
        {
            return;
        }
        gesture.set_state(gtk::EventSequenceState::Claimed);
        empty_popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        empty_popover.popup();
    });
    column_view.add_controller(gesture);
    GridMenus {
        context,
        editable_popover,
        readonly_popover,
        edit_action,
        edit_full_value_action,
        reference_action,
        foreign_key_columns: Rc::new(options.foreign_key_columns),
    }
}

fn build_menu(
    editable: bool,
    row_operations: bool,
    insert_copy: bool,
    filterable: bool,
    local_result: bool,
) -> gio::Menu {
    let menu = gio::Menu::new();
    if editable {
        let section = gio::Menu::new();
        let item = gio::MenuItem::new(Some(&crate::tr!("Edit cell")), Some("cell.edit"));
        item.set_attribute_value("hidden-when", Some(&"action-disabled".to_variant()));
        section.append_item(&item);
        let full_value = gio::MenuItem::new(Some(&crate::tr!("Edit Full Value…")), Some("cell.edit-full-value"));
        full_value.set_attribute_value("hidden-when", Some(&"action-disabled".to_variant()));
        section.append_item(&full_value);
        menu.append_section(None, &section);
    }
    let copy_as = gio::Menu::new();
    copy_as.append(Some(&crate::tr!("Rows")), Some("cell.copy-rows"));
    copy_as.append(Some(&crate::tr!("With Headers")), Some("cell.copy-rows-headers"));
    copy_as.append(Some(&crate::tr!("JSON")), Some("cell.copy-json"));
    copy_as.append(Some(&crate::tr!("CSV")), Some("cell.copy-csv"));
    copy_as.append(Some(&crate::tr!("CSV with Headers")), Some("cell.copy-csv-headers"));
    copy_as.append(Some(&crate::tr!("Markdown")), Some("cell.copy-markdown"));
    copy_as.append(Some(&crate::tr!("IN Clause")), Some("cell.copy-in-clause"));
    if insert_copy {
        copy_as.append(Some(&crate::tr!("INSERT Statement")), Some("cell.copy-row-insert"));
    }
    let copy = gio::Menu::new();
    copy.append(Some(&crate::tr!("Copy value")), Some("cell.copy-value"));
    copy.append_submenu(Some(&crate::tr!("Copy as")), &copy_as);
    copy.append(Some(&crate::tr!("Copy column name")), Some("cell.copy-column-name"));
    menu.append_section(None, &copy);
    let display = gio::Menu::new();
    if filterable || local_result {
        display.append(Some(&crate::tr!("Filter by This Value")), Some("cell.filter-by-value"));
    }
    if filterable {
        display.append(Some(&crate::tr!("Go to Referenced Row")), Some("cell.go-to-reference"));
    }
    display.append(Some(&crate::tr!("View Value…")), Some("cell.view-value"));
    display.append(Some(&crate::tr!("Show Row as JSON")), Some("cell.show-row-json"));
    menu.append_section(None, &display);
    let actions = gio::Menu::new();
    let export_label = if local_result {
        crate::tr!("Export Visible Rows…")
    } else {
        crate::tr!("Export Results…")
    };
    actions.append(Some(&export_label), Some("cell.export"));
    actions.append(Some(&crate::tr!("Columns…")), Some("grid.columns"));
    actions.append(Some(&crate::tr!("Jump to Column…")), Some("grid.jump-column"));
    actions.append(Some(&crate::tr!("Find in Loaded Rows…")), Some("grid.find-row"));
    if row_operations {
        actions.append(Some(&crate::tr!("Insert row")), Some("cell.insert-row"));
        actions.append(Some(&crate::tr!("Duplicate row")), Some("cell.duplicate-row"));
        actions.append(Some(&crate::tr!("Set to NULL")), Some("cell.set-null"));
        actions.append(Some(&crate::tr!("Delete row")), Some("cell.delete-row"));
    }
    menu.append_section(None, &actions);
    menu
}

fn go_to_reference_action(
    context: Rc<RefCell<Option<CellContext>>>,
    sender: relm4::Sender<GridMsg>,
    column_view: &gtk::ColumnView,
    columns: Rc<Vec<ColumnInfo>>,
) -> gio::SimpleAction {
    let action = gio::SimpleAction::new("go-to-reference", None);
    action.set_enabled(false);
    let view = column_view.downgrade();
    action.connect_activate(move |_, _| {
        let context = context.borrow();
        let Some(slot) = context.as_ref() else { return };
        let Some(view) = view.upgrade() else { return };
        let Some(cells) = row_at(&view, position(slot)) else {
            return;
        };
        let row = columns
            .iter()
            .zip(cells)
            .map(|(column, value)| (column.name.clone(), value))
            .collect();
        sender
            .send(GridMsg::GoToReference {
                column: slot.column_name.clone(),
                row,
            })
            .ok();
    });
    action
}

fn filter_by_value_action(
    context: Rc<RefCell<Option<CellContext>>>,
    sender: relm4::Sender<GridMsg>,
    column_view: &gtk::ColumnView,
    columns: Rc<Vec<ColumnInfo>>,
    local_result_view: Option<LocalResultView>,
) -> gio::ActionEntry<gio::SimpleActionGroup> {
    let view = column_view.downgrade();
    gio::ActionEntry::builder("filter-by-value")
        .activate(move |_, _, _| {
            let context = context.borrow();
            let Some(slot) = context.as_ref() else { return };
            let Some(view) = view.upgrade() else { return };
            let value = match &local_result_view {
                Some(_) => source_value_at(&view, position(slot), slot.col_index),
                None => row_at(&view, position(slot)).and_then(|row| row.get(slot.col_index).cloned()),
            };
            let Some(value) = value else { return };
            if let Some(local_result_view) = &local_result_view {
                local_result_view.filter_by_value(slot.col_index, value);
                return;
            }
            let Some(column) = columns.get(slot.col_index) else {
                return;
            };
            sender
                .send(GridMsg::FilterByValue {
                    column: column.name.clone(),
                    value,
                })
                .ok();
        })
        .build()
}

fn source_value_at(view: &gtk::ColumnView, position: u32, column: usize) -> Option<Value> {
    view.model()?
        .downcast::<gtk::MultiSelection>()
        .ok()?
        .model()?
        .downcast::<crate::ui::row_store::RowStore>()
        .ok()?
        .source_value_at(position, column)
}

fn copy_rows_action<F>(
    name: &'static str,
    context: Rc<RefCell<Option<CellContext>>>,
    sender: relm4::Sender<GridMsg>,
    column_view: &gtk::ColumnView,
    columns: Rc<Vec<ColumnInfo>>,
    render: F,
) -> gio::ActionEntry<gio::SimpleActionGroup>
where
    F: Fn(&[ColumnInfo], &[Vec<Value>]) -> String + 'static,
{
    let view = column_view.downgrade();
    gio::ActionEntry::builder(name)
        .activate(move |_, _, _| {
            let context = context.borrow();
            let Some(slot) = context.as_ref() else { return };
            let Some(view) = view.upgrade() else { return };
            let Some(rows) = rows_for_menu(&view, position(slot)) else {
                sender.send(GridMsg::IncompleteRowData).ok();
                return;
            };
            sender.send(GridMsg::CopyToClipboard(render(&columns, &rows))).ok();
        })
        .build()
}

pub(super) struct CellGestureOptions {
    pub(super) idx: usize,
    pub(super) column_name: String,
    pub(super) is_editable: bool,
    pub(super) is_text_editable: bool,
    pub(super) supports_full_value: bool,
}

pub(super) fn attach_cell_gesture(
    widget: &gtk::Widget,
    column_view: &gtk::ColumnView,
    options: CellGestureOptions,
    menus: &GridMenus,
) {
    let CellGestureOptions {
        idx,
        column_name,
        is_editable,
        is_text_editable,
        supports_full_value,
    } = options;
    let popover = if is_editable {
        menus.editable_popover.clone()
    } else {
        menus.readonly_popover.clone()
    };
    let gesture_widget = widget.clone();
    let view = column_view.clone();
    let context = menus.context.clone();
    let edit_action = menus.edit_action.clone();
    let edit_full_value_action = menus.edit_full_value_action.clone();
    let reference_action = menus.reference_action.clone();
    let foreign_key_columns = menus.foreign_key_columns.clone();
    let gesture_popover = popover.clone();
    let gesture_name = column_name.clone();
    let gesture = gtk::GestureClick::builder()
        .button(3)
        .propagation_phase(gtk::PropagationPhase::Capture)
        .build();
    gesture.connect_pressed(move |gesture, _, x, y| {
        gesture.set_state(gtk::EventSequenceState::Claimed);
        select_row_for_menu(&view, POSITION_SLOT.get(&gesture_widget).unwrap_or(0));
        *context.borrow_mut() = Some(CellContext {
            widget: gesture_widget.clone(),
            col_index: idx,
            column_name: gesture_name.clone(),
        });
        edit_action.set_enabled(edit_enabled_for(&gesture_widget, is_text_editable));
        edit_full_value_action.set_enabled(
            supports_full_value
                && row_has_full_text_value(
                    &view,
                    &gesture_widget,
                    POSITION_SLOT.get(&gesture_widget).unwrap_or(0),
                    idx,
                ),
        );
        reference_action.set_enabled(
            foreign_key_columns.contains(&gesture_name)
                && row_at(&view, POSITION_SLOT.get(&gesture_widget).unwrap_or(0))
                    .and_then(|row| row.get(idx).cloned())
                    .is_some_and(|value| !matches!(value, Value::Null)),
        );
        let local = gtk::graphene::Point::new(x as f32, y as f32);
        let (x, y) = gesture_widget
            .compute_point(&view, &local)
            .map(|point| (point.x() as i32, point.y() as i32))
            .unwrap_or((x as i32, y as i32));
        gesture_popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x, y, 1, 1)));
        gesture_popover.popup();
    });
    widget.add_controller(gesture);
    let key_widget = widget.clone();
    let key_view = column_view.clone();
    let key_context = menus.context.clone();
    let key_action = menus.edit_action.clone();
    let key_full_value_action = menus.edit_full_value_action.clone();
    let shortcut = gtk::Shortcut::builder()
        .trigger(&crate::ui::shortcut::parse(CELL_MENU_TRIGGER))
        .action(&gtk::CallbackAction::new(move |_, _| {
            select_row_for_menu(&key_view, POSITION_SLOT.get(&key_widget).unwrap_or(0));
            *key_context.borrow_mut() = Some(CellContext {
                widget: key_widget.clone(),
                col_index: idx,
                column_name: column_name.clone(),
            });
            key_action.set_enabled(edit_enabled_for(&key_widget, is_text_editable));
            key_full_value_action.set_enabled(
                supports_full_value
                    && row_has_full_text_value(
                        &key_view,
                        &key_widget,
                        POSITION_SLOT.get(&key_widget).unwrap_or(0),
                        idx,
                    ),
            );
            popover.set_pointing_to(
                key_widget
                    .compute_bounds(&key_view)
                    .map(|bounds| {
                        gtk::gdk::Rectangle::new(
                            bounds.x() as i32,
                            bounds.y() as i32,
                            bounds.width() as i32,
                            bounds.height() as i32,
                        )
                    })
                    .as_ref(),
            );
            popover.popup();
            glib::Propagation::Stop
        }))
        .build();
    let controller = gtk::ShortcutController::new();
    controller.add_shortcut(shortcut);
    widget.add_controller(controller);
}

fn edit_enabled_for(widget: &gtk::Widget, fallback: bool) -> bool {
    widget
        .downcast_ref::<crate::ui::cell_editor::CellEditor>()
        .map(|editor| editor.is_inline_editable())
        .unwrap_or(fallback)
}

fn position(slot: &CellContext) -> u32 {
    POSITION_SLOT.get(&slot.widget).unwrap_or(0)
}

enum TextSeed {
    Value(String, super::full_value_editor::FullValueKind),
    TooLarge,
    Unsupported,
}

fn full_value_seed(
    widget: &gtk::Widget,
    row: &crate::ui::row_object::RowObject,
    column: usize,
    data_type: &str,
) -> TextSeed {
    if IS_NULL_SLOT.get(widget).unwrap_or(false) {
        return super::full_value_editor::edit_kind(data_type, &Value::Null)
            .map(|kind| TextSeed::Value(String::new(), kind))
            .unwrap_or(TextSeed::Unsupported);
    }
    if let Some(size) = FULL_EDIT_TEXT_SLOT.with(widget, String::len) {
        if !super::full_value_editor::within_edit_budget(size) {
            return TextSeed::TooLarge;
        }
        let Some(text) = FULL_EDIT_TEXT_SLOT.cloned(widget) else {
            return TextSeed::Unsupported;
        };
        let Some(kind) = FULL_EDIT_KIND_SLOT.get(widget) else {
            return TextSeed::Unsupported;
        };
        return TextSeed::Value(text, kind);
    }
    row.with_cell_value(column, |value| match value {
        Value::Text(text) if super::full_value_editor::within_edit_budget(text.len()) => {
            super::full_value_editor::edit_kind(data_type, value)
                .map(|kind| TextSeed::Value(text.clone(), kind))
                .unwrap_or(TextSeed::Unsupported)
        }
        Value::Text(_) => TextSeed::TooLarge,
        value => super::full_value_editor::edit_kind(data_type, value)
            .map(|kind| {
                let text = super::display::value_to_full_edit_text(value);
                if super::full_value_editor::within_edit_budget(text.len()) {
                    TextSeed::Value(text, kind)
                } else {
                    TextSeed::TooLarge
                }
            })
            .unwrap_or(TextSeed::Unsupported),
    })
    .unwrap_or(TextSeed::Unsupported)
}

fn row_has_full_text_value(view: &gtk::ColumnView, widget: &gtk::Widget, position: u32, column: usize) -> bool {
    let Some(row) = row_object_at(view, position) else {
        return false;
    };
    let (_, row_key) = cell_row_identity(widget);
    (row.draft_id().is_some() || has_persisted_row_key(&row_key))
        && row
            .with_cell_value(column, |value| {
                matches!(
                    value,
                    Value::Text(_) | Value::Json(_) | Value::JsonText(_) | Value::Null
                )
            })
            .unwrap_or(false)
}

fn has_persisted_row_key(row_key: &[Value]) -> bool {
    crate::services::change_tracker::RowKey::from_pk_values(row_key).is_some()
}

fn cell_row_identity(widget: &gtk::Widget) -> (u32, Vec<Value>) {
    (
        POSITION_SLOT.get(widget).unwrap_or(0),
        ROW_KEY_SLOT.cloned(widget).unwrap_or_default(),
    )
}
fn pending_cell_value(widget: &gtk::Widget) -> Option<Value> {
    if IS_NULL_SLOT.get(widget).unwrap_or(false) {
        return Some(Value::Null);
    }
    FULL_EDIT_TEXT_SLOT.cloned(widget).map(Value::Text)
}
fn previewed_cell_text(row: Option<&crate::ui::row_object::RowObject>, col: usize) -> Option<String> {
    let row = row?;
    row.cell_preview(col)?;
    Some(super::display::value_to_full_edit_text(&row.cell_value(col)))
}

fn copy_value_text(widget: &gtk::Widget, row: Option<&crate::ui::row_object::RowObject>, col: usize) -> String {
    if !IS_NULL_SLOT.get(widget).unwrap_or(false) {
        if let Some(text) = FULL_EDIT_TEXT_SLOT.cloned(widget) {
            return text;
        }
        if let Some(text) = previewed_cell_text(row, col) {
            return text;
        }
    }
    cell_text(widget)
}

fn cell_text(widget: &gtk::Widget) -> String {
    if let Some(label) = widget.downcast_ref::<crate::ui::cell_editor::CellEditor>() {
        label.text().to_string()
    } else if let Some(label) = widget.downcast_ref::<gtk::Label>() {
        label.text().to_string()
    } else {
        String::new()
    }
}
fn row_at(view: &gtk::ColumnView, position: u32) -> Option<Vec<Value>> {
    row_object_at(view, position).map(|row| row.cells_clone())
}
fn row_object_at(view: &gtk::ColumnView, position: u32) -> Option<crate::ui::row_object::RowObject> {
    view.model()?
        .item(position)?
        .downcast::<crate::ui::row_object::RowObject>()
        .ok()
}
fn complete_row_at(view: &gtk::ColumnView, position: u32) -> Option<Vec<Value>> {
    let row = view
        .model()?
        .item(position)?
        .downcast::<crate::ui::row_object::RowObject>()
        .ok()?;
    row.complete_cells()
}
fn rows_for_menu(view: &gtk::ColumnView, clicked: u32) -> Option<Vec<Vec<Value>>> {
    complete_rows(
        selected_row_positions(view, clicked)
            .into_iter()
            .map(|position| complete_row_at(view, position)),
    )
}
fn values_for_column_menu(view: &gtk::ColumnView, clicked: u32, column: usize) -> Option<Vec<Vec<Value>>> {
    selected_row_positions(view, clicked)
        .into_iter()
        .map(|position| row_at(view, position)?.get(column).cloned().map(|value| vec![value]))
        .collect()
}
fn selected_row_positions(view: &gtk::ColumnView, clicked: u32) -> Vec<u32> {
    view.model()
        .and_then(|model| model.downcast::<gtk::MultiSelection>().ok())
        .map(|selection| selected_positions(&selection))
        .filter(|positions| !positions.is_empty())
        .unwrap_or_else(|| vec![clicked])
}
fn complete_rows(rows: impl Iterator<Item = Option<Vec<Value>>>) -> Option<Vec<Vec<Value>>> {
    rows.collect()
}
fn selected_positions(selection: &gtk::MultiSelection) -> Vec<u32> {
    let bitset = selection.selection();
    (0..bitset.size()).map(|index| bitset.nth(index as u32)).collect()
}
fn select_row_for_menu(view: &gtk::ColumnView, position: u32) {
    if let Some(selection) = view
        .model()
        .and_then(|model| model.downcast::<gtk::MultiSelection>().ok())
        && position < selection.n_items()
        && !selection.is_selected(position)
    {
        selection.select_item(position, true);
    }
}
fn export_snapshot(view: &gtk::ColumnView, columns: &[ColumnInfo], truncated: bool) -> Option<QueryResult> {
    Some(QueryResult {
        columns: columns.to_vec(),
        rows: complete_rows((0..view.model()?.n_items()).map(|position| complete_row_at(view, position)))?,
        truncated,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn copying_a_previewed_cell_copies_the_full_value() {
        gtk::init().unwrap();
        let full = "original".repeat(1_200);
        let row = crate::ui::row_object::RowObject::new(vec![Value::Text(full.clone())]);
        row.preview_values_from_result();
        let editor = crate::ui::cell_editor::CellEditor::new();
        editor.set_text("preview text");
        IS_NULL_SLOT.set(&editor, false);

        assert_eq!(copy_value_text(editor.upcast_ref(), Some(&row), 0), full);
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn copy_value_keeps_keyless_previews_pending_edits_and_drafts_whole() {
        gtk::init().unwrap();
        let original = "original".repeat(1_200);
        let keyless = crate::ui::row_object::RowObject::new(vec![Value::Text(original)]);
        keyless.preview_values_from_result();
        let pending = "pending".repeat(1_200);
        let editor = crate::ui::cell_editor::CellEditor::new();
        editor.set_inline_editable(true);
        editor.set_text("pending preview");
        IS_NULL_SLOT.set(&editor, false);
        FULL_EDIT_TEXT_SLOT.set(&editor, pending.clone());
        assert_eq!(
            copy_value_text(editor.upcast_ref(), Some(&keyless), 0),
            pending,
            "a pending edit on a keyless query must copy the current full value"
        );

        let draft_value = "draft".repeat(1_200);
        let draft = crate::ui::row_object::RowObject::new_draft(1, vec![Value::Text(draft_value.clone())]);
        editor.set_text("draft preview");
        IS_NULL_SLOT.set(&editor, false);
        FULL_EDIT_TEXT_SLOT.set(&editor, draft_value.clone());
        assert_eq!(copy_value_text(editor.upcast_ref(), Some(&draft), 0), draft_value);
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn view_value_resolves_pending_text_null_and_draft_values_from_the_cell() {
        gtk::init().unwrap();
        let editor = crate::ui::cell_editor::CellEditor::new();
        let widget = editor.upcast_ref::<gtk::Widget>();
        let pending = "new value".repeat(1_200);
        IS_NULL_SLOT.set(&editor, false);
        FULL_EDIT_TEXT_SLOT.set(&editor, pending.clone());
        assert_eq!(pending_cell_value(widget), Some(Value::Text(pending.clone())));

        IS_NULL_SLOT.set(&editor, true);
        FULL_EDIT_TEXT_SLOT.take(&editor);
        assert_eq!(pending_cell_value(widget), Some(Value::Null));

        IS_NULL_SLOT.set(&editor, false);
        assert_eq!(pending_cell_value(widget), None);

        FULL_EDIT_TEXT_SLOT.set(&editor, pending.clone());
        assert_eq!(pending_cell_value(widget), Some(Value::Text(pending)));
    }

    #[test]
    fn export_rows_refuse_an_incomplete_page() {
        assert!(complete_rows([Some(vec![Value::Int(1)]), None].into_iter()).is_none());
        assert_eq!(
            complete_rows([Some(vec![Value::Int(1)])].into_iter()),
            Some(vec![vec![Value::Int(1)]])
        );
    }

    #[test]
    fn full_value_edit_requires_a_persisted_key_or_a_draft_identity() {
        assert!(!has_persisted_row_key(&[]));
        assert!(!has_persisted_row_key(&[Value::Undecodable("text".into())]));
        assert!(has_persisted_row_key(&[Value::Int(7)]));
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn the_cell_menu_opens_with_the_menu_key_and_shift_f10() {
        relm4::adw::init().unwrap();
        let trigger = crate::ui::shortcut::parse(CELL_MENU_TRIGGER);
        assert!(!trigger.is::<gtk::NeverTrigger>());
        let text = trigger.to_str().to_string();
        assert!(text.contains("Menu"), "{text}");
        assert!(text.contains("<Shift>F10"), "{text}");
    }
}

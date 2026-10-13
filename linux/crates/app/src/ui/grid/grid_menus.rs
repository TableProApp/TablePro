use std::cell::RefCell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, gio};

use tablepro_core::column::ResultColumn;

use super::cell_editor::CellEditor;
use super::context_menu::{CellContext, CellMenuTarget, ClickedCell};
use super::inline_edit::enter_edit_mode;
use super::row_json_dialog::show_row_json_dialog;
use super::selection::{export_snapshot, row_at, rows_for_menu};
use super::widget_slot::POSITION_SLOT;
use super::{CellPreset, GridMsg, TabGridContext};

/// Enabled per right-clicked cell. Their items are hidden while
/// disabled, so a cell they do not apply to shows no dead entry. `None`
/// on a read-only grid, which registers neither.
#[derive(Clone, Default)]
pub(super) struct CellActions {
    edit: Option<gio::SimpleAction>,
    set_empty: Option<gio::SimpleAction>,
}

impl CellActions {
    pub(super) fn arm(&self, target: &CellMenuTarget) {
        if let Some(edit) = &self.edit {
            edit.set_enabled(target.text_editable);
        }
        if let Some(set_empty) = &self.set_empty {
            set_empty.set_enabled(target.accepts_empty);
        }
    }
}

#[derive(Clone)]
pub(super) struct GridMenus {
    pub(super) context: Rc<RefCell<Option<ClickedCell>>>,
    pub(super) editable_popover: gtk::PopoverMenu,
    pub(super) readonly_popover: gtk::PopoverMenu,
    pub(super) actions: CellActions,
}

#[derive(Clone, Copy)]
struct MenuShape {
    edit_cell: bool,
    set_value: bool,
    row_ops: bool,
}

impl MenuShape {
    const READ_ONLY: MenuShape = MenuShape {
        edit_cell: false,
        set_value: false,
        row_ops: false,
    };
    const ROW_OPS: MenuShape = MenuShape {
        edit_cell: false,
        set_value: false,
        row_ops: true,
    };
    const FULL: MenuShape = MenuShape {
        edit_cell: true,
        set_value: true,
        row_ops: true,
    };
}

fn build_cell_menu(shape: MenuShape) -> gio::Menu {
    let menu = gio::Menu::new();
    if shape.edit_cell {
        let edit_section = gio::Menu::new();
        let edit_item = gio::MenuItem::new(Some(&crate::i18n::gettext("Edit cell")), Some("cell.edit"));
        edit_item.set_attribute_value("hidden-when", Some(&"action-disabled".to_variant()));
        edit_section.append_item(&edit_item);
        menu.append_section(None, &edit_section);
    }

    let copy_as = gio::Menu::new();
    copy_as.append(Some(&crate::i18n::gettext("Rows")), Some("cell.copy-rows"));
    copy_as.append(
        Some(&crate::i18n::gettext("With Headers")),
        Some("cell.copy-rows-headers"),
    );
    copy_as.append(Some(&crate::i18n::gettext("JSON")), Some("cell.copy-json"));
    copy_as.append(Some(&crate::i18n::gettext("CSV")), Some("cell.copy-csv"));
    copy_as.append(
        Some(&crate::i18n::gettext("CSV with Headers")),
        Some("cell.copy-csv-headers"),
    );
    copy_as.append(Some(&crate::i18n::gettext("Markdown")), Some("cell.copy-markdown"));
    copy_as.append(Some(&crate::i18n::gettext("IN Clause")), Some("cell.copy-in-clause"));
    if shape.row_ops {
        let sql_section = gio::Menu::new();
        sql_section.append(
            Some(&crate::i18n::gettext("INSERT Statement")),
            Some("cell.copy-row-insert"),
        );
        copy_as.append_section(None, &sql_section);
    }
    let copy_section = gio::Menu::new();
    copy_section.append(Some(&crate::i18n::gettext("Copy")), Some("cell.copy"));
    copy_section.append_submenu(Some(&crate::i18n::gettext("Copy as")), &copy_as);
    copy_section.append(
        Some(&crate::i18n::gettext("Copy column name")),
        Some("cell.copy-column-name"),
    );
    menu.append_section(None, &copy_section);

    let json_section = gio::Menu::new();
    json_section.append(
        Some(&crate::i18n::gettext("Show Row as JSON")),
        Some("cell.show-row-json"),
    );
    menu.append_section(None, &json_section);

    let action_section = gio::Menu::new();
    if shape.set_value {
        let set_value = gio::Menu::new();
        // Only a free-text column can hold an empty string: elsewhere
        // "Empty" would either be rejected by the server or mean NULL,
        // which the item below already says plainly.
        let empty_item = gio::MenuItem::new(Some(&crate::i18n::gettext("Empty")), Some("cell.set-empty"));
        empty_item.set_attribute_value("hidden-when", Some(&"action-disabled".to_variant()));
        set_value.append_item(&empty_item);
        set_value.append(Some("NULL"), Some("cell.set-null"));
        action_section.append_submenu(Some(&crate::i18n::gettext("Set Value")), &set_value);
    }
    action_section.append(Some(&crate::i18n::gettext("Export Results…")), Some("cell.export"));
    if shape.row_ops {
        action_section.append(Some(&crate::i18n::gettext("Insert row")), Some("cell.insert-row"));
        action_section.append(Some(&crate::i18n::gettext("Duplicate")), Some("cell.duplicate-row"));
        action_section.append(Some(&crate::i18n::gettext("Delete")), Some("cell.delete-row"));
    }
    menu.append_section(None, &action_section);
    menu
}

pub(super) struct GridMenuInit<'a> {
    pub(super) column_view: &'a gtk::ColumnView,
    pub(super) sender: relm4::Sender<GridMsg>,
    pub(super) columns: std::sync::Arc<[ResultColumn]>,
    /// From the fetch that filled the grid, so Export Results reports the
    /// same truncation the paginator does.
    pub(super) truncated: bool,
    pub(super) tab_ctx: TabGridContext,
    pub(super) editable: bool,
}

pub(super) fn install_grid_context_menus(init: GridMenuInit<'_>) -> GridMenus {
    let GridMenuInit {
        column_view,
        sender,
        columns,
        truncated,
        tab_ctx,
        editable,
    } = init;
    let context: Rc<RefCell<Option<ClickedCell>>> = Rc::new(RefCell::new(None));
    // Every action closure holds the view weakly. The action group
    // belongs to the ColumnView, so a strong clone in a closure is a
    // cycle: the grid, its selection model, its store and every row it
    // holds would outlive the page that built them.
    let view = column_view.downgrade();
    let tab = Rc::new(tab_ctx);

    let group = gio::SimpleActionGroup::new();
    let slot_position = |slot: &CellContext| POSITION_SLOT.get(&slot.widget).unwrap_or(0);

    macro_rules! cell_action {
        ($name:literal, |$slot:ident| $body:expr) => {{
            let ctx = context.clone();
            gio::ActionEntry::builder($name)
                .activate(move |_, _, _| {
                    let clicked = ctx.borrow().as_ref().and_then(ClickedCell::get);
                    if let Some($slot) = clicked.as_ref() {
                        $body;
                    }
                })
                .build()
        }};
    }
    fn clipboard_message(encoded: Result<String, tablepro_core::export::EncodeError>) -> GridMsg {
        match encoded {
            Ok(text) => GridMsg::CopyToClipboard(text),
            Err(error) => GridMsg::ShowToast(crate::i18n::gettext_f(
                "Couldn't copy the selection: {error}",
                &[("error", &error.to_string())],
            )),
        }
    }
    macro_rules! copy_action {
        ($name:literal, |$slot:ident, $rows:ident| $message:expr) => {{
            let s = sender.clone();
            let view = view.clone();
            let tab = tab.clone();
            cell_action!($name, |$slot| {
                let Some(cv) = view.upgrade() else { return };
                let $rows = rows_for_menu(&cv, &tab, slot_position($slot));
                s.send($message).ok();
            })
        }};
    }
    macro_rules! send_action {
        ($name:literal, |$slot:ident| $msg:expr) => {{
            let s = sender.clone();
            cell_action!($name, |$slot| s.send($msg).ok())
        }};
    }

    let edit_action = cell_action!("edit", |slot| {
        if let Ok(label) = slot.widget.clone().downcast::<CellEditor>() {
            enter_edit_mode(&label);
        }
    });
    // Plain Copy reads the cell's value, never the widget's text: the
    // widget carries the display form, which is the `<NULL>` sentinel,
    // the `(auto)` placeholder, `<N bytes>` for a blob and a value cut
    // at the 10k display cap.
    let copy_action = {
        let s = sender.clone();
        let view = view.clone();
        let tab = tab.clone();
        let cols = columns.clone();
        cell_action!("copy", |slot| {
            let Some(cv) = view.upgrade() else { return };
            let rows = rows_for_menu(&cv, &tab, slot_position(slot));
            let message = match rows.as_slice() {
                [row] => GridMsg::CopyToClipboard(
                    row.get(slot.col_index)
                        .and_then(|value| tablepro_core::export::cell_text(&cols, slot.col_index, value))
                        .unwrap_or_default(),
                ),
                many => clipboard_message(tablepro_core::export::render_tsv(&cols, many, false)),
            };
            s.send(message).ok();
        })
    };
    let copy_rows_action = {
        let cols = columns.clone();
        copy_action!("copy-rows", |_slot, rows| clipboard_message(
            tablepro_core::export::render_tsv(&cols, &rows, false)
        ))
    };
    let copy_rows_headers_action = {
        let cols = columns.clone();
        copy_action!("copy-rows-headers", |_slot, rows| clipboard_message(
            tablepro_core::export::render_tsv(&cols, &rows, true)
        ))
    };
    let copy_json_action = {
        let cols = columns.clone();
        copy_action!("copy-json", |_slot, rows| GridMsg::CopyToClipboard(
            tablepro_core::export::render_json(&cols, &rows)
        ))
    };
    let copy_csv_action = {
        let cols = columns.clone();
        copy_action!("copy-csv", |_slot, rows| clipboard_message(
            tablepro_core::export::render_csv(
                &cols,
                &rows,
                &tablepro_core::export::CsvOptions {
                    header_row: false,
                    ..Default::default()
                }
            )
        ))
    };
    let copy_csv_headers_action = {
        let cols = columns.clone();
        copy_action!("copy-csv-headers", |_slot, rows| clipboard_message(
            tablepro_core::export::render_csv(&cols, &rows, &tablepro_core::export::CsvOptions::default())
        ))
    };
    let copy_markdown_action = {
        let cols = columns.clone();
        copy_action!("copy-markdown", |_slot, rows| GridMsg::CopyToClipboard(
            tablepro_core::export::render_markdown(&cols, &rows)
        ))
    };
    // NULL and binary values have no place in an IN list, so the
    // clause says how many it left out instead of handing back a
    // shorter list that quietly selects different rows.
    let copy_in_clause_action = {
        let s = sender.clone();
        let view = view.clone();
        let tab = tab.clone();
        cell_action!("copy-in-clause", |slot| {
            let Some(cv) = view.upgrade() else { return };
            let rows = rows_for_menu(&cv, &tab, slot_position(slot));
            let clause = tablepro_core::export::render_in_clause(&rows, slot.col_index);
            if clause.sql.is_empty() {
                s.send(GridMsg::ShowToast(crate::i18n::gettext(
                    "Nothing to copy: an IN clause can't carry NULL or binary values",
                )))
                .ok();
                return;
            }
            s.send(GridMsg::CopyToClipboard(clause.sql)).ok();
            if clause.skipped > 0 {
                s.send(GridMsg::ShowToast(crate::i18n::gettext_f(
                    "{n} NULL or binary values left out of the IN clause",
                    &[("n", &clause.skipped.to_string())],
                )))
                .ok();
            }
        })
    };
    let copy_column_name_action = send_action!("copy-column-name", |slot| GridMsg::CopyToClipboard(
        slot.column_name.clone()
    ));
    let copy_row_insert_action = send_action!("copy-row-insert", |slot| GridMsg::CopyRowAsInsert {
        row_position: slot_position(slot),
    });
    let show_row_json_action = {
        let cols = columns.clone();
        let view = view.clone();
        let tab = tab.clone();
        cell_action!("show-row-json", |slot| {
            let Some(cv) = view.upgrade() else { return };
            let Some(row) = row_at(&cv, slot_position(slot)) else {
                return;
            };
            let text = tablepro_core::export::row_to_json(&cols, &tab.effective_cells(&row));
            show_row_json_dialog(&cv, text);
        })
    };
    let set_empty_action = send_action!("set-empty", |slot| GridMsg::SetCellValue {
        row_position: slot_position(slot),
        col_index: slot.col_index,
        preset: CellPreset::Empty,
    });
    let set_null_action = send_action!("set-null", |slot| GridMsg::SetCellValue {
        row_position: slot_position(slot),
        col_index: slot.col_index,
        preset: CellPreset::Null,
    });
    let export_action = {
        let s = sender.clone();
        let view = view.clone();
        let cols = columns.clone();
        let tab = tab.clone();
        gio::ActionEntry::builder("export")
            .activate(move |_, _, _| {
                let Some(cv) = view.upgrade() else { return };
                s.send(GridMsg::ExportResults(export_snapshot(&cv, &cols, truncated, &tab)))
                    .ok();
            })
            .build()
    };
    let insert_row_action = {
        let s = sender.clone();
        gio::ActionEntry::builder("insert-row")
            .activate(move |_, _, _| {
                s.send(GridMsg::InsertRow).ok();
            })
            .build()
    };
    let delete_row_action = send_action!("delete-row", |slot| GridMsg::DeleteRowAt {
        row_position: slot_position(slot),
    });
    let duplicate_row_action = send_action!("duplicate-row", |slot| GridMsg::DuplicateRow {
        row_position: slot_position(slot),
    });

    let mut entries = vec![
        copy_action,
        copy_rows_action,
        copy_rows_headers_action,
        copy_json_action,
        copy_csv_action,
        copy_csv_headers_action,
        copy_markdown_action,
        copy_in_clause_action,
        copy_column_name_action,
        show_row_json_action,
        export_action,
    ];
    // A read-only grid registers none of the mutating actions: it
    // shows no menu item for them, and the editor throws their
    // messages away at the far end.
    if editable {
        entries.extend([
            edit_action,
            set_empty_action,
            set_null_action,
            copy_row_insert_action,
            insert_row_action,
            delete_row_action,
            duplicate_row_action,
        ]);
    }
    group.add_action_entries(entries);
    column_view.insert_action_group("cell", Some(&group));

    let actions = CellActions {
        edit: editable.then(|| simple_action(&group, "edit")).flatten(),
        set_empty: editable.then(|| simple_action(&group, "set-empty")).flatten(),
    };

    // Popovers are parented eagerly so each PopoverMenu's action muxer
    // snapshots the ColumnView's `cell` group at set_parent() time.
    // Lazy parenting in the gesture handler drops every activation
    // silently.
    let make_popover = |shape: MenuShape| {
        let popover = gtk::PopoverMenu::from_model_full(&build_cell_menu(shape), gtk::PopoverMenuFlags::NESTED);
        popover.set_has_arrow(true);
        popover.set_parent(column_view);
        popover
    };
    // A read-only grid has a single shape and both fields name it.
    let (editable_popover, readonly_popover) = if editable {
        (make_popover(MenuShape::FULL), make_popover(MenuShape::ROW_OPS))
    } else {
        let readonly = make_popover(MenuShape::READ_ONLY);
        (readonly.clone(), readonly)
    };

    let mut popovers_for_destroy = vec![editable_popover.clone()];
    if readonly_popover != editable_popover {
        popovers_for_destroy.push(readonly_popover.clone());
    }

    if editable {
        let empty_menu = gio::Menu::new();
        empty_menu.append(Some(&crate::i18n::gettext("Insert row")), Some("cell.insert-row"));
        let empty_popover = gtk::PopoverMenu::from_model_full(&empty_menu, gtk::PopoverMenuFlags::NESTED);
        empty_popover.set_has_arrow(true);
        empty_popover.set_parent(column_view);
        popovers_for_destroy.push(empty_popover.clone());

        let view_for_empty = view.clone();
        let empty_gesture = gtk::GestureClick::builder().button(3).build();
        empty_gesture.connect_pressed(move |g, _, x, y| {
            let Some(cv) = view_for_empty.upgrade() else { return };
            let cv_widget: gtk::Widget = cv.clone().upcast();
            if let Some(picked) = cv.pick(x, y, gtk::PickFlags::DEFAULT)
                && picked != cv_widget
            {
                return;
            }
            g.set_state(gtk::EventSequenceState::Claimed);
            empty_popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            empty_popover.popup();
        });
        column_view.add_controller(empty_gesture);
    }

    column_view.connect_destroy(move |_| {
        for popover in &popovers_for_destroy {
            popover.unparent();
        }
    });

    GridMenus {
        context,
        editable_popover,
        readonly_popover,
        actions,
    }
}

fn simple_action(group: &gio::SimpleActionGroup, name: &str) -> Option<gio::SimpleAction> {
    group
        .lookup_action(name)
        .and_then(|a| a.downcast::<gio::SimpleAction>().ok())
}

use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, gio};

use tablepro_core::column::ResultColumn;

use super::context_menu::{CellContext, CellMenuTarget};
use super::inline_edit::enter_edit_mode;
use super::menu_rows::menu_rows_of;
use super::row_json_dialog::show_row_json_dialog;
use super::selection::export_snapshot;
use super::{CellPreset, DeleteAvailability, GridMsg, GridSink, RowObject, TabGridContext, delete_availability};

/// Enabled per right-clicked cell. `None` on a read-only grid, which
/// registers none of them.
#[derive(Clone, Default)]
pub(super) struct CellActions {
    /// Hidden while disabled, so a cell they do not apply to shows no
    /// dead entry.
    edit: Option<gio::SimpleAction>,
    set_empty: Option<gio::SimpleAction>,
    /// Shown insensitive while disabled, since a menu item cannot carry
    /// a tooltip to say why.
    delete_row: Option<gio::SimpleAction>,
}

impl CellActions {
    /// `rows` is what the menu acts on, read when it opens.
    pub(super) fn arm(&self, target: &CellMenuTarget, rows: &[RowObject]) {
        if let Some(edit) = &self.edit {
            edit.set_enabled(target.text_editable);
        }
        if let Some(set_empty) = &self.set_empty {
            set_empty.set_enabled(target.accepts_empty);
        }
        if let Some(delete_row) = &self.delete_row {
            let availability = delete_availability(rows.iter().map(RowObject::id), false);
            delete_row.set_enabled(availability == DeleteAvailability::Available);
        }
    }
}

#[derive(Clone)]
pub(super) struct GridMenus {
    pub(super) context: Rc<CellContext>,
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
    pub(super) sink: GridSink,
    pub(super) columns: std::sync::Arc<[ResultColumn]>,
    /// From the fetch that filled the grid, so Export Results reports the
    /// same truncation the paginator does.
    pub(super) truncated: bool,
    pub(super) tab_ctx: TabGridContext,
}

pub(super) fn install_grid_context_menus(init: GridMenuInit<'_>) -> GridMenus {
    let GridMenuInit {
        column_view,
        sink,
        columns,
        truncated,
        tab_ctx,
    } = init;
    let editable = tab_ctx.editable;
    let context = Rc::new(CellContext::default());
    // Every action closure holds the view weakly. The action group
    // belongs to the ColumnView, so a strong clone in a closure is a
    // cycle: the grid, its selection model, its store and every row it
    // holds would outlive the page that built them.
    let view = column_view.downgrade();
    let tab = Rc::new(tab_ctx);

    let group = gio::SimpleActionGroup::new();

    // The row is the one the cell shows when the item is chosen, which
    // is still the clicked one after rows above it came or went.
    macro_rules! cell_action {
        ($name:literal, |$cell:ident, $row:ident| $body:expr) => {{
            let ctx = context.clone();
            gio::ActionEntry::builder($name)
                .activate(move |_, _, _| {
                    let Some($cell) = ctx.cell() else { return };
                    let Some($row) = $cell.row() else { return };
                    let $cell = &$cell;
                    $body;
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
    // The rows each item acts on are read when it is chosen, from the
    // row the cell shows then.
    macro_rules! rows_action {
        ($name:literal, |$cell:ident, $rows:ident| $body:expr) => {{
            let view = view.clone();
            cell_action!($name, |$cell, _row| {
                let Some(cv) = view.upgrade() else { return };
                let $rows = menu_rows_of(&cv, $cell);
                $body;
            })
        }};
    }
    macro_rules! copy_action {
        ($name:literal, |$rows:ident| $message:expr) => {{
            let s = sink.clone();
            let tab = tab.clone();
            rows_action!($name, |_cell, rows| {
                let $rows: Vec<_> = rows.iter().map(|row| tab.effective_cells(row)).collect();
                s($message);
            })
        }};
    }
    macro_rules! send_action {
        ($name:literal, |$cell:ident, $row:ident| $msg:expr) => {{
            let s = sink.clone();
            cell_action!($name, |$cell, $row| s($msg))
        }};
    }

    let edit_action = cell_action!("edit", |cell, _row| enter_edit_mode(cell));
    // Plain Copy reads the cell's value, never the widget's text: the
    // widget carries the display form, which is the `<NULL>` sentinel,
    // the `(auto)` placeholder, `<N bytes>` for a blob and a value cut
    // at the 10k display cap.
    let copy_action = {
        let s = sink.clone();
        let tab = tab.clone();
        let cols = columns.clone();
        rows_action!("copy", |cell, rows| {
            let rows: Vec<_> = rows.iter().map(|row| tab.effective_cells(row)).collect();
            let column = cell.column();
            let message = match rows.as_slice() {
                [row] => GridMsg::CopyToClipboard(
                    row.get(column)
                        .and_then(|value| tablepro_core::export::cell_text(&cols, column, value))
                        .unwrap_or_default(),
                ),
                many => clipboard_message(tablepro_core::export::render_tsv(&cols, many, false)),
            };
            s(message);
        })
    };
    let copy_rows_action = {
        let cols = columns.clone();
        copy_action!("copy-rows", |rows| clipboard_message(
            tablepro_core::export::render_tsv(&cols, &rows, false)
        ))
    };
    let copy_rows_headers_action = {
        let cols = columns.clone();
        copy_action!("copy-rows-headers", |rows| clipboard_message(
            tablepro_core::export::render_tsv(&cols, &rows, true)
        ))
    };
    let copy_json_action = {
        let cols = columns.clone();
        copy_action!("copy-json", |rows| GridMsg::CopyToClipboard(
            tablepro_core::export::render_json(&cols, &rows)
        ))
    };
    let copy_csv_action = {
        let cols = columns.clone();
        copy_action!("copy-csv", |rows| clipboard_message(tablepro_core::export::render_csv(
            &cols,
            &rows,
            &tablepro_core::export::CsvOptions {
                header_row: false,
                ..Default::default()
            }
        )))
    };
    let copy_csv_headers_action = {
        let cols = columns.clone();
        copy_action!("copy-csv-headers", |rows| clipboard_message(
            tablepro_core::export::render_csv(&cols, &rows, &tablepro_core::export::CsvOptions::default())
        ))
    };
    let copy_markdown_action = {
        let cols = columns.clone();
        copy_action!("copy-markdown", |rows| GridMsg::CopyToClipboard(
            tablepro_core::export::render_markdown(&cols, &rows)
        ))
    };
    // NULL and binary values have no place in an IN list, so the
    // clause says how many it left out instead of handing back a
    // shorter list that quietly selects different rows.
    let copy_in_clause_action = {
        let s = sink.clone();
        let tab = tab.clone();
        rows_action!("copy-in-clause", |cell, rows| {
            let rows: Vec<_> = rows.iter().map(|row| tab.effective_cells(row)).collect();
            let clause = tablepro_core::export::render_in_clause(&rows, cell.column());
            if clause.sql.is_empty() {
                s(GridMsg::ShowToast(crate::i18n::gettext(
                    "Nothing to copy: an IN clause can't carry NULL or binary values",
                )));
                return;
            }
            s(GridMsg::CopyToClipboard(clause.sql));
            if clause.skipped > 0 {
                s(GridMsg::ShowToast(crate::i18n::gettext_f(
                    "{n} NULL or binary values left out of the IN clause",
                    &[("n", &clause.skipped.to_string())],
                )));
            }
        })
    };
    let copy_column_name_action = {
        let cols = columns.clone();
        send_action!("copy-column-name", |cell, _row| GridMsg::CopyToClipboard(
            cols.get(cell.column())
                .map(|column| column.name.clone())
                .unwrap_or_default()
        ))
    };
    let copy_row_insert_action = {
        let s = sink.clone();
        rows_action!("copy-row-insert", |_cell, rows| s(GridMsg::CopyRowsAsInsert { rows }))
    };
    let show_row_json_action = {
        let cols = columns.clone();
        let view = view.clone();
        let tab = tab.clone();
        cell_action!("show-row-json", |_cell, row| {
            let Some(cv) = view.upgrade() else { return };
            let text = tablepro_core::export::row_to_json(&cols, &tab.effective_cells(&row));
            show_row_json_dialog(&cv, text);
        })
    };
    let set_empty_action = send_action!("set-empty", |cell, row| GridMsg::SetCellValue {
        row,
        column: cell.column(),
        preset: CellPreset::Empty,
    });
    let set_null_action = send_action!("set-null", |cell, row| GridMsg::SetCellValue {
        row,
        column: cell.column(),
        preset: CellPreset::Null,
    });
    let export_action = {
        let s = sink.clone();
        let view = view.clone();
        let cols = columns.clone();
        let tab = tab.clone();
        gio::ActionEntry::builder("export")
            .activate(move |_, _, _| {
                let Some(cv) = view.upgrade() else { return };
                s(GridMsg::ExportResults(export_snapshot(&cv, &cols, truncated, &tab)));
            })
            .build()
    };
    let insert_row_action = {
        let s = sink.clone();
        gio::ActionEntry::builder("insert-row")
            .activate(move |_, _, _| s(GridMsg::InsertRow))
            .build()
    };
    let delete_row_action = {
        let s = sink.clone();
        rows_action!("delete-row", |_cell, rows| s(GridMsg::DeleteRows { rows }))
    };
    let duplicate_row_action = {
        let s = sink.clone();
        rows_action!("duplicate-row", |_cell, rows| s(GridMsg::DuplicateRows { rows }))
    };

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
        delete_row: editable.then(|| simple_action(&group, "delete-row")).flatten(),
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

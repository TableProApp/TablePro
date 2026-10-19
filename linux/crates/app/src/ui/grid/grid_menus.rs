use std::rc::Rc;
use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{self as gtk, gio, glib};

use tablepro_core::column::ResultColumn;

use super::cell_edit::begin_edit;
use super::cell_editor_kind::CellEditorKind;
use super::cell_preset::cell_presets;
use super::column_resize::{ColumnResize, resize_column};
use super::context_menu::{CellContext, MenuTarget};
use super::grid_columns::ShownColumn;
use super::row_json_dialog::RowJsonRequest;
use super::selection::export_snapshot;
use super::{
    CellPreset, DeleteAvailability, GridCell, GridMsg, GridSink, RowObject, RowSnapshot, TabGridContext,
    delete_availability,
};
use crate::ui::clipboard::{CopyKind, CopyRequest, InClauseRows};

/// Enabled per right-clicked cell. `None` on a read-only grid, which
/// registers none of them.
#[derive(Clone, Default)]
pub(super) struct CellActions {
    /// Hidden while disabled, so a cell they do not apply to shows no
    /// dead entry.
    edit: Option<gio::SimpleAction>,
    set_empty: Option<gio::SimpleAction>,
    set_null: Option<gio::SimpleAction>,
    set_default: Option<gio::SimpleAction>,
    /// Shown insensitive while disabled, since a menu item cannot carry
    /// a tooltip to say why.
    delete_row: Option<gio::SimpleAction>,
    /// On while the rows are sorted.
    clear_sort: Option<gio::SimpleAction>,
}

impl CellActions {
    /// Set for `cell` and `rows`, what the menu acts on, as it opens.
    pub(super) fn arm(&self, cell: &GridCell, rows: &[RowObject]) {
        let column = cell.drawing().and_then(|drawing| drawing.catalog.clone());
        let row = cell.row();
        let editor = column
            .as_ref()
            .map(|column| CellEditorKind::for_cell(column, cell.lock().map_or(Ok(()), Err)));
        let presets = column
            .as_ref()
            .zip(row.as_ref())
            .map(|(column, row)| cell_presets(column, row.id()));
        let enable = |action: &Option<gio::SimpleAction>, enabled: bool| {
            if let Some(action) = action {
                action.set_enabled(enabled);
            }
        };
        enable(
            &self.edit,
            matches!(
                editor,
                Some(CellEditorKind::Inline { .. } | CellEditorKind::Multiline { .. } | CellEditorKind::Calendar)
            ),
        );
        enable(&self.set_empty, presets.is_some_and(|presets| presets.empty));
        enable(&self.set_null, presets.is_some_and(|presets| presets.null));
        enable(&self.set_default, presets.is_some_and(|presets| presets.default));
        if let Some(delete_row) = &self.delete_row {
            let availability = delete_availability(rows.iter().map(RowObject::id), false);
            delete_row.set_enabled(availability == DeleteAvailability::Available);
        }
        let sorted = cell
            .column_view()
            .and_then(|view| view.sorter())
            .and_downcast::<gtk::ColumnViewSorter>()
            .is_some_and(|sorter| sorter.primary_sort_column().is_some());
        enable(&self.clear_sort, sorted);
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
    let edit_section = gio::Menu::new();
    let hidden_while_disabled = |label: String, action: &str| {
        let item = crate::application::menu_item(&label, action);
        item.set_attribute_value("hidden-when", Some(&"action-disabled".to_variant()));
        edit_section.append_item(&item);
    };
    if shape.edit_cell {
        hidden_while_disabled(crate::i18n::gettext("Edit Cell"), "cell.edit");
    }
    if shape.set_value {
        // Each is offered only where the column can hold it, so a menu
        // never offers a value the save would refuse.
        hidden_while_disabled(crate::i18n::gettext("Set to Empty"), "cell.set-empty");
        hidden_while_disabled(crate::i18n::gettext("Set to NULL"), "cell.set-null");
        hidden_while_disabled(crate::i18n::gettext("Set to DEFAULT"), "cell.set-default");
    }
    if shape.edit_cell || shape.set_value {
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
        Some(&crate::i18n::gettext("CSV With Headers")),
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
    copy_section.append_submenu(Some(&crate::i18n::gettext("Copy As")), &copy_as);
    copy_section.append(
        Some(&crate::i18n::gettext("Copy Column Name")),
        Some("cell.copy-column-name"),
    );
    menu.append_section(None, &copy_section);

    let json_section = gio::Menu::new();
    json_section.append(
        Some(&crate::i18n::gettext("Show Row as JSON")),
        Some("cell.show-row-json"),
    );
    menu.append_section(None, &json_section);

    // A header's click and drag, which no key reaches.
    let column_section = gio::Menu::new();
    column_section.append(
        Some(&crate::i18n::gettext("Sort Ascending")),
        Some("cell.sort-ascending"),
    );
    column_section.append(
        Some(&crate::i18n::gettext("Sort Descending")),
        Some("cell.sort-descending"),
    );
    column_section.append(Some(&crate::i18n::gettext("Clear Sort")), Some("cell.clear-sort"));
    column_section.append_item(&crate::application::menu_item(
        &crate::i18n::gettext("Widen Column"),
        "cell.widen-column",
    ));
    column_section.append_item(&crate::application::menu_item(
        &crate::i18n::gettext("Narrow Column"),
        "cell.narrow-column",
    ));
    column_section.append(
        Some(&crate::i18n::gettext("Reset Column Width")),
        Some("cell.reset-width"),
    );
    menu.append_section(None, &column_section);

    let action_section = gio::Menu::new();
    action_section.append(Some(&crate::i18n::gettext("Export…")), Some("cell.export"));
    if shape.row_ops {
        action_section.append(Some(&crate::i18n::gettext("Insert Row")), Some("cell.insert-row"));
        action_section.append(Some(&crate::i18n::gettext("Duplicate")), Some("cell.duplicate-row"));
        action_section.append(Some(&crate::i18n::gettext("Delete")), Some("cell.delete-row"));
    }
    menu.append_section(None, &action_section);
    menu
}

pub(super) struct GridMenuInit<'a> {
    pub(super) column_view: &'a gtk::ColumnView,
    pub(super) sink: GridSink,
    pub(super) columns: Arc<[ResultColumn]>,
    pub(super) tab_ctx: TabGridContext,
}

pub(super) fn install_grid_context_menus(init: GridMenuInit<'_>) -> GridMenus {
    let GridMenuInit {
        column_view,
        sink,
        columns,
        tab_ctx,
    } = init;
    let editable = tab_ctx.editable;
    let kit = CellActionKit {
        context: Rc::new(CellContext::default()),
        view: column_view.downgrade(),
        sink,
        columns,
        tab: Rc::new(tab_ctx),
    };

    let group = gio::SimpleActionGroup::new();
    let mut entries = kit.reading_entries();
    // A read-only grid registers none of the mutating actions: it
    // shows no menu item for them, and the editor throws their
    // messages away at the far end.
    if editable {
        entries.extend(kit.editing_entries());
    }
    group.add_action_entries(entries);
    column_view.insert_action_group("cell", Some(&group));

    let actions = CellActions {
        edit: editable.then(|| simple_action(&group, "edit")).flatten(),
        set_empty: editable.then(|| simple_action(&group, "set-empty")).flatten(),
        set_null: editable.then(|| simple_action(&group, "set-null")).flatten(),
        set_default: editable.then(|| simple_action(&group, "set-default")).flatten(),
        delete_row: editable.then(|| simple_action(&group, "delete-row")).flatten(),
        clear_sort: simple_action(&group, "clear-sort"),
    };

    let (editable_popover, readonly_popover) = cell_popovers(column_view, editable);
    let mut popovers_for_destroy = vec![editable_popover.clone()];
    if readonly_popover != editable_popover {
        popovers_for_destroy.push(readonly_popover.clone());
    }
    if editable {
        popovers_for_destroy.push(install_empty_space_menu(column_view));
    }
    column_view.connect_destroy(move |_| {
        for popover in &popovers_for_destroy {
            popover.unparent();
        }
    });

    GridMenus {
        context: kit.context,
        editable_popover,
        readonly_popover,
        actions,
    }
}

type CellEntry = gio::ActionEntry<gio::SimpleActionGroup>;

struct CellActionKit {
    context: Rc<CellContext>,
    /// Every action closure holds the view weakly. The action group
    /// belongs to the ColumnView, so a strong clone in a closure is a
    /// cycle: the grid, its selection model, its store and every row it
    /// holds would outlive the page that built them.
    view: glib::WeakRef<gtk::ColumnView>,
    sink: GridSink,
    columns: Arc<[ResultColumn]>,
    tab: Rc<TabGridContext>,
}

impl CellActionKit {
    /// An action on the cell the menu opened on, its row and the rows
    /// the menu acts on.
    fn on_target(&self, name: &str, act: impl Fn(&GridCell, RowObject, Vec<RowObject>) + 'static) -> CellEntry {
        let ctx = self.context.clone();
        let view = self.view.clone();
        gio::ActionEntry::builder(name)
            .activate(move |_, _, _| {
                let Some(cv) = view.upgrade() else { return };
                let Some(MenuTarget { cell, row, rows }) = ctx.target(&cv) else {
                    return;
                };
                act(&cell, row, rows);
            })
            .build()
    }

    /// The rows are taken as the grid shows them, sharing its cells, and
    /// the owner renders the copy off the GTK thread.
    fn copy(&self, name: &str, kind: impl Fn(&GridCell, &[RowObject]) -> CopyKind + 'static) -> CellEntry {
        let s = self.sink.clone();
        let tab = self.tab.clone();
        let columns = self.columns.clone();
        self.on_target(name, move |cell, _row, rows| {
            s(GridMsg::Copy(CopyRequest::Rows {
                columns: columns.clone(),
                rows: snapshots(&tab, &rows),
                kind: kind(cell, &rows),
            }));
        })
    }

    fn send(&self, name: &str, msg: impl Fn(&GridCell, RowObject, Vec<RowObject>) -> GridMsg + 'static) -> CellEntry {
        let s = self.sink.clone();
        self.on_target(name, move |cell, row, rows| s(msg(cell, row, rows)))
    }

    /// The actions a read-only grid offers too.
    fn reading_entries(&self) -> Vec<CellEntry> {
        let mut entries = self.copy_entries();
        entries.extend([self.copy_column_name(), self.show_row_json(), self.export()]);
        entries.extend(self.column_entries());
        entries
    }

    /// Sort by the cell's column, as a header click does, or change the
    /// width a header drag sets.
    fn column_entries(&self) -> Vec<CellEntry> {
        let sort = |name: &str, order: gtk::SortType| {
            let view = self.view.clone();
            self.on_target(name, move |cell, _row, _rows| {
                let Some(cv) = view.upgrade() else { return };
                if let Some(column) = shown_column(&cv, cell) {
                    cv.sort_by_column(Some(&column.view_column), order);
                }
            })
        };
        let clear_sort = {
            let view = self.view.clone();
            let sink = self.sink.clone();
            self.on_target("clear-sort", move |_cell, _row, _rows| {
                let Some(cv) = view.upgrade() else { return };
                cv.sort_by_column(None, gtk::SortType::Ascending);
                // The server sorts a browse page, and an unsorted view
                // tells it nothing by itself.
                sink(GridMsg::SortCleared);
            })
        };
        let resize = |name: &str, change: ColumnResize| {
            let view = self.view.clone();
            self.on_target(name, move |cell, _row, _rows| {
                if let Some(cv) = view.upgrade() {
                    resize_column(&cv, cell, change);
                }
            })
        };
        let reset_width = {
            let view = self.view.clone();
            let tab = self.tab.clone();
            let columns = self.columns.clone();
            self.on_target("reset-width", move |cell, _row, _rows| {
                let Some(column) = view.upgrade().and_then(|cv| shown_column(&cv, cell)) else {
                    return;
                };
                column.view_column.set_fixed_width(column.default_width.unwrap_or(-1));
                column.view_column.set_expand(true);
                if let (Some(widths), Some(info)) = (&tab.column_widths, columns.get(column.index)) {
                    widths.forget(&info.name);
                }
            })
        };
        vec![
            sort("sort-ascending", gtk::SortType::Ascending),
            sort("sort-descending", gtk::SortType::Descending),
            clear_sort,
            resize("widen-column", ColumnResize::Wider),
            resize("narrow-column", ColumnResize::Narrower),
            reset_width,
        ]
    }

    fn copy_entries(&self) -> Vec<CellEntry> {
        vec![
            // Plain Copy reads the cell's value, never the widget's text:
            // the widget carries the display form, which is the `<NULL>`
            // sentinel, the `(auto)` placeholder, `<N bytes>` for a blob and
            // a value cut at the 10k display cap.
            self.copy("copy", |cell, rows| match rows.len() {
                1 => CopyKind::Value(cell.column()),
                _ => CopyKind::Rows,
            }),
            self.copy("copy-rows", |_, _| CopyKind::Rows),
            self.copy("copy-rows-headers", |_, _| CopyKind::RowsWithHeaders),
            self.copy("copy-json", |_, _| CopyKind::Json),
            self.copy("copy-csv", |_, _| CopyKind::Csv),
            self.copy("copy-csv-headers", |_, _| CopyKind::CsvWithHeaders),
            self.copy("copy-markdown", |_, _| CopyKind::Markdown),
            self.copy_in_clause(),
        ]
    }

    fn copy_in_clause(&self) -> CellEntry {
        let tab = self.tab.clone();
        let columns = self.columns.clone();
        self.send("copy-in-clause", move |cell, _row, rows| {
            GridMsg::CopyInClause(InClauseRows {
                columns: columns.clone(),
                rows: snapshots(&tab, &rows),
                column: cell.column(),
            })
        })
    }

    fn copy_column_name(&self) -> CellEntry {
        let s = self.sink.clone();
        let cols = self.columns.clone();
        let view = self.view.clone();
        self.on_target("copy-column-name", move |cell, _row, _rows| {
            let Some(cv) = view.upgrade() else { return };
            let name = cols
                .get(cell.column())
                .map(|column| column.name.clone())
                .unwrap_or_default();
            crate::ui::clipboard::copy_text(&cv, name, |message| s(GridMsg::ShowToast(message.to_owned())));
        })
    }

    fn show_row_json(&self) -> CellEntry {
        let cols = self.columns.clone();
        let tab = self.tab.clone();
        self.send("show-row-json", move |_cell, row, _rows| {
            GridMsg::ShowRowJson(RowJsonRequest {
                columns: cols.clone(),
                row: tab.snapshot(&row),
            })
        })
    }

    fn export(&self) -> CellEntry {
        let s = self.sink.clone();
        let view = self.view.clone();
        let cols = self.columns.clone();
        let tab = self.tab.clone();
        gio::ActionEntry::builder("export")
            .activate(move |_, _, _| {
                let Some(cv) = view.upgrade() else { return };
                s(GridMsg::ExportResults(crate::ui::export::ExportSource::Rows {
                    columns: cols.clone(),
                    rows: export_snapshot(&cv, &tab),
                }));
            })
            .build()
    }

    /// The actions that change rows, which only an editable grid has.
    fn editing_entries(&self) -> Vec<CellEntry> {
        let set_value = |name: &str, preset: CellPreset| {
            self.send(name, move |cell, row, _rows| GridMsg::SetCellValue {
                row,
                column: cell.column(),
                preset,
            })
        };
        let insert_row = {
            let s = self.sink.clone();
            gio::ActionEntry::builder("insert-row")
                .activate(move |_, _, _| s(GridMsg::InsertRow))
                .build()
        };
        vec![
            // Editing opens on the cell, which must still show the row.
            self.on_target("edit", |cell, row, _rows| {
                if cell.row().as_ref() == Some(&row) {
                    begin_edit(cell);
                }
            }),
            set_value("set-empty", CellPreset::Empty),
            set_value("set-null", CellPreset::Null),
            set_value("set-default", CellPreset::Default),
            self.send("copy-row-insert", |_cell, _row, rows| GridMsg::CopyRowsAsInsert {
                rows,
            }),
            insert_row,
            self.send("delete-row", |_cell, _row, rows| GridMsg::DeleteRows { rows }),
            self.send("duplicate-row", |_cell, _row, rows| GridMsg::DuplicateRows { rows }),
        ]
    }
}

/// The menus a right click on a cell opens: one for a row that can be
/// edited and one for a row that can't. A read-only grid has a single
/// shape and both name it.
fn cell_popovers(column_view: &gtk::ColumnView, editable: bool) -> (gtk::PopoverMenu, gtk::PopoverMenu) {
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
    if editable {
        (make_popover(MenuShape::FULL), make_popover(MenuShape::ROW_OPS))
    } else {
        let readonly = make_popover(MenuShape::READ_ONLY);
        (readonly.clone(), readonly)
    }
}

/// Insert Row on a right click below the last row.
fn install_empty_space_menu(column_view: &gtk::ColumnView) -> gtk::PopoverMenu {
    let empty_menu = gio::Menu::new();
    empty_menu.append(Some(&crate::i18n::gettext("Insert Row")), Some("cell.insert-row"));
    let empty_popover = gtk::PopoverMenu::from_model_full(&empty_menu, gtk::PopoverMenuFlags::NESTED);
    empty_popover.set_has_arrow(true);
    empty_popover.set_parent(column_view);

    let view = column_view.downgrade();
    let popover = empty_popover.clone();
    let empty_gesture = gtk::GestureClick::builder().button(3).build();
    empty_gesture.connect_pressed(move |g, _, x, y| {
        let Some(cv) = view.upgrade() else { return };
        let cv_widget: gtk::Widget = cv.clone().upcast();
        if let Some(picked) = cv.pick(x, y, gtk::PickFlags::DEFAULT)
            && picked != cv_widget
        {
            return;
        }
        g.set_state(gtk::EventSequenceState::Claimed);
        popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        popover.popup();
    });
    column_view.add_controller(empty_gesture);
    empty_popover
}

/// The view's column that `cell` sits in.
pub(super) fn shown_column(view: &gtk::ColumnView, cell: &GridCell) -> Option<ShownColumn> {
    cell.columns()?
        .shown(view)
        .into_iter()
        .find(|column| column.index == cell.column())
}

/// The rows a menu item copies, as the grid shows them.
fn snapshots(tab: &TabGridContext, rows: &[RowObject]) -> Vec<RowSnapshot> {
    rows.iter().map(|row| tab.snapshot(row)).collect()
}

fn simple_action(group: &gio::SimpleActionGroup, name: &str) -> Option<gio::SimpleAction> {
    group
        .lookup_action(name)
        .and_then(|a| a.downcast::<gio::SimpleAction>().ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn accel_of(menu: &gio::MenuModel, action: &str) -> Option<Option<String>> {
        for position in 0..menu.n_items() {
            let named = menu
                .item_attribute_value(position, "action", None)
                .and_then(|value| value.get::<String>());
            if named.as_deref() == Some(action) {
                return Some(
                    menu.item_attribute_value(position, "accel", None)
                        .and_then(|value| value.get::<String>()),
                );
            }
            for link in ["section", "submenu"] {
                if let Some(found) = menu
                    .item_link(position, link)
                    .and_then(|inner| accel_of(&inner, action))
                {
                    return Some(found);
                }
            }
        }
        None
    }

    #[gtk4::test]
    fn the_cell_menu_shows_the_cell_keys() {
        let menu = build_cell_menu(MenuShape::FULL).upcast::<gio::MenuModel>();

        assert_eq!(
            accel_of(&menu, "cell.set-null"),
            Some(Some("<Primary>BackSpace".to_owned()))
        );
        assert_eq!(accel_of(&menu, "cell.edit"), Some(Some("F2".to_owned())));
        assert_eq!(accel_of(&menu, "cell.set-empty"), Some(None));
    }
}

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gdk, gio};

use super::selection::Target;
use super::{DataGrid, GridCell, GridRow, GridSorting};
use crate::i18n::gettext;
use crate::services::grid::GridColumn;

/// The grid's menus, built once from what the grid offers and parented to
/// the grid, so their items reach its `grid` actions.
#[derive(Debug)]
pub struct GridMenus {
    pub cell: gtk::PopoverMenu,
    /// Below the last row, for a grid that takes new rows.
    pub empty: Option<gtk::PopoverMenu>,
    /// Filled from the table's foreign keys as a menu opens.
    pub references: gio::Menu,
    /// Filled with the expressions the cell takes as a menu opens.
    pub expressions: gio::Menu,
    /// The keys a column is in, for Ctrl+J to choose from.
    pub reference_chooser: gtk::PopoverMenu,
    /// An enum or set cell's labels, for a grid that edits.
    pub choices: Option<gtk::PopoverMenu>,
}

/// An item shown only while its action is enabled, so a cell it does not
/// apply to shows no dead entry.
fn hidden_while_disabled(label: &str, action: &str) -> gio::MenuItem {
    let item = crate::application::menu_item(label, action);
    item.set_attribute_value("hidden-when", Some(&"action-disabled".to_variant()));
    item
}

fn item(label: &str, action: &str) -> gio::MenuItem {
    crate::application::menu_item(label, action)
}

/// Set to Empty, NULL or DEFAULT, each shown where the cell takes it.
pub(crate) fn presets_section() -> gio::Menu {
    section([
        hidden_while_disabled(&gettext("Set _to Empty"), "grid.set-empty"),
        hidden_while_disabled(&gettext("Set to _NULL"), "grid.set-null"),
        hidden_while_disabled(&gettext("Set to DEFAU_LT"), "grid.set-default"),
    ])
}

fn section(items: impl IntoIterator<Item = gio::MenuItem>) -> gio::Menu {
    let menu = gio::Menu::new();
    for item in items {
        menu.append_item(&item);
    }
    menu
}

impl GridMenus {
    pub fn new(grid: &DataGrid) -> Self {
        let editable = grid.config().is_some_and(|config| config.tracker.is_some());
        let references = gio::Menu::new();
        let expressions = gio::Menu::new();
        let cell = popover(grid, &cell_menu(grid, &references, &expressions));
        let empty = editable.then(|| {
            popover(
                grid,
                &section([
                    item(&gettext("_Insert Row"), "grid.insert-row"),
                    item(&gettext("_Paste"), "grid.paste"),
                ]),
            )
        });
        let reference_chooser = popover(grid, &gio::Menu::new());
        let choices = editable.then(|| popover(grid, &gio::Menu::new()));
        Self {
            cell,
            empty,
            references,
            expressions,
            reference_chooser,
            choices,
        }
    }

    /// The popovers are the grid's children beside its template's, which
    /// the grid lets go of itself.
    pub fn unparent(&self) {
        self.cell.unparent();
        if let Some(empty) = &self.empty {
            empty.unparent();
        }
        self.reference_chooser.unparent();
        if let Some(choices) = &self.choices {
            choices.unparent();
        }
    }
}

fn popover(grid: &DataGrid, model: &gio::Menu) -> gtk::PopoverMenu {
    let popover = gtk::PopoverMenu::from_model(Some(model));
    popover.set_has_arrow(false);
    popover.set_halign(gtk::Align::Start);
    popover.set_parent(grid);
    let weak = grid.downgrade();
    popover.connect_closed(move |_| {
        if let Some(grid) = weak.upgrade() {
            grid.return_focus_from_menu();
            grid.release_menu_target_soon();
        }
    });
    popover
}

fn cell_menu(grid: &DataGrid, references: &gio::Menu, expressions: &gio::Menu) -> gio::Menu {
    let config = grid.config();
    let editable = config.is_some_and(|config| config.tracker.is_some());
    let sorts = config.is_some_and(|config| config.sorting != GridSorting::None);
    let menu = gio::Menu::new();
    if editable {
        let edits = presets_section();
        edits.prepend_item(&hidden_while_disabled(&gettext("_Edit Cell"), "grid.edit"));
        menu.append_section(None, &edits);
        menu.append_section(None, expressions);
    }
    let copy_as = section([
        item(&gettext("_Rows"), "grid.copy-rows"),
        item(&gettext("_With Headers"), "grid.copy-rows-headers"),
        item(&gettext("_CSV"), "grid.copy-csv"),
        item(&gettext("CSV With _Headers"), "grid.copy-csv-headers"),
    ]);
    copy_as.append_section(
        None,
        &section([
            item(&gettext("_JSON"), "grid.copy-json"),
            item(&gettext("JSON _Lines"), "grid.copy-json-lines"),
            item(&gettext("_Markdown"), "grid.copy-markdown"),
            item(&gettext("_Text Table"), "grid.copy-text-table"),
        ]),
    );
    copy_as.append_section(
        None,
        &section([
            hidden_while_disabled(&gettext("_IN Clause"), "grid.copy-in-clause"),
            hidden_while_disabled(&gettext("_One Row"), "grid.copy-one-row"),
            hidden_while_disabled(&gettext("INSERT _Statement"), "grid.copy-insert"),
            hidden_while_disabled(
                &gettext("INSERT Without Generated _Keys"),
                "grid.copy-insert-without-generated-keys",
            ),
        ]),
    );
    copy_as.append_section(
        None,
        &section([item(&gettext("Column _Name"), "grid.copy-column-name")]),
    );
    let clipboard = section([item(&gettext("_Copy"), "grid.copy")]);
    clipboard.append_submenu(Some(&gettext("Copy _As")), &copy_as);
    if editable {
        clipboard.append_item(&item(&gettext("_Paste"), "grid.paste"));
    }
    menu.append_section(None, &clipboard);
    if config.is_some_and(|config| config.filter_by_value) {
        menu.append_section(
            None,
            &section([
                hidden_while_disabled(&gettext("_Filter by Value"), "grid.filter-by-value"),
                hidden_while_disabled(&gettext("Exclude _Value"), "grid.exclude-value"),
            ]),
        );
    }
    menu.append_section(None, references);
    menu.append_section(
        None,
        &section([
            item(&gettext("_Row Details"), "grid.show-details"),
            item(&gettext("Show Row as _JSON"), "grid.show-row-json"),
        ]),
    );
    menu.append_section(None, &column_section(sorts));
    let rows = section([item(&gettext("E_xport…"), "grid.export")]);
    if editable {
        rows.append_item(&item(&gettext("_Insert Row"), "grid.insert-row"));
        rows.append_item(&item(&gettext("D_uplicate"), "grid.duplicate-rows"));
        rows.append_item(&item(&gettext("_Delete"), "grid.delete-rows"));
    }
    menu.append_section(None, &rows);
    menu
}

/// What a header's click and drag do, which no key reaches, so the cell
/// menu offers them for the cell's column.
fn column_section(sorts: bool) -> gio::Menu {
    let column = gio::Menu::new();
    if sorts {
        column.append_item(&hidden_while_disabled(
            &gettext("Sort _Ascending"),
            "grid.sort-ascending",
        ));
        column.append_item(&hidden_while_disabled(
            &gettext("Sort _Descending"),
            "grid.sort-descending",
        ));
        column.append_item(&item(&gettext("_Clear Sort"), "grid.clear-sort"));
    }
    column.append_section(
        None,
        &section([
            item(&gettext("_Hide Column"), "grid.hide-column"),
            item(&gettext("_Size to Fit"), "grid.size-to-fit"),
            item(&gettext("Move Column _Left"), "grid.move-column-left"),
            item(&gettext("Move Column _Right"), "grid.move-column-right"),
            item(&gettext("Col_umns…"), "grid.columns"),
        ]),
    );
    let menu = gio::Menu::new();
    menu.append_submenu(Some(&gettext("Colu_mn")), &column);
    menu
}

/// A header's own menu, on a secondary click. It names its column, since
/// GTK opens it without telling the grid.
pub fn header_menu(column: &GridColumn, sorting: GridSorting) -> gio::Menu {
    let index = (column.index as u32).to_variant();
    let at = |label: String, action: &str| {
        let item = gio::MenuItem::new(Some(&label), None);
        item.set_action_and_target_value(Some(action), Some(&index));
        item
    };
    let menu = gio::Menu::new();
    if sorting != GridSorting::None && column.sortable() {
        menu.append_section(
            None,
            &section([
                at(gettext("Sort _Ascending"), "grid.sort-column-ascending"),
                at(gettext("Sort _Descending"), "grid.sort-column-descending"),
                item(&gettext("_Clear Sort"), "grid.clear-sort"),
            ]),
        );
    }
    menu.append_section(
        None,
        &section([
            at(gettext("_Hide Column"), "grid.hide-column-at"),
            at(gettext("_Size to Fit"), "grid.size-column-to-fit"),
            at(gettext("Move Column _Left"), "grid.move-column-left-at"),
            at(gettext("Move Column _Right"), "grid.move-column-right-at"),
            at(gettext("Copy Column _Name"), "grid.copy-column-name-at"),
        ]),
    );
    menu.append_section(None, &section([item(&gettext("Col_umns…"), "grid.columns")]));
    menu
}

/// The row number column's header menu. GTK keeps a header's click for
/// sorting, so the header selects the rows from here. The key is
/// GtkListBase's `list.select-all`, out of a header menu's reach.
pub fn row_numbers_header_menu() -> gio::Menu {
    let select_all = item(&gettext("Select _All Rows"), "grid.select-all");
    if let Some(key) = crate::application::triggers_for("list.select-all").first() {
        select_all.set_attribute_value("accel", Some(&key.to_variant()));
    }
    let menu = gio::Menu::new();
    menu.append_section(None, &section([select_all]));
    menu.append_section(None, &section([item(&gettext("Col_umns…"), "grid.columns")]));
    menu
}

impl DataGrid {
    pub(crate) fn menus(&self) -> Option<&GridMenus> {
        self.imp().menus.get()
    }

    /// The cell menu for `cell`, at `at` in the view's coordinates, or
    /// pointing at the whole cell for a key.
    pub(crate) fn open_cell_menu(&self, cell: &GridCell, at: Option<gdk::Rectangle>) -> bool {
        let (Some(row), Some(position), Some(menus)) = (cell.row(), cell.position(), self.menus()) else {
            return false;
        };
        self.select_for_menu(position, Some(cell.column()));
        let target = Target {
            cell: Some((row.pin(), cell.column())),
            rows: self.rows_for(&row, position),
        };
        self.arm_menu(target, Some(cell));
        let at = at.or_else(|| self.bounds_in_view(cell.upcast_ref()));
        self.show_popover(&menus.cell, at);
        true
    }

    pub(crate) fn open_row_menu(&self, row: &GridRow, position: u32, at: gdk::Rectangle) -> bool {
        let Some(menus) = self.menus() else {
            return false;
        };
        self.select_for_menu(position, None);
        let target = Target {
            cell: None,
            rows: self.rows_for(row, position),
        };
        self.arm_menu(target, None);
        self.show_popover(&menus.cell, Some(at));
        true
    }

    pub(crate) fn open_empty_menu(&self, at: gdk::Rectangle) -> bool {
        let Some(empty) = self.menus().and_then(|menus| menus.empty.clone()) else {
            return false;
        };
        self.arm_menu(
            Target {
                cell: None,
                rows: Vec::new(),
            },
            None,
        );
        self.show_popover(&empty, Some(at));
        true
    }

    fn arm_menu(&self, target: Target, cell: Option<&GridCell>) {
        self.hold_menu_target(target);
        self.refresh_actions();
        self.arm_references(cell);
        self.edit().arm_expressions(self, cell);
    }

    /// A popover parented to the grid points in the grid's coordinates.
    pub(crate) fn show_popover(&self, popover: &gtk::PopoverMenu, at_in_view: Option<gdk::Rectangle>) {
        let at = at_in_view.and_then(|rect| {
            let point = gtk::graphene::Point::new(rect.x() as f32, rect.y() as f32);
            let point = self.column_view().compute_point(self, &point)?;
            Some(gdk::Rectangle::new(
                point.x() as i32,
                point.y() as i32,
                rect.width(),
                rect.height(),
            ))
        });
        popover.set_pointing_to(at.as_ref());
        popover.popup();
    }

    pub(crate) fn bounds_in_view(&self, widget: &gtk::Widget) -> Option<gdk::Rectangle> {
        let bounds = widget.compute_bounds(&self.column_view())?;
        Some(gdk::Rectangle::new(
            bounds.x() as i32,
            bounds.y() as i32,
            bounds.width() as i32,
            bounds.height() as i32,
        ))
    }
}

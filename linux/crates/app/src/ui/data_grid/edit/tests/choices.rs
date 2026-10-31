use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gdk, gio};
use tablepro_core::Value;
use tablepro_core::column::ColumnKind;
use tablepro_core::edit::CellInput;

use super::{editing, editor, none, pending, press_in_editor, type_into};
use crate::test_support::{assert_labelled, descendants, drain_main_context, test_backend_records_properties};
use crate::ui::data_grid::test_grid::{Grid, named, text};

fn sizes_and_tags() -> Grid {
    Grid::open(
        vec![
            named("id", "integer", true),
            named("name", "text", false),
            named("size", "enum('small','medium','in_stock','')", false),
            named("tags", "set('new','sale','gift')", false),
        ],
        vec![vec![
            Value::Int(1),
            Value::Text("a".into()),
            Value::Text("small".into()),
            Value::Text("new".into()),
        ]],
    )
}

fn choices(grid: &Grid) -> gtk::PopoverMenu {
    grid.grid
        .menus()
        .and_then(|menus| menus.choices.clone())
        .expect("an editing grid has a choice menu")
}

/// The menu's item labelled `label`. A menu item is a GtkModelButton,
/// which GTK keeps private and gives no action name.
fn find_item(grid: &Grid, label: &str) -> Option<gtk::Widget> {
    descendants(&choices(grid)).into_iter().find(|widget| {
        widget.type_().name() == "GtkModelButton" && widget.property::<Option<String>>("text").as_deref() == Some(label)
    })
}

fn item(grid: &Grid, label: &str) -> gtk::Widget {
    find_item(grid, label).expect("the menu has the item")
}

/// GTK takes an item hidden while its action is disabled out of the menu.
fn shown(grid: &Grid, label: &str) -> bool {
    find_item(grid, label).is_some_and(|item| item.is_visible())
}

fn checked(item: &gtk::Widget) -> bool {
    item.property::<bool>("active")
}

fn labels(menu: &gio::MenuModel) -> Vec<String> {
    (0..menu.n_items())
        .flat_map(|position| {
            let label = menu
                .item_attribute_value(position, "label", None)
                .and_then(|label| label.get::<String>());
            let inner = menu.item_link(position, "section").map(|section| labels(&section));
            label.into_iter().chain(inner.unwrap_or_default())
        })
        .collect()
}

fn open_on(grid: &Grid, column: usize) {
    let cell = grid.focus(0, column);
    assert!(grid.grid.edit().edit_cell(&cell));
    assert!(choices(grid).is_visible(), "the cell opened no menu");
    assert!(editor(grid).is_none(), "the cell opened a text editor");
}

#[gtk4::test]
fn an_enum_cell_marks_its_label_and_takes_the_one_picked() {
    let grid = sizes_and_tags();
    open_on(&grid, 2);
    assert!(checked(&item(&grid, "small")), "the cell's own label is not marked");
    assert!(!checked(&item(&grid, "medium")));

    item(&grid, "medium").emit_by_name::<()>("clicked", &[]);
    drain_main_context();

    assert_eq!(pending(&grid, 1, 2), Some(text("medium")));
    assert!(!choices(&grid).is_visible(), "a picked label left the menu open");
    assert_eq!(
        grid.focused_cell().map(|cell| (cell.position(), cell.column())),
        Some((Some(0), 2)),
        "the keyboard left the cell"
    );
}

#[gtk4::test]
fn labels_keep_their_underscores_and_the_empty_label_has_a_name() {
    let grid = sizes_and_tags();
    open_on(&grid, 2);
    let model = choices(&grid).menu_model().expect("a menu");

    assert_eq!(&labels(&model)[..4], ["small", "medium", "in__stock", "Empty"]);
    assert!(shown(&grid, "Set to NULL"), "a nullable cell offered no NULL");
    assert!(shown(&grid, "Set to Empty"), "the empty label is not offered as Empty");
    assert!(!shown(&grid, "Set to DEFAULT"), "a saved row offered DEFAULT");
    if test_backend_records_properties() {
        assert_labelled(&choices(&grid)).expect("the menu is named after its column");
    }
}

/// ClickHouse labels can hold a NUL, where GTK and GVariant strings end.
#[gtk4::test]
fn a_label_with_a_nul_is_a_choice_of_its_own() {
    let mut state = named("state", "text", false);
    state.column_type.kind = ColumnKind::Enum {
        labels: vec!["x".to_owned(), "x\0y".to_owned()],
        multiple: false,
    };
    let grid = Grid::open(
        vec![named("id", "integer", true), state],
        vec![vec![Value::Int(1), Value::Text("x".into())]],
    );
    open_on(&grid, 1);
    assert!(checked(&item(&grid, "x")));
    assert!(!checked(&item(&grid, "x\u{2400}y")));

    item(&grid, "x\u{2400}y").emit_by_name::<()>("clicked", &[]);
    drain_main_context();
    assert_eq!(pending(&grid, 1, 1), Some(text("x\0y")));

    open_on(&grid, 1);
    assert!(
        checked(&item(&grid, "x\u{2400}y")),
        "a value no text editor can hold did not reopen its labels"
    );
}

/// A value a one-line editor would mangle still opens the labels, and Tab
/// goes past it as it goes past any cell edited elsewhere.
#[gtk4::test]
fn tab_passes_a_value_the_one_line_editor_cannot_hold() {
    let grid = Grid::open(
        vec![
            named("id", "integer", true),
            named("name", "text", false),
            named("size", "enum('small','large')", false),
            named("note", "text", false),
        ],
        vec![vec![
            Value::Int(1),
            Value::Text("a".into()),
            Value::Text("two\nlines".into()),
            Value::Text("n".into()),
        ]],
    );
    let name = grid.focus(0, 1);
    type_into(&grid, &name, "b");
    assert!(press_in_editor(
        &editor(&grid).expect("an editor"),
        gdk::Key::Tab,
        none()
    ));
    let note = editing(&grid);
    assert_eq!(
        note.column(),
        3,
        "Tab opened a one-line editor on a value with a line break"
    );

    open_on(&grid, 2);
}

/// GTK gives the focus a closed menu held to the first control an ancestor
/// of the grid takes, below the rows.
#[gtk4::test]
fn the_cell_takes_the_keyboard_back_when_the_labels_close() {
    let grid = sizes_and_tags();
    open_on(&grid, 2);
    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);

    choices(&grid).popdown();
    drain_main_context();

    assert_eq!(
        grid.focused_cell().map(|cell| (cell.position(), cell.column())),
        Some((Some(0), 2)),
        "the keyboard did not come back to the cell"
    );
}

/// Edit Cell in the cell menu opens the labels while the cell menu lets go
/// of its target, which GTK has it do before the item runs.
#[gtk4::test]
fn edit_cell_from_the_cell_menu_keeps_the_labels_target() {
    let grid = sizes_and_tags();
    let cell = grid.focus(0, 2);
    assert!(grid.grid.open_cell_menu(&cell, None));
    grid.grid.menus().expect("menus").cell.popdown();
    grid.grid.release_menu_target_soon();

    grid.activate("edit");

    assert!(choices(&grid).is_visible(), "Edit Cell opened no labels");
    assert!(
        grid.grid.imp().menu_target.borrow().is_some(),
        "the cell menu's close let go of the labels' target"
    );
}

#[gtk4::test]
fn set_to_null_from_the_menu_writes_null_into_the_cell() {
    let grid = sizes_and_tags();
    open_on(&grid, 2);

    item(&grid, "Set to NULL").emit_by_name::<()>("clicked", &[]);
    drain_main_context();

    assert_eq!(pending(&grid, 1, 2), Some(CellInput::Value(Value::Null)));
}

/// Space on a check item toggles it in place, as activating its action
/// does, so several members change while the menu stays open.
#[gtk4::test]
fn set_members_toggle_one_at_a_time_in_the_columns_order() {
    let grid = sizes_and_tags();
    open_on(&grid, 3);
    let menu = choices(&grid);
    assert!(checked(&item(&grid, "new")), "the cell's member is not checked");
    assert!(!checked(&item(&grid, "gift")));

    menu.activate_action("choice.member-2", None).expect("gift");
    drain_main_context();
    assert_eq!(pending(&grid, 1, 3), Some(text("new,gift")));
    assert!(checked(&item(&grid, "gift")));

    menu.activate_action("choice.member-1", None).expect("sale");
    menu.activate_action("choice.member-0", None).expect("new");
    menu.activate_action("choice.member-2", None).expect("gift");
    drain_main_context();
    assert_eq!(pending(&grid, 1, 3), Some(text("sale")));

    menu.activate_action("choice.member-1", None).expect("sale");
    drain_main_context();
    assert_eq!(
        pending(&grid, 1, 3),
        Some(text("")),
        "the empty set was written as something else"
    );
    assert!(menu.is_visible(), "a toggled member closed the menu");
}

#[gtk4::test]
fn a_set_cell_takes_the_empty_set_as_empty() {
    let grid = sizes_and_tags();
    grid.focus(0, 3);
    grid.grid.refresh_actions();
    assert!(grid.is_enabled("set-empty"), "a set cannot be set to the empty set");

    grid.activate("set-empty");

    assert_eq!(pending(&grid, 1, 3), Some(text("")));
}

#[gtk4::test]
fn tab_and_typing_edit_an_enum_cells_text() {
    let grid = sizes_and_tags();
    let name = grid.focus(0, 1);
    type_into(&grid, &name, "b");

    assert!(press_in_editor(
        &editor(&grid).expect("an editor"),
        gdk::Key::Tab,
        none()
    ));

    let size = editing(&grid);
    assert_eq!((size.position(), size.column()), (Some(0), 2), "Tab skipped the enum");
    assert_eq!(editor(&grid).expect("a text editor").text(), "small");
    assert!(!choices(&grid).is_visible());
}

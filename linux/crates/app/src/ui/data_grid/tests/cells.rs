use std::cell::Cell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{glib, pango};
use tablepro_core::Value;
use tablepro_core::column::{BoolStorage, ColumnKind};

use super::{delete_saved, described, keyed, rename_first, row_widget, text, untyped};
use crate::services::grid::display_text::editable_null_sentinel;
use crate::services::grid::grid_columns;
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{descendants, drain_main_context, wait_until};
use crate::ui::data_grid::columns::ColumnPaint;
use crate::ui::data_grid::grid_cell::TextAttributes;
use crate::ui::data_grid::test_grid::{Grid, GridSpec, WAIT, key, named, results, two_text_columns, two_text_values};
use crate::ui::data_grid::{GridCell, GridRow, RowData, TrackedValues};

fn two_text_rows() -> Grid {
    Grid::open(two_text_columns(), two_text_values())
}

/// What a cell of a text column outside any grid draws with.
fn paint() -> Rc<ColumnPaint> {
    let info = named("name", "text", false);
    let columns = grid_columns(&[info.result_column()], &[info], |_| true);
    Rc::new(ColumnPaint {
        column: columns[0].clone(),
        tracked: TrackedValues::untracked(),
        attributes: Rc::new(TextAttributes::new()),
        numbers: Cell::new(false),
    })
}

fn has_attribute(cell: &GridCell, kind: pango::AttrType) -> bool {
    cell.display()
        .and_then(|display| display.attributes())
        .is_some_and(|list| list.attributes().iter().any(|attr| attr.type_() == kind))
}

fn has_class(cell: &GridCell, class: &str) -> bool {
    cell.display().is_some_and(|display| display.has_css_class(class))
}

#[gtk4::test]
fn a_page_in_the_same_slots_keeps_every_cell_and_draws_each_once() {
    let grid = Grid::build(GridSpec::table(two_text_columns()), keyed(&[1, 2, 3, 4, 5]));
    drain_main_context();
    let before: Vec<(GridCell, u32)> = grid
        .cells()
        .into_iter()
        .map(|cell| {
            let renders = cell.render_count();
            (cell, renders)
        })
        .collect();
    assert_eq!(before.len(), 10, "every row's cells are drawn");

    grid.grid.replace_rows(keyed(&[11, 12, 13, 14, 15]), 0);
    drain_main_context();

    let after = grid.cells();
    assert_eq!(after.len(), before.len(), "a cell widget came or went");
    for (cell, renders) in &before {
        assert!(after.contains(cell), "a cell widget was built again");
        assert_eq!(
            cell.render_count(),
            renders + 1,
            "the cell of column {} at {:?} did not draw the new row once",
            cell.column(),
            cell.position()
        );
    }
    assert_eq!(Grid::display_text(&grid.cell_of(11, 1)), "row 11");
}

/// D9: one spelling in every grid, and no check box.
#[gtk4::test]
fn booleans_read_true_or_false_in_every_grid() {
    let columns = vec![named("id", "integer", true), named("flag", "boolean", false)];
    let rows = vec![
        vec![Value::Int(1), Value::Bool(true)],
        vec![Value::Int(2), Value::Bool(false)],
    ];
    let table = Grid::open(columns.clone(), rows.clone());
    let shown = Grid::build(GridSpec::results(columns), results(&rows));

    for grid in [&table, &shown] {
        assert_eq!(Grid::display_text(&grid.cell_at(0, 1)), "true");
        assert_eq!(Grid::display_text(&grid.cell_at(1, 1)), "false");
        assert!(
            descendants(&grid.grid.column_view())
                .iter()
                .all(|widget| !widget.is::<gtk::CheckButton>()),
            "a boolean drew a check box"
        );
    }
}

/// D9: a boolean kept as a number reads as one stored natively, and a
/// number that is no boolean reads as itself.
#[gtk4::test]
fn an_integer_boolean_reads_true_or_false_and_other_numbers_as_themselves() {
    let mut active = named("active", "tinyint(1)", false);
    active.column_type.kind = ColumnKind::Bool(BoolStorage::Integer);
    let grid = Grid::open(
        vec![named("id", "integer", true), active],
        vec![
            vec![Value::Int(1), Value::Int(1)],
            vec![Value::Int(2), Value::Int(0)],
            vec![Value::Int(3), Value::Int(2)],
        ],
    );

    let shown: Vec<String> = (1..=3).map(|id| Grid::display_text(&grid.cell_of(id, 1))).collect();

    assert_eq!(shown, ["true", "false", "2"]);
}

/// D10: a boolean draws as text, so its row is no taller.
#[gtk4::test]
fn a_row_with_a_boolean_is_as_tall_as_one_without() {
    let texts = two_text_rows();
    let flags = Grid::open(
        vec![named("id", "integer", true), named("flag", "boolean", false)],
        vec![vec![Value::Int(1), Value::Bool(true)]],
    );
    let height = |grid: &Grid| row_widget(&grid.cell_of(1, 1)).height();

    wait_until(WAIT, || height(&texts) > 0 && height(&flags) > 0).expect("the rows are laid out");

    assert_eq!(height(&flags), height(&texts));
}

// Every cell of the row, the gutter and the filler included.
fn stripes_across(cell: &GridCell) -> Vec<bool> {
    let row = row_widget(cell);
    std::iter::successors(row.first_child(), |column| column.next_sibling())
        .map(|column| {
            column
                .first_child()
                .is_some_and(|child| child.has_css_class("tp-stripe"))
        })
        .collect()
}

fn striped_rows(ids: &[i64]) -> Grid {
    Grid::build(GridSpec::table(two_text_columns()), keyed(ids))
}

#[gtk4::test]
fn every_other_row_is_striped_out_to_the_filler() {
    let grid = striped_rows(&[1, 2, 3, 4]);

    assert!(grid.grid.column_view().has_css_class("tp-striped"), "on by default");
    for position in 0..4 {
        let row = stripes_across(&grid.cell_at(position, 1));
        assert_eq!(row.len(), 4, "gutter, two columns and the filler");
        assert!(
            row.iter().all(|striped| *striped == (position % 2 == 1)),
            "row {position}: {row:?}"
        );
    }
}

#[gtk4::test]
fn a_row_added_above_moves_the_stripes() {
    let grid = two_text_rows();

    grid.insert_draft();

    assert!(stripes_across(&grid.cell_of(1, 1)).iter().all(|striped| *striped));
    assert!(stripes_across(&grid.cell_of(2, 1)).iter().all(|striped| !striped));
}

#[gtk4::test]
fn recycled_rows_take_the_stripe_of_their_new_position() {
    let ids: Vec<i64> = (1..=300).collect();
    let grid = striped_rows(&ids);

    grid.focus(250, 1);

    let drawn = grid.cells();
    assert!(drawn.iter().any(|cell| cell.position() == Some(250)));
    for cell in drawn {
        let position = cell.position().expect("a bound cell");
        assert_eq!(cell.has_css_class("tp-stripe"), position % 2 == 1, "row {position}");
    }
}

#[gtk4::test]
fn open_grids_follow_the_stripes_preference() {
    let grid = two_text_rows();
    let settings = grid.grid.config().expect("a configured grid").settings.clone();
    let striped = || grid.grid.column_view().has_css_class("tp-striped");

    settings.set_show_alternate_rows(false).expect("store the flag");
    drain_main_context();
    assert!(!striped());

    settings.set_show_alternate_rows(true).expect("store the flag");
    drain_main_context();
    assert!(striped());
}

#[gtk4::test]
fn column_view_carries_data_table_class() {
    let grid = two_text_rows();

    assert!(grid.grid.column_view().has_css_class("data-table"));
}

#[gtk4::test]
fn numeric_column_cells_align_end_with_numeric_class() {
    let grid = Grid::open(
        vec![
            named("id", "integer", true),
            named("name", "text", false),
            named("price", "numeric(10,2)", false),
        ],
        vec![vec![
            Value::Int(1),
            text("tea"),
            Value::Decimal("4.5".parse().expect("a decimal")),
        ]],
    );
    let xalign = |column| grid.cell_of(1, column).display().map(|display| display.xalign());

    for column in [0, 2] {
        assert_eq!(xalign(column), Some(1.0), "column {column}");
        assert!(has_class(&grid.cell_of(1, column), "numeric"), "column {column}");
    }
    assert_eq!(xalign(1), Some(0.0));
    assert!(!has_class(&grid.cell_of(1, 1), "numeric"));
    assert_eq!(Grid::display_text(&grid.cell_of(1, 2)), "4.50", "the column's scale");
}

/// PostgreSQL's editor reads columns with no type, holding the server's
/// text.
#[gtk4::test]
fn untyped_numbers_line_up_as_the_browse_grid_lines_them_up() {
    let result = Grid::build(
        GridSpec::results(Vec::from(["id", "category", "products", "avg_price"].map(untyped))),
        results(&[
            vec![text("1"), text("Coffee"), text("7"), text("23.79")],
            vec![text("2"), text("Tea"), Value::Null, text("10.58")],
        ]),
    );
    let browse = Grid::open(
        vec![
            named("id", "integer", true),
            named("category", "text", false),
            named("products", "bigint", false),
            named("avg_price", "numeric", false),
        ],
        vec![vec![
            Value::Int(1),
            text("Coffee"),
            Value::Int(7),
            Value::Decimal("23.79".parse().expect("a decimal")),
        ]],
    );
    let drawn = |cell: GridCell| {
        let display = cell.display().expect("a text cell");
        (display.xalign(), display.has_css_class("numeric"))
    };

    for column in 0..4 {
        assert_eq!(
            drawn(result.cell_at(0, column)),
            drawn(browse.cell_of(1, column)),
            "column {column}"
        );
    }
    assert_eq!(drawn(result.cell_at(0, 2)), (1.0, true));
    assert_eq!(drawn(result.cell_at(0, 1)), (0.0, false));
}

#[gtk4::test]
fn pending_delete_row_uses_shared_strikethrough_attributes() {
    let grid = two_text_rows();
    let attributes = |id, column| {
        grid.cell_of(id, column)
            .display()
            .and_then(|display| display.attributes())
            .map(|attrs| attrs.as_ptr())
    };
    assert_eq!(attributes(1, 1), None, "plain text carries no attributes");

    delete_saved(&grid, 1, "A");

    let struck = attributes(1, 0).expect("the deleted row's text is struck through");
    assert_eq!(attributes(1, 1), Some(struck), "each cell built its own list");
    assert_eq!(attributes(2, 1), None);
    assert!(has_attribute(&grid.cell_of(1, 1), pango::AttrType::Strikethrough));
    assert!(has_class(&grid.cell_of(1, 1), "dimmed"));
}

#[gtk4::test]
fn modified_cell_renders_bold() {
    let grid = two_text_rows();
    let cell = grid.cell_of(1, 1);
    assert!(!has_attribute(&cell, pango::AttrType::Weight));

    rename_first(&grid, "edited");
    assert!(
        has_attribute(&cell, pango::AttrType::Weight),
        "an edit showed only by its colour"
    );
    assert!(
        has_class(&cell, "warning"),
        "an edit is not in Adwaita's warning colour"
    );
    assert!(!has_attribute(&grid.cell_of(1, 0), pango::AttrType::Weight));

    delete_saved(&grid, 1, "A");
    assert!(has_attribute(&cell, pango::AttrType::Strikethrough));
    assert!(
        !has_attribute(&cell, pango::AttrType::Weight) && !has_class(&cell, "warning"),
        "a cell going away with its row read as an edit"
    );
}

#[gtk4::test]
fn a_null_placeholder_is_italic_and_a_locked_one_dimmed() {
    let rows = vec![vec![Value::Int(1), Value::Null]];
    let grid = Grid::open(two_text_columns(), rows.clone());
    let editable = grid.cell_of(1, 1);
    let locked_grid = Grid::build(GridSpec::results(two_text_columns()), results(&rows));
    let locked = locked_grid.cell_at(0, 1);

    assert_eq!(Grid::display_text(&editable), editable_null_sentinel());
    assert!(
        has_attribute(&editable, pango::AttrType::Style),
        "a placeholder reads like a value"
    );
    assert!(!has_class(&editable, "dimmed"), "an editable NULL was dimmed");
    assert!(
        editable
            .display()
            .is_some_and(|display| display.tooltip_text().is_none())
    );
    assert_eq!(Grid::display_text(&locked), "NULL");
    assert!(has_class(&locked, "dimmed"), "a NULL no one can change was not dimmed");
}

#[gtk4::test]
fn locked_cells_draw_in_an_inscription_with_no_label() {
    let grid = two_text_rows();
    let locked = grid.cell_of(1, 0);

    assert!(locked.lock().is_some(), "a saved row's key was offered for editing");
    assert!(locked.display().is_some());
    assert!(
        descendants(&locked).iter().all(|widget| !widget.is::<gtk::Label>()),
        "a locked cell carries a label, whose own menu takes Shift+F10"
    );
    assert_eq!(Grid::display_text(&locked), "1");
}

/// A revision alone redraws a cell, which reads the tracker as it draws.
#[gtk4::test]
fn a_revision_bump_draws_the_pending_value_in_the_same_cell() {
    let grid = two_text_rows();
    let cell = grid.cell_of(1, 1);
    let delta = grid.tracker.apply(TrackerEdit::Cell {
        row_key: key(1),
        col: 1,
        original: text("A"),
        value: tablepro_core::edit::CellInput::Value(text("new")),
    });

    grid.grid.store().row(0).expect("a row").bump_revision();

    assert_eq!(delta.pending_count, 1);
    assert_eq!(Grid::display_text(&cell), "new");
    assert!(has_class(&cell, "warning"));
}

#[gtk4::test]
fn unbind_disconnects_revision_handler() {
    let grid = two_text_rows();
    let cell = grid.cell_of(2, 1);
    let row = cell.row().expect("a bound row");
    let bound_renders = cell.render_count();
    row.bump_revision();
    assert_eq!(cell.render_count(), bound_renders + 1, "a bound cell did not redraw");

    cell.unbind();
    row.bump_revision();

    assert_eq!(
        cell.render_count(),
        bound_renders + 1,
        "a cell drew again for a row it no longer shows"
    );
}

#[gtk4::test]
fn a_cell_follows_only_the_row_it_is_bound_to() {
    let cell = GridCell::new(paint());
    let (first, second) = (GridRow::new(RowData::draft(1)), GridRow::new(RowData::draft(2)));

    cell.bind(&first);
    cell.bind(&second);
    let drawn = cell.render_count();
    first.bump_revision();
    assert_eq!(cell.render_count(), drawn, "the cell drew the row it showed before");
    second.bump_revision();
    cell.unbind();
    second.bump_revision();

    assert_eq!(cell.render_count(), drawn + 1);
}

#[gtk4::test]
fn pending_edit_sets_description_on_grid_cell() {
    let grid = two_text_rows();
    let cell = grid.cell_of(1, 1);
    assert!(!described(&cell));

    rename_first(&grid, "edited");
    assert!(described(&cell), "an edited cell said nothing");
    assert!(!described(&grid.cell_of(2, 1)));

    grid.grid.undo();
    assert!(!described(&cell), "an undone edit still read as modified");
}

#[gtk4::test]
fn null_cell_has_description_text_null_does_not() {
    let shown = Grid::build(
        GridSpec::results(vec![named("id", "integer", false), named("name", "text", false)]),
        results(&[vec![Value::Null, text("NULL")]]),
    );
    assert!(described(&shown.cell_at(0, 0)), "a NULL read the same as the text NULL");
    assert!(!described(&shown.cell_at(0, 1)), "the text NULL read as a NULL");
    drop(shown);

    let editable = Grid::open(
        two_text_columns(),
        vec![vec![Value::Int(1), Value::Null], vec![Value::Int(2), text("NULL")]],
    );
    assert!(described(&editable.cell_of(1, 1)));
    assert!(!described(&editable.cell_of(2, 1)));
}

#[gtk4::test]
fn from_focus_finds_the_cell_below_a_focused_cell_widget_or_above_its_editor() {
    let cell_widget = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    let cell = GridCell::new(paint());
    let editor = gtk::Text::new();
    editor.set_parent(&cell);
    cell_widget.append(&cell);

    let below = GridCell::from_focus(cell_widget.upcast_ref());
    let above = GridCell::from_focus(editor.upcast_ref());

    assert_eq!(below.as_ref(), Some(&cell));
    assert_eq!(above.as_ref(), Some(&cell));
    assert!(GridCell::from_focus(gtk::Label::new(None).upcast_ref()).is_none());
    editor.unparent();
}

#[gtk4::test]
fn an_unattached_cell_has_no_row() {
    let cell = GridCell::new(paint());

    assert!(cell.row().is_none());
    assert!(cell.position().is_none());
    assert!(!cell.is_editing());
}

/// A menu's target and an open editor are holds on a cell too.
#[gtk4::test]
fn cells_are_freed_with_the_grid() {
    let grid = Grid::open(
        vec![
            named("id", "integer", true),
            named("name", "text", false),
            named("flag", "boolean", false),
        ],
        vec![vec![Value::Int(7), text("a"), Value::Bool(true)]],
    );
    for cell in grid.cells() {
        assert!(grid.grid.open_cell_menu(&cell, None), "the menu opens");
        super::close_menus(&grid);
    }
    let name = grid.focus(0, 1);
    assert!(grid.grid.edit().edit_cell(&name));
    let freed: Vec<glib::WeakRef<GridCell>> = grid.cells().iter().map(ObjectExt::downgrade).collect();
    assert_eq!(freed.len(), 3);
    // GTK 4.22 leaks a focused widget that is hidden and then unparented.
    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);
    drain_main_context();

    drop((grid, name));
    drain_main_context();

    let alive = freed.iter().filter(|cell| cell.upgrade().is_some()).count();
    assert_eq!(alive, 0, "cells outlived their grid");
}

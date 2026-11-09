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
        grid: glib::WeakRef::new(),
        tracked: TrackedValues::untracked(),
        attributes: Rc::new(TextAttributes::new()),
        preferences: Default::default(),
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
fn open_grids_follow_the_display_preferences() {
    let grid = two_text_rows();
    let settings = grid.grid.config().expect("a configured grid").settings.clone();
    let view = grid.grid.column_view();
    let numbers = grid.grid.row_numbers_column().expect("a row number column");

    settings.set_show_row_numbers(false).expect("store the flag");
    settings.set_grid_row_height("compact").expect("store the height");
    drain_main_context();
    assert!(!numbers.is_visible());
    assert!(view.has_css_class("row-compact"));

    settings.set_grid_row_height("spacious").expect("store the height");
    settings.set_show_row_numbers(true).expect("store the flag");
    drain_main_context();
    assert!(numbers.is_visible());
    assert!(view.has_css_class("row-spacious") && !view.has_css_class("row-compact"));
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

#[gtk4::test]
fn highlight_rules_tint_the_rows_and_cells_that_meet_them() {
    use crate::services::grid::{HighlightColor, HighlightRule, HighlightTarget};
    use tablepro_core::filter::{FilterOp, FilterValue};

    let grid = Grid::open(two_text_columns(), two_text_values());
    let mut row_rule = HighlightRule::new("name");
    row_rule.op = FilterOp::Eq;
    row_rule.value = Some(FilterValue::Single("B".to_owned()));
    row_rule.color = HighlightColor::Red;
    let mut cell_rule = HighlightRule::new("id");
    cell_rule.op = FilterOp::Eq;
    cell_rule.value = Some(FilterValue::Single("1".to_owned()));
    cell_rule.color = HighlightColor::Green;
    cell_rule.target = HighlightTarget::Cell;

    grid.grid.set_highlight_rules(vec![row_rule, cell_rule]);
    drain_main_context();

    let tint = |id: i64, column: usize| {
        let cell = grid.cell_of(id, column);
        HighlightColor::ALL
            .into_iter()
            .find(|color| cell.has_css_class(color.css_class()))
    };
    assert_eq!(tint(2, 0), Some(HighlightColor::Red), "the row that meets the rule");
    assert_eq!(tint(2, 1), Some(HighlightColor::Red));
    assert!(described(&grid.cell_of(2, 1)), "a highlight needs a spoken description");
    assert_eq!(
        tint(1, 0),
        Some(HighlightColor::Green),
        "the cell that meets its own rule"
    );
    assert_eq!(tint(1, 1), None, "a cell rule leaves the row's other cells");

    grid.grid.set_highlight_rules(Vec::new());
    drain_main_context();
    assert_eq!(tint(2, 1), None, "the tint outlived its rule");
    assert!(!described(&grid.cell_of(2, 1)));
}

#[gtk4::test]
fn highlights_announce_their_colour_and_keep_modified_text_readable() {
    use crate::services::grid::{HighlightColor, HighlightRule};
    use tablepro_core::filter::FilterValue;

    let grid = two_text_rows();
    let mut rule = HighlightRule::new("name");
    rule.value = Some(FilterValue::Single("edited".to_owned()));
    rule.color = HighlightColor::Red;
    grid.grid.set_highlight_rules(vec![rule]);
    rename_first(&grid, "edited");
    let cell = grid.cell_of(1, 1);
    assert!(cell.has_css_class(HighlightColor::Red.css_class()));
    assert!(has_attribute(&cell, pango::AttrType::Weight));
    assert!(!has_class(&cell, "warning"));
    assert!(described(&cell));
    grid.grid.set_highlight_rules(Vec::new());
    assert!(has_class(&cell, "warning"));
}

/// A host that keeps the rules hears of each change, and only of changes.
#[gtk4::test]
fn the_grid_tells_its_host_when_the_highlight_rules_change() {
    use crate::services::grid::HighlightRule;

    let grid = Grid::open(two_text_columns(), two_text_values());
    let heard = Rc::new(Cell::new(0));
    let count = heard.clone();
    grid.grid
        .connect_highlight_rules_changed(move |_| count.set(count.get() + 1));

    grid.grid.set_highlight_rules(vec![HighlightRule::new("name")]);
    assert_eq!(heard.get(), 1);
    assert_eq!(grid.grid.highlight_rules().len(), 1);

    grid.grid.set_highlight_rules(Vec::new());
    assert_eq!(heard.get(), 2);
}

#[gtk4::test]
fn restored_highlights_apply_to_the_first_rows_without_a_refresh() {
    use crate::services::grid::{HighlightColor, HighlightRule, HighlightTarget};
    use tablepro_core::filter::FilterValue;

    let grid = Grid::open(two_text_columns(), Vec::new());
    grid.grid
        .set_columns([].into(), crate::ui::data_grid::GridSorting::None, None);
    let mut row_rule = HighlightRule::new("name");
    row_rule.value = Some(FilterValue::Single("B".to_owned()));
    row_rule.color = HighlightColor::Red;
    let mut cell_rule = HighlightRule::new("id");
    cell_rule.value = Some(FilterValue::Single("1".to_owned()));
    cell_rule.target = HighlightTarget::Cell;
    cell_rule.color = HighlightColor::Green;
    grid.grid.set_highlight_rules(vec![row_rule, cell_rule]);
    grid.grid
        .set_columns(grid.columns.clone(), crate::ui::data_grid::GridSorting::None, None);
    grid.grid
        .replace_rows(crate::ui::data_grid::test_grid::persisted(&two_text_values()), 0);
    wait_until(WAIT, || grid.cells().len() == 4).expect("first rows bind");

    assert!(grid.cell_of(2, 0).has_css_class(HighlightColor::Red.css_class()));
    assert!(grid.cell_of(2, 1).has_css_class(HighlightColor::Red.css_class()));
    assert!(grid.cell_of(1, 0).has_css_class(HighlightColor::Green.css_class()));
    assert!(!grid.cell_of(1, 1).has_css_class(HighlightColor::Green.css_class()));
    assert!(described(&grid.cell_of(2, 1)));
}

#[gtk4::test]
fn a_cell_can_read_highlights_when_bound_before_it_is_parented() {
    use crate::services::grid::{HighlightColor, HighlightRule};
    use tablepro_core::filter::FilterValue;

    let grid = Grid::open(two_text_columns(), two_text_values());
    let mut rule = HighlightRule::new("name");
    rule.value = Some(FilterValue::Single("A".to_owned()));
    rule.color = HighlightColor::Red;
    grid.grid.set_highlight_rules(vec![rule]);
    let cell = GridCell::new(Rc::new(ColumnPaint {
        column: grid.columns[1].clone(),
        grid: grid.grid.downgrade(),
        tracked: grid.grid.tracked(),
        attributes: Rc::new(TextAttributes::new()),
        preferences: Default::default(),
        numbers: Cell::new(false),
    }));
    assert!(cell.parent().is_none());
    cell.bind(&grid.grid.store().row(0).expect("first row"));
    assert!(cell.has_css_class(HighlightColor::Red.css_class()));
    assert!(described(&cell));
    cell.unbind();
    let owner = grid.grid.downgrade();
    drop(grid);
    drain_main_context();
    assert!(owner.upgrade().is_none(), "cell paint kept the grid alive");
}

#[gtk4::test]
fn null_text_reaches_every_grid_and_stays_with_its_settings() {
    let editable = Grid::open(two_text_columns(), vec![vec![Value::Int(1), Value::Null]]);
    let settings = editable.grid.config().expect("configured grid").settings.clone();
    let readonly = Grid::build(
        GridSpec {
            settings: Some(settings.clone()),
            ..GridSpec::results(two_text_columns())
        },
        results(&[vec![Value::Int(1), Value::Null]]),
    );
    let isolated = Grid::build(
        GridSpec::results(two_text_columns()),
        results(&[vec![Value::Int(1), Value::Null]]),
    );
    let editable_cell = editable.cell_of(1, 1);
    let readonly_cell = readonly.cell_at(0, 1);
    assert_eq!(Grid::display_text(&editable_cell), editable_null_sentinel());
    assert_eq!(Grid::display_text(&readonly_cell), "NULL");

    settings.set_null_display("missing").expect("store placeholder");
    drain_main_context();

    assert_eq!(Grid::display_text(&editable_cell), "missing");
    assert_eq!(Grid::display_text(&readonly_cell), "missing");
    assert_eq!(Grid::display_text(&isolated.cell_at(0, 1)), "NULL");
    assert!(described(&editable_cell));
    assert!(described(&readonly_cell));
    let reopened = Grid::build(
        GridSpec {
            settings: Some(settings),
            ..GridSpec::results(two_text_columns())
        },
        results(&[vec![Value::Int(1), Value::Null]]),
    );
    assert_eq!(Grid::display_text(&reopened.cell_at(0, 1)), "missing");
}

#[gtk4::test]
fn display_preferences_preserve_the_inline_draft_and_selected_rows() {
    let grid = two_text_rows();
    let cell = grid.focus(0, 1);
    grid.grid.selection().select_range(0, 2, true);
    assert!(grid.grid.edit().edit_cell(&cell));
    let editor = grid.grid.edit().open_text().expect("inline editor");
    editor.set_text("unfinished");
    let selected = super::selected_ids(&grid);
    let settings = grid.grid.config().expect("configured grid").settings.clone();

    settings.set_null_display("missing").expect("store placeholder");
    settings.set_grid_row_height("spacious").expect("store height");
    settings.set_show_row_numbers(false).expect("hide numbers");
    drain_main_context();

    assert_eq!(grid.grid.edit().open_text().as_ref(), Some(&editor));
    assert_eq!(editor.text(), "unfinished");
    assert_eq!(grid.grid.edit().editing_cell(), Some(cell));
    assert_eq!(super::selected_ids(&grid), selected);
    assert_eq!(grid.tracker.cell_overlay(&key(1), 1).pending, None);
}

#[gtk4::test]
fn row_height_preferences_change_the_allocated_row_height() {
    let grid = two_text_rows();
    let settings = grid.grid.config().expect("configured grid").settings.clone();
    let cell = grid.cell_of(1, 1);
    crate::test_support::after_next_frame(&grid.grid);
    let row = row_widget(&cell);
    wait_until(WAIT, || row.height() > 0).expect("row laid out");
    let normal = row.height();

    settings.set_grid_row_height("compact").expect("compact height");
    wait_until(WAIT, || row.height() < normal).expect("compact rows allocate less height than normal rows");
    let compact = row.height();

    settings.set_grid_row_height("spacious").expect("spacious height");
    wait_until(WAIT, || row.height() > normal).expect("spacious rows allocate more height than normal rows");
    assert!(row.height() > compact);

    settings.set_grid_row_height("normal").expect("normal height");
    wait_until(WAIT, || row.height() == normal).expect("normal rows restore their original height");
    assert_eq!(row_widget(&cell), row);
    assert_eq!(grid.cell_of(1, 1), cell);
}

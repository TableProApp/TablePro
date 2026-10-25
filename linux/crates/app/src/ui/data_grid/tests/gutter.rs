use std::collections::BTreeMap;

use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_core::edit::CellInput;

use super::{Layouts, delete_saved, described, draft_cell, keyed, rename_first, row_widget, sorts, text};
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{after_next_frame, descendants, drain_main_context};
use crate::ui::data_grid::GridCell;
use crate::ui::data_grid::test_grid::{Grid, GridSpec, key, results, two_text_columns, two_text_values};
use crate::ui::icons;

fn two_text_rows() -> Grid {
    Grid::open(two_text_columns(), two_text_values())
}

/// The gutter cell in `cell`'s row: its pending icon and its number.
fn gutter(cell: &GridCell) -> (gtk::Image, gtk::Inscription) {
    let content = descendants(&row_widget(cell))
        .into_iter()
        .find_map(|widget| widget.downcast::<gtk::Box>().ok())
        .expect("the row's gutter cell");
    (
        content.first_child().and_downcast().expect("the gutter's icon"),
        content.last_child().and_downcast().expect("the gutter's number"),
    )
}

fn number(cell: &GridCell) -> Option<String> {
    gutter(cell).1.text().map(|number| number.to_string())
}

/// The icon the gutter shows for `cell`'s row and the text it names it by.
fn state(cell: &GridCell) -> (Option<String>, Option<String>) {
    let (icon, _) = gutter(cell);
    let name = icon
        .is_visible()
        .then(|| icon.icon_name())
        .flatten()
        .map(|name| name.to_string());
    (name, icon.tooltip_text().map(|text| text.to_string()))
}

fn shown(icon: &str, text: &str) -> (Option<String>, Option<String>) {
    (Some(icon.to_owned()), Some(text.to_owned()))
}

#[gtk4::test]
fn row_numbers_count_from_the_base_under_the_drafts() {
    let grid = two_text_rows();
    let numbers = |grid: &Grid| [1, 2].map(|id| number(&grid.cell_of(id, 1)));
    assert_eq!(numbers(&grid), [Some("1".to_owned()), Some("2".to_owned())]);

    grid.grid.replace_rows(keyed(&[1, 2]), 100);
    drain_main_context();
    assert_eq!(numbers(&grid), [Some("101".to_owned()), Some("102".to_owned())]);

    grid.insert_draft();
    let draft = draft_cell(&grid);
    after_next_frame(&grid.window);

    assert_eq!(number(&draft).unwrap_or_default(), "", "a draft has no number");
    assert_eq!(
        numbers(&grid),
        [Some("101".to_owned()), Some("102".to_owned())],
        "a draft on top moved the numbers"
    );
}

#[gtk4::test]
fn a_results_grid_numbers_its_rows_too() {
    let grid = Grid::build(GridSpec::results(two_text_columns()), results(&two_text_values()));
    let first = grid
        .grid
        .column_view()
        .columns()
        .item(0)
        .and_downcast::<gtk::ColumnViewColumn>()
        .expect("the first column");

    assert_eq!(first.id().as_deref(), Some("row-numbers"));
    assert_eq!(number(&grid.cell_at(1, 1)).as_deref(), Some("2"));
}

/// The row keeps the error icon of a failed save until it is edited.
#[gtk4::test]
fn the_gutter_shows_each_pending_state() {
    let grid = two_text_rows();
    let (icon, _) = gutter(&grid.cell_of(1, 1));
    assert_eq!(state(&grid.cell_of(1, 1)), (None, None));
    assert!(gtk::test_accessible_has_role(&icon, gtk::AccessibleRole::Presentation));
    assert!(
        !icon
            .parent()
            .and_then(|content| content.parent())
            .is_some_and(|cell| cell.is_focusable()),
        "the gutter took the focus a data cell should"
    );

    rename_first(&grid, "edited");
    assert_eq!(state(&grid.cell_of(1, 1)), shown(icons::DOCUMENT_EDIT, "Modified"));
    grid.grid.apply_delta(&grid.tracker.mark_error_row(key(1)));
    assert_eq!(state(&grid.cell_of(1, 1)), shown(icons::DIALOG_ERROR, "Not saved"));
    rename_first(&grid, "again");
    assert_eq!(state(&grid.cell_of(1, 1)), shown(icons::DOCUMENT_EDIT, "Modified"));

    delete_saved(&grid, 2, "B");
    assert_eq!(
        state(&grid.cell_of(2, 1)),
        shown(icons::EDIT_DELETE, "Marked for deletion")
    );

    grid.insert_draft();
    assert_eq!(state(&draft_cell(&grid)), shown(icons::LIST_ADD, "New row"));

    grid.grid.discard();
    assert_eq!(state(&grid.cell_of(1, 1)), (None, None));
    assert_eq!(state(&grid.cell_of(2, 1)), (None, None));
}

#[gtk4::test]
fn pending_delete_sets_row_widget_description() {
    let grid = two_text_rows();
    let row = row_widget(&grid.cell_of(1, 1));
    assert!(gtk::test_accessible_has_role(&row, gtk::AccessibleRole::Row));
    assert!(!described(&row));
    assert!(!row.is_focusable(), "a row took the focus a cell should");

    delete_saved(&grid, 1, "A");
    assert!(described(&row), "a row marked for deletion said nothing");

    grid.grid.undo();
    assert!(!described(&row), "a restored row still read as marked");
    rename_first(&grid, "edited");
    assert!(!described(&row), "an edited row repeats what its edited cells say");
    grid.grid.apply_delta(&grid.tracker.mark_error_row(key(1)));
    assert!(described(&row), "a row a save failed on said nothing");
}

/// A new row's label says so, which a description would only repeat.
#[gtk4::test]
fn a_new_row_is_labelled_and_neither_it_nor_its_cells_described() {
    let grid = two_text_rows();
    let draft_id = grid.insert_draft();
    let draft = draft_cell(&grid);
    let row = row_widget(&draft);
    // A NULL is named whatever the row, so the cell holds a value.
    grid.grid.apply_delta(&grid.tracker.apply(TrackerEdit::DraftCell {
        draft_id,
        col: draft.column(),
        input: CellInput::Value(text("typed")),
    }));

    assert!(gtk::test_accessible_has_property(&row, gtk::AccessibleProperty::Label));
    assert!(!described(&row));
    assert!(!described(&draft));
}

/// The second row, since the list keeps the first row's widgets for its
/// focus.
#[gtk4::test]
fn an_unbound_gutter_cell_stops_following_its_row() {
    let grid = two_text_rows();
    let (icon, _) = gutter(&grid.cell_of(2, 1));
    let row = grid.cell_of(2, 1).row().expect("a bound row");

    grid.grid.replace_rows(keyed(&[1]), 0);
    drain_main_context();
    let _ = grid.tracker.apply(TrackerEdit::Cell {
        row_key: key(2),
        col: 1,
        original: text("B"),
        value: text("edited"),
    });
    row.bump_revision();

    assert_eq!(icon.icon_name(), None, "a recycled icon drew a row it no longer shows");
}

/// The gutter is a column like the others for GTK, and none for the
/// layout, the sort or the data columns' numbering.
#[gtk4::test]
fn the_gutter_neither_sorts_nor_saves_its_width() {
    let layouts = Layouts::new();
    let grid = Grid::build(
        GridSpec {
            layout: Some(layouts.binding("t")),
            ..GridSpec::table(two_text_columns())
        },
        keyed(&[1]),
    );
    let view = grid.grid.column_view();
    let gutter = view
        .columns()
        .item(0)
        .and_downcast::<gtk::ColumnViewColumn>()
        .expect("the gutter");
    let titles: Vec<String> = (0..2)
        .filter_map(|index| grid.grid.data_view_column(index))
        .filter_map(|column| column.title().map(|title| title.to_string()))
        .collect();

    assert_eq!(gutter.id().as_deref(), Some("row-numbers"));
    assert_eq!(gutter.title().as_deref(), Some("#"));
    assert!(!gutter.is_resizable());
    assert!(gutter.sorter().is_none());
    assert!(gutter.fixed_width() > 0);
    assert_eq!(titles, ["id", "name"]);

    gutter.set_fixed_width(60);
    super::data_column(&grid, 1).set_fixed_width(200);
    drain_main_context();
    assert_eq!(layouts.saved("t").widths, BTreeMap::from([("name".to_owned(), 200)]));

    view.sort_by_column(Some(&super::data_column(&grid, 0)), gtk::SortType::Descending);
    drain_main_context();
    assert_eq!(
        sorts(&grid),
        [Some((0, false))],
        "a sort by the first data column named another"
    );
}

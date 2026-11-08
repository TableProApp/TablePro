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
        value: CellInput::Value(text("edited")),
    });
    row.bump_revision();

    assert_eq!(icon.icon_name(), None, "a recycled icon drew a row it no longer shows");
}

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

struct TestStyle {
    display: gtk::gdk::Display,
    provider: gtk::CssProvider,
}

impl TestStyle {
    fn new(grid: &Grid, css: &str) -> Self {
        let provider = gtk::CssProvider::new();
        provider.load_from_string(css);
        let display = gtk::prelude::WidgetExt::display(&grid.window);
        gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_USER);
        after_next_frame(&grid.window);
        Self { display, provider }
    }
}

impl Drop for TestStyle {
    fn drop(&mut self) {
        gtk::style_context_remove_provider_for_display(&self.display, &self.provider);
    }
}

fn wide_rows(count: i64) -> Grid {
    use tablepro_core::Value;
    let mut columns = vec![crate::ui::data_grid::test_grid::named("id", "integer", true)];
    columns.extend((0..12).map(|n| crate::ui::data_grid::test_grid::named(&format!("column_{n}"), "text", false)));
    let rows = (1..=count)
        .map(|id| {
            std::iter::once(Value::Int(id))
                .chain((0..12).map(|n| Value::Text(format!("value {id}-{n}"))))
                .collect()
        })
        .collect();
    Grid::open(columns, rows)
}

fn projection(grid: &Grid) -> gtk::ColumnView {
    use gtk::subclass::prelude::*;
    grid.grid.imp().gutter_view.get()
}

fn scroll(grid: &Grid) -> gtk::ScrolledWindow {
    use gtk::subclass::prelude::*;
    grid.grid.imp().scrolled.get()
}

fn pinned_number(grid: &Grid, value: &str) -> gtk::Inscription {
    descendants(&projection(grid))
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Inscription>().ok())
        .find(|number| number.text().as_deref() == Some(value))
        .expect("the pinned row number")
}

fn assert_aligned(grid: &Grid) {
    let view = grid.grid.column_view();
    let shown = descendants(&view)
        .into_iter()
        .filter_map(|widget| widget.downcast::<GridCell>().ok())
        .filter(|cell| cell.column() == 1)
        .filter_map(|cell| {
            let bounds = cell.compute_bounds(&view)?;
            (bounds.y() >= 40.0 && bounds.y() + bounds.height() < view.height() as f32).then_some((cell, bounds))
        })
        .collect::<Vec<_>>();
    assert!(!shown.is_empty(), "no visible rows checked");
    for (cell, bounds) in shown {
        let position = cell.position().expect("bound position");
        let number = pinned_number(grid, &(position + 1).to_string());
        let content = number.parent().expect("gutter content");
        let pinned = content.compute_bounds(&view).expect("gutter bounds");
        assert!(
            (pinned.y() - bounds.y()).abs() <= 1.0,
            "row {position}: {pinned:?} != {bounds:?}"
        );
        assert!((pinned.height() - bounds.height()).abs() <= 1.0);
    }
}

fn sideways(grid: &Grid) {
    let adjustment = scroll(grid).hadjustment();
    adjustment.set_value(300.0);
    after_next_frame(&grid.window);
}

#[gtk4::test]
fn the_row_numbers_stay_in_view_when_the_columns_scroll_sideways() {
    let grid = wide_rows(1000);
    assert!(!projection(&grid).is_visible());
    sideways(&grid);
    assert!(projection(&grid).is_visible());
    assert!(!projection(&grid).can_target());
    assert!(!projection(&grid).can_focus());
    assert_eq!(projection(&grid).vadjustment(), grid.grid.column_view().vadjustment());
    assert_eq!(projection(&grid).model(), grid.grid.column_view().model());
    for fraction in [0.0, 0.5, 1.0] {
        let adjustment = scroll(&grid).vadjustment();
        adjustment.set_value(fraction * (adjustment.upper() - adjustment.page_size()));
        after_next_frame(&grid.window);
        assert_aligned(&grid);
    }
    scroll(&grid).hadjustment().set_value(0.0);
    drain_main_context();
    assert!(!projection(&grid).is_visible());
}

#[gtk4::test]
fn scrolling_over_the_gutter_uses_the_grid_in_both_axes() {
    use crate::test_support::{KeyInjector, wait_until};
    use crate::ui::data_grid::test_grid::WAIT;
    let grid = wide_rows(1000);
    KeyInjector::focus_only(&grid.window);
    sideways(&grid);
    let input = KeyInjector::connect().expect("X11 input");
    let gutter = projection(&grid);
    let vertical = scroll(&grid).vadjustment();
    input.button(&gutter, (10.0, 80.0), 5, 3).expect("wheel down");
    wait_until(WAIT, || vertical.value() > 0.0).expect("the grid scrolled vertically");
    after_next_frame(&grid.window);
    assert_aligned(&grid);
    let horizontal = scroll(&grid).hadjustment();
    let before = horizontal.value();
    input.button(&gutter, (10.0, 80.0), 7, 3).expect("wheel right");
    wait_until(WAIT, || horizontal.value() > before).expect("the grid scrolled horizontally");
    after_next_frame(&grid.window);
    assert_aligned(&grid);
}

#[gtk4::test]
fn the_pinned_gutter_keeps_row_and_header_menus() {
    use crate::test_support::{KeyInjector, wait_until};
    use crate::ui::data_grid::test_grid::WAIT;
    use gtk::subclass::prelude::*;
    let grid = wide_rows(20);
    KeyInjector::focus_only(&grid.window);
    sideways(&grid);
    let input = KeyInjector::connect().expect("X11 input");
    let number = pinned_number(&grid, "2");
    input.button(&number, (4.0, 4.0), 3, 1).expect("row menu click");
    let menus = grid.grid.imp().menus.get().expect("menus");
    wait_until(WAIT, || menus.cell.is_visible()).expect("row menu opened");
    let target = grid.grid.target().expect("menu target");
    assert_eq!(target.rows.len(), 1);
    assert_eq!(target.rows[0].key(), Some(key(2)));
    menus.cell.popdown();
    drain_main_context();
    sideways(&grid);
    input
        .button(&projection(&grid), (10.0, 10.0), 3, 1)
        .expect("header menu click");
    wait_until(WAIT, || menus.row_numbers.is_visible()).expect("header menu opened");
    assert!(grid.grid.activate_action("grid.select-all", None).is_ok());
    assert_eq!(grid.grid.selection().selection().size(), 20);
    menus.row_numbers.popdown();
}

#[gtk4::test]
fn gutter_and_data_clicks_share_the_selection_anchor() {
    use crate::test_support::{KeyInjector, wait_until};
    use crate::ui::data_grid::test_grid::WAIT;
    let grid = wide_rows(20);
    KeyInjector::focus_only(&grid.window);
    grid.focus(1, 1);
    sideways(&grid);
    let input = KeyInjector::connect().expect("X11 input");
    input
        .click(&pinned_number(&grid, "2"), (4.0, 4.0), 1)
        .expect("row selection");
    wait_until(WAIT, || grid.grid.selection().is_selected(1)).expect("second row selected");
    let shift = input.hold(gtk::gdk::Key::Shift_L).expect("Shift");
    input
        .click(&pinned_number(&grid, "5"), (4.0, 4.0), 1)
        .expect("range selection");
    wait_until(WAIT, || grid.grid.selection().selection().size() == 4).expect("native selection range");
    drop(shift);
    assert!((1..=4).all(|position| grid.grid.selection().is_selected(position)));
    input
        .press(gtk::gdk::Key::Down, gtk::gdk::ModifierType::empty())
        .expect("keyboard navigation");
    wait_until(WAIT, || {
        grid.focused_cell().is_some_and(|cell| cell.position() == Some(5))
    })
    .expect("keyboard follows the clicked row");
}

#[gtk4::test]
fn the_gutter_matches_font_and_density_changes() {
    let grid = wide_rows(1000);
    sideways(&grid);
    let style = TestStyle::new(
        &grid,
        "columnview { font-size: 23px; } columnview .monospace { font-size: 23px; } columnview.data-table > listview > row > cell > * { padding: 9px 6px; }",
    );
    for fraction in [0.0, 0.5, 1.0] {
        let adjustment = scroll(&grid).vadjustment();
        adjustment.set_value(fraction * (adjustment.upper() - adjustment.page_size()));
        after_next_frame(&grid.window);
        assert_aligned(&grid);
    }
    drop(style);
    after_next_frame(&grid.window);
    assert_aligned(&grid);
}

#[gtk4::test]
fn the_pinned_gutter_shows_pending_states_and_stripes() {
    let grid = wide_rows(20);
    sideways(&grid);
    rename_first(&grid, "edited");
    let number = pinned_number(&grid, "1");
    let icon = number
        .parent()
        .and_then(|content| content.first_child())
        .and_downcast::<gtk::Image>()
        .expect("icon");
    assert_eq!(icon.icon_name().as_deref(), Some(icons::DOCUMENT_EDIT));
    assert_eq!(icon.tooltip_text().as_deref(), Some("Modified"));
    let second = pinned_number(&grid, "2");
    assert!(second.parent().expect("content").has_css_class("tp-stripe"));
    grid.grid.discard();
    assert!(!icon.is_visible());
}

#[gtk4::test]
fn small_fonts_and_an_offscreen_editor_keep_the_gutter_aligned() {
    let grid = wide_rows(1200);
    let _style = TestStyle::new(
        &grid,
        "columnview { font-size: 7px; } columnview .monospace { font-size: 7px; }",
    );
    rename_first(&grid, "changed");
    grid.focus(0, 1);
    assert!(grid.grid.edit().edit_cell(&grid.cell_of(1, 1)));
    sideways(&grid);
    for fraction in [0.0, 0.5, 1.0, 0.0] {
        let adjustment = scroll(&grid).vadjustment();
        adjustment.set_value(fraction * (adjustment.upper() - adjustment.page_size()));
        after_next_frame(&grid.window);
        assert_aligned(&grid);
    }
}

#[gtk4::test]
fn a_covered_editor_cannot_take_a_gutter_click() {
    use crate::test_support::{KeyInjector, wait_until};
    use crate::ui::data_grid::test_grid::WAIT;
    let grid = wide_rows(20);
    KeyInjector::focus_only(&grid.window);
    grid.focus(0, 1);
    assert!(grid.grid.edit().edit_cell(&grid.cell_of(1, 1)));
    let input = KeyInjector::connect().expect("X11 input");
    sideways(&grid);
    let number = pinned_number(&grid, "3");
    input.click(&number, (4.0, 4.0), 1).expect("gutter click");
    wait_until(WAIT, || grid.grid.selection().is_selected(2)).expect("the gutter selects its row");
    assert!(!grid.grid.edit().editor_has_focus());
}

#[gtk4::test]
fn clicking_the_pinned_header_does_not_sort_the_covered_column() {
    use crate::test_support::KeyInjector;
    let grid = wide_rows(20);
    KeyInjector::focus_only(&grid.window);
    sideways(&grid);
    let input = KeyInjector::connect().expect("X11 input");
    let before = sorts(&grid);
    input.click(&projection(&grid), (10.0, 10.0), 2).expect("header click");
    after_next_frame(&grid.window);
    assert_eq!(sorts(&grid), before);
}

#[gtk4::test]
fn keyboard_focus_stays_clear_of_the_pinned_gutter() {
    use crate::test_support::{KeyInjector, wait_until};
    use crate::ui::data_grid::test_grid::WAIT;
    let grid = wide_rows(20);
    KeyInjector::focus_only(&grid.window);
    grid.focus(0, 10);
    after_next_frame(&grid.window);
    let input = KeyInjector::connect().expect("X11 input");
    for column in (0..10).rev() {
        input
            .press(gtk::gdk::Key::Left, gtk::gdk::ModifierType::empty())
            .expect("left");
        wait_until(WAIT, || grid.focused_cell().is_some_and(|cell| cell.column() == column)).expect("focused column");
        after_next_frame(&grid.window);
        let cell = grid.focused_cell().expect("cell");
        let bounds = cell.compute_bounds(&grid.grid.column_view()).expect("bounds");
        let width = grid.grid.row_numbers_column().expect("numbers").fixed_width() as f32;
        assert!(bounds.x() >= width - 1.0, "column {column} is hidden: {bounds:?}");
    }
}

#[gtk4::test]
fn dragging_across_the_gutter_uses_one_rubberband() {
    use crate::test_support::{KeyInjector, wait_until};
    use crate::ui::data_grid::test_grid::WAIT;
    let grid = wide_rows(20);
    KeyInjector::focus_only(&grid.window);
    sideways(&grid);
    let input = KeyInjector::connect().expect("X11 input");
    let view = grid.grid.column_view();
    let point = |value: &str| {
        pinned_number(&grid, value)
            .compute_point(&view, &gtk::graphene::Point::new(4.0, 4.0))
            .expect("point")
    };
    let from = point("2");
    let to = point("6");
    input
        .drag(&view, (10.0, from.y()), (160.0, to.y()))
        .expect("drag from gutter into data");
    wait_until(WAIT, || grid.grid.selection().selection().size() >= 4).expect("one native rubberband selected rows");
    grid.grid.selection().unselect_all();
    input
        .drag(&view, (160.0, to.y()), (10.0, from.y()))
        .expect("drag from data into gutter");
    wait_until(WAIT, || grid.grid.selection().selection().size() >= 4).expect("the reverse drag selected rows");
}

#[gtk4::test]
fn dragging_the_pinned_header_does_not_move_a_data_column() {
    use crate::test_support::KeyInjector;
    let grid = wide_rows(20);
    KeyInjector::focus_only(&grid.window);
    sideways(&grid);
    let input = KeyInjector::connect().expect("X11 input");
    let before = grid.grid.shown_columns();
    input
        .drag(&grid.grid.column_view(), (10.0, 10.0), (220.0, 10.0))
        .expect("header drag");
    after_next_frame(&grid.window);
    assert_eq!(grid.grid.shown_columns(), before);
}

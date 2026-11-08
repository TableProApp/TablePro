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

fn projection(grid: &Grid) -> gtk::Box {
    use gtk::subclass::prelude::*;
    grid.grid.imp().gutter_backing.get()
}

fn scroll(grid: &Grid) -> gtk::ScrolledWindow {
    use gtk::subclass::prelude::*;
    grid.grid.imp().scrolled.get()
}

fn pinned_number(grid: &Grid, value: &str) -> gtk::Inscription {
    descendants(&grid.grid.column_view())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Inscription>().ok())
        .find(|number| {
            number.text().as_deref() == Some(value)
                && number
                    .parent()
                    .is_some_and(|content| content.has_css_class("row-number-cell"))
        })
        .expect("the pinned row number")
}

fn pinned_point(grid: &Grid, value: &str) -> (f32, f32) {
    let number = pinned_number(grid, value);
    let source = number.compute_bounds(&grid.grid.column_view()).expect("number bounds");
    let target = projection(grid)
        .compute_bounds(&grid.grid.column_view())
        .expect("gutter bounds");
    (target.x() + 10.0, source.y() + 4.0)
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

fn gutter_pixels(grid: &Grid) -> Vec<u8> {
    use gtk::subclass::prelude::*;
    let viewport = grid.grid.imp().viewport.get();
    let parent = viewport.parent().expect("viewport parent");
    let snapshot = gtk::Snapshot::new();
    parent.snapshot_child(&viewport, &snapshot);
    let node = snapshot.to_node().expect("rendered grid");
    let bounds = viewport.compute_bounds(&parent).expect("viewport bounds");
    let width = grid.grid.row_numbers_column().expect("number column").fixed_width() as f32;
    let x = if viewport.direction() == gtk::TextDirection::Rtl {
        bounds.x() + bounds.width() - width
    } else {
        bounds.x()
    };
    let area = gtk::graphene::Rect::new(x, bounds.y(), width, bounds.height());
    let texture = grid
        .window
        .renderer()
        .expect("renderer")
        .render_texture(&node, Some(&area));
    gtk::gdk::TextureDownloader::new(&texture)
        .download_bytes()
        .0
        .as_ref()
        .to_vec()
}

fn assert_pinned_pixels(grid: &Grid) {
    let adjustment = scroll(grid).hadjustment();
    let value = adjustment.value();
    adjustment.set_value(0.0);
    after_next_frame(&grid.window);
    let native = gutter_pixels(grid);
    adjustment.set_value(value);
    after_next_frame(&grid.window);
    let pinned = gutter_pixels(grid);
    assert_eq!(native.len(), pinned.len());
    assert_eq!(
        native.iter().zip(&pinned).filter(|(a, b)| a != b).count(),
        0,
        "the pinned gutter differs from the native row-number column"
    );
}

fn sideways(grid: &Grid) {
    let adjustment = scroll(grid).hadjustment();
    adjustment.set_value(300.0);
    after_next_frame(&grid.window);
}

#[gtk4::test]
fn the_row_numbers_stay_in_view_when_the_columns_scroll_sideways() {
    let grid = wide_rows(1000);
    scroll(&grid).set_overlay_scrolling(false);
    assert!(!projection(&grid).is_visible());
    sideways(&grid);
    assert!(projection(&grid).is_visible());
    assert!(!projection(&grid).can_target());
    assert!(!projection(&grid).can_focus());
    assert_eq!(projection(&grid).height(), grid.grid.column_view().height());
    assert_eq!(
        descendants(&grid.grid)
            .iter()
            .filter(|widget| widget.is::<gtk::ColumnView>())
            .count(),
        1,
        "the gutter must not introduce a second row layout or accessibility tree"
    );
    for fraction in [0.0, 0.5, 1.0] {
        let adjustment = scroll(&grid).vadjustment();
        adjustment.set_value(fraction * (adjustment.upper() - adjustment.page_size()));
        after_next_frame(&grid.window);
        assert_aligned(&grid);
        assert_pinned_pixels(&grid);
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
    input
        .button(&grid.grid.column_view(), pinned_point(&grid, "2"), 3, 1)
        .expect("row menu click");
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
    let data = |position: u32| {
        let view = grid.grid.column_view();
        descendants(&view)
            .into_iter()
            .filter_map(|widget| widget.downcast::<GridCell>().ok())
            .find(|cell| {
                cell.position() == Some(position)
                    && cell.compute_bounds(&view).is_some_and(|bounds| {
                        bounds.x() > projection(&grid).width() as f32
                            && bounds.x() + bounds.width() < view.width() as f32
                    })
            })
            .expect("a fully visible data cell")
            .compute_point(&view, &gtk::graphene::Point::new(4.0, 4.0))
            .map(|point| (point.x(), point.y()))
            .expect("data point")
    };
    for reverse in [false, true] {
        let start = if reverse { pinned_point(&grid, "2") } else { data(1) };
        input.click(&grid.grid.column_view(), start, 1).expect("row selection");
        wait_until(WAIT, || {
            grid.grid.selection().selection().size() == 1 && grid.grid.selection().is_selected(1)
        })
        .expect("second row selected");
        let shift = input.hold(gtk::gdk::Key::Shift_L).expect("Shift");
        let end = if reverse { data(4) } else { pinned_point(&grid, "5") };
        input.click(&grid.grid.column_view(), end, 1).expect("range selection");
        wait_until(WAIT, || grid.grid.selection().selection().size() == 4).expect("native selection range");
        drop(shift);
        assert!((1..=4).all(|position| grid.grid.selection().is_selected(position)));
    }
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
        assert_pinned_pixels(&grid);
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
    after_next_frame(&grid.window);
    assert_pinned_pixels(&grid);
    assert_eq!(icon.tooltip_text().as_deref(), Some("Modified"));
    let second = pinned_number(&grid, "2");
    assert!(second.parent().expect("content").has_css_class("tp-stripe"));
    grid.grid.selection().select_item(1, false);
    after_next_frame(&grid.window);
    assert_pinned_pixels(&grid);
    grid.grid.discard();
    assert!(!icon.is_visible());
    after_next_frame(&grid.window);
    assert_pinned_pixels(&grid);
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
        assert_pinned_pixels(&grid);
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
    let point = pinned_point(&grid, "1");
    let picked = grid
        .grid
        .column_view()
        .pick(f64::from(point.0), f64::from(point.1), gtk::PickFlags::DEFAULT)
        .expect("gutter target");
    assert!(!picked.is::<gtk::Text>(), "the covered editor took the gutter");
    input.click(&grid.grid.column_view(), point, 1).expect("gutter click");
    wait_until(WAIT, || {
        !grid.grid.edit().editor_has_focus() && grid.grid.selection().is_selected(0)
    })
    .expect("the gutter selected the row and moved focus out of the editor");
    assert!(grid.grid.selection().is_selected(0));
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
    let from = pinned_point(&grid, "2");
    let to = pinned_point(&grid, "6");
    input
        .drag(&view, (10.0, from.1), (160.0, to.1))
        .expect("drag from gutter into data");
    wait_until(WAIT, || grid.grid.selection().selection().size() >= 4).expect("one native rubberband selected rows");
    grid.grid.selection().unselect_all();
    input
        .drag(&view, (160.0, to.1), (10.0, from.1))
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

#[gtk4::test]
fn rtl_gutter_menus_and_focus_follow_its_actual_edge() {
    use crate::test_support::{KeyInjector, wait_until};
    use crate::ui::data_grid::test_grid::WAIT;
    use gtk::subclass::prelude::*;
    struct Direction(gtk::TextDirection);
    impl Drop for Direction {
        fn drop(&mut self) {
            gtk::Widget::set_default_direction(self.0);
        }
    }
    let _direction = Direction(gtk::Widget::default_direction());
    gtk::Widget::set_default_direction(gtk::TextDirection::Rtl);
    let grid = wide_rows(20);
    KeyInjector::focus_only(&grid.window);
    sideways(&grid);
    let view = grid.grid.column_view();
    let gutter = projection(&grid).compute_bounds(&view).expect("gutter");
    assert!(gutter.x() > view.width() as f32 / 2.0);
    assert_pinned_pixels(&grid);
    let input = KeyInjector::connect().expect("X11 input");
    input.button(&view, pinned_point(&grid, "2"), 3, 1).expect("row menu");
    let menus = grid.grid.imp().menus.get().expect("menus");
    wait_until(WAIT, || menus.cell.is_visible()).expect("row menu opened");
    assert_eq!(grid.grid.target().expect("target").rows[0].key(), Some(key(2)));
    menus.cell.popdown();
    drain_main_context();
    sideways(&grid);
    input
        .button(&projection(&grid), (10.0, 10.0), 3, 1)
        .expect("header menu");
    wait_until(WAIT, || menus.row_numbers.is_visible()).expect("header menu opened");
    menus.row_numbers.popdown();
    grid.focus(0, 1);
    assert!(grid.grid.edit().edit_cell(&grid.cell_of(1, 1)));
    sideways(&grid);
    grid.window.set_default_size(740, 430);
    after_next_frame(&grid.window);
    let point = pinned_point(&grid, "1");
    let picked = view
        .pick(f64::from(point.0), f64::from(point.1), gtk::PickFlags::DEFAULT)
        .expect("target");
    assert!(
        !picked.is::<gtk::Text>(),
        "RTL resize exposed the editor under the gutter"
    );
    grid.grid.edit().cancel_open_edit();
    grid.focus(0, 10);
    after_next_frame(&grid.window);
    for column in (0..10).rev() {
        input
            .press(gtk::gdk::Key::Right, gtk::gdk::ModifierType::empty())
            .expect("right");
        wait_until(WAIT, || grid.focused_cell().is_some_and(|cell| cell.column() == column)).expect("focused column");
        after_next_frame(&grid.window);
        let cell = grid.focused_cell().expect("cell");
        let bounds = cell.compute_bounds(&view).expect("bounds");
        let width = grid.grid.row_numbers_column().expect("numbers").fixed_width() as f32;
        assert!(
            bounds.x() + bounds.width() <= view.width() as f32 - width + 1.0,
            "column {column}: {bounds:?}"
        );
    }
}

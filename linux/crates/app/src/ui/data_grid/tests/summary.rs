use std::cell::RefCell;
use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::Value;
use tablepro_core::value::SqlDecimal;

use super::super::GridRequest;
use super::super::test_grid::{Grid, WAIT, key, named};
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{descendants, drain_main_context, finish_on_main, wait_until};

fn text(value: &str) -> Value {
    Value::Text(value.to_owned())
}

/// Amounts 10, 32 and NULL, keyed 1 to 3.
fn amounts() -> Grid {
    Grid::open(
        vec![
            named("id", "integer", true),
            named("amount", "integer", false),
            named("name", "text", false),
        ],
        vec![
            vec![Value::Int(1), Value::Int(10), text("a")],
            vec![Value::Int(2), Value::Int(32), text("b")],
            vec![Value::Int(3), Value::Null, text("c")],
        ],
    )
}

fn readout(grid: &Grid) -> (gtk::Revealer, gtk::MenuButton) {
    let revealer = grid
        .grid
        .selection_summary()
        .downcast::<gtk::Revealer>()
        .expect("the readout is a revealer");
    let button = revealer
        .child()
        .and_downcast::<gtk::MenuButton>()
        .expect("the readout's menu button");
    (revealer, button)
}

fn wait_for_label(button: &gtk::MenuButton, expected: &str) {
    wait_until(WAIT, || button.label().as_deref() == Some(expected))
        .unwrap_or_else(|_| panic!("the readout said {:?}, not {expected:?}", button.label()));
}

fn wait_hidden(revealer: &gtk::Revealer) {
    wait_until(WAIT, || !revealer.reveals_child()).expect("the readout hides");
}

#[gtk4::test]
fn sums_the_focused_column_over_the_selected_rows() {
    let grid = amounts();
    let (revealer, button) = readout(&grid);
    drain_main_context();
    assert!(!revealer.reveals_child(), "nothing is selected yet");

    grid.focus(0, 1);
    grid.grid.selection().select_all();

    wait_for_label(&button, "Sum 42, Average 21, Count 2");
    assert!(revealer.reveals_child());
    assert_eq!(button.tooltip_text().as_deref(), Some("Sum 42, Average 21, Count 2"));
}

#[gtk4::test]
fn a_text_column_only_counts() {
    let grid = amounts();
    let (_, button) = readout(&grid);

    grid.focus(0, 2);
    grid.grid.selection().select_all();

    wait_for_label(&button, "Count 3");
}

#[gtk4::test]
fn a_single_row_shows_no_summary() {
    let grid = amounts();
    let (revealer, button) = readout(&grid);
    grid.focus(0, 1);
    grid.grid.selection().select_all();
    wait_for_label(&button, "Sum 42, Average 21, Count 2");

    grid.grid.selection().select_item(1, true);

    wait_hidden(&revealer);
}

#[gtk4::test]
fn an_edit_counts_as_the_cell_shows_it_while_the_focus_is_elsewhere() {
    let grid = amounts();
    let (revealer, button) = readout(&grid);
    grid.focus(0, 1);
    grid.grid.selection().select_all();
    wait_for_label(&button, "Sum 42, Average 21, Count 2");

    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);
    grid.grid.apply_delta(&grid.tracker.apply(TrackerEdit::Cell {
        row_key: key(1),
        col: 1,
        original: Value::Int(10),
        value: Value::Int(20),
    }));

    wait_for_label(&button, "Sum 52, Average 26, Count 2");
    assert!(revealer.reveals_child(), "the focus leaving the cells hid the readout");
}

#[gtk4::test]
fn rows_marked_for_deletion_are_left_out_also_after_a_failed_save() {
    let grid = amounts();
    let (_, button) = readout(&grid);
    grid.focus(0, 1);
    grid.grid.selection().select_all();
    wait_for_label(&button, "Sum 42, Average 21, Count 2");

    grid.grid.apply_delta(&grid.tracker.apply(TrackerEdit::DeleteRows {
        persisted: vec![(key(2), vec![Value::Int(2), Value::Int(32), text("b")].into())],
        drafts: Vec::new(),
    }));
    wait_for_label(&button, "Sum 10, Average 10, Count 1");

    grid.grid.apply_delta(&grid.tracker.mark_error_row(key(2)));
    grid.grid.apply_delta(&grid.tracker.apply(TrackerEdit::Cell {
        row_key: key(1),
        col: 1,
        original: Value::Int(10),
        value: Value::Int(11),
    }));
    wait_for_label(&button, "Sum 11, Average 11, Count 1");
}

#[gtk4::test]
fn a_hidden_column_is_not_summed() {
    let grid = amounts();
    let (revealer, button) = readout(&grid);
    grid.focus(0, 1);
    grid.grid.selection().select_all();
    wait_for_label(&button, "Sum 42, Average 21, Count 2");

    grid.grid.set_column_visible(1, false);

    // GTK may move the focus to a cell still shown, whose column is summed then.
    wait_until(WAIT, || {
        !revealer.reveals_child() || button.label().as_deref() != Some("Sum 42, Average 21, Count 2")
    })
    .expect("the hidden column is still summed");
}

#[gtk4::test]
fn the_readout_keeps_its_height_while_hidden() {
    let grid = amounts();
    let (revealer, button) = readout(&grid);
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    footer.append(&gtk::Label::new(Some("3 rows")));
    footer.append(&revealer);
    let hidden = footer.measure(gtk::Orientation::Vertical, -1).1;

    grid.focus(0, 1);
    grid.grid.selection().select_all();
    wait_for_label(&button, "Sum 42, Average 21, Count 2");

    assert_eq!(footer.measure(gtk::Orientation::Vertical, -1).1, hidden);
}

#[gtk4::test]
fn the_popover_lists_each_figure_and_copies_it_without_grouping() {
    let decimal = |text: &str| Value::Decimal(text.parse::<SqlDecimal>().expect("a decimal"));
    let grid = Grid::open(
        vec![named("id", "integer", true), named("price", "numeric(10,2)", false)],
        vec![
            vec![Value::Int(1), decimal("1234.5")],
            vec![Value::Int(2), decimal("0.25")],
            vec![Value::Int(3), decimal("NaN")],
        ],
    );
    let toasts: Rc<RefCell<Vec<String>>> = Rc::default();
    let log = toasts.clone();
    grid.grid.connect_request(move |_, request| {
        if let GridRequest::Toast(text) = request {
            log.borrow_mut().push(text);
        }
    });
    let (_, button) = readout(&grid);
    grid.focus(0, 1);
    grid.grid.selection().select_all();
    // CI runs in the C locale, which groups as English does.
    wait_for_label(&button, "Sum 1,234.75, Average 617.375, Count 3");

    let popover = button.popover().expect("the readout's popover");
    let labels: Vec<String> = descendants(&popover)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
        .filter(|label| label.get_visible())
        .map(|label| label.label().to_string())
        .collect();
    assert_eq!(
        labels,
        [
            "price",
            "Count",
            "3",
            "Numbers",
            "2",
            "Empty",
            "0",
            "Not a Number",
            "1",
            "Sum",
            "1,234.75",
            "Average",
            "617.375",
            "Minimum",
            "0.25",
            "Maximum",
            "1,234.50",
        ]
    );

    let copy_maximum = descendants(&popover)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        .find(|copy| copy.tooltip_text().as_deref() == Some("Copy Maximum"))
        .expect("Copy Maximum");
    assert!(copy_maximum.is_sensitive(), "Copy stayed off after the figures came in");
    copy_maximum.emit_clicked();
    wait_until(WAIT, || !toasts.borrow().is_empty()).expect("the copy lands");
    let clipboard = grid.grid.clipboard();
    let copied = finish_on_main(WAIT, async move { clipboard.read_text_future().await })
        .expect("the clipboard to answer")
        .expect("text on the clipboard");
    assert_eq!(copied.as_deref(), Some("1234.50"));
}

#[gtk4::test]
fn a_long_figure_keeps_its_popover_row_on_one_line() {
    let grid = amounts();
    let (_, button) = readout(&grid);
    grid.focus(0, 1);
    grid.grid.selection().select_all();
    wait_for_label(&button, "Sum 42, Average 21, Count 2");
    let popover = button.popover().expect("the readout's popover");
    let height = || {
        popover
            .child()
            .expect("the popover's content")
            .measure(gtk::Orientation::Vertical, -1)
            .1
    };
    let short = height();

    let wide = format!("1{}", "0".repeat(1_500))
        .parse::<SqlDecimal>()
        .expect("a decimal");
    grid.grid.apply_delta(&grid.tracker.apply(TrackerEdit::Cell {
        row_key: key(1),
        col: 1,
        original: Value::Int(10),
        value: Value::Decimal(wide),
    }));
    wait_until(WAIT, || button.label().is_some_and(|label| label.len() > 1_000)).expect("the wide sum");

    assert_eq!(height(), short, "a long figure made the popover taller");
}

#[gtk4::test]
fn the_readout_goes_with_its_grid() {
    let grid = amounts();
    let (revealer, button) = readout(&grid);
    grid.focus(0, 1);
    grid.grid.selection().select_all();
    wait_for_label(&button, "Sum 42, Average 21, Count 2");
    let (revealer_ref, button_ref) = (revealer.downgrade(), button.downgrade());
    drop((revealer, button));

    drop(grid);
    drain_main_context();

    assert!(revealer_ref.upgrade().is_none(), "the readout outlived its grid");
    assert!(button_ref.upgrade().is_none(), "the menu button outlived its grid");
}

#[gtk4::test]
fn closing_the_grid_stops_the_run_still_out() {
    let grid = amounts();
    readout(&grid);
    grid.focus(0, 1);
    grid.grid.selection().select_all();
    let running = || grid.grid.imp().summary.running.borrow().clone();
    wait_until(WAIT, || running().is_some()).expect("a run starts");
    let running = running().expect("the run");

    drop(grid);
    drain_main_context();

    assert!(running.load(std::sync::atomic::Ordering::Relaxed));
}

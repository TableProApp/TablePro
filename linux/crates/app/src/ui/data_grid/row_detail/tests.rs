use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use chrono::{NaiveDate, NaiveTime};
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gdk};
use tablepro_core::column::{TemporalZone, TimeRange};
use tablepro_core::edit::CellInput;
use tablepro_core::value::{JsonText, SqlTime, Temporal};
use tablepro_core::{ColumnInfo, Value};

use super::RowDetailPane;
use super::calendar::{day_of, day_start_offset, with_day};
use super::clock::{ClockField, time_of, with_time};
use super::fields::field_order;
use super::value_editor::value_content;
use crate::services::change_tracker::RowKey;
use crate::services::grid::{CellLock, GridColumn, GridRowId, grid_columns};
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{
    descendants, drain_main_context, finish_on_main, test_backend_records_properties, unlabelled_icon_buttons,
    wait_until,
};
use crate::ui::data_grid::GridRequest;
use crate::ui::data_grid::test_grid::{
    Grid, GridSpec, WAIT, focus_in_grid, key, named, page, persisted, text, two_text_columns, two_text_values,
};
use crate::ui::error_text::edit_parse_message;

fn pane_of(grid: &Grid) -> RowDetailPane {
    grid.grid.imp().detail_pane.get()
}

/// A grid of `rows` keyed by their first cell, with its pane open.
fn opened(columns: Vec<ColumnInfo>, rows: Vec<Vec<Value>>) -> (Grid, RowDetailPane) {
    let grid = Grid::open(columns, rows);
    grid.activate("show-details");
    let pane = pane_of(&grid);
    (grid, pane)
}

/// The window has the keyboard, so a focus move inside it reaches the
/// controllers. Other tests' windows take it too, so it is asked for
/// until it comes.
fn take_keyboard(grid: &Grid) {
    wait_until(WAIT, || {
        if !grid.window.is_active() {
            grid.window.present();
        }
        grid.window.is_active()
    })
    .expect("the window takes the keyboard");
}

/// Focus the grid's cell, then the value editor, as a click into the
/// pane does.
fn edit_field(grid: &Grid, pane: &RowDetailPane, position: u32, column: usize) {
    take_keyboard(grid);
    grid.focus(position, column);
    pane.focus_value();
    wait_until(WAIT, || crate::ui::a11y::holds_focus(&pane.imp().value_view.get()))
        .expect("the value editor takes the focus");
}

/// Change the value editor's text as typing does: the pane is not
/// filling it itself.
fn type_value(pane: &RowDetailPane, typed: &str) {
    pane.imp().value_buffer.set_text(typed);
}

/// Press `key` in the value editor, through the handler a real key press
/// reaches first.
fn press_in_value(pane: &RowDetailPane, key: gdk::Key, modifiers: gdk::ModifierType) -> bool {
    let controllers = pane.imp().value_view.observe_controllers();
    let keys = (0..controllers.n_items())
        .filter_map(|position| controllers.item(position).and_downcast::<gtk::EventControllerKey>())
        .find(|controller| controller.name().as_deref() == Some(super::value_editor::KEYS_NAME))
        .expect("the value editor's key handler");
    keys.emit_by_name::<bool>("key-pressed", &[&key, &0u32, &modifiers])
}

fn pending(grid: &Grid, id: i64, column: usize) -> Option<CellInput> {
    grid.tracker.cell_overlay(&key(id), column).pending
}

fn selected_field(pane: &RowDetailPane) -> Option<usize> {
    pane.imp().field.get()
}

fn title(pane: &RowDetailPane) -> String {
    pane.imp().title_label.label().to_string()
}

fn message(pane: &RowDetailPane) -> Option<String> {
    let label = pane.imp().message_label.get();
    label.is_visible().then(|| label.label().to_string())
}

/// The position of data column `column` in the fields list.
fn field_position(pane: &RowDetailPane, column: usize) -> u32 {
    let store = &pane.imp().fields.0;
    (0..store.n_items())
        .find(|position| {
            store
                .item(*position)
                .and_downcast::<gtk4::glib::BoxedAnyObject>()
                .is_some_and(|boxed| *boxed.borrow::<usize>() == column)
        })
        .expect("the column has a field")
}

fn fields(pane: &RowDetailPane) -> Vec<usize> {
    let store = &pane.imp().fields.0;
    (0..store.n_items())
        .filter_map(|position| store.item(position).and_downcast::<gtk4::glib::BoxedAnyObject>())
        .map(|boxed| *boxed.borrow::<usize>())
        .collect()
}

fn three_text_columns() -> Vec<ColumnInfo> {
    vec![
        named("id", "integer", true),
        named("name", "text", false),
        named("note", "text", false),
    ]
}

fn three_text_values() -> Vec<Vec<Value>> {
    vec![
        vec![Value::Int(1), Value::Text("A".into()), Value::Text("x".into())],
        vec![Value::Int(2), Value::Text("B".into()), Value::Text("y".into())],
    ]
}

fn a_date(year: i32, month: u32, day: u32) -> Value {
    Value::Date(Temporal::Finite(
        NaiveDate::from_ymd_opt(year, month, day).expect("a date"),
    ))
}

fn column_of(info: ColumnInfo) -> GridColumn {
    grid_columns(&[info.result_column()], std::slice::from_ref(&info), |_| true)[0].clone()
}

#[gtk4::test]
fn the_pane_follows_the_focused_cell() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());

    grid.focus(1, 1);
    assert_eq!(title(&pane), "Row 2");
    assert_eq!(selected_field(&pane), Some(1));
    assert_eq!(pane.typed_text(), "B");

    grid.focus(0, 0);
    assert_eq!(title(&pane), "Row 1");
    assert_eq!(selected_field(&pane), Some(0));
    assert_eq!(pane.typed_text(), "1");
    assert_eq!(pane.imp().stack.visible_child_name().as_deref(), Some("row"));
}

#[gtk4::test]
fn with_no_row_the_pane_says_so() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());
    grid.focus(0, 1);

    grid.grid.clear_rows();
    drain_main_context();

    assert_eq!(pane.imp().stack.visible_child_name().as_deref(), Some("empty"));
}

#[gtk4::test]
fn selecting_a_field_moves_the_grid_focus_column_without_taking_the_keyboard() {
    let (grid, pane) = opened(three_text_columns(), three_text_values());
    take_keyboard(&grid);
    grid.focus(1, 1);
    let list = pane.imp().field_list.get();
    list.grab_focus();

    pane.imp().selection.set_selected(field_position(&pane, 2));
    drain_main_context();

    assert_eq!(pane.typed_text(), "y");
    assert!(crate::ui::a11y::holds_focus(&list), "the list lost the keyboard");
    assert!(!focus_in_grid(&grid));
    grid.grid.column_view().grab_focus();
    let focused = grid.focused_cell().expect("the grid focuses a cell");
    assert_eq!((focused.position(), focused.column()), (Some(1), 2));
}

#[gtk4::test]
fn editing_a_value_commits_on_focus_out() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());
    edit_field(&grid, &pane, 0, 1);

    type_value(&pane, "A2");
    assert!(grid.grid.is_editing(), "typing opened no edit");
    pane.imp().field_list.grab_focus();
    drain_main_context();

    assert_eq!(pending(&grid, 1, 1), Some(text("A2")));
    assert!(!grid.grid.is_editing());
}

#[gtk4::test]
fn ctrl_return_commits_the_value_and_keeps_the_focus() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());
    edit_field(&grid, &pane, 1, 1);

    type_value(&pane, "B2");
    assert!(press_in_value(&pane, gdk::Key::Return, gdk::ModifierType::CONTROL_MASK));

    assert_eq!(pending(&grid, 2, 1), Some(text("B2")));
    assert!(!grid.grid.is_editing());
    assert!(crate::ui::a11y::holds_focus(&pane.imp().value_view.get()));
}

#[gtk4::test]
fn escape_restores_the_value() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());
    edit_field(&grid, &pane, 0, 1);

    type_value(&pane, "typed");
    assert!(press_in_value(&pane, gdk::Key::Escape, gdk::ModifierType::empty()));

    assert_eq!(pane.typed_text(), "A");
    assert_eq!(pending(&grid, 1, 1), None);
    assert!(!grid.grid.is_editing());
    assert!(
        !press_in_value(&pane, gdk::Key::Escape, gdk::ModifierType::empty()),
        "Escape with nothing typed was kept from the window"
    );
}

#[gtk4::test]
fn a_refused_value_stays_with_its_reason() {
    let document = Value::Json(JsonText::parse(r#"{"a":1}"#.to_owned()).expect("JSON"));
    let (grid, pane) = opened(
        vec![named("id", "integer", true), named("doc", "json", false)],
        vec![vec![Value::Int(1), document]],
    );
    edit_field(&grid, &pane, 0, 1);

    type_value(&pane, r#"{"a":"#);
    press_in_value(&pane, gdk::Key::Return, gdk::ModifierType::CONTROL_MASK);

    assert_eq!(pane.typed_text(), r#"{"a":"#, "the refused text was thrown away");
    assert!(pane.imp().value_view.has_css_class("error"));
    assert!(
        message(&pane).is_some_and(|reason| !reason.is_empty()),
        "no reason under the editor"
    );
    assert!(grid.grid.is_editing());
    assert_eq!(pending(&grid, 1, 1), None);

    type_value(&pane, r#"{"a":2}"#);
    press_in_value(&pane, gdk::Key::Return, gdk::ModifierType::CONTROL_MASK);

    assert!(matches!(pending(&grid, 1, 1), Some(CellInput::Value(Value::Json(_)))));
    assert!(!pane.imp().value_view.has_css_class("error"));
    assert_eq!(message(&pane), None);
}

#[gtk4::test]
fn a_read_only_connection_locks_every_field() {
    let grid = Grid::build(
        GridSpec {
            policy: Some(crate::services::grid::edit_policy(true, true, true)),
            ..GridSpec::table(two_text_columns())
        },
        page(1..3),
    );
    grid.activate("show-details");
    let pane = pane_of(&grid);

    grid.focus(0, 1);

    assert!(
        !pane.imp().value_view.is_editable(),
        "a read-only connection took typing"
    );
    assert_eq!(
        message(&pane),
        Some(CellLock::ReadOnlySession.explanation(edit_parse_message))
    );
}

#[gtk4::test]
fn a_locked_cell_is_read_only_with_its_sentence() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());

    grid.focus(0, 0);

    assert!(!pane.imp().value_view.is_editable());
    assert_eq!(
        message(&pane),
        Some(CellLock::KeyColumn.explanation(edit_parse_message))
    );
    pane.imp().value_menu_button.popup();
    assert!(!grid.is_enabled("set-null"), "the menu offered to change a locked cell");
    assert!(grid.is_enabled("copy"));
}

#[gtk4::test]
fn a_page_that_replaces_the_row_commits_the_open_edit_against_the_pinned_row() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());
    edit_field(&grid, &pane, 0, 1);
    type_value(&pane, "A2");

    grid.grid.replace_rows(page(10..12), 0);
    drain_main_context();

    assert_eq!(pending(&grid, 1, 1), Some(text("A2")), "the edit went to another row");
    assert_eq!(pending(&grid, 10, 1), None);
    assert!(!grid.grid.is_editing());
}

#[gtk4::test]
fn set_to_null_writes_null_into_the_field() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());
    take_keyboard(&grid);
    grid.focus(0, 1);
    pane.focus_value();
    pane.imp().value_menu_button.popup();
    assert!(grid.is_enabled("set-null"), "the menu does not act on the field");
    assert!(!grid.is_enabled("set-default"), "a saved row offered DEFAULT");

    grid.activate("set-null");

    assert_eq!(pending(&grid, 1, 1), Some(CellInput::Value(Value::Null)));
    assert_eq!(pane.typed_text(), "");
    assert!(pane.imp().placeholder_label.is_visible(), "NULL left no placeholder");
}

#[gtk4::test]
fn the_values_redraw_when_the_row_changes() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());
    grid.focus(0, 1);

    let delta = grid.tracker.apply(TrackerEdit::Cell {
        row_key: key(1),
        col: 1,
        original: Value::Text("A".into()),
        value: Value::Text("changed".into()),
    });
    grid.grid.apply_delta(&delta);
    drain_main_context();

    assert_eq!(pane.typed_text(), "changed");
    let shown: Vec<String> = descendants(&pane.imp().field_list.get())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Inscription>().ok())
        .filter_map(|inscription| inscription.text().map(|text| text.to_string()))
        .collect();
    assert!(shown.contains(&"changed".to_owned()), "the field list showed {shown:?}");
    assert_eq!(pane.imp().state_label.label(), "Modified");
}

#[gtk4::test]
fn copy_value_copies_the_field() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());
    grid.focus(1, 1);
    pane.imp().field_list.grab_focus();
    let heard: Rc<RefCell<Vec<String>>> = Rc::default();
    let log = heard.clone();
    grid.grid.connect_request(move |_, request| {
        if let GridRequest::Toast(text) = request {
            log.borrow_mut().push(text);
        }
    });

    pane.imp().value_menu_button.popup();
    grid.activate("copy");
    wait_until(WAIT, || !heard.borrow().is_empty()).expect("the copy lands");

    let clipboard = grid.grid.clipboard();
    let copied = finish_on_main(WAIT, async move { clipboard.read_text_future().await })
        .expect("the clipboard to answer")
        .expect("text on the clipboard");
    assert_eq!(copied.as_deref(), Some("B"));
}

#[gtk4::test]
fn the_fields_follow_the_grid_column_order() {
    let (grid, pane) = opened(three_text_columns(), three_text_values());
    grid.focus(0, 1);
    assert_eq!(fields(&pane), [0, 1, 2]);

    grid.grid.set_column_visible(0, false);
    drain_main_context();

    assert_eq!(fields(&pane), [1, 2, 0], "a hidden column's field did not go last");
}

#[gtk4::test]
fn every_control_in_the_pane_is_named() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());
    grid.focus(0, 1);
    if !test_backend_records_properties() {
        return;
    }

    assert_eq!(unlabelled_icon_buttons(&pane), Vec::<String>::new());
    for widget in [
        pane.imp().field_list.get().upcast::<gtk::Widget>(),
        pane.imp().value_view.get().upcast(),
        pane.imp().calendar.get().upcast(),
    ] {
        crate::test_support::assert_labelled(&widget).expect("the control is named");
    }
}

/// The middle of the first of the calendar's labels that `matches`,
/// once the popover has laid it out.
fn calendar_label(calendar: &gtk::Calendar, matches: impl Fn(&gtk::Widget) -> bool) -> (f64, f64) {
    let mut found = None;
    wait_until(WAIT, || {
        found = descendants(calendar)
            .into_iter()
            .find(|widget| widget.width() > 0 && matches(widget));
        found.is_some()
    })
    .expect("the label is drawn");
    let label = found.expect("a label");
    let middle = gtk::graphene::Point::new(label.width() as f32 / 2.0, label.height() as f32 / 2.0);
    let point = label
        .compute_point(calendar, &middle)
        .expect("the label is inside the calendar");
    (f64::from(point.x()), f64::from(point.y()))
}

fn selected_day(calendar: &gtk::Calendar) -> (f64, f64) {
    calendar_label(calendar, |label| {
        label.has_css_class("day-number") && label.state_flags().contains(gtk::StateFlags::SELECTED)
    })
}

/// What the calendar hears when a primary click at `(x, y)` ends.
fn release_on(calendar: &gtk::Calendar, (x, y): (f64, f64)) {
    let controllers = calendar.observe_controllers();
    for gesture in
        (0..controllers.n_items()).filter_map(|index| controllers.item(index).and_downcast::<gtk::GestureClick>())
    {
        gesture.emit_by_name::<()>("released", &[&1i32, &x, &y]);
    }
}

fn release_space(calendar: &gtk::Calendar) {
    use gtk4::glib::translate::IntoGlib;
    let controllers = calendar.observe_controllers();
    for keys in
        (0..controllers.n_items()).filter_map(|index| controllers.item(index).and_downcast::<gtk::EventControllerKey>())
    {
        keys.emit_by_name::<()>(
            "key-released",
            &[&gdk::Key::space.into_glib(), &0u32, &gdk::ModifierType::empty()],
        );
    }
}

/// Open the pane's calendar until it shows. Test processes share one X
/// display, where another test's window can close an autohide popover
/// before it maps.
fn open_calendar(pane: &RowDetailPane) -> gtk::Calendar {
    let calendar = pane.imp().calendar.get();
    for _ in 0..5 {
        pane.imp().calendar_button.popup();
        if wait_until(Duration::from_secs(2), || calendar.is_mapped() && calendar.width() > 0).is_ok() {
            return calendar;
        }
        pane.imp().calendar_button.popdown();
        drain_main_context();
    }
    panic!("the calendar never showed");
}

fn shown_day(calendar: &gtk::Calendar) -> Value {
    let (year, month, day) = calendar.date().ymd();
    a_date(
        year,
        u32::try_from(month).expect("a month"),
        u32::try_from(day).expect("a day"),
    )
}

fn date_grid(value: Value) -> (Grid, RowDetailPane) {
    let (grid, pane) = opened(
        vec![named("id", "integer", true), named("day", "date", false)],
        vec![vec![Value::Int(1), value]],
    );
    take_keyboard(&grid);
    grid.focus(0, 1);
    (grid, pane)
}

#[gtk4::test]
fn the_calendar_writes_a_date() {
    let (grid, pane) = date_grid(a_date(2024, 2, 29));
    assert!(pane.imp().calendar_button.is_visible(), "a date column has no calendar");
    pane.imp().calendar_button.popup();
    let calendar = pane.imp().calendar.get();
    assert_eq!(
        calendar.date().ymd(),
        (2024, 2, 29),
        "the calendar did not open on the value"
    );

    calendar.set_date(&gtk4::glib::DateTime::from_utc(2024, 3, 1, 0, 0, 0.0).expect("a day"));

    assert_eq!(pending(&grid, 1, 1), Some(CellInput::Value(a_date(2024, 3, 1))));
    assert_eq!(pane.typed_text(), "2024-03-01");
}

#[gtk4::test]
fn the_calendar_opens_toward_the_rows() {
    let (_grid, pane) = date_grid(a_date(2024, 2, 29));
    assert_eq!(
        pane.imp().calendar_button.direction(),
        gtk::ArrowType::Left,
        "a calendar dropped below the pane's button has no room on a short screen"
    );
}

#[gtk4::test]
fn clicking_today_on_a_null_date_writes_it() {
    let (grid, pane) = date_grid(Value::Null);
    let calendar = open_calendar(&pane);
    let today = shown_day(&calendar);

    release_on(
        &calendar,
        calendar_label(&calendar, |label| label.has_css_class("day-name")),
    );
    assert_eq!(pending(&grid, 1, 1), None, "a click on a weekday name picked a day");
    release_on(&calendar, selected_day(&calendar));

    assert_eq!(pending(&grid, 1, 1), Some(CellInput::Value(today)));
}

#[gtk4::test]
fn picking_the_same_day_in_another_month_writes_it() {
    let (grid, pane) = date_grid(a_date(2024, 3, 15));
    let calendar = open_calendar(&pane);

    // As the next-month arrow does, this moves the date without a
    // day-selected.
    calendar.set_date(&gtk4::glib::DateTime::from_utc(2024, 4, 15, 0, 0, 0.0).expect("a day"));
    assert_eq!(pending(&grid, 1, 1), None, "a month change picked a day");
    release_on(&calendar, selected_day(&calendar));

    assert_eq!(pending(&grid, 1, 1), Some(CellInput::Value(a_date(2024, 4, 15))));
}

#[gtk4::test]
fn space_on_the_selected_day_writes_it() {
    let (grid, pane) = date_grid(Value::Null);
    let calendar = open_calendar(&pane);
    let today = shown_day(&calendar);

    release_space(&calendar);

    assert_eq!(pending(&grid, 1, 1), Some(CellInput::Value(today)));
}

#[test]
fn a_picked_day_keeps_a_timestamp_time() {
    let day = NaiveDate::from_ymd_opt(2024, 3, 1).expect("a day");
    let plus_two = chrono::FixedOffset::east_opt(2 * 3600).expect("an offset");
    let naive = Some(&TemporalZone::Naive);
    let zoned = Some(&TemporalZone::Offset);

    assert_eq!(
        with_day("2024-02-29 10:30:00+02", day, zoned, plus_two),
        "2024-03-01 10:30:00+02"
    );
    assert_eq!(with_day("", day, naive, plus_two), "2024-03-01 00:00:00");
    assert_eq!(with_day("infinity", day, naive, plus_two), "2024-03-01 00:00:00");
    assert_eq!(with_day("2024-02-29", day, None, plus_two), "2024-03-01");
    let new_zoned = with_day("", day, zoned, plus_two);
    assert_eq!(new_zoned, "2024-03-01 00:00:00+02:00");
    assert!(
        tablepro_core::edit::parse_timestamp_with_offset(&new_zoned).is_ok(),
        "a NULL zoned timestamp took no day"
    );
    assert_eq!(day_of("2024-02-29 10:30"), NaiveDate::from_ymd_opt(2024, 2, 29));
    assert_eq!(day_of("12000-01-01"), None);
    assert_eq!(day_of("2024-02-2é"), None, "a cut inside a character");
}

/// A zone whose offset moves from `before` to `after` at `change`, in UTC.
#[derive(Clone)]
struct OneChange {
    before: chrono::FixedOffset,
    after: chrono::FixedOffset,
    change: chrono::NaiveDateTime,
}

impl chrono::TimeZone for OneChange {
    type Offset = chrono::FixedOffset;

    fn from_offset(offset: &chrono::FixedOffset) -> Self {
        Self {
            before: *offset,
            after: *offset,
            change: chrono::NaiveDateTime::MIN,
        }
    }

    fn offset_from_local_date(&self, _: &NaiveDate) -> chrono::MappedLocalTime<chrono::FixedOffset> {
        chrono::MappedLocalTime::None
    }

    fn offset_from_local_datetime(
        &self,
        local: &chrono::NaiveDateTime,
    ) -> chrono::MappedLocalTime<chrono::FixedOffset> {
        let fits = |offset: chrono::FixedOffset| (*local - offset < self.change) == (offset == self.before);
        match (fits(self.before), fits(self.after)) {
            (true, true) => chrono::MappedLocalTime::Ambiguous(self.before, self.after),
            (true, false) => chrono::MappedLocalTime::Single(self.before),
            (false, true) => chrono::MappedLocalTime::Single(self.after),
            (false, false) => chrono::MappedLocalTime::None,
        }
    }

    fn offset_from_utc_date(&self, utc: &NaiveDate) -> chrono::FixedOffset {
        self.offset_from_utc_datetime(&utc.and_time(chrono::NaiveTime::MIN))
    }

    fn offset_from_utc_datetime(&self, utc: &chrono::NaiveDateTime) -> chrono::FixedOffset {
        if *utc < self.change { self.before } else { self.after }
    }
}

#[test]
fn a_picked_day_starts_at_the_local_offset_of_its_midnight() {
    let hours = |hours: i32| chrono::FixedOffset::east_opt(hours * 3600).expect("an offset");
    let at = |date: &str| chrono::NaiveDateTime::parse_from_str(date, "%Y-%m-%d %H:%M").expect("a UTC time");
    let day = |date: &str| NaiveDate::parse_from_str(date, "%Y-%m-%d").expect("a day");
    // Sydney moves to +11 at 02:00 local on 2026-10-04, after its midnight.
    let sydney = OneChange {
        before: hours(10),
        after: hours(11),
        change: at("2026-10-03 16:00"),
    };
    // A clock that skips from 00:00 to 01:00: the day starts at the change.
    let skipped = OneChange {
        before: hours(-4),
        after: hours(-3),
        change: at("2026-09-06 04:00"),
    };

    assert_eq!(day_start_offset(&sydney, day("2026-10-04")), hours(10));
    assert_eq!(day_start_offset(&sydney, day("2026-10-05")), hours(11));
    assert_eq!(day_start_offset(&skipped, day("2026-09-06")), hours(-4));
}

#[test]
fn hidden_fields_go_after_the_ones_on_screen() {
    assert_eq!(field_order(&[2, 0], 4), [2, 0, 1, 3]);
    assert_eq!(field_order(&[], 2), [0, 1]);
    assert_eq!(field_order(&[5, 1], 2), [1, 0], "a column past the set");
}

#[test]
fn what_the_value_editor_shows_for_a_cell() {
    let note = column_of(named("note", "text", false));
    let count = column_of(named("count", "integer", false));
    let doc = column_of(named("doc", "json", false));
    let day = column_of(named("day", "date", false));
    let saved = GridRowId::Persisted(RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"));
    let value = |value: Value| CellInput::Value(value);

    let null = value_content(&note, &saved, None, &value(Value::Null));
    assert_eq!(
        (null.text.as_str(), null.open_placeholder.as_deref()),
        ("", Some("NULL"))
    );
    let empty = value_content(&note, &saved, None, &value(Value::Text(String::new())));
    assert_eq!(empty.open_placeholder, None, "an empty string read as NULL");
    let number = value_content(&count, &saved, None, &value(Value::Int(5)));
    assert_eq!(
        (number.text.as_str(), number.emptied_placeholder.as_deref()),
        ("5", Some("NULL"))
    );
    let nul = value_content(&note, &saved, None, &value(Value::Text("a\0b".into())));
    assert!(
        nul.message.is_some() && !nul.text.contains('\0'),
        "a NUL reached the buffer"
    );
    let locked = value_content(&day, &saved, Some(CellLock::PendingDelete), &value(a_date(2024, 1, 1)));
    assert_eq!(
        locked.message,
        Some(CellLock::PendingDelete.explanation(edit_parse_message))
    );
    assert!(!locked.calendar, "a locked cell offered a calendar");
    assert!(value_content(&day, &saved, None, &value(a_date(2024, 1, 1))).calendar);
    assert_eq!(
        value_content(&doc, &saved, None, &value(Value::Null)).language,
        Some("json")
    );
    let draft = value_content(&count, &GridRowId::Draft(1), None, &CellInput::Default);
    assert_eq!(draft.open_placeholder.as_deref(), Some("DEFAULT"));
}

#[gtk4::test]
fn opening_the_calendar_and_closing_it_records_no_edit() {
    let (grid, pane) = date_grid(a_date(2024, 2, 29));

    open_calendar(&pane);
    pane.imp().calendar_button.popdown();
    drain_main_context();

    assert_eq!(
        grid.tracker.pending_count(),
        0,
        "opening the calendar recorded its own day"
    );
}

#[gtk4::test]
fn a_date_past_the_calendar_shows_as_text() {
    let (_grid, pane) = date_grid(a_date(12_000, 1, 1));

    assert!(pane.typed_text().contains("12000"), "{}", pane.typed_text());
    assert_eq!(
        day_of(&pane.typed_text()),
        None,
        "the calendar took a year it cannot show"
    );
}

#[gtk4::test]
fn f005_unchanged_40kb_multiline_text_records_no_edit() {
    let long = "lorem ipsum\n".repeat(3_500);
    let (grid, pane) = opened(
        vec![named("id", "integer", true), named("note", "text", true)],
        vec![vec![Value::Int(1), Value::Text(long.clone())]],
    );
    edit_field(&grid, &pane, 0, 1);

    assert_eq!(
        pane.typed_text(),
        long,
        "the value editor opened on less than the whole text"
    );
    assert!(press_in_value(&pane, gdk::Key::Return, gdk::ModifierType::CONTROL_MASK));

    assert_eq!(
        grid.tracker.pending_count(),
        0,
        "committing the text as it was recorded an edit"
    );
}

#[gtk4::test]
fn a_page_that_takes_the_row_closes_its_calendar_and_writes_nothing() {
    let (grid, pane) = opened(
        vec![named("id", "integer", true), named("day", "date", false)],
        vec![
            vec![Value::Int(1), a_date(2024, 2, 29)],
            vec![Value::Int(2), a_date(2024, 3, 1)],
        ],
    );
    take_keyboard(&grid);
    grid.focus(0, 1);
    let calendar = open_calendar(&pane);

    grid.grid
        .replace_rows(persisted(&[vec![Value::Int(2), a_date(2024, 3, 1)]]), 0);
    drain_main_context();
    calendar.set_date(&gtk::glib::DateTime::from_utc(2024, 3, 9, 0, 0, 0.0).expect("a day"));
    drain_main_context();

    assert_eq!(
        grid.tracker.pending_count(),
        0,
        "the calendar wrote into the row that took the slot"
    );
    assert!(!pane.imp().calendar_popover.is_visible());
}

#[gtk4::test]
fn row_details_from_a_cell_menu_shows_that_cell() {
    let grid = Grid::open(two_text_columns(), two_text_values());
    take_keyboard(&grid);
    grid.focus(0, 0);
    let pane = pane_of(&grid);

    assert!(grid.grid.open_cell_menu(&grid.cell_at(1, 1), None));
    grid.activate("show-details");

    assert_eq!(title(&pane), "Row 2");
    assert_eq!(selected_field(&pane), Some(1));
    assert_eq!(pane.typed_text(), "B");
}

/// The gutter's menu has no cell, so the focus keeps its column.
#[gtk4::test]
fn row_details_from_a_row_menu_shows_that_row() {
    let grid = Grid::open(two_text_columns(), two_text_values());
    take_keyboard(&grid);
    grid.focus(0, 1);
    let pane = pane_of(&grid);
    let row = grid.grid.store().row(1).expect("the second row");

    assert!(grid.grid.open_row_menu(&row, 1, gdk::Rectangle::new(0, 0, 1, 1)));
    grid.activate("show-details");

    assert_eq!(title(&pane), "Row 2");
    assert_eq!(selected_field(&pane), Some(1));
    assert_eq!(pane.typed_text(), "B");
}

/// A grid that narrows past its breakpoint and widens again leaves Row
/// Details as the user left it.
#[gtk4::test]
fn crossing_the_breakpoint_neither_opens_nor_closes_row_details() {
    let grid = Grid::open(two_text_columns(), two_text_values());
    let split_view = grid.grid.imp().split_view.get();
    for collapsed in [true, false] {
        split_view.set_collapsed(collapsed);
        assert!(!split_view.shows_sidebar(), "Row Details opened unasked");
    }

    grid.activate("show-details");
    for collapsed in [true, false] {
        split_view.set_collapsed(collapsed);
        assert!(split_view.shows_sidebar(), "Row Details closed unasked");
    }
}

/// Row Details scrolls in a short grid rather than making the grid need
/// more height than its rows, which a host at its smallest cuts off.
#[gtk4::test]
fn row_details_never_make_the_grid_taller() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());
    take_keyboard(&grid);
    grid.focus(0, 1);
    pane.imp().message_label.set_label("a long reason");
    pane.imp().message_label.set_visible(true);
    let split_view = grid.grid.imp().split_view.get();
    let high = |widget: &gtk::Widget| widget.measure(gtk::Orientation::Vertical, -1).0;

    let (rows, details) = (high(&split_view.content().expect("the rows")), high(pane.upcast_ref()));

    assert!(details <= rows, "Row Details need {details} px high, the rows {rows}");
}

/// Alt+Return closes Row Details from inside the pane, where the keyboard
/// is once a field was picked.
#[gtk4::test]
fn alt_return_closes_row_details_from_the_pane() {
    let (grid, pane) = opened(two_text_columns(), two_text_values());
    crate::test_support::KeyInjector::focus_only(&grid.window);
    take_keyboard(&grid);
    grid.focus(1, 1);
    pane.imp().field_list.grab_focus();
    let keys = crate::test_support::KeyInjector::connect().expect("an X11 display");

    keys.press(gdk::Key::Return, gdk::ModifierType::ALT_MASK)
        .expect("the key press");

    wait_until(WAIT, || {
        grid.grid
            .actions()
            .action_state("show-details")
            .and_then(|state| state.get::<bool>())
            == Some(false)
    })
    .expect("Alt+Return to close Row Details");
}

/// Open the pane's clock until it shows, as `open_calendar` does.
fn open_clock(pane: &RowDetailPane) {
    for _ in 0..5 {
        pane.imp().clock_button.popup();
        if wait_until(Duration::from_secs(2), || pane.imp().hour.is_mapped()).is_ok() {
            return;
        }
        pane.imp().clock_button.popdown();
        drain_main_context();
    }
    panic!("the clock never showed");
}

fn set_clock(pane: &RowDetailPane, (hour, minute, second): (u32, u32, u32)) {
    pane.imp().hour.set_value(f64::from(hour));
    pane.imp().minute.set_value(f64::from(minute));
    pane.imp().second.set_value(f64::from(second));
}

fn clock_text(pane: &RowDetailPane) -> [String; 3] {
    let imp = pane.imp();
    [&imp.hour, &imp.minute, &imp.second].map(|spin| spin.text().to_string())
}

fn a_time(hour: u32, minute: u32, second: u32) -> NaiveTime {
    NaiveTime::from_hms_opt(hour, minute, second).expect("a time")
}

fn a_timestamp(day: (i32, u32, u32), time: NaiveTime) -> Value {
    let (year, month, date) = day;
    Value::Timestamp(Temporal::Finite(
        NaiveDate::from_ymd_opt(year, month, date)
            .expect("a day")
            .and_time(time),
    ))
}

const NAIVE: ClockField = ClockField {
    dated: true,
    with_offset: false,
};
const ZONED: ClockField = ClockField {
    dated: true,
    with_offset: true,
};
const TIME: ClockField = ClockField {
    dated: false,
    with_offset: false,
};
const TIMETZ: ClockField = ClockField {
    dated: false,
    with_offset: true,
};

fn set_at_nine(text: &str, field: ClockField) -> String {
    let today = NaiveDate::from_ymd_opt(2026, 10, 29).expect("a day");
    let plus_two = chrono::FixedOffset::east_opt(2 * 3600).expect("an offset");
    with_time(text, a_time(9, 5, 30), field, today, &plus_two)
}

#[test]
fn the_clock_sets_only_the_time_a_value_shows() {
    assert_eq!(
        set_at_nine("2024-02-29 23:59:58.125000", NAIVE),
        "2024-02-29 09:05:30.125000"
    );
    assert_eq!(set_at_nine("2024-02-29T23:59:58", NAIVE), "2024-02-29T09:05:30");
    assert_eq!(set_at_nine("2024-02-29 23:59", NAIVE), "2024-02-29 09:05:30");
    assert_eq!(
        set_at_nine("2024-02-29 23:59:58+05:30", ZONED),
        "2024-02-29 09:05:30+05:30"
    );
    assert_eq!(set_at_nine("0044-03-15 12:00:00 BC", NAIVE), "0044-03-15 09:05:30 BC");
    assert_eq!(
        set_at_nine("12000-01-01 10:00:00", NAIVE),
        "12000-01-01 09:05:30",
        "a year past 9999 lost its day"
    );
    assert_eq!(set_at_nine("13:45:07.5+01", TIMETZ), "09:05:30.5+01");
    assert_eq!(
        set_at_nine("2024-03-10T02:30:00.125-08:00", TIME),
        "2024-03-10T09:05:30.125-08:00",
        "SQLite keeps a timestamp in a TIME column"
    );
    assert_eq!(set_at_nine("10:00", NAIVE), "09:05:30", "a time in a DATETIME column");
    assert_eq!(set_at_nine("  2024-01-01 10:00:00", NAIVE), "  2024-01-01 09:05:30");
    assert_eq!(
        set_at_nine("2024-01-01  12:34:56.789+02:00", ZONED),
        "2024-01-01  09:05:30.789+02:00"
    );
    assert_eq!(set_at_nine("-0001-01-01 12:34:56", NAIVE), "-0001-01-01 09:05:30");
    assert_eq!(
        set_at_nine("2024-02-29T 12:34:56.125+05:30", ZONED),
        "2024-02-29T 09:05:30.125+05:30"
    );
    assert_eq!(set_at_nine("2024-2-9 9:5:3.5", NAIVE), "2024-2-9 09:05:30.5");
    assert_eq!(set_at_nine("2024- 2-29 12: 34", NAIVE), "2024- 2-29 09:05:30");
    assert_eq!(set_at_nine("24:00:00+01", TIMETZ), "09:05:30+01");
}

#[test]
fn the_clock_starts_a_value_that_has_no_time() {
    assert_eq!(set_at_nine("", NAIVE), "2026-10-29 09:05:30");
    assert_eq!(set_at_nine("infinity", NAIVE), "2026-10-29 09:05:30");
    assert_eq!(set_at_nine("2024-02-29", NAIVE), "2024-02-29 09:05:30");
    assert_eq!(set_at_nine(" 2024-02-29", NAIVE), " 2024-02-29 09:05:30");
    assert_eq!(set_at_nine("4713-01-01 BC", NAIVE), "4713-01-01 09:05:30 BC");
    assert_eq!(set_at_nine("4713-01-01 BC", ZONED), "4713-01-01 09:05:30+02:00 BC");
    assert_eq!(set_at_nine("12000-01-01", NAIVE), "12000-01-01 09:05:30");
    assert_eq!(
        set_at_nine("2024-02-29", TIME),
        "2024-02-29 09:05:30",
        "SQLite keeps a date in a TIME column"
    );
    assert_eq!(set_at_nine("", TIME), "09:05:30");
    let zoned = set_at_nine("", ZONED);
    assert_eq!(zoned, "2026-10-29 09:05:30+02:00");
    assert!(tablepro_core::edit::parse_timestamp_with_offset(&zoned).is_ok());
    let timetz = set_at_nine("", TIMETZ);
    assert_eq!(timetz, "09:05:30+02:00");
    assert!(tablepro_core::edit::parse_time_with_offset(&timetz).is_ok());
}

#[test]
fn a_new_zoned_time_takes_the_offset_of_its_own_moment() {
    let hours = |hours: i32| chrono::FixedOffset::east_opt(hours * 3600).expect("an offset");
    // Sydney moves to +11 at 02:00 local on 2026-10-04.
    let sydney = OneChange {
        before: hours(10),
        after: hours(11),
        change: chrono::NaiveDateTime::parse_from_str("2026-10-03 16:00", "%Y-%m-%d %H:%M").expect("a UTC time"),
    };
    let day = NaiveDate::from_ymd_opt(2026, 10, 4).expect("a day");
    let set = |text: &str, time: NaiveTime, field: ClockField| with_time(text, time, field, day, &sydney);

    assert_eq!(set("", a_time(9, 5, 0), ZONED), "2026-10-04 09:05:00+11:00");
    assert_eq!(set("", a_time(1, 30, 0), ZONED), "2026-10-04 01:30:00+10:00");
    assert_eq!(
        set("", a_time(2, 30, 0), ZONED),
        "2026-10-04 02:30:00+10:00",
        "a time the change skips"
    );
    assert_eq!(set("", a_time(9, 5, 0), TIMETZ), "09:05:00+11:00");
    let earlier = NaiveDate::from_ymd_opt(2026, 7, 1).expect("a day");
    assert_eq!(
        with_time("2026-10-04", a_time(9, 5, 0), ZONED, earlier, &sydney),
        "2026-10-04 09:05:00+11:00",
        "the offset was today's, not the value's day"
    );
}

#[test]
fn the_clock_reads_the_time_a_value_shows() {
    assert_eq!(time_of("2024-02-29 23:59:58.125"), Some(a_time(23, 59, 58)));
    assert_eq!(time_of("12000-01-01 10:00:00"), Some(a_time(10, 0, 0)));
    assert_eq!(time_of("2024-02-29 10:30"), Some(a_time(10, 30, 0)));
    assert_eq!(time_of("13:45:07.5+01"), Some(a_time(13, 45, 7)));
    assert_eq!(time_of(" 2024-02-29T10:00:00Z"), Some(a_time(10, 0, 0)));
    assert_eq!(time_of("2024-2-9 9:5:3"), Some(a_time(9, 5, 3)));
    assert_eq!(time_of("2024- 2-29 12: 34"), Some(a_time(12, 34, 0)));
    assert_eq!(time_of("24:00:00"), None);
    assert_eq!(time_of("2024-02-29"), None);
    assert_eq!(time_of("2024-02-2é 10:00:00"), None, "a cut inside a character");
    assert_eq!(time_of("not a time"), None);
}

#[test]
fn a_clock_is_offered_where_a_time_of_day_can_be_typed() {
    let saved = GridRowId::Persisted(RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"));
    let clock = |data_type: &str, lock: Option<CellLock>| {
        value_content(
            &column_of(named("t", data_type, false)),
            &saved,
            lock,
            &CellInput::Value(Value::Null),
        )
        .clock
    };

    assert!(clock("timestamp", None));
    assert!(clock("timestamptz", None));
    assert!(clock("time", None));
    assert!(!clock("date", None));
    assert!(!clock("interval", None));
    assert!(
        !clock("timestamp", Some(CellLock::PendingDelete)),
        "a locked cell offered a clock"
    );
    let time = |range| tablepro_core::column::ColumnKind::Time {
        fractional_digits: None,
        with_offset: false,
        range,
    };
    assert_eq!(ClockField::of(&time(TimeRange::TimeOfDay)), Some(TIME));
    assert_eq!(
        ClockField::of(&time(TimeRange::Duration)),
        None,
        "MySQL TIME runs past a day"
    );
    assert_eq!(ClockField::of(&time(TimeRange::LongDuration)), None);
}

#[gtk4::test]
fn the_clock_opens_on_the_value_and_sets_its_time() {
    let (grid, pane) = opened(
        vec![named("id", "integer", true), named("at", "timestamp", false)],
        vec![vec![Value::Int(1), a_timestamp((2024, 2, 29), a_time(23, 59, 8))]],
    );
    take_keyboard(&grid);
    grid.focus(0, 1);
    assert!(pane.imp().clock_button.is_visible(), "a timestamp has no clock");

    open_clock(&pane);
    assert_eq!(
        clock_text(&pane),
        ["23", "59", "08"],
        "the clock did not open on the value"
    );
    set_clock(&pane, (9, 5, 30));
    assert_eq!(clock_text(&pane), ["09", "05", "30"], "a clock shows two digits");
    pane.imp().clock_set.emit_clicked();

    assert_eq!(
        pending(&grid, 1, 1),
        Some(CellInput::Value(a_timestamp((2024, 2, 29), a_time(9, 5, 30))))
    );
    assert!(!pane.imp().clock_popover.is_visible());
}

#[gtk4::test]
fn enter_in_a_clock_field_sets_the_time() {
    let (grid, pane) = opened(
        vec![named("id", "integer", true), named("at", "time", false)],
        vec![vec![Value::Int(1), Value::Null]],
    );
    take_keyboard(&grid);
    grid.focus(0, 1);
    open_clock(&pane);
    set_clock(&pane, (9, 5, 30));

    let text = descendants(&pane.imp().second.get())
        .into_iter()
        .find_map(|widget| widget.downcast::<gtk::Text>().ok())
        .expect("the field's text");
    text.emit_by_name::<()>("activate", &[]);
    // A button activated from the keyboard clicks once its pressed look has shown.
    wait_until(WAIT, || pending(&grid, 1, 1).is_some()).expect("Enter to set the time");

    let set = SqlTime::from_time_of_day(a_time(9, 5, 30));
    assert_eq!(pending(&grid, 1, 1), Some(CellInput::Value(Value::Time(set))));
}

#[gtk4::test]
fn a_page_that_takes_the_row_closes_its_clock_and_writes_nothing() {
    let (grid, pane) = opened(
        vec![named("id", "integer", true), named("at", "time", false)],
        vec![vec![Value::Int(1), Value::Null], vec![Value::Int(2), Value::Null]],
    );
    take_keyboard(&grid);
    grid.focus(0, 1);
    open_clock(&pane);

    grid.grid
        .replace_rows(persisted(&[vec![Value::Int(2), Value::Null]]), 0);
    drain_main_context();
    pane.imp().clock_set.emit_clicked();
    drain_main_context();

    assert_eq!(
        grid.tracker.pending_count(),
        0,
        "the clock wrote into the row that took the slot"
    );
    assert!(!pane.imp().clock_popover.is_visible());
}

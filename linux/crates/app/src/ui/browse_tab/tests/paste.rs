use std::cell::RefCell;
use std::rc::Rc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::RowIdentity;
use tablepro_core::{ColumnInfo, QueryResult, Value};
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};

use super::{
    Harness, Shown, WAIT, column, column_view, copied_by, draft_rows, grid_cell_of, key, menu_gesture, named_col, rows,
    serving_table, toasts,
};
use crate::test_support::{drain_main_context, wait_until};
use crate::ui::browse_tab::paste_at::PasteAt;
use crate::ui::browse_tab::paste_handlers::PASTE_CONFIRM_ROWS;
use crate::ui::browse_tab::{BrowseTab, ClipboardInput, EditInput, PagingInput};
use crate::ui::clipboard::{CopyKind, CopyRequest};
use crate::ui::grid::GridCell;
use crate::ui::grid::RowSnapshot;

/// An `id` key, a name and an age, with Ada and Grace saved.
fn people() -> Vec<ColumnInfo> {
    let mut id = named_col("id", "integer", false);
    id.primary_key = true;
    vec![id, named_col("name", "text", true), named_col("age", "integer", true)]
}

fn people_table() -> Harness {
    people_holding(vec![
        vec![Value::Int(0), Value::Text("Ada".into()), Value::Int(36)],
        vec![Value::Int(1), Value::Text("Grace".into()), Value::Int(85)],
    ])
}

fn people_holding(saved: Vec<Vec<Value>>) -> Harness {
    let columns = people();
    let mut script = ConnectionScript::default();
    script.fetch_columns.always(FakeReply::ok(columns.clone()));
    script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }));
    script.count_rows.always(FakeReply::ok(2));
    script.probe.always(FakeReply::ok(()));
    script.fetch_outbound_foreign_keys.always(FakeReply::ok(Vec::new()));
    script.fetch_inbound_foreign_keys.always(FakeReply::ok(Vec::new()));
    let count = saved.len();
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        saved,
    )));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.saved_rows().len() == count).expect("the first page");
    harness
}

/// Put `text` on the tab's clipboard and paste it at `at`. The read
/// comes back later, so each test waits for what it should do.
fn paste(harness: &Harness, text: &str, at: Option<PasteAt>) {
    harness.tab().clipboard().set_text(text);
    harness.tab().send(ClipboardInput::Paste(at));
}

fn alerts(tab: &BrowseTab) -> Rc<RefCell<Vec<String>>> {
    let alerts = Rc::new(RefCell::new(Vec::new()));
    let sink = alerts.clone();
    tab.connect_alert(move |_, title, body| sink.borrow_mut().push(format!("{title}: {body}")));
    alerts
}

fn confirming_paste(tab: &BrowseTab) -> Option<libadwaita::AlertDialog> {
    tab.imp()
        .model
        .borrow()
        .as_ref()
        .and_then(|model| model.confirming_paste.as_ref().map(|pending| pending.dialog.clone()))
}

fn draft_cells(harness: &Harness, position: u32) -> Vec<CellInput> {
    let draft_id = harness.grid_row(position).draft_id().expect("a new row");
    harness.tracker.draft_inputs(draft_id).expect("the draft's cells")
}

fn int(value: i64) -> CellInput {
    CellInput::Value(Value::Int(value))
}

fn name(value: &str) -> CellInput {
    CellInput::Value(Value::Text(value.to_owned()))
}

fn null() -> CellInput {
    CellInput::Value(Value::Null)
}

#[gtk4::test]
fn pasted_rows_are_new_rows_in_the_order_they_were_copied() {
    let harness = people_table();
    let toasts = toasts(harness.tab());

    paste(&harness, "7\tLinus\t54\n8\tKen\t\n", None);

    wait_until(WAIT, || draft_rows(&harness.store()) == 2).expect("the rows were pasted");
    assert_eq!(draft_cells(&harness, 0), vec![int(7), name("Linus"), int(54)]);
    assert_eq!(draft_cells(&harness, 1), vec![int(8), name("Ken"), null()]);
    assert_eq!(
        harness.grid_row(2).key(),
        Some(&key(0)),
        "the saved rows moved above the new ones"
    );
    assert_eq!(toasts.borrow().as_slice(), ["Pasted 2 rows"]);
}

/// The copy offers the cells beside its text, which says the same of a
/// NULL and the text `NULL`, and quotes what it then cannot unquote.
#[gtk4::test]
fn rows_copied_from_the_grid_paste_back_exactly() {
    let harness = people_holding(vec![
        vec![Value::Int(0), Value::Text("NULL".into()), Value::Null],
        vec![Value::Int(1), Value::Text("\"two\nlines\"".into()), Value::Int(3)],
    ]);
    harness.selection().select_all();
    copied_by(harness.tab(), || {
        harness.tab().send(ClipboardInput::CopySelectedRowsAsTsv)
    });

    harness.tab().send(ClipboardInput::Paste(None));

    wait_until(WAIT, || draft_rows(&harness.store()) == 2).expect("the rows were pasted");
    assert_eq!(draft_cells(&harness, 0), vec![int(0), name("NULL"), null()]);
    assert_eq!(draft_cells(&harness, 1), vec![int(1), name("\"two\nlines\""), int(3)]);
}

#[gtk4::test]
fn a_copied_cell_pastes_into_another_cell_as_it_was() {
    let harness = people_holding(vec![
        vec![Value::Int(0), Value::Text("\"two\nlines\"".into()), Value::Null],
        vec![Value::Int(1), Value::Text("Grace".into()), Value::Int(85)],
    ]);
    let request = CopyRequest::Rows {
        columns: people().iter().map(ColumnInfo::result_column).collect(),
        rows: vec![RowSnapshot::new(
            harness.grid_row(0).cells().expect("the row's cells"),
            Vec::new(),
        )],
        kind: CopyKind::Value(1),
    };
    copied_by(harness.tab(), || harness.tab().send(ClipboardInput::GridCopy(request)));

    harness.tab().send(ClipboardInput::Paste(Some(PasteAt {
        row: harness.grid_row(1),
        column: 1,
    })));

    wait_until(WAIT, || harness.tracker.pending_count() == 1).expect("the cell was edited");
    assert_eq!(
        harness.tracker.pending_values(&key(1), 3),
        vec![(1, Value::Text("\"two\nlines\"".into()))]
    );
}

#[gtk4::test]
fn one_undo_takes_back_the_whole_paste() {
    let harness = people_table();
    paste(&harness, "7\tLinus\t54\n8\tKen\t1\n9\tDennis\t70\n", None);
    wait_until(WAIT, || draft_rows(&harness.store()) == 3).expect("the rows were pasted");

    harness.tab().send(EditInput::Undo);

    assert_eq!(draft_rows(&harness.store()), 0);
    assert_eq!(harness.tracker.pending_count(), 0);
    harness.tab().send(EditInput::Redo);
    assert_eq!(draft_rows(&harness.store()), 3);
    assert_eq!(
        draft_cells(&harness, 0)[1],
        name("Linus"),
        "the redone rows came back in another order"
    );
}

#[gtk4::test]
fn rows_fill_the_columns_from_the_one_the_paste_starts_at() {
    let harness = people_table();
    let toasts = toasts(harness.tab());
    let at = PasteAt {
        row: harness.grid_row(0),
        column: 1,
    };

    paste(&harness, "Linus\t54\textra\n", Some(at));

    wait_until(WAIT, || draft_rows(&harness.store()) == 1).expect("the row was pasted");
    assert_eq!(draft_cells(&harness, 0), vec![null(), name("Linus"), int(54)]);
    assert_eq!(
        toasts.borrow().as_slice(),
        ["Pasted 1 row", "Left out 1 value no column could take"]
    );
}

#[gtk4::test]
fn values_fill_the_columns_in_the_order_the_grid_shows_them() {
    let harness = people_table();
    let view = column_view(harness.tab());
    let shown = crate::ui::grid::data_columns(&view);
    let (name_column, age_column) = (shown[1].clone(), shown[2].clone());
    let columns = view.columns();
    let name_at = (0..columns.n_items())
        .find(|position| columns.item(*position).as_ref() == Some(name_column.upcast_ref::<glib::Object>()))
        .expect("the name column");
    view.insert_column(name_at, &age_column);

    paste(
        &harness,
        "7\t54\tLinus\n",
        Some(PasteAt {
            row: harness.grid_row(0),
            column: 0,
        }),
    );

    wait_until(WAIT, || draft_rows(&harness.store()) == 1).expect("the row was pasted");
    assert_eq!(draft_cells(&harness, 0), vec![int(7), name("Linus"), int(54)]);
}

#[gtk4::test]
fn a_header_line_maps_the_values_by_name() {
    let harness = people_table();

    paste(&harness, "age\tname\tid\n54\tLinus\t7\n", None);

    wait_until(WAIT, || draft_rows(&harness.store()) == 1).expect("the row was pasted");
    assert_eq!(draft_cells(&harness, 0), vec![int(7), name("Linus"), int(54)]);
}

#[gtk4::test]
fn one_value_goes_into_the_cell_the_paste_starts_at() {
    let harness = people_table();
    let ada = harness.grid_row(0);

    paste(
        &harness,
        "Lovelace",
        Some(PasteAt {
            row: ada.clone(),
            column: 1,
        }),
    );

    wait_until(WAIT, || harness.tracker.pending_count() == 1).expect("the cell was edited");
    assert_eq!(draft_rows(&harness.store()), 0, "one value made a new row");
    assert_eq!(
        harness.tracker.pending_values(&key(0), 3),
        vec![(1, Value::Text("Lovelace".into()))]
    );
}

#[gtk4::test]
fn one_value_a_cell_cannot_take_says_why() {
    let harness = people_table();
    let toasts = toasts(harness.tab());
    let ada = harness.grid_row(0);

    paste(
        &harness,
        "5",
        Some(PasteAt {
            row: ada.clone(),
            column: 0,
        }),
    );
    wait_until(WAIT, || toasts.borrow().len() == 1).expect("the key said why");
    paste(&harness, "old", Some(PasteAt { row: ada, column: 2 }));
    wait_until(WAIT, || toasts.borrow().len() == 2).expect("the number said why");

    assert_eq!(harness.tracker.pending_count(), 0);
    assert_eq!(
        toasts.borrow().as_slice(),
        ["A saved row's key can't be changed here", "Enter a whole number"]
    );
}

#[gtk4::test]
fn ctrl_v_pastes_at_the_focused_cell() {
    let harness = people_table();
    let shown = Shown::new(harness.tab());
    let view = column_view(harness.tab());
    let age = crate::ui::grid::data_columns(&view)
        .into_iter()
        .nth(2)
        .expect("the age column");
    view.scroll_to(1, Some(&age), gtk4::ListScrollFlags::FOCUS, None);
    view.grab_focus();
    wait_until(WAIT, || {
        gtk4::prelude::GtkWindowExt::focus(&shown.0)
            .and_then(|focus| GridCell::from_focus(&focus))
            .is_some_and(|cell| cell.position() == Some(1) && cell.column() == 2)
    })
    .expect("Grace's age takes the focus");
    harness.tab().clipboard().set_text("90");

    harness
        .tab()
        .activate_action("browse.paste-rows", None)
        .expect("the tab's Paste");

    wait_until(WAIT, || harness.tracker.pending_count() == 1).expect("the focused cell was edited");
    assert_eq!(harness.tracker.pending_values(&key(1), 3), vec![(2, Value::Int(90))]);
}

#[gtk4::test]
fn the_cell_menu_pastes_rows_from_its_column() {
    let harness = people_table();
    let _shown = Shown::new(harness.tab());
    let cell = grid_cell_of(harness.tab(), 1, 1);
    harness.tab().clipboard().set_text("Linus\t54\nKen\t81\n");

    menu_gesture(&cell).emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);
    column_view(harness.tab())
        .activate_action("cell.paste", None)
        .expect("the menu's Paste");

    wait_until(WAIT, || draft_rows(&harness.store()) == 2).expect("the rows were pasted");
    assert_eq!(draft_cells(&harness, 1), vec![null(), name("Ken"), int(81)]);
    wait_until(WAIT, || {
        crate::ui::grid::selected_positions(&harness.selection()) == vec![0, 1]
    })
    .expect("the pasted rows are the selection");
}

#[gtk4::test]
fn a_value_the_column_refuses_stops_the_paste_and_names_it() {
    let harness = people_table();
    let alerts = alerts(harness.tab());

    paste(&harness, "7\tLinus\t54\n8\tKen\tforty\n", None);

    wait_until(WAIT, || !alerts.borrow().is_empty()).expect("the paste said why it stopped");
    assert_eq!(draft_rows(&harness.store()), 0, "part of the paste landed");
    assert_eq!(
        alerts.borrow().as_slice(),
        ["Couldn't Paste: Line 2, column age: Enter a whole number (the value was “forty”)"]
    );
}

#[gtk4::test]
fn an_empty_clipboard_says_there_is_nothing_to_paste() {
    let harness = people_table();
    let toasts = toasts(harness.tab());

    paste(&harness, "\n\n", None);

    wait_until(WAIT, || !toasts.borrow().is_empty()).expect("the paste said why it stopped");
    assert_eq!(toasts.borrow().as_slice(), ["The clipboard has no rows to paste."]);
}

#[gtk4::test]
fn a_read_only_connection_refuses_to_paste() {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada"])));
    let harness = Harness::open_read_only(script);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");
    let toasts = toasts(harness.tab());

    paste(&harness, "7\tLinus\n", None);

    assert_eq!(harness.tracker.pending_count(), 0);
    assert_eq!(toasts.borrow().as_slice(), ["This connection is read-only."]);
}

/// A view has no key either: rows pasted there could not be named once
/// saved, as the toolbar's Insert says.
#[gtk4::test]
fn a_table_without_a_key_refuses_to_paste() {
    let columns = [column("id", false), column("name", false)];
    let mut script = serving_table();
    script.fetch_columns.always(FakeReply::ok(columns.to_vec()));
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![vec![Value::Int(0), Value::Text("Ada".into())]],
    )));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 1).expect("the first page");
    let toasts = toasts(harness.tab());

    paste(&harness, "7\tLinus\n", None);

    assert_eq!(harness.tracker.pending_count(), 0);
    assert_eq!(
        toasts.borrow().as_slice(),
        ["Rows can only be pasted into a table with a primary key."]
    );
}

#[gtk4::test]
fn a_large_paste_asks_first() {
    let harness = people_table();
    let text: String = (0..=PASTE_CONFIRM_ROWS)
        .map(|n| format!("{}\tuser {n}\t\n", n + 10))
        .collect();

    paste(&harness, &text, None);

    wait_until(WAIT, || confirming_paste(harness.tab()).is_some()).expect("a paste this large asks first");
    let dialog = confirming_paste(harness.tab()).expect("the question");
    assert_eq!(harness.tracker.pending_count(), 0, "the rows landed before the answer");
    dialog.emit_by_name::<()>("response", &[&"paste"]);
    drain_main_context();

    assert_eq!(draft_rows(&harness.store()), PASTE_CONFIRM_ROWS + 1);
    assert_eq!(draft_cells(&harness, 0)[1], name("user 0"));
}

#[gtk4::test]
fn more_lines_than_a_paste_takes_point_to_import_csv() {
    let harness = people_table();
    let toasts = toasts(harness.tab());
    let text = "x\n".repeat(tablepro_core::import::MAX_PASTED_ROWS + 1);

    paste(&harness, &text, None);

    wait_until(WAIT, || !toasts.borrow().is_empty()).expect("the paste said why it stopped");
    assert_eq!(
        toasts.borrow().as_slice(),
        ["The clipboard holds too much to paste. Import CSV takes large amounts of data."]
    );
    assert_eq!(harness.tracker.pending_count(), 0);
}

#[gtk4::test]
fn duplicated_rows_keep_their_order_on_screen_and_after_a_refresh() {
    let harness = people_table();
    let (ada, grace) = (harness.grid_row(0), harness.grid_row(1));

    harness.tab().send(EditInput::DuplicateRows(vec![ada, grace]));

    let names = |harness: &Harness| (draft_cells(harness, 0)[1].clone(), draft_cells(harness, 1)[1].clone());
    assert_eq!(names(&harness), (name("Ada"), name("Grace")));
    let reads = || CallCounters::get(&harness.connection.counters().query_bound);
    let before = reads();
    harness.tab().send(PagingInput::Refresh);
    wait_until(WAIT, || reads() > before && harness.saved_rows().len() == 2).expect("the page read again");
    assert_eq!(
        names(&harness),
        (name("Ada"), name("Grace")),
        "a refresh turned them around"
    );
}

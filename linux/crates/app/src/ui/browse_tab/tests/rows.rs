use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::RowIdentity;
use tablepro_core::{ColumnInfo, QueryResult, Value};
use tablepro_test_support::{ConnectionScript, FakeReply};

use super::super::{DataInput, GridInput, PagingInput};
use super::{
    Harness, Shown, WAIT, col_with_default, column, full_page, grid_cell_of, headers_are, key, paging,
    pending_bar_shown, rename, rows, rows_from, serving_table, text, toasts, type_into,
};
use crate::services::change_tracker::RowState;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{drain_main_context, respond, wait_until};
use crate::ui::browse_tab::BrowseTab;

/// A table of an `id` key and `column`, with one row, id 0, holding
/// `value`.
fn one_row(column: ColumnInfo, value: Value) -> Harness {
    let columns = vec![self::column("id", true), column];
    let mut script = ConnectionScript::default();
    script.fetch_columns.always(FakeReply::ok(columns.clone()));
    script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }));
    script.count_rows.always(FakeReply::ok(1));
    script.probe.always(FakeReply::ok(()));
    script.fetch_outbound_foreign_keys.always(FakeReply::ok(Vec::new()));
    script.fetch_inbound_foreign_keys.always(FakeReply::ok(Vec::new()));
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![vec![Value::Int(0), value]],
    )));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.saved_rows().len() == 1).expect("the first page");
    harness
}

fn two_rows() -> Harness {
    let mut script = serving_table();
    script.query_bound.always(FakeReply::ok(rows(&["Ada", "Grace"])));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    harness
}

/// What the clipboard holds once the copy `copy` starts lands there.
fn copied_by(tab: &BrowseTab, copy: impl FnOnce()) -> String {
    const BEFORE: &str = "nothing copied yet";
    let clipboard = tab.clipboard();
    clipboard.set_text(BEFORE);
    copy();
    let text = || -> Option<String> { clipboard.content()?.value(String::static_type()).ok()?.get().ok() };
    wait_until(WAIT, || text().is_some_and(|text| text != BEFORE)).expect("the copy to land");
    text().unwrap_or_default()
}

/// A partitioned PostgreSQL table with no key, whose page carries the
/// partition, the row address and its version after the visible cells.
fn partitioned_table() -> ConnectionScript {
    let server = tablepro_core::ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0);
    let mut script = ConnectionScript {
        dialect: Arc::new(tablepro_driver_postgres::PgDialect::new(&server)),
        ..ConnectionScript::default()
    };
    script
        .fetch_columns
        .always(FakeReply::ok(vec![column("id", false), column("name", false)]));
    script.row_identity.always(FakeReply::ok(RowIdentity::EngineRowId(
        tablepro_core::meta::EngineRowId::PostgresTableoidCtid,
    )));
    script.count_rows.always(FakeReply::ok(2));
    script.probe.always(FakeReply::ok(()));
    let mut columns: Vec<_> = [column("id", false), column("name", false)]
        .iter()
        .map(ColumnInfo::result_column)
        .collect();
    for hidden in ["__tablepro_row_oid", "__tablepro_row_id", "__tablepro_row_xmin"] {
        columns.push(column(hidden, false).result_column());
    }
    let rows = [("Ada", "(0,1)"), ("Grace", "(0,1)")]
        .iter()
        .zip(0..)
        .map(|((name, ctid), id)| {
            vec![
                Value::Int(id),
                Value::Text((*name).to_owned()),
                Value::Int(16_401 + id),
                Value::Text((*ctid).to_owned()),
                Value::Text("812".to_owned()),
            ]
        })
        .collect();
    script
        .query_bound
        .always(FakeReply::ok(QueryResult::new(columns, rows)));
    script
}

fn visible_only(values: &[Value]) {
    assert_eq!(values.len(), 2, "a row carried hidden cells: {values:?}");
}

#[gtk4::test]
fn page_rows_hold_only_visible_cells() {
    let harness = Harness::open(partitioned_table(), []);
    wait_until(WAIT, || harness.saved_rows().len() == 2).expect("the first page");

    for row in harness.saved_rows() {
        visible_only(&row.cells().expect("a saved row's cells"));
        assert_eq!(row.key(), None, "a table with no primary key took edits");
    }
    assert_eq!(
        harness.grid().grid_columns().len(),
        2,
        "the grid was given the hidden columns"
    );
}

#[gtk4::test]
fn page_rows_have_single_owner() {
    let harness = Harness::open(partitioned_table(), []);
    wait_until(WAIT, || harness.saved_rows().len() == 2).expect("the first page");

    for row in harness.saved_rows() {
        let cells = row.cells().expect("a saved row's cells");
        // This handle and the grid's slot.
        assert_eq!(Arc::strong_count(&cells), 2, "the tab kept its own copy of the page");
    }
}

/// D1: a table with no key takes no new row, a duplicate included.
#[gtk4::test]
fn copy_as_insert_contains_no_hidden_columns_and_a_keyless_table_takes_no_duplicate() {
    let harness = Harness::open(partitioned_table(), []);
    wait_until(WAIT, || harness.saved_rows().len() == 2).expect("the first page");
    harness.select(0..2);

    let copied = copied_by(harness.tab(), || harness.activate_grid("copy-insert"));

    assert_eq!(copied.lines().count(), 2, "{copied}");
    for hidden in ["16401", "(0,1)", "812", "__tablepro"] {
        assert!(!copied.contains(hidden), "{hidden} reached the copy: {copied}");
    }
    assert!(!harness.grid_enabled("duplicate-rows"));
    assert!(!harness.grid_enabled("insert-row"));
}

#[gtk4::test]
fn page_export_contains_no_hidden_columns() {
    let harness = Harness::open(partitioned_table(), []);
    wait_until(WAIT, || harness.saved_rows().len() == 2).expect("the first page");
    let exported = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let sink = exported.clone();
    harness
        .tab()
        .connect_export_results(move |_, offer| sink.borrow_mut().push(offer.origin.shown().clone()));

    harness.tab().send(GridInput::Export);

    let exported = exported.borrow();
    let [crate::ui::export::ExportSource::Rows { columns, rows }] = exported.as_slice() else {
        panic!("one export, not {}", exported.len());
    };
    let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(names, ["id", "name"]);
    assert_eq!(rows.len(), 2);
    for row in rows {
        visible_only(&row.to_values());
    }
}

/// The page writes into the rows the grid has and drops the ones past
/// its end, under the drafts.
#[gtk4::test]
fn a_page_turn_keeps_the_drafts_on_top_and_changes_only_the_tail() {
    let harness = Harness::open(paging(full_page(0), rows_from(100, &["Linus", "Ken"])), []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    harness.activate_grid("insert-row");
    let store = harness.store();
    let changes = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let log = changes.clone();
    store.connect_items_changed(move |_, position, removed, added| {
        log.borrow_mut().push((position, removed, added));
    });

    harness.tab().send(PagingInput::NextPage);
    wait_until(WAIT, || harness.shown() == text(&["Linus", "Ken"])).expect("the next page");

    assert_eq!(*changes.borrow(), [(3, 98, 0)], "the page built rows again");
    assert!(harness.grid_row(0).draft_id().is_some(), "the draft left the top");
    assert_eq!(harness.grid_row(1).key(), Some(key(100)));
}

/// The grid keeps its row slots across pages, and lets go of the cells
/// they held.
#[gtk4::test]
fn a_new_page_lets_go_of_the_cells_it_replaced() {
    let harness = Harness::open(paging(full_page(0), rows_from(100, &["Linus"])), []);
    wait_until(WAIT, || harness.shown().len() == 100).expect("the first page");
    let first: Vec<std::sync::Weak<[Value]>> = harness
        .saved_rows()
        .iter()
        .filter_map(|row| row.cells())
        .map(|cells| Arc::downgrade(&cells))
        .collect();

    harness.tab().send(PagingInput::NextPage);
    wait_until(WAIT, || harness.shown() == text(&["Linus"])).expect("the next page");

    wait_until(WAIT, || first.iter().all(|cells| cells.upgrade().is_none()))
        .expect("the first page's cells were let go");
}

#[gtk4::test]
fn duplicate_row_copies_pending_edits_of_persisted_row() {
    let harness = two_rows();
    harness.apply_delta(&harness.tracker.apply(rename(0, "Ada", "Ada Lovelace")));
    harness.select(0..1);

    harness.activate_grid("duplicate-rows");

    let drafts = harness.tracker.drafts();
    assert_eq!(drafts.len(), 1, "{drafts:?}");
    assert_eq!(
        drafts[0].cells,
        vec![
            CellInput::Value(Value::Null),
            CellInput::Value(Value::Text("Ada Lovelace".to_owned()))
        ],
        "the duplicate left out the row's pending edit"
    );
}

#[gtk4::test]
fn duplicating_a_draft_leaves_its_defaulted_cells_to_the_server() {
    let mut level = col_with_default("integer", "0");
    level.name = "level".to_owned();
    let harness = one_row(level, Value::Int(3));
    harness.activate_grid("insert-row");
    assert!(harness.grid_row(0).draft_id().is_some(), "the new row goes on top");
    harness.select(0..1);

    harness.activate_grid("duplicate-rows");

    let drafts = harness.tracker.drafts();
    assert_eq!(drafts.len(), 2, "{drafts:?}");
    assert_eq!(
        drafts[1].cells[1],
        CellInput::Default,
        "the copy wrote NULL where the server fills in"
    );
}

#[gtk4::test]
fn duplicating_a_selection_is_one_undo_step() {
    let harness = two_rows();
    harness.select(0..2);

    harness.activate_grid("duplicate-rows");
    assert_eq!(harness.drafts(), 2);
    harness.tab().send(GridInput::Undo);

    assert_eq!(harness.drafts(), 0, "one undo left copies behind");
    assert_eq!(harness.tracker.pending_count(), 0);
}

/// F004: the row under a new one is the one copied, not the new one.
#[gtk4::test]
fn f004_copy_row_as_insert_uses_row_below_draft() {
    let harness = two_rows();
    harness.activate_grid("insert-row");
    harness.select(1..2);

    let copied = copied_by(harness.tab(), || harness.activate_grid("copy-insert"));

    assert_eq!(copied, "INSERT INTO \"users\" (\"id\", \"name\") VALUES (0, 'Ada');");
}

#[gtk4::test]
fn an_edit_held_for_the_running_save_says_so_once() {
    let harness = two_rows();
    let toasts = toasts(harness.tab());
    harness.activate_grid("insert-row");
    harness.activate_grid("insert-row");
    let _saving = harness.tracker.begin_save().expect("a save").expect("the drafts");
    harness.select(0..2);

    harness.activate_grid("delete-rows");

    assert_eq!(harness.tracker.drafts().len(), 2, "a draft the save holds was dropped");
    assert_eq!(toasts.borrow().len(), 1, "{:?}", toasts.borrow());
}

#[gtk4::test]
fn deleting_a_draft_from_the_toolbar_empties_the_footer() {
    let harness = two_rows();
    harness.activate_grid("insert-row");
    assert_eq!(harness.store().n_items(), 3);
    harness.select(0..1);
    assert!(harness.grid_enabled("delete-rows"), "a draft could not be deleted");

    harness.activate_grid("delete-rows");

    assert_eq!(harness.store().n_items(), 2, "the dropped draft stayed in the grid");
    assert_eq!(harness.drafts(), 0);
    assert_eq!(harness.tracker.pending_count(), 0);
    assert!(
        !pending_bar_shown(harness.tab()),
        "the footer still counts the dropped draft"
    );
}

/// The toolbar says why Delete is off, and the count names Delete only
/// where it acts (D12).
#[gtk4::test]
fn delete_is_off_for_rows_without_a_key_and_the_toolbar_says_why() {
    let columns = [column("id", false), column("name", false)];
    let mut script = serving_table();
    script.fetch_columns = Default::default();
    script.fetch_columns.always(FakeReply::ok(columns.to_vec()));
    script.query_bound.always(FakeReply::ok(QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![
            vec![Value::Int(0), Value::Text("Ada".into())],
            vec![Value::Int(1), Value::Text("Grace".into())],
        ],
    )));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == 2).expect("the first page");
    let imp = harness.tab().imp();

    harness.select(0..1);
    assert!(
        !harness.grid_enabled("delete-rows"),
        "Delete was offered for a row with no key"
    );
    assert_eq!(
        imp.delete_button.tooltip_text().as_deref(),
        Some("Rows without a primary key or unique key can't be deleted here")
    );
    harness.select(0..2);
    assert_eq!(imp.selection_label.label(), "2 selected");
    harness.tab().activate_action("grid.delete-rows", None).ok();
    drain_main_context();

    assert_eq!(harness.tracker.pending_count(), 0);
}

/// More rows than a delete marks without asking first.
const DOZEN: [&str; 12] = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"];
const DOZEN_ROWS: std::ops::Range<u32> = 0..12;

fn dozen_rows(script: ConnectionScript) -> Harness {
    let mut script = script;
    script.query_bound.always(FakeReply::ok(rows(&DOZEN)));
    let harness = Harness::open(script, []);
    wait_until(WAIT, || harness.shown().len() == DOZEN.len()).expect("the first page");
    harness
}

/// Every row selected and Delete clicked, which asks before marking.
fn ask_to_delete_every_row(harness: &Harness) -> libadwaita::AlertDialog {
    harness.select(DOZEN_ROWS);
    harness.activate_grid("delete-rows");
    let dialog = harness.grid().edit().question().expect("a bulk delete asks first");
    assert_eq!(harness.tracker.pending_count(), 0);
    dialog
}

fn change_schema(harness: &Harness, done: impl Fn(&[ColumnInfo]) -> bool) {
    harness
        .session
        .invalidate_table(&tablepro_core::TableRef::unqualified("users"));
    harness.tab().send(DataInput::SchemaChanged);
    wait_until(WAIT, || done(&harness.tab().columns())).expect("the new columns");
}

#[gtk4::test]
fn a_bulk_delete_waiting_while_the_primary_key_moves_is_cancelled() {
    let mut script = serving_table();
    script.fetch_columns = Default::default();
    script
        .fetch_columns
        .once(FakeReply::ok(vec![column("id", true), column("name", false)]))
        .always(FakeReply::ok(vec![column("id", false), column("name", true)]));
    let harness = dozen_rows(script);
    let _shown = Shown::new(harness.tab());
    let toasts = toasts(harness.tab());
    let dialog = ask_to_delete_every_row(&harness);

    change_schema(&harness, |columns| {
        columns.iter().any(|column| column.name == "name" && column.primary_key)
    });
    respond(&dialog, "delete");

    wait_until(WAIT, || !toasts.borrow().is_empty()).expect("the cancelled delete says why");
    assert_eq!(
        harness.tracker.pending_count(),
        0,
        "rows were marked by the key they had before"
    );
    assert_eq!(toasts.borrow().len(), 1, "{:?}", toasts.borrow());
}

#[gtk4::test]
fn a_bulk_delete_waiting_while_a_column_is_added_marks_its_rows_under_the_new_columns() {
    let widened = [column("id", true), column("name", false), column("email", false)];
    let mut script = serving_table();
    script.fetch_columns = Default::default();
    script
        .fetch_columns
        .once(FakeReply::ok(vec![column("id", true), column("name", false)]))
        .always(FakeReply::ok(widened.to_vec()));
    let harness = dozen_rows(script);
    let _shown = Shown::new(harness.tab());
    let dialog = ask_to_delete_every_row(&harness);

    change_schema(&harness, |columns| columns.len() == widened.len());
    respond(&dialog, "delete");

    wait_until(WAIT, || harness.tracker.pending_count() == DOZEN.len()).expect("the rows were marked");
    assert_eq!(harness.tracker.row_state(&key(0)), RowState::PendingDelete);
}

/// The tab hands the grid the settings it reads at each delete, so a
/// change in Preferences reaches an open tab.
#[gtk4::test]
fn the_delete_confirmation_follows_preferences_in_an_open_tab() {
    let harness = dozen_rows(serving_table());
    let _shown = Shown::new(harness.tab());
    let settings = harness.stores.settings.get();
    settings
        .set_confirm_bulk_delete(false)
        .expect("turn the confirmation off");
    harness.select(DOZEN_ROWS);

    harness.activate_grid("delete-rows");
    assert!(
        harness.grid().edit().question().is_none(),
        "the delete asked with the switch off"
    );
    assert_eq!(harness.tracker.pending_count(), DOZEN.len());
    harness.tab().send(GridInput::Undo);
    assert_eq!(harness.tracker.pending_count(), 0);

    settings
        .set_confirm_bulk_delete(true)
        .expect("turn the confirmation on");
    let dialog = ask_to_delete_every_row(&harness);
    respond(&dialog, "delete");

    wait_until(WAIT, || harness.tracker.pending_count() == DOZEN.len()).expect("the confirmed delete");
}

fn people(names: &[&str]) -> Vec<ColumnInfo> {
    std::iter::once(column("id", true))
        .chain(names.iter().map(|name| column(name, false)))
        .collect()
}

/// One row, id 0, each cell holding its column's name.
fn people_page(columns: &[ColumnInfo]) -> QueryResult {
    QueryResult::new(
        columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
        vec![
            std::iter::once(Value::Int(0))
                .chain(columns[1..].iter().map(|column| Value::Text(column.name.clone())))
                .collect(),
        ],
    )
}

/// A table whose `nickname` another client drops before the tab reads
/// its columns again. `after` is what the page under the new columns
/// answers.
fn losing_nickname(after: FakeReply<QueryResult>) -> ConnectionScript {
    let before = people(&["nickname", "name", "email"]);
    let mut script = serving_table();
    script.fetch_columns = Default::default();
    script
        .fetch_columns
        .once(FakeReply::ok(before.clone()))
        .always(FakeReply::ok(people(&["name", "email"])));
    script
        .query_bound
        .when_sql_contains("nickname", FakeReply::ok(people_page(&before)))
        .always(after);
    script
}

fn without_nickname() -> FakeReply<QueryResult> {
    FakeReply::ok(people_page(&people(&["name", "email"])))
}

/// Each assignment of the save, by the name of the column it writes.
fn saved_cells(tracker: &TabTrackerHandle) -> Vec<(String, Option<String>)> {
    let batch = tracker.begin_save().expect("a save").expect("changes to save");
    batch
        .changes
        .changes
        .changes
        .iter()
        .flat_map(|change| match change {
            tablepro_core::save::RowChange::Update(update) => update.assignments.clone(),
            other => panic!("only a cell was edited: {other:?}"),
        })
        .map(|(col, value)| {
            (
                batch.columns[col].name.clone(),
                tablepro_core::export::value_to_text(value.value().unwrap_or(&tablepro_core::Value::Null)),
            )
        })
        .collect()
}

/// Write `input` into `column` of the first row, as a commit in the
/// grid does.
fn edit_first_row(harness: &Harness, column: usize, input: &str) {
    let original = harness
        .grid_row(0)
        .cells()
        .and_then(|cells| cells.get(column).cloned())
        .unwrap_or(Value::Null);
    harness.apply_delta(&harness.tracker.apply(TrackerEdit::Cell {
        row_key: key(0),
        col: column,
        original,
        value: CellInput::Value(Value::Text(input.to_owned())),
    }));
    assert_eq!(harness.tracker.pending_count(), 1);
}

fn first_grid(harness: &Harness) {
    wait_until(WAIT, || {
        headers_are(harness.tab(), &["id", "nickname", "name", "email"]) && harness.saved_rows().len() == 1
    })
    .expect("the first grid");
}

#[gtk4::test]
fn refresh_after_a_column_is_dropped_keeps_an_edit_on_its_column() {
    let harness = Harness::open(losing_nickname(without_nickname()), []);
    first_grid(&harness);
    edit_first_row(&harness, 2, "Grace");

    harness.tab().send(PagingInput::Refresh);
    wait_until(WAIT, || headers_are(harness.tab(), &["id", "name", "email"])).expect("the grid under the new columns");

    assert_eq!(
        saved_cells(&harness.tracker),
        vec![("name".to_owned(), Some("Grace".to_owned()))]
    );
}

#[gtk4::test]
fn a_structure_save_that_drops_the_edited_column_refuses_the_save() {
    let harness = Harness::open(losing_nickname(without_nickname()), []);
    first_grid(&harness);
    edit_first_row(&harness, 1, "countess");

    change_schema(&harness, |columns| columns == people(&["name", "email"]));
    wait_until(WAIT, || headers_are(harness.tab(), &["id", "name", "email"])).expect("the grid under the new columns");

    let refused = harness
        .tracker
        .begin_save()
        .map(|batch| batch.map(|batch| batch.changes.changes));
    assert!(
        refused
            .as_ref()
            .is_err_and(|rejection| rejection.message().contains("nickname")),
        "{refused:?}"
    );
    assert_eq!(
        harness.tracker.pending_count(),
        1,
        "the edit was dropped without a word"
    );
}

/// The grid takes the new columns before the tracker does, so what was
/// typed is filed under the column it was typed in, wherever that column
/// has moved.
#[gtk4::test]
fn an_edit_open_while_the_columns_change_stays_on_its_column() {
    let harness = Harness::open(losing_nickname(FakeReply::UntilStopped), []);
    first_grid(&harness);
    let _shown = Shown::new(harness.tab());
    let cell = grid_cell_of(harness.tab(), 0, 2);
    type_into(&harness, &cell, "Grace");

    change_schema(&harness, |columns| columns == people(&["name", "email"]));

    assert_eq!(
        saved_cells(&harness.tracker),
        vec![("name".to_owned(), Some("Grace".to_owned()))],
        "what was typed was dropped, or landed on another column"
    );
    assert_eq!(harness.visible_page().as_deref(), Some("loading"));
    assert_eq!(harness.grid().row_count(), 0, "rows read under the old columns stayed");
}

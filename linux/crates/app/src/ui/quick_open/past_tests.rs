use std::time::{Duration, SystemTime};

use tablepro_storage::query_history::{NewEntry, Outcome};
use tablepro_test_support::{ConnectionScript, FakeReply};
use uuid::Uuid;

use super::past_source::read_past_queries;
use super::query_tests::history;
use super::*;
use crate::test_support::{FakeSession, finish_on_main, test_runtime, wait_until};

const WAIT: Duration = Duration::from_secs(10);

fn entry(connection: Uuid, query: &str, outcome: Outcome) -> NewEntry {
    NewEntry {
        query: query.into(),
        driver_id: "sqlite".into(),
        connection_id: connection,
        connection_name: "Test".into(),
        executed_at: SystemTime::now(),
        duration_ms: Some(1),
        rows_affected: None,
        outcome,
    }
}

#[gtk4::test]
fn successful_queries_are_filtered_before_the_page_limit() {
    adw::init().unwrap();
    let runtime = test_runtime();
    let (_root, _history, store) = history(&runtime.tasks());
    let connection = Uuid::new_v4();
    let rows = finish_on_main(
        WAIT,
        runtime.tasks().spawn_task(async move {
            store
                .record(entry(connection, "SELECT * FROM orders", Outcome::Success))
                .await
                .unwrap();
            for i in 0..105 {
                store
                    .record(entry(
                        connection,
                        &format!("failed {i}"),
                        Outcome::Error("syntax".into()),
                    ))
                    .await
                    .unwrap();
            }
            store
                .record(entry(connection, "cancelled", Outcome::Cancelled))
                .await
                .unwrap();
            store
                .record(entry(Uuid::new_v4(), "other connection", Outcome::Success))
                .await
                .unwrap();
            read_past_queries(&store, connection).await.unwrap()
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].name(), "SELECT * FROM orders");
}

#[gtk4::test]
fn history_search_reads_full_sql_and_inserts_the_original_without_running_it() {
    adw::init().unwrap();
    let runtime = test_runtime();
    let (_root, history, store) = history(&runtime.tasks());
    let connection = Uuid::new_v4();
    let sql = format!("SELECT {}second_line_term\nFROM orders;\nSELECT 42;", "x".repeat(130));
    let original = sql.clone();
    finish_on_main(
        WAIT,
        runtime.tasks().spawn_task(async move {
            store.record(entry(connection, &sql, Outcome::Success)).await.unwrap();
        }),
    )
    .unwrap()
    .unwrap();
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(vec![]));
    let fake = FakeSession::start(script, [], runtime.tasks());
    let chosen = Rc::new(RefCell::new(Vec::new()));
    let sink = chosen.clone();
    let dialog = QuickOpen::new(fake.session, runtime.tasks(), move |pick| sink.borrow_mut().push(pick));
    dialog.include_queries(history, connection);
    wait_until(WAIT, || {
        !dialog.imp().requests.borrow().is_pending(Request::Past) && dialog.current()
    })
    .unwrap();
    let widgets = dialog.imp().widgets.get().unwrap();
    assert_eq!(dialog.selected().unwrap().name().chars().count(), 120);
    for term in ["second_line_term", "orders"] {
        widgets.entry.set_text(term);
        dialog.search();
        wait_until(WAIT, || dialog.current()).unwrap();
        assert_eq!(widgets.store.n_items(), 1);
    }
    dialog.activate(false);
    wait_until(WAIT, || !chosen.borrow().is_empty()).unwrap();
    assert_eq!(chosen.borrow()[0], Pick::Query(original));
}

#[gtk4::test]
fn repeated_executions_have_one_row_and_deleted_history_cannot_open() {
    adw::init().unwrap();
    let runtime = test_runtime();
    let (_root, history, store) = history(&runtime.tasks());
    let connection = Uuid::new_v4();
    let recording = store.clone();
    let ids = finish_on_main(
        WAIT,
        runtime.tasks().spawn_task(async move {
            let first = recording
                .record(entry(connection, "SELECT 42", Outcome::Success))
                .await
                .unwrap();
            let second = recording
                .record(entry(connection, "SELECT 42", Outcome::Success))
                .await
                .unwrap();
            vec![first, second]
        }),
    )
    .unwrap()
    .unwrap();
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(vec![]));
    let fake = FakeSession::start(script, [], runtime.tasks());
    let chosen = Rc::new(RefCell::new(Vec::new()));
    let sink = chosen.clone();
    let dialog = QuickOpen::new(fake.session, runtime.tasks(), move |pick| sink.borrow_mut().push(pick));
    dialog.include_queries(history, connection);
    wait_until(WAIT, || {
        !dialog.imp().requests.borrow().is_pending(Request::Past) && dialog.current()
    })
    .unwrap();
    assert_eq!(dialog.imp().widgets.get().unwrap().store.n_items(), 1);
    finish_on_main(
        WAIT,
        runtime
            .tasks()
            .spawn_task(async move { store.delete_returning(&ids).await }),
    )
    .unwrap()
    .unwrap()
    .unwrap();
    dialog.activate(false);
    wait_until(WAIT, || dialog.imp().widgets.get().unwrap().banner.is_revealed()).unwrap();
    assert!(chosen.borrow().is_empty());
    dialog.dismiss();
}

#[gtk4::test]
fn an_empty_list_stays_loading_until_the_history_reply_arrives() {
    adw::init().unwrap();
    let runtime = test_runtime();
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(vec![]));
    let fake = FakeSession::start(script, [], runtime.tasks());
    let dialog = QuickOpen::new(fake.session, runtime.tasks(), |_| {});
    wait_until(WAIT, || dialog.current()).unwrap();
    let pending = dialog.imp().requests.borrow_mut().issue(Request::Past);
    dialog.show_results(String::new(), vec![]);
    let widgets = dialog.imp().widgets.get().unwrap();
    assert_eq!(widgets.status.title(), "Loading Results");
    assert!(widgets.status.description().is_none());
    assert!(dialog.imp().requests.borrow_mut().accept(Request::Past, pending.stamp));
    dialog.show_results(
        String::new(),
        vec![Candidate::PastQuery {
            id: 1,
            name: "SELECT 42".into(),
            sql: Arc::from("SELECT 42"),
        }],
    );
    assert_eq!(widgets.stack.visible_child_name().as_deref(), Some("list"));
    assert_eq!(dialog.selected().unwrap().name(), "SELECT 42");
    dialog.dismiss();
}

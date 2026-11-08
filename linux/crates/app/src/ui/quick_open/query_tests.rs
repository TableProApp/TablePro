use std::time::Duration;

use tablepro_core::DriverError;
use tablepro_storage::saved_queries::NewSavedQuery;
use tablepro_storage::{QueryHistory, StoragePaths};
use tablepro_test_support::{ConnectionScript, FakeReply};
use uuid::Uuid;

use super::*;
use crate::services::history_preferences::HistoryPreferences;
use crate::services::history_service::HistoryService;
use crate::test_support::{FakeSession, finish_on_main, test_runtime, wait_until};

const WAIT: Duration = Duration::from_secs(5);

fn history(tasks: &Tasks) -> (tempfile::TempDir, HistoryService, QueryHistory) {
    let root = tempfile::tempdir().unwrap();
    let paths = StoragePaths::under(root.path(), "quick-open-test", "app.tablepro.TablePro.Devel");
    let history = HistoryService::start(
        paths,
        HistoryPreferences {
            retention_days: tokio::sync::watch::channel(30).1,
            save: tokio::sync::watch::channel(true).1,
        },
        tasks,
    );
    wait_until(WAIT, || history.availability().borrow().is_ready()).unwrap();
    let store = history.store().unwrap();
    (root, history, store)
}

fn save(tasks: &Tasks, history: &QueryHistory, connection: Uuid, name: &str, sql: &str) -> i64 {
    let saved = history.saved_queries();
    let query = NewSavedQuery {
        name: name.into(),
        query: sql.into(),
        connection_id: connection,
        connection_name: "Test".into(),
    };
    finish_on_main(WAIT, tasks.spawn_task(async move { saved.save(query).await }))
        .unwrap()
        .unwrap()
        .unwrap()
        .id
}

fn ready(dialog: &QuickOpen) {
    wait_until(WAIT, || {
        !dialog.imp().requests.borrow().is_pending(Request::Queries) && dialog.current()
    })
    .unwrap();
}

#[gtk4::test]
fn saved_queries_work_when_the_catalog_fails_and_only_for_their_connection() {
    adw::init().unwrap();
    let runtime = test_runtime();
    let (_root, history, store) = history(&runtime.tasks());
    let connection = Uuid::new_v4();
    save(
        &runtime.tasks(),
        &store,
        connection,
        "My orders",
        "SELECT 1;\nSELECT 2;",
    );
    save(&runtime.tasks(), &store, Uuid::new_v4(), "Other orders", "SELECT 3");
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::err(DriverError::Cancelled));
    let fake = FakeSession::start(script, [], runtime.tasks());
    let chosen = Rc::new(RefCell::new(Vec::new()));
    let sink = chosen.clone();
    let dialog = QuickOpen::new(fake.session, runtime.tasks(), move |pick| sink.borrow_mut().push(pick));
    dialog.include_saved_queries(history, connection);
    ready(&dialog);
    let widgets = dialog.imp().widgets.get().unwrap();
    assert_eq!(widgets.store.n_items(), 1);
    assert!(widgets.banner.is_revealed());
    assert_eq!(dialog.selected().unwrap().name(), "My orders");
    dialog.activate(false);
    wait_until(WAIT, || !chosen.borrow().is_empty()).unwrap();
    assert_eq!(chosen.borrow()[0], Pick::Query("SELECT 1;\nSELECT 2;".into()));
}

#[gtk4::test]
fn choosing_a_saved_query_reads_its_current_sql() {
    adw::init().unwrap();
    let runtime = test_runtime();
    let (_root, history, store) = history(&runtime.tasks());
    let connection = Uuid::new_v4();
    save(&runtime.tasks(), &store, connection, "Orders", "SELECT 1");
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(vec![]));
    let fake = FakeSession::start(script, [], runtime.tasks());
    let chosen = Rc::new(RefCell::new(Vec::new()));
    let sink = chosen.clone();
    let dialog = QuickOpen::new(fake.session, runtime.tasks(), move |pick| sink.borrow_mut().push(pick));
    dialog.include_saved_queries(history, connection);
    ready(&dialog);
    save(&runtime.tasks(), &store, connection, "Orders", "SELECT 42");
    dialog.activate(false);
    wait_until(WAIT, || !chosen.borrow().is_empty()).unwrap();
    assert_eq!(chosen.borrow()[0], Pick::Query("SELECT 42".into()));
}

#[gtk4::test]
fn closing_during_query_lookup_discards_the_reply() {
    adw::init().unwrap();
    let runtime = test_runtime();
    let (_root, history, store) = history(&runtime.tasks());
    let connection = Uuid::new_v4();
    save(&runtime.tasks(), &store, connection, "Orders", "SELECT 42");
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(vec![]));
    let fake = FakeSession::start(script, [], runtime.tasks());
    let chosen = Rc::new(RefCell::new(Vec::new()));
    let sink = chosen.clone();
    let dialog = QuickOpen::new(fake.session, runtime.tasks(), move |pick| sink.borrow_mut().push(pick));
    dialog.include_saved_queries(history, connection);
    ready(&dialog);
    dialog.activate(false);
    dialog.dismiss();
    crate::test_support::drain_main_context();
    assert!(chosen.borrow().is_empty());
    assert!(dialog.imp().queries.borrow().is_none());
    assert!(!dialog.imp().requests.borrow().is_pending(Request::Pick));
}

#[gtk4::test]
fn a_successful_catalog_refresh_keeps_a_saved_query_error_visible() {
    adw::init().unwrap();
    let runtime = test_runtime();
    let root = tempfile::tempdir().unwrap();
    let paths = StoragePaths::under(root.path(), "quick-open-test", "app.tablepro.TablePro.Devel");
    std::fs::create_dir_all(paths.history_database()).unwrap();
    let history = HistoryService::start(
        paths,
        HistoryPreferences {
            retention_days: tokio::sync::watch::channel(30).1,
            save: tokio::sync::watch::channel(true).1,
        },
        &runtime.tasks(),
    );
    let mut script = ConnectionScript::default();
    script
        .list_objects
        .always(FakeReply::ok(vec![ObjectInfo::new(None, "orders", ObjectKind::Table)]));
    let fake = FakeSession::start(script, [], runtime.tasks());
    let dialog = QuickOpen::new(fake.session.clone(), runtime.tasks(), |_| {});
    dialog.include_saved_queries(history, Uuid::new_v4());
    ready(&dialog);
    let widgets = dialog.imp().widgets.get().unwrap();
    assert!(widgets.banner.is_revealed());
    let session = fake.session.clone();
    finish_on_main(
        WAIT,
        runtime
            .tasks()
            .spawn_task(async move { session.refresh_objects(ObjectScope::AllSchemas).await }),
    )
    .unwrap()
    .unwrap()
    .unwrap();
    wait_until(WAIT, || dialog.imp().generation.get() == Some(2) && dialog.current()).unwrap();
    assert!(widgets.banner.is_revealed());
    assert_eq!(dialog.selected().unwrap().name(), "orders");
    dialog.dismiss();
}

#[gtk4::test]
fn saved_queries_arrive_before_the_catalog_and_survive_its_commit() {
    adw::init().unwrap();
    let runtime = test_runtime();
    let (_root, history, store) = history(&runtime.tasks());
    let connection = Uuid::new_v4();
    save(&runtime.tasks(), &store, connection, "Saved orders", "SELECT 1");
    let release = tokio_util::sync::CancellationToken::new();
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::UntilReleased {
        release: release.clone(),
        outcome: Ok(vec![ObjectInfo::new(None, "orders", ObjectKind::Table)]),
    });
    let fake = FakeSession::start(script, [], runtime.tasks());
    let dialog = QuickOpen::new(fake.session, runtime.tasks(), |_| {});
    dialog.include_saved_queries(history, connection);
    ready(&dialog);
    assert_eq!(dialog.selected().unwrap().name(), "Saved orders");
    assert!(dialog.imp().generation.get().is_none());
    release.cancel();
    wait_until(WAIT, || dialog.imp().generation.get().is_some() && dialog.current()).unwrap();
    assert_eq!(dialog.imp().widgets.get().unwrap().store.n_items(), 2);
    assert_eq!(dialog.selected().unwrap().name(), "Saved orders");
    dialog.dismiss();
}

#[gtk4::test]
fn a_deleted_saved_query_reports_an_error_without_opening_sql() {
    adw::init().unwrap();
    let runtime = test_runtime();
    let (_root, history, store) = history(&runtime.tasks());
    let connection = Uuid::new_v4();
    let id = save(&runtime.tasks(), &store, connection, "Orders", "SELECT 1");
    let mut script = ConnectionScript::default();
    script.list_objects.always(FakeReply::ok(vec![]));
    let fake = FakeSession::start(script, [], runtime.tasks());
    let chosen = Rc::new(RefCell::new(Vec::new()));
    let sink = chosen.clone();
    let dialog = QuickOpen::new(fake.session, runtime.tasks(), move |pick| sink.borrow_mut().push(pick));
    dialog.include_saved_queries(history, connection);
    ready(&dialog);
    let saved = store.saved_queries();
    finish_on_main(WAIT, runtime.tasks().spawn_task(async move { saved.delete(id).await }))
        .unwrap()
        .unwrap()
        .unwrap();
    dialog.activate(false);
    let widgets = dialog.imp().widgets.get().unwrap();
    wait_until(WAIT, || widgets.banner.is_revealed()).unwrap();
    assert!(chosen.borrow().is_empty());
    assert!(dialog.imp().context.borrow().is_some());
    widgets.banner.emit_by_name::<()>("button-clicked", &[]);
    ready(&dialog);
    assert_eq!(widgets.store.n_items(), 0);
    assert!(!widgets.banner.is_revealed());
    dialog.dismiss();
}

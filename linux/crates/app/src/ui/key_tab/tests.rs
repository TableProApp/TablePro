use std::time::Duration;

use tablepro_core::keyspace::{KeyCursor, KeyPage, KeyTtl};
use tablepro_core::meta::KeyKind;
use tablepro_core::{QueryResult, Value};
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};

use super::*;
use crate::test_support::{FakeSession, test_runtime, wait_until};

const WAIT: Duration = Duration::from_secs(10);

fn text_column(name: &str) -> ResultColumn {
    ResultColumn::new(name, tablepro_core::column::ColumnType::untyped_text("string"))
}

fn list_page(from: i64, to: i64, next: Option<&str>) -> KeyPage {
    let rows = (from..to)
        .map(|index| vec![Value::Int(index), Value::Text(format!("element{index}"))])
        .collect();
    KeyPage {
        kind: KeyKind::List,
        type_name: "list".to_owned(),
        ttl: KeyTtl::ExpiresIn(Duration::from_secs(150)),
        length: Some(3),
        rows: QueryResult::new(vec![text_column("index"), text_column("element")], rows),
        next: next.map(KeyCursor::new),
    }
}

fn opened(script: ConnectionScript) -> (KeyTab, FakeSession, crate::runtime::AppRuntime) {
    adw::init().expect("libadwaita initialises under the test backend");
    let runtime = test_runtime();
    let fake = FakeSession::start(script, [], runtime.tasks());
    let tab = KeyTab::new(KeyTabInit {
        key: "queue".to_owned(),
        session: fake.session.clone(),
        tasks: runtime.tasks(),
        first_load: FirstLoad::Now,
    });
    (tab, fake, runtime)
}

#[gtk4::test]
fn a_key_reads_a_window_at_a_time_until_its_end() {
    let mut script = ConnectionScript::default();
    script.read_key.once(FakeReply::ok(Some(list_page(0, 2, Some("2")))));
    script.read_key.once(FakeReply::ok(Some(list_page(2, 3, None))));
    let (tab, fake, _runtime) = opened(script);

    wait_until(WAIT, || tab.rows() == 2).expect("the first window");
    assert_eq!(tab.shown_page().as_deref(), Some(CONTENT));
    assert_eq!(tab.type_text(), "List");
    assert_eq!(tab.summary_text(), "3 elements · Expires in 2 minutes");
    assert_eq!(tab.footer_text(), "2 of 3 shown");
    assert!(tab.offers_more());

    tab.load_more();

    wait_until(WAIT, || tab.rows() == 3).expect("the second window");
    assert_eq!(tab.footer_text(), "3 shown");
    assert!(!tab.offers_more(), "Load More past the end");
    assert_eq!(CallCounters::get(&fake.connection.counters().read_key), 2);
    assert!(!tab.is_loading());
}

#[gtk4::test]
fn a_key_that_is_gone_says_so() {
    let mut script = ConnectionScript::default();
    script.read_key.always(FakeReply::ok(None));
    let (tab, _fake, _runtime) = opened(script);

    wait_until(WAIT, || tab.shown_page().as_deref() == Some(ERROR)).expect("the error page");
    assert_eq!(
        tab.error_text().as_deref(),
        Some("This key no longer exists. It may have been deleted or renamed, or it expired.")
    );
}

#[gtk4::test]
fn a_window_that_fails_can_be_asked_for_again() {
    let mut script = ConnectionScript::default();
    script.read_key.once(FakeReply::ok(Some(list_page(0, 2, Some("2")))));
    script
        .read_key
        .once(FakeReply::err(tablepro_core::DriverError::server("busy")));
    script.read_key.once(FakeReply::ok(Some(list_page(2, 3, None))));
    let (tab, _fake, _runtime) = opened(script);
    wait_until(WAIT, || tab.rows() == 2).expect("the first window");

    tab.load_more();

    wait_until(WAIT, || tab.offers_more() && !tab.is_loading()).expect("Load More back after the failure");
    assert_eq!(tab.rows(), 2, "the failure dropped what was shown");
    tab.load_more();
    wait_until(WAIT, || tab.rows() == 3).expect("the window asked for again");
}

#[gtk4::test]
fn a_key_written_over_with_another_type_is_read_again() {
    let column = ResultColumn::new("value", tablepro_core::column::ColumnType::untyped_text("string"));
    let string = KeyPage {
        kind: KeyKind::String,
        type_name: "string".to_owned(),
        ttl: KeyTtl::Unknown,
        length: Some(3),
        rows: QueryResult::new(vec![column], vec![vec![Value::Text("Ada".to_owned())]]),
        next: None,
    };
    let mut script = ConnectionScript::default();
    script.read_key.once(FakeReply::ok(Some(list_page(0, 2, Some("2")))));
    script.read_key.always(FakeReply::ok(Some(string)));
    let (tab, _fake, _runtime) = opened(script);
    wait_until(WAIT, || tab.rows() == 2).expect("the list's first window");

    tab.load_more();

    wait_until(WAIT, || tab.type_text() == "String").expect("the key read again as a string");
    assert_eq!(tab.rows(), 1);
    assert_eq!(
        tab.summary_text(),
        "3 bytes",
        "an expiry the server would not give was shown"
    );
}

#[gtk4::test]
fn a_refresh_reads_the_key_from_its_start() {
    let mut script = ConnectionScript::default();
    script.read_key.once(FakeReply::ok(Some(list_page(0, 2, Some("2")))));
    script.read_key.always(FakeReply::ok(Some(list_page(0, 3, None))));
    let (tab, _fake, _runtime) = opened(script);
    wait_until(WAIT, || tab.rows() == 2).expect("the first window");

    tab.refresh();

    wait_until(WAIT, || tab.rows() == 3).expect("the key read again");
    assert_eq!(tab.footer_text(), "3 shown");
}

#[gtk4::test]
fn a_module_type_is_named_and_left_to_the_editor() {
    let mut script = ConnectionScript::default();
    script.read_key.always(FakeReply::ok(Some(KeyPage {
        kind: KeyKind::Other,
        type_name: "ReJSON-RL".to_owned(),
        ttl: KeyTtl::Persistent,
        length: None,
        rows: QueryResult::empty(),
        next: None,
    })));
    let (tab, _fake, _runtime) = opened(script);

    wait_until(WAIT, || tab.shown_page().as_deref() == Some(CONTENT)).expect("the key's page");
    assert_eq!(tab.type_text(), "Other");
    assert_eq!(tab.summary_text(), "No expiry");
    assert!(!tab.offers_more());
}

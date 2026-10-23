use std::time::Duration;

use tablepro_core::keyspace::{KeyCursor, KeyPage, KeyTtl};
use tablepro_core::meta::KeyKind;
use tablepro_core::{DriverError, LossPhase, QueryResult, Value};
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};
use tokio_util::sync::CancellationToken;

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
    reopened(script, [])
}

/// A tab whose session reconnects with `reconnects` once a read loses
/// the link.
fn reopened(
    script: ConnectionScript,
    reconnects: impl IntoIterator<Item = FakeEstablish>,
) -> (KeyTab, FakeSession, crate::runtime::AppRuntime) {
    adw::init().expect("libadwaita initialises under the test backend");
    let runtime = test_runtime();
    let fake = FakeSession::start(script, reconnects, runtime.tasks());
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
fn a_window_brings_the_key_s_new_length_and_expiry() {
    let mut grown = list_page(2, 3, None);
    grown.length = Some(4);
    grown.ttl = KeyTtl::Persistent;
    let mut script = ConnectionScript::default();
    script.read_key.once(FakeReply::ok(Some(list_page(0, 2, Some("2")))));
    script.read_key.once(FakeReply::ok(Some(grown)));
    let (tab, _fake, _runtime) = opened(script);
    wait_until(WAIT, || tab.rows() == 2).expect("the first window");

    tab.load_more();

    wait_until(WAIT, || tab.rows() == 3).expect("the second window");
    assert_eq!(tab.summary_text(), "4 elements · No expiry");
    assert_eq!(tab.footer_text(), "3 of 4 shown");
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
fn load_more_waits_for_a_refresh_still_running() {
    let release = CancellationToken::new();
    let mut script = ConnectionScript::default();
    script.read_key.once(FakeReply::ok(Some(list_page(0, 2, Some("2")))));
    script.read_key.once(FakeReply::UntilReleased {
        release: release.clone(),
        outcome: Ok(Some(list_page(0, 3, None))),
    });
    script.read_key.always(FakeReply::ok(Some(list_page(2, 3, None))));
    let (tab, fake, _runtime) = opened(script);
    wait_until(WAIT, || tab.rows() == 2).expect("the first window");

    tab.refresh();
    assert!(!tab.offers_more(), "Load More while the key is read again");
    tab.load_more();
    release.cancel();

    wait_until(WAIT, || tab.rows() == 3 && !tab.is_loading()).expect("the key read again");
    assert_eq!(tab.footer_text(), "3 shown");
    assert_eq!(
        CallCounters::get(&fake.connection.counters().read_key),
        2,
        "a window was read under rows the refresh replaced"
    );
}

fn link_lost() -> FakeReply<Option<KeyPage>> {
    FakeReply::err(DriverError::ConnectionLost {
        during: LossPhase::Statement,
    })
}

#[gtk4::test]
fn a_failed_read_is_asked_again_on_the_next_link() {
    let mut first = ConnectionScript::default();
    first.read_key.always(link_lost());
    let mut second = ConnectionScript::default();
    second.read_key.always(FakeReply::ok(Some(list_page(0, 3, None))));
    let (tab, fake, _runtime) = reopened(first, [FakeEstablish::Connect(second)]);

    wait_until(WAIT, || tab.rows() == 3).expect("the key read on the new link");
    assert_eq!(tab.shown_page().as_deref(), Some(CONTENT));
    assert_eq!(CallCounters::get(&fake.replacement().counters().read_key), 1);
}

#[gtk4::test]
fn a_failed_window_is_asked_again_on_the_next_link() {
    let mut first = ConnectionScript::default();
    first.read_key.once(FakeReply::ok(Some(list_page(0, 2, Some("2")))));
    first.read_key.always(link_lost());
    let mut second = ConnectionScript::default();
    second.read_key.always(FakeReply::ok(Some(list_page(2, 3, None))));
    let (tab, fake, _runtime) = reopened(first, [FakeEstablish::Connect(second)]);
    wait_until(WAIT, || tab.rows() == 2).expect("the first window");

    tab.load_more();

    wait_until(WAIT, || tab.rows() == 3 && !tab.is_loading()).expect("the window read on the new link");
    assert_eq!(tab.footer_text(), "3 shown");
    assert_eq!(CallCounters::get(&fake.replacement().counters().read_key), 1);
}

fn hash_page(fields: &[&str], next: Option<&str>) -> KeyPage {
    let rows = fields
        .iter()
        .map(|field| vec![Value::Text((*field).to_owned()), Value::Text("v".to_owned())])
        .collect();
    KeyPage {
        kind: KeyKind::Hash,
        type_name: "hash".to_owned(),
        ttl: KeyTtl::Persistent,
        length: Some(3),
        rows: QueryResult::new(vec![text_column("field"), text_column("value")], rows),
        next: next.map(KeyCursor::new),
    }
}

#[gtk4::test]
fn a_field_a_later_scan_step_returns_again_is_shown_once() {
    let mut script = ConnectionScript::default();
    script
        .read_key
        .once(FakeReply::ok(Some(hash_page(&["a", "b"], Some("hash:7")))));
    script.read_key.once(FakeReply::ok(Some(hash_page(&["b", "c"], None))));
    let (tab, _fake, _runtime) = opened(script);
    wait_until(WAIT, || tab.rows() == 2).expect("the first window");

    tab.load_more();

    wait_until(WAIT, || !tab.offers_more() && !tab.is_loading()).expect("the last window");
    assert_eq!(tab.rows(), 3);
    assert_eq!(tab.footer_text(), "3 shown");
}

#[gtk4::test]
fn a_cut_string_still_says_so_after_a_refresh_fails() {
    let page = KeyPage {
        kind: KeyKind::String,
        type_name: "string".to_owned(),
        ttl: KeyTtl::Persistent,
        length: Some(4 * 1024 * 1024),
        rows: QueryResult::new(vec![text_column("value")], vec![vec![Value::Text("x".repeat(1024))]]).truncated(true),
        next: None,
    };
    let mut script = ConnectionScript::default();
    script.read_key.once(FakeReply::ok(Some(page)));
    script
        .read_key
        .always(FakeReply::err(tablepro_core::DriverError::server("busy")));
    let (tab, _fake, _runtime) = opened(script);
    wait_until(WAIT, || tab.rows() == 1).expect("the string's first megabyte");
    let cut = tab.footer_text();
    assert!(cut.starts_with("Only the first"), "{cut}");

    tab.refresh();

    wait_until(WAIT, || !tab.is_loading()).expect("the refresh to fail");
    assert_eq!(tab.rows(), 1, "the failure dropped the value shown");
    assert_eq!(tab.footer_text(), cut);
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

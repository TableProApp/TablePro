use std::time::Duration;

use tablepro_core::keyspace::{KeyCursor, KeyPage, KeyTtl};
use tablepro_core::meta::KeyKind;
use tablepro_core::{DriverError, LossPhase, QueryResult, Value};
use tablepro_session::fakes::FakeEstablish;
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};
use tokio_util::sync::CancellationToken;

use super::*;
use crate::test_support::{FakeSession, MemorySettings, drain_main_context, test_runtime, wait_until};

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

/// What a test tab runs on, held for the test's length.
struct Held {
    _runtime: crate::runtime::AppRuntime,
    _settings: MemorySettings,
}

fn opened(script: ConnectionScript) -> (KeyTab, FakeSession, Held) {
    reopened(script, [])
}

/// A tab whose session reconnects with `reconnects` once a read loses
/// the link.
fn reopened(
    script: ConnectionScript,
    reconnects: impl IntoIterator<Item = FakeEstablish>,
) -> (KeyTab, FakeSession, Held) {
    adw::init().expect("libadwaita initialises under the test backend");
    crate::register_test_resources();
    let runtime = test_runtime();
    let settings = MemorySettings::new();
    let fake = FakeSession::start(script, reconnects, runtime.tasks());
    let tab = KeyTab::new(KeyTabInit {
        key: "queue".to_owned(),
        session: fake.session.clone(),
        tasks: runtime.tasks(),
        settings: settings.get().clone(),
        first_load: FirstLoad::Now,
    });
    let held = Held {
        _runtime: runtime,
        _settings: settings,
    };
    (tab, fake, held)
}

/// The second column of each row, in the order the grid shows them.
fn shown_elements(tab: &KeyTab) -> Vec<String> {
    tab.grid()
        .shown_rows()
        .iter()
        .filter_map(|row| match row.cells()?.get(1)? {
            Value::Text(text) => Some(text.clone()),
            _ => None,
        })
        .collect()
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

/// A reread lands in the grid the tab had, under the sort the user set.
#[gtk4::test]
fn a_refresh_keeps_the_grid_and_its_sort() {
    let mut script = ConnectionScript::default();
    script.read_key.once(FakeReply::ok(Some(list_page(0, 2, Some("2")))));
    script.read_key.always(FakeReply::ok(Some(list_page(0, 3, None))));
    let (tab, _fake, _runtime) = opened(script);
    wait_until(WAIT, || tab.rows() == 2).expect("the first window");
    let grid = tab.grid().clone();
    grid.set_sort(Some((1, false)));
    assert_eq!(shown_elements(&tab), ["element1", "element0"]);

    tab.refresh();

    wait_until(WAIT, || tab.rows() == 3).expect("the key read again");
    assert_eq!(tab.grid(), &grid, "the reread built another grid");
    assert!(grid.is_sorted(), "the reread dropped the sort");
    assert_eq!(shown_elements(&tab), ["element2", "element1", "element0"]);
}

#[gtk4::test]
fn the_footer_sums_the_selected_entries() {
    let mut script = ConnectionScript::default();
    script.read_key.always(FakeReply::ok(Some(list_page(0, 3, None))));
    let (tab, _fake, _runtime) = opened(script);
    let window = crate::test_support::OwnedWindow::presented(gtk::Window::builder().child(tab.widget()).build());
    wait_until(WAIT, || tab.rows() == 3 && tab.grid().width() > 0).expect("the key, laid out");
    let readout = tab
        .grid()
        .selection_summary()
        .downcast::<gtk::Revealer>()
        .expect("the readout");
    assert!(
        readout.is_ancestor(tab.widget()),
        "the readout is not in the key's footer"
    );

    wait_until(WAIT, || tab.grid().focus_cell(0, 0).is_some()).expect("a cell takes the focus");
    tab.grid().selection().select_all();

    let button = readout
        .child()
        .and_downcast::<gtk::MenuButton>()
        .expect("the menu button");
    wait_until(WAIT, || button.label().as_deref() == Some("Sum 3, Average 1, Count 3")).expect("the index summed");

    button.popup();

    // The figures are in place before the popover opens and takes the focus.
    let first_copy = || {
        gtk::prelude::GtkWindowExt::focus(&*window)
            .and_downcast::<gtk::Button>()
            .and_then(|focused| focused.tooltip_text())
            .is_some_and(|tooltip| tooltip == "Copy Count")
    };
    wait_until(WAIT, first_copy).expect("the popover's first Copy button takes the focus");
}

/// The header's Row Details toggle reaches the tab's grid.
#[gtk4::test]
fn row_details_reaches_the_key_s_grid() {
    let mut script = ConnectionScript::default();
    script.read_key.always(FakeReply::ok(Some(list_page(0, 2, None))));
    let (tab, _fake, _runtime) = opened(script);
    // Wide enough that the grid keeps its detail pane beside the rows.
    let _window = crate::test_support::OwnedWindow::presented(
        gtk::Window::builder()
            .default_width(1200)
            .default_height(700)
            .child(tab.widget())
            .build(),
    );
    wait_until(WAIT, || tab.rows() == 2 && tab.grid().width() > 0).expect("the first window, laid out");
    let toggle = crate::test_support::descendants(tab.widget())
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::ToggleButton>().ok())
        .find(|toggle| toggle.action_name().as_deref() == Some("grid.show-details"))
        .expect("the Row Details toggle");
    wait_until(WAIT, || toggle.is_sensitive()).expect("the toggle reaches the grid");

    toggle.emit_clicked();
    drain_main_context();

    let shown = tab
        .grid()
        .actions()
        .action_state("show-details")
        .and_then(|state| state.get::<bool>());
    assert_eq!(shown, Some(true));
    assert!(toggle.is_active());
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

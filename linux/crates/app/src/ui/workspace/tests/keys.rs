use std::sync::Arc;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::QueryResult;
use tablepro_core::keyspace::{KeyListing, KeyPage, KeyTtl};
use tablepro_core::meta::{KeyKind, ObjectInfo, ObjectKind};
use tablepro_test_support::{ConnectionScript, FakeReply};

use super::super::{OpenMode, Workspace, WorkspaceInput, WorkspaceTab};
use crate::runtime::DeliverInput;
use crate::test_support::wait_until;
use crate::ui::SessionWindowInput;
use crate::ui::session_window::tests::{Script, TestWindow, WAIT};
use crate::workspace::{TabRecord, WorkspaceRecord};

fn key(name: &str, kind: KeyKind) -> ObjectInfo {
    ObjectInfo {
        schema: None,
        name: name.to_owned(),
        kind: ObjectKind::Key(kind),
    }
}

fn listing(keys: Vec<ObjectInfo>, complete: bool) -> FakeReply<KeyListing> {
    FakeReply::ok(KeyListing { keys, complete })
}

fn three_keys() -> Vec<ObjectInfo> {
    vec![
        key("user:1", KeyKind::Hash),
        key("user:2", KeyKind::String),
        key("queue", KeyKind::List),
    ]
}

fn string_page(value: &str) -> FakeReply<Option<KeyPage>> {
    let column = tablepro_core::column::ResultColumn::new(
        "value",
        tablepro_core::column::ColumnType::untyped_text("string"),
    );
    FakeReply::ok(Some(KeyPage {
        kind: KeyKind::String,
        type_name: "string".to_owned(),
        ttl: KeyTtl::Persistent,
        length: Some(value.len() as u64),
        rows: QueryResult::new(vec![column], vec![vec![tablepro_core::Value::Text(value.to_owned())]]),
        next: None,
    }))
}

/// A window on a key-value engine's workspace.
fn keys_window(name: &str, script: impl FnOnce(&mut ConnectionScript)) -> TestWindow {
    let mut connection = ConnectionScript {
        dialect: Arc::new(tablepro_driver_redis::RedisDialect),
        ..ConnectionScript::default()
    };
    script(&mut connection);
    let test = TestWindow::with_script(
        name,
        Script {
            connection,
            keys: true,
            ..Script::default()
        },
    );
    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    test
}

fn shown(workspace: &Workspace) -> u32 {
    workspace.read(|model| model.sidebar.shown()).unwrap_or_default()
}

fn key_tabs(workspace: &Workspace) -> Vec<String> {
    workspace
        .read(|model| {
            model
                .workspace_tabs
                .borrow()
                .values()
                .filter_map(|tab| match tab {
                    WorkspaceTab::Key(slot) => Some(slot.tab.key().to_owned()),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default()
}

fn open_key(workspace: &Workspace, name: &str) {
    let input = workspace.input().expect("the workspace's input");
    input.deliver(WorkspaceInput::SelectTable {
        schema: None,
        name: name.to_owned(),
        open_mode: OpenMode::SwitchOrAppend,
    });
}

#[gtk4::test]
fn a_key_value_session_lists_its_keys_with_their_types() {
    let test = keys_window("KeysListed", |script| {
        script.scan_keys.always(listing(three_keys(), true));
    });
    let workspace = test.workspace();

    wait_until(WAIT, || shown(&workspace) == 3).expect("the keys listed");

    let rows = workspace
        .read(|model| model.sidebar.row_descriptions())
        .unwrap_or_default();
    assert!(rows.contains(&("user:1".to_owned(), "Hash".to_owned())), "{rows:?}");
    assert!(rows.contains(&("queue".to_owned(), "List".to_owned())), "{rows:?}");
    let imp = workspace.imp();
    assert_eq!(imp.table_search.placeholder_text().as_deref(), Some("Filter keys…"));
    assert!(!imp.key_limit_banner.is_revealed());
    assert_eq!(
        test.connection().observed_sql("scan_keys").first().cloned().flatten(),
        None,
        "the first listing asked for a pattern"
    );
}

#[gtk4::test]
fn a_search_asks_the_server_for_the_keys_that_match() {
    let test = keys_window("KeysSearched", |script| {
        script
            .scan_keys
            .when_sql_contains("user", listing(vec![key("user:1", KeyKind::Hash)], true));
        script.scan_keys.always(listing(three_keys(), true));
    });
    let workspace = test.workspace();
    wait_until(WAIT, || shown(&workspace) == 3).expect("the keys listed");

    workspace.imp().table_search.set_text("user");

    wait_until(WAIT, || shown(&workspace) == 1).expect("the matching key");
    let patterns = test.connection().observed_sql("scan_keys");
    assert_eq!(patterns.last().cloned().flatten().as_deref(), Some("*user*"));

    workspace.imp().table_search.set_text("");

    wait_until(WAIT, || shown(&workspace) == 3).expect("every key again");
}

#[gtk4::test]
fn a_listing_cut_short_says_so() {
    let test = keys_window("KeysCut", |script| {
        script.scan_keys.always(listing(three_keys(), false));
    });
    let workspace = test.workspace();
    let banner = workspace.imp().key_limit_banner.get();

    wait_until(WAIT, || banner.is_revealed()).expect("the banner over a cut listing");
    assert_eq!(banner.title(), "Not every key is listed. Search to narrow the list.");
}

#[gtk4::test]
fn a_key_opens_in_one_tab_that_reads_its_value() {
    let test = keys_window("KeyTabOpens", |script| {
        script.scan_keys.always(listing(three_keys(), true));
        script.read_key.always(string_page("Ada"));
    });
    let workspace = test.workspace();
    wait_until(WAIT, || shown(&workspace) == 3).expect("the keys listed");

    open_key(&workspace, "user:2");
    wait_until(WAIT, || key_tabs(&workspace) == ["user:2"]).expect("the key's tab");
    open_key(&workspace, "user:2");

    let view = workspace.imp().tab_view.get();
    wait_until(Duration::from_millis(300), || view.n_pages() == 2).expect_err("a second tab for the same key");
    assert_eq!(view.n_pages(), 1);
    assert_eq!(
        view.selected_page().map(|page| page.title().to_string()).as_deref(),
        Some("user:2")
    );
    assert_eq!(
        test.connection().observed_sql("read_key").first().cloned().flatten().as_deref(),
        Some("user:2")
    );
}

#[gtk4::test]
fn a_key_tab_is_reopened_with_the_session() {
    let test = TestWindow::with_script(
        "KeyTabRestored",
        Script {
            connection: {
                let mut connection = ConnectionScript::default();
                connection.scan_keys.always(listing(three_keys(), true));
                connection.read_key.always(string_page("Ada"));
                connection
            },
            keys: true,
            ..Script::default()
        },
    );
    let store = test.services.storage.workspaces().clone();
    store
        .schedule(
            &test.key(),
            WorkspaceRecord {
                active_tab: Some(0),
                tabs: vec![TabRecord::Key {
                    key: "user:2".to_owned(),
                }],
            },
        )
        .expect("the record to queue");
    crate::test_support::finish_on_main(WAIT, store.flush(&test.key()))
        .expect("the flush to end")
        .expect("the record written");

    test.window
        .send(SessionWindowInput::OpenSaved(Box::new(test.saved.clone())));
    test.wait_for_page("workspace");
    let workspace = test.workspace();

    wait_until(WAIT, || key_tabs(&workspace) == ["user:2"]).expect("the saved key tab");
}

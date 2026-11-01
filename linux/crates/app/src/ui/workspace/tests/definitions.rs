use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::DriverError;
use tablepro_core::meta::{ObjectDefinition, ObjectInfo, ObjectKind};
use tablepro_test_support::{CallCounters, ConnectionScript, FakeReply};
use tokio_util::sync::CancellationToken;

use super::super::WorkspaceInput;
use super::{open_editor, two_sessions_with};
use crate::runtime::DeliverInput;
use crate::test_support::{descendants, drain_main_context, wait_until};
use crate::ui::session_window::tests::{TestWindow, WAIT, editors};

const SQL: &str = "CREATE FUNCTION total() RETURNS int RETURN 1;";

fn function(name: &str) -> ObjectInfo {
    ObjectInfo::new(Some("sales".to_owned()), name, ObjectKind::Function)
}

fn listed(script: &mut ConnectionScript) {
    script
        .list_objects
        .always(FakeReply::ok(vec![function("total"), function("other")]));
}

fn ask(test: &TestWindow, object: ObjectInfo) {
    test.workspace()
        .sender()
        .expect("the workspace's input")
        .deliver(WorkspaceInput::ShowDefinition(object));
}

fn shown(test: &TestWindow) -> Option<adw::Dialog> {
    test.window.visible_dialog()
}

fn alert_heading(test: &TestWindow) -> Option<String> {
    shown(test)
        .and_downcast::<adw::AlertDialog>()
        .and_then(|alert| alert.heading())
        .map(|heading| heading.to_string())
}

#[gtk4::test]
fn open_in_editor_takes_the_text_to_the_database_it_runs_in() {
    let test = TestWindow::connected_with("DefinitionOpens", |script| {
        listed(script);
        script
            .fetch_object_definition
            .always(FakeReply::ok(Some(ObjectDefinition {
                sql: SQL.to_owned(),
                database: Some("analytics".to_owned()),
                opens_in_editor: true,
            })));
    });

    ask(&test, function("total"));
    wait_until(WAIT, || shown(&test).is_some()).expect("the definition");
    let dialog = shown(&test).expect("the definition");
    assert_eq!(dialog.title(), "Function “total”");
    let before = editors(&test.window).len();
    descendants(&dialog)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        .find(|button| button.label().as_deref() == Some("_Open in Editor"))
        .expect("Open in Editor")
        .emit_clicked();

    wait_until(WAIT, || editors(&test.window).len() == before + 1).expect("an editor tab");
    let editor = editors(&test.window).pop().expect("the editor");
    let buffer = editor.buffer();
    assert_eq!(buffer.text(&buffer.start_iter(), &buffer.end_iter(), false), SQL);
    assert_eq!(editor.tab_database().as_deref(), Some("analytics"));
    wait_until(WAIT, || shown(&test).is_none()).expect("the dialog to close");
}

#[gtk4::test]
fn only_the_last_definition_asked_for_is_shown_once() {
    let release = CancellationToken::new();
    let test = TestWindow::connected_with("DefinitionOnce", |script| {
        listed(script);
        let answer = |name: &str| ObjectDefinition {
            sql: format!("CREATE FUNCTION {name}() RETURNS int RETURN 1;"),
            database: None,
            opens_in_editor: true,
        };
        for name in ["total", "other"] {
            script.fetch_object_definition.when_sql_contains(
                name,
                FakeReply::UntilReleased {
                    release: release.clone(),
                    outcome: Ok(Some(answer(name))),
                },
            );
        }
    });
    let counters: CallCounters = test.connection().counters();

    ask(&test, function("total"));
    ask(&test, function("total"));
    wait_until(WAIT, || CallCounters::get(&counters.fetch_object_definition) == 1).expect("one read");
    ask(&test, function("other"));
    wait_until(WAIT, || CallCounters::get(&counters.fetch_object_definition) == 2).expect("a second read");
    release.cancel();

    wait_until(WAIT, || shown(&test).is_some()).expect("a definition");
    drain_main_context();
    let dialog = shown(&test).expect("a definition");
    assert_eq!(
        dialog.title(),
        "Function “other”",
        "the read it superseded landed later"
    );
    dialog.force_close();
    drain_main_context();
    assert!(shown(&test).is_none(), "a second dialog stacked under the first");
    assert_eq!(CallCounters::get(&counters.fetch_object_definition), 2);
}

#[gtk4::test]
fn a_definition_the_server_no_longer_has_reads_the_list_again() {
    let test = TestWindow::connected_with("DefinitionGone", |script| {
        listed(script);
        script.fetch_object_definition.always(FakeReply::ok(None));
    });
    let counters = test.connection().counters();
    let reads = CallCounters::get(&counters.list_objects);

    ask(&test, function("total"));

    wait_until(WAIT, || alert_heading(&test).is_some()).expect("an alert");
    assert_eq!(alert_heading(&test).as_deref(), Some("No Definition"));
    wait_until(WAIT, || CallCounters::get(&counters.list_objects) > reads).expect("the list read again");
}

#[gtk4::test]
fn a_failed_read_says_why() {
    let test = TestWindow::connected_with("DefinitionFails", |script| {
        listed(script);
        script
            .fetch_object_definition
            .always(FakeReply::err(DriverError::Unsupported {
                feature: tablepro_core::UnsupportedFeature::ClrRoutine,
            }));
    });

    ask(&test, function("total"));

    wait_until(WAIT, || alert_heading(&test).is_some()).expect("an alert");
    assert_eq!(alert_heading(&test).as_deref(), Some("Could Not Show Definition"));
    let body = shown(&test)
        .and_downcast::<adw::AlertDialog>()
        .map(|alert| alert.body().to_string())
        .unwrap_or_default();
    assert!(body.contains(".NET assembly"), "{body}");
}

#[gtk4::test]
fn a_definition_asked_for_from_a_session_behind_shows_until_the_user_moves() {
    let release = CancellationToken::new();
    let held = release.clone();
    let sessions = two_sessions_with("DefinitionBehind", "Other", move |script| {
        listed(script);
        script.fetch_object_definition.when_sql_contains(
            "other",
            FakeReply::UntilReleased {
                release: held.clone(),
                outcome: Ok(Some(ObjectDefinition {
                    sql: SQL.to_owned(),
                    database: None,
                    opens_in_editor: true,
                })),
            },
        );
        script
            .fetch_object_definition
            .always(FakeReply::ok(Some(ObjectDefinition {
                sql: SQL.to_owned(),
                database: None,
                opens_in_editor: true,
            })));
    });
    let (test, first, second) = (&sessions.test, &sessions.first, &sessions.second);
    open_editor(first);
    let ask = |workspace: &crate::ui::workspace::Workspace, name: &str| {
        workspace
            .sender()
            .expect("the workspace's input")
            .deliver(WorkspaceInput::ShowDefinition(function(name)));
    };

    ask(second, "total");
    wait_until(WAIT, || shown(test).is_some()).expect("the session behind's definition");
    shown(test).expect("a definition").force_close();
    wait_until(WAIT, || shown(test).is_none()).expect("the dialog to close");

    ask(second, "other");
    drain_main_context();
    open_editor(second);
    release.cancel();
    wait_until(WAIT, || {
        second.read(|model| model.definition_read.is_none()).unwrap_or_default()
    })
    .expect("the read to land");
    drain_main_context();
    assert!(
        shown(test).is_none(),
        "a read that landed after the user moved still showed"
    );
}

#[gtk4::test]
fn text_that_cannot_run_as_it_is_offers_no_editor() {
    let test = TestWindow::connected_with("DefinitionSplit", |script| {
        listed(script);
        script
            .fetch_object_definition
            .always(FakeReply::ok(Some(ObjectDefinition {
                sql: "CREATE PROCEDURE [sales].total AS SELECT 1\nGO\nSELECT 2".to_owned(),
                database: None,
                opens_in_editor: false,
            })));
    });

    ask(&test, function("total"));

    wait_until(WAIT, || shown(&test).is_some()).expect("the definition");
    let dialog = shown(&test).expect("the definition");
    let offers_editor = descendants(&dialog)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
        .any(|button| button.label().as_deref() == Some("_Open in Editor"));
    assert!(!offers_editor);
}

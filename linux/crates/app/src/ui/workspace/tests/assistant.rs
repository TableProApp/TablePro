use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::{AiPolicy, AiProvider};
use tablepro_storage::SavedConnection;

use super::super::WorkspaceInput;
use super::super::tab_spec::TabSpec;
use super::{open_editor, shell_of, two_sessions};
use crate::runtime::DeliverInput;
use crate::test_support::{descendants, drain_main_context, wait_until};
use crate::ui::assistant::AssistantRequest;
use crate::ui::assistant::fake_provider::serve_held;
use crate::ui::session_window::tests::{TestWindow, WAIT};

fn assistant_enabled(test: &TestWindow) -> bool {
    test.window
        .lookup_action("show-assistant")
        .is_some_and(|action| action.is_enabled())
}

#[gtk4::test]
fn with_no_provider_the_assistant_is_out_of_the_way() {
    let test = TestWindow::connected("AssistantOff");
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let imp = shell.imp();

    assert!(!imp.assistant_toggle.is_visible());
    assert!(!assistant_enabled(&test));
    assert!(!imp.assistant_split.shows_sidebar());
}

#[gtk4::test]
fn choosing_a_provider_brings_the_toggle_and_the_key_shows_the_pane() {
    let test = TestWindow::connected("AssistantOn");
    let workspace = test.workspace();
    let shell = shell_of(&workspace);
    let imp = shell.imp();

    test.services
        .settings
        .set_ai_provider(Some(AiProvider::Anthropic))
        .expect("the provider");
    wait_until(WAIT, || imp.assistant_toggle.is_visible()).expect("the toggle");
    assert!(assistant_enabled(&test));
    WidgetExt::activate_action(&test.window, "win.show-assistant", None).expect("win.show-assistant");

    assert!(imp.assistant_split.shows_sidebar());
    assert!(imp.assistant_toggle.is_active());
    assert_eq!(test.app.accels_for_action("win.show-assistant"), ["<Control><Alt>a"]);

    test.services.settings.set_ai_provider(None).expect("off");
    wait_until(WAIT, || !imp.assistant_toggle.is_visible()).expect("the toggle gone");
    assert!(!imp.assistant_split.shows_sidebar(), "the pane stayed with no provider");
}

/// A window that narrows past a breakpoint and widens again leaves the
/// assistant as the user left it.
#[gtk4::test]
fn crossing_a_breakpoint_neither_opens_nor_closes_the_assistant() {
    let test = TestWindow::connected("AssistantPinned");
    let workspace = test.workspace();
    let split = shell_of(&workspace).imp().assistant_split.get();
    for collapsed in [true, false] {
        split.set_collapsed(collapsed);
        assert!(!split.shows_sidebar(), "the assistant opened unasked");
    }

    split.set_show_sidebar(true);
    for collapsed in [true, false] {
        split.set_collapsed(collapsed);
        assert!(split.shows_sidebar(), "the assistant closed unasked");
    }
}

#[gtk4::test]
fn insert_goes_to_the_editor_in_front_or_a_new_one() {
    let test = TestWindow::connected("AssistantInsert");
    let workspace = test.workspace();
    let input = workspace.sender().expect("the workspace's input");

    input.deliver(WorkspaceInput::InsertFromAssistant("SELECT 1;".to_owned()));
    drain_main_context();
    let first = workspace
        .read(|model| model.active_editor_query())
        .flatten()
        .expect("an editor tab opened for the code");
    assert_eq!(first, "SELECT 1;");

    workspace.with_model(|model| {
        model.open_tab(TabSpec::Editor {
            initial_query: Some("-- ".to_owned()),
            draft: None,
            file: None,
            database: None,
        })
    });
    input.deliver(WorkspaceInput::InsertFromAssistant("SELECT 2;".to_owned()));
    drain_main_context();

    let second = workspace
        .read(|model| model.active_editor_query())
        .flatten()
        .expect("the editor in front");
    assert!(second.contains("-- ") && second.contains("SELECT 2;"), "{second}");
    assert_eq!(
        shell_of(&workspace).imp().tab_view.n_pages(),
        2,
        "a tab opened for code an editor could take"
    );
}

fn labels(widget: &impl IsA<gtk::Widget>) -> Vec<String> {
    descendants(widget)
        .into_iter()
        .filter_map(|widget| widget.downcast::<gtk::Label>().ok())
        .map(|label| label.text().to_string())
        .collect()
}

/// Each session has its own pane, so the one behind keeps its reply
/// coming in while another session's tab is on screen.
#[gtk4::test]
fn a_reply_keeps_coming_while_another_sessions_tab_is_in_front() {
    let runtime = crate::test_support::test_runtime();
    let (provider, release) = serve_held(
        &runtime,
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"There are \"}}]}\n\n",
        concat!(
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"**42** orders.\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n",
        ),
    );
    let sessions = two_sessions("AssistantBehind", "Other");
    let services = &sessions.test.services;
    services
        .settings
        .set_ai_provider(Some(AiProvider::OpenAiCompatible))
        .expect("the provider");
    services
        .settings
        .set_ai_compatible_url(&format!("http://127.0.0.1:{}/v1", provider.port))
        .expect("the address");
    services
        .settings
        .set_ai_model(AiProvider::OpenAiCompatible, "llama3.2")
        .expect("the model");
    let id = sessions.test.saved.id;
    services
        .storage
        .connections()
        .upsert_blocking(SavedConnection {
            ai_policy: AiPolicy::Allow,
            ..sessions.test.saved.clone()
        })
        .expect("allow the assistant");
    wait_until(WAIT, || {
        services
            .saved_connections
            .get(id)
            .is_some_and(|saved| saved.ai_policy == AiPolicy::Allow)
    })
    .expect("the list to allow it");
    open_editor(&sessions.first);
    let pane = sessions.first.assistant_pane().expect("the first session's pane");
    sessions
        .first
        .sender()
        .expect("the workspace's input")
        .deliver(WorkspaceInput::AskAssistant(Box::new(AssistantRequest {
            action: tablepro_ai::Action::Explain,
            statement: "SELECT count(*) FROM orders;".to_owned(),
            error: None,
        })));
    wait_until(WAIT, || labels(&pane).iter().any(|text| text.starts_with("There are"))).expect("the reply to start");

    open_editor(&sessions.second);
    assert_eq!(sessions.shell.front().as_ref(), Some(&sessions.second));
    assert_ne!(
        sessions.shell.imp().assistant_stack.visible_child(),
        Some(pane.clone().upcast()),
        "the column still shows the session behind"
    );
    release.notify_one();

    wait_until(WAIT, || labels(&pane).iter().any(|text| text == "There are 42 orders."))
        .expect("the rest of the reply behind");
    assert!(
        !labels(&pane).iter().any(|text| text == "Stopped."),
        "the other session's tab stopped the reply"
    );
    let theirs = sessions.second.assistant_pane().expect("the other session's pane");
    assert!(!labels(&theirs).iter().any(|text| text.starts_with("There are")));
    assert_eq!(provider.bodies.lock().expect("the bodies").len(), 1);
}

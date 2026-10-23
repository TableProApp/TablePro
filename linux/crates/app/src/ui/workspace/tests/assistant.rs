use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::AiProvider;

use super::super::WorkspaceInput;
use super::super::tab_spec::TabSpec;
use crate::runtime::DeliverInput;
use crate::test_support::{drain_main_context, wait_until};
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
    let imp = workspace.imp();

    assert!(!imp.assistant_toggle.is_visible());
    assert!(!assistant_enabled(&test));
    assert!(!imp.assistant_split.shows_sidebar());
}

#[gtk4::test]
fn choosing_a_provider_brings_the_toggle_and_the_key_shows_the_pane() {
    let test = TestWindow::connected("AssistantOn");
    let workspace = test.workspace();
    let imp = workspace.imp();

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

#[gtk4::test]
fn insert_goes_to_the_editor_in_front_or_a_new_one() {
    let test = TestWindow::connected("AssistantInsert");
    let workspace = test.workspace();
    let input = workspace.input().expect("the workspace's input");

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
        workspace.imp().tab_view.n_pages(),
        2,
        "a tab opened for code an editor could take"
    );
}

//! The window's own actions. Their keys are application accelerators,
//! from the accelerator table.
//!
//! The actions go on the window's own action map, which GTK already
//! exports as `win`: a second group inserted under that name would hide
//! it from the application's accelerators and from D-Bus.

use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;

use super::SessionWindowInput;
use super::session_page::SessionPage;
use crate::runtime::{DeliverInput, InputSender};

/// Builds the input an action sends.
type ActionInput = fn() -> SessionWindowInput;

/// The window's actions and the input each one sends. A closure holds
/// only the window's input sender, so an action that outlives the window
/// drops its input rather than reaching a window that is gone.
const ACTIONS: [(&str, ActionInput); 10] = [
    ("new-connection", || SessionWindowInput::OpenConnectDialog),
    ("close-current", || SessionWindowInput::CloseCurrent),
    ("disconnect", || SessionWindowInput::Disconnect),
    ("reconnect", || SessionWindowInput::Reconnect),
    ("cancel-connect", || SessionWindowInput::CancelConnect),
    ("retry-connect", || SessionWindowInput::RetryConnect),
    ("edit-connection", || SessionWindowInput::EditConnection),
    ("reset-workspace-layout", || SessionWindowInput::ResetWorkspaceLayout),
    ("export-connections", || SessionWindowInput::ExportConnections),
    ("import-connections", || SessionWindowInput::ImportConnections),
];

pub(super) fn install(window: &adw::ApplicationWindow, input: &InputSender<SessionWindowInput>) {
    let entries = ACTIONS.map(|(name, message)| {
        let input = input.clone();
        gio::ActionEntry::<adw::ApplicationWindow>::builder(name)
            .activate(move |_, _, _| input.deliver(message()))
            .build()
    });
    window.add_action_entries(entries);
    window.add_action_entries([retry_with_new_secret(input.clone())]);
}

/// Takes the secret to ask for as its target, named the way the keyring
/// attribute names it.
fn retry_with_new_secret(input: InputSender<SessionWindowInput>) -> gio::ActionEntry<adw::ApplicationWindow> {
    gio::ActionEntry::builder("retry-with-new-secret")
        .parameter_type(Some(glib::VariantTy::STRING))
        .activate(move |_, _, target| {
            if let Some(kind) = target
                .and_then(|target| target.str())
                .and_then(super::secret_retry::secret_kind_named)
            {
                input.deliver(SessionWindowInput::RetryWithNewSecret(kind));
            }
        })
        .build()
}

/// Enable each action on the page it means something on, so its menu
/// item and button are insensitive elsewhere.
pub(super) fn sync(window: &adw::ApplicationWindow, page: &SessionPage, editable: bool) {
    let connected = matches!(page, SessionPage::Workspace { .. });
    let failed = matches!(page, SessionPage::ConnectFailed { .. });
    let reenter = matches!(page, SessionPage::ConnectFailed { failure, .. } if failure.reenter.is_some());
    for (name, enabled) in [
        ("disconnect", connected),
        ("reconnect", connected),
        ("reset-workspace-layout", connected),
        (
            "cancel-connect",
            matches!(page, SessionPage::Connecting { .. }) || failed,
        ),
        ("retry-connect", failed),
        ("retry-with-new-secret", reenter),
        ("edit-connection", failed && editable),
    ] {
        if let Some(action) = window.lookup_action(name).and_downcast::<gio::SimpleAction>() {
            action.set_enabled(enabled);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::Delivery;
    use crate::test_support::wait_until;
    use crate::ui::session_window::tests::{TestWindow, WAIT, editors};

    #[gtk4::test]
    fn actions_live_on_application_window_map() {
        let window = adw::ApplicationWindow::builder().build();
        let (input, mut receiver) = crate::runtime::input_queue::<SessionWindowInput>();

        install(&window, &input);
        sync(&window, &SessionPage::Picker, false);

        assert!(
            window
                .lookup_action("disconnect")
                .is_some_and(|action| !action.is_enabled())
        );
        for moved in ["quit", "about", "preferences"] {
            assert!(
                window.lookup_action(moved).is_none(),
                "win.{moved} is still on the window"
            );
        }
        WidgetExt::activate_action(&window, "win.export-connections", None)
            .expect("win resolves to the window's own map");
        assert!(matches!(receiver.try_recv(), Ok(SessionWindowInput::ExportConnections)));
    }

    #[gtk4::test]
    fn action_after_workspace_drop_does_not_panic() {
        let test = TestWindow::connected("ActionAfterDrop");
        let action = test
            .window
            .lookup_action("reopen-closed-tab")
            .expect("the workspace's reopen action");
        let input = test.workspace().input().expect("the workspace's input");

        test.window.send(SessionWindowInput::Disconnect);
        test.wait_for_page("picker");
        crate::test_support::drain_main_context();

        assert!(
            test.window.lookup_action("reopen-closed-tab").is_none(),
            "the action outlived its workspace"
        );
        action.activate(None);
        assert_eq!(
            input.try_deliver(crate::ui::workspace::WorkspaceInput::RefreshPage),
            Delivery::ReceiverGone
        );
    }

    /// An accelerator for an action nobody adds does nothing, silently.
    #[gtk4::test]
    fn application_accelerators_name_actions_a_connected_window_has() {
        use crate::application::{ACCELERATORS, AcceleratorScope};
        let test = TestWindow::connected("AcceleratorActions");

        for entry in ACCELERATORS
            .iter()
            .filter(|entry| entry.scope == AcceleratorScope::Application)
        {
            let found = match entry.action.split_once('.') {
                Some(("win", name)) => test.window.lookup_action(name).is_some(),
                Some(("app", name)) => test.app.lookup_action(name).is_some(),
                _ => false,
            };
            assert!(found, "{} has an accelerator and no action", entry.action);
        }
    }

    #[gtk4::test]
    fn close_current_closes_a_window_with_no_workspace() {
        let test = TestWindow::picker("CloseCurrentPicker");

        WidgetExt::activate_action(&test.window, "win.close-current", None).expect("win.close-current");

        wait_until(WAIT, || test.app.windows().is_empty()).expect("the picker's window to close");
    }

    #[gtk4::test]
    fn close_current_closes_the_tab_and_still_works_after_a_disconnect() {
        let test = TestWindow::connected("CloseCurrentTab");
        WidgetExt::activate_action(&test.window, "win.new-editor-tab", None).expect("win.new-editor-tab");
        wait_until(WAIT, || editors(&test.window).len() == 1).expect("an editor tab");

        WidgetExt::activate_action(&test.window, "win.close-current", None).expect("win.close-current");
        wait_until(WAIT, || editors(&test.window).is_empty()).expect("the tab to close");
        assert_eq!(test.app.windows().len(), 1, "the window closed with its tab");

        test.window.send(SessionWindowInput::Disconnect);
        test.wait_for_page("picker");
        WidgetExt::activate_action(&test.window, "win.close-current", None).expect("win.close-current on the picker");

        wait_until(WAIT, || test.app.windows().is_empty()).expect("the window to close");
    }
}

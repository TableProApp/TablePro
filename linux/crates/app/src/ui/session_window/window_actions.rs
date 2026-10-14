//! The window's own actions and shortcuts.
//!
//! The actions go on the window's own action map, which GTK already
//! exports as `win`: a second group inserted under that name would hide
//! it from the application's accelerators and from D-Bus.

use gtk4 as gtk;
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
const ACTIONS: [(&str, ActionInput); 9] = [
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

/// Quit, New Window and Preferences are application accelerators, which
/// GTK runs before these, so none of their keys is bound here. The
/// workspace adds the actions these name while it is open, apart from
/// close-current, which the window keeps so Ctrl+W works on every page.
pub(crate) fn install_window_shortcuts(window: &adw::ApplicationWindow) {
    use gtk::gdk::{Key, ModifierType};
    let primary = ModifierType::CONTROL_MASK;
    let primary_shift = ModifierType::CONTROL_MASK | ModifierType::SHIFT_MASK;
    let controller = gtk::ShortcutController::new();
    controller.set_scope(gtk::ShortcutScope::Global);
    controller.add_shortcut(make_shortcut(Key::w, primary, "win.close-current"));
    controller.add_shortcut(make_shortcut(Key::e, primary, "win.open-editor"));
    // Ctrl+T mirrors Ctrl+E for the browser's "new tab".
    controller.add_shortcut(make_shortcut(Key::t, primary, "win.open-editor"));
    controller.add_shortcut(make_shortcut(Key::F5, ModifierType::empty(), "win.refresh-page"));
    controller.add_shortcut(make_shortcut(Key::f, primary, "win.open-filter"));
    controller.add_shortcut(make_shortcut(Key::h, primary, "win.show-history"));
    controller.add_shortcut(make_shortcut(Key::s, primary, "win.save-changes"));
    controller.add_shortcut(make_shortcut(Key::z, primary, "win.undo-change"));
    controller.add_shortcut(make_shortcut(Key::y, primary, "win.redo-change"));
    controller.add_shortcut(make_shortcut(Key::z, primary_shift, "win.redo-change"));
    controller.add_shortcut(make_shortcut(Key::t, primary_shift, "win.reopen-closed-tab"));
    controller.add_shortcut(make_shortcut(Key::s, primary_shift, "win.save-query"));
    window.add_controller(controller);
}

fn make_shortcut(key: gtk::gdk::Key, modifiers: gtk::gdk::ModifierType, action: &str) -> gtk::Shortcut {
    gtk::Shortcut::builder()
        .trigger(&gtk::KeyvalTrigger::new(key, modifiers))
        .action(&gtk::NamedAction::new(action))
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::Delivery;
    use crate::test_support::wait_until;
    use crate::ui::session_window::tests::{TestWindow, WAIT, editors};

    fn shortcut_action_names(window: &adw::ApplicationWindow) -> Vec<String> {
        let controllers = window.observe_controllers();
        let mut names = Vec::new();
        for index in 0..controllers.n_items() {
            let Some(controller) = controllers.item(index).and_downcast::<gtk::ShortcutController>() else {
                continue;
            };
            for position in 0..controller.n_items() {
                let Some(shortcut) = controller.item(position).and_downcast::<gtk::Shortcut>() else {
                    continue;
                };
                if let Some(action) = shortcut.action().and_downcast::<gtk::NamedAction>() {
                    names.push(action.action_name().to_string());
                }
            }
        }
        names
    }

    #[gtk4::test]
    fn window_shortcuts_leave_the_application_keys_alone() {
        let window = adw::ApplicationWindow::builder().build();

        install_window_shortcuts(&window);
        let names = shortcut_action_names(&window);

        assert!(names.iter().any(|name| name == "win.close-current"), "{names:?}");
        for owned_by_the_application in ["win.quit", "win.preferences", "win.shortcuts"] {
            assert!(
                !names.iter().any(|name| name == owned_by_the_application),
                "{owned_by_the_application} is an application action now: {names:?}"
            );
        }
    }

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
            .lookup_action("refresh-page")
            .expect("the workspace's refresh action");
        let input = test.workspace().input().expect("the workspace's input");

        test.window.send(SessionWindowInput::Disconnect);
        test.wait_for_page("picker");
        crate::test_support::drain_main_context();

        assert!(
            test.window.lookup_action("refresh-page").is_none(),
            "the action outlived its workspace"
        );
        action.activate(None);
        assert_eq!(
            input.try_deliver(crate::ui::workspace::WorkspaceInput::RefreshPage),
            Delivery::ReceiverGone
        );
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
        WidgetExt::activate_action(&test.window, "win.open-editor", None).expect("win.open-editor");
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

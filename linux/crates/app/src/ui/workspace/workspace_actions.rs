//! The window actions the sessions' workspaces act on. The shell adds
//! them once and each one goes to the session in front, so a change of
//! front changes where they go without taking any off the window. Their
//! keys are application accelerators; a tab's own keys belong to the tab.
//! Reopen Closed Tab, Switch to Recent Tab and View Open Tabs are the
//! shell's own: the tabs they name may be any session's.

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;

use super::{WorkspaceInput, WorkspaceShell};
use crate::runtime::DeliverInput;
use crate::services::history_availability::HistoryAvailability;

/// Builds the input an action sends.
type ActionInput = fn() -> WorkspaceInput;

/// The two actions that need the query database, which opens on a
/// background task. Once it failed to open they say why when used, so
/// they are not left greyed out with no reason.
const HISTORY_ACTIONS: [&str; 2] = ["show-history", "show-saved-queries"];

const ENTRIES: [(&str, ActionInput); 6] = [
    ("new-editor-tab", || WorkspaceInput::NewEditorTab),
    ("refresh-tables", || WorkspaceInput::RefreshCatalog),
    ("save-query", || WorkspaceInput::SaveActiveQuery),
    ("show-history", || WorkspaceInput::ShowHistory),
    ("show-saved-queries", || WorkspaceInput::ShowSavedQueries),
    (super::health_banner::REVIEW_HOST_KEY, || WorkspaceInput::ReviewHostKey),
];

const REOPEN_CLOSED_TAB: &str = "reopen-closed-tab";
const SWITCH_RECENT_TAB: &str = "switch-recent-tab";
const SHOW_TABS: &str = "show-tabs";

/// Add the actions to the window's own action map, which GTK exports as
/// `win`. Each sends its input to the session in front when activated;
/// with none, or once the shell is gone, it does nothing.
pub(super) fn install(window: &adw::ApplicationWindow, shell: &WorkspaceShell) {
    let actions = ENTRIES.map(|(name, message)| {
        let shell = shell.downgrade();
        gio::ActionEntry::<adw::ApplicationWindow>::builder(name)
            .activate(move |_, _, _| {
                if let Some(input) = shell
                    .upgrade()
                    .and_then(|shell| shell.front())
                    .and_then(|front| front.sender())
                {
                    input.deliver(message());
                }
            })
            .build()
    });
    window.add_action_entries(actions);
    let reopening = shell.downgrade();
    window.add_action_entries([gio::ActionEntry::<adw::ApplicationWindow>::builder(REOPEN_CLOSED_TAB)
        .activate(move |_, _, _| {
            if let Some(shell) = reopening.upgrade() {
                shell.reopen_closed_tab();
            }
        })
        .build()]);
    let switching = shell.downgrade();
    window.add_action_entries([gio::ActionEntry::<adw::ApplicationWindow>::builder(SWITCH_RECENT_TAB)
        .activate(move |_, _, _| {
            if let Some(shell) = switching.upgrade() {
                shell.switch_recent_tab();
            }
        })
        .build()]);
    let overview = shell.imp().tab_overview.downgrade();
    window.add_action_entries([gio::ActionEntry::<adw::ApplicationWindow>::builder(SHOW_TABS)
        .activate(move |_, _, _| {
            if let Some(overview) = overview.upgrade() {
                overview.set_open(!overview.is_open());
            }
        })
        .build()]);
    // The overview refuses to open or close with no tab, and with one tab
    // Ctrl+E goes on to the tab.
    for (name, least) in [(SWITCH_RECENT_TAB, 2), (SHOW_TABS, 1)] {
        if let Some(action) = window.lookup_action(name) {
            shell
                .tab_view()
                .bind_property("n-pages", &action, "enabled")
                .transform_to(move |_, pages: i32| Some(pages >= least))
                .sync_create()
                .build();
        }
    }
    // Insensitive until the query database has opened or failed to.
    for name in HISTORY_ACTIONS {
        set_enabled(window, name, false);
    }
}

/// Take the actions off the window as its shell goes.
pub(super) fn remove(window: &adw::ApplicationWindow) {
    for (name, _) in ENTRIES {
        window.remove_action(name);
    }
    window.remove_action(REOPEN_CLOSED_TAB);
    window.remove_action(SWITCH_RECENT_TAB);
    window.remove_action(SHOW_TABS);
}

fn set_enabled(window: &adw::ApplicationWindow, name: &str, enabled: bool) {
    if let Some(action) = window.lookup_action(name).and_downcast::<gio::SimpleAction>() {
        action.set_enabled(enabled);
    }
}

/// Flip the actions that need the query database whenever
/// `HistoryService` changes state. The watch is read on the GTK thread,
/// so the actions are only touched from the thread that owns them.
pub(super) fn spawn_history_gate(
    window: &adw::ApplicationWindow,
    mut availability: tokio::sync::watch::Receiver<HistoryAvailability>,
) -> glib::JoinHandle<()> {
    let window = window.downgrade();
    glib::spawn_future_local(async move {
        loop {
            let state = availability.borrow_and_update().clone();
            let Some(window) = window.upgrade() else {
                return;
            };
            for name in HISTORY_ACTIONS {
                set_enabled(&window, name, state.is_settled());
            }
            drop(window);
            if availability.changed().await.is_err() {
                return;
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn the_history_gate_follows_availability() {
        crate::register_test_resources();
        let window = crate::test_support::OwnedWindow::new(adw::ApplicationWindow::builder().build());
        install(&window, &glib::Object::new::<WorkspaceShell>());
        let (sender, receiver) = tokio::sync::watch::channel(HistoryAvailability::Starting);
        let gate = spawn_history_gate(&window, receiver);
        let enabled = || {
            window
                .lookup_action("show-history")
                .is_some_and(|action| action.is_enabled())
        };

        crate::test_support::drain_main_context();
        assert!(!enabled(), "enabled while the database was still opening");

        sender.send_replace(HistoryAvailability::Ready);
        crate::test_support::drain_main_context();
        assert!(enabled(), "stayed disabled after the database opened");

        sender.send_replace(HistoryAvailability::Failed("no disk".to_owned()));
        crate::test_support::drain_main_context();
        assert!(enabled(), "a failed database left the action greyed out with no reason");

        gate.abort();
    }

    #[gtk4::test]
    fn workspace_actions_live_on_the_windows_own_map_and_go_with_the_shell() {
        crate::register_test_resources();
        let window = crate::test_support::OwnedWindow::new(adw::ApplicationWindow::builder().build());
        let shell: WorkspaceShell = glib::Object::new();

        install(&window, &shell);

        // With no session in front the action has nowhere to go.
        WidgetExt::activate_action(&*window, "win.new-editor-tab", None).expect("win resolves to the window's own map");
        remove(&window);
        assert!(window.lookup_action("new-editor-tab").is_none());
        assert!(window.lookup_action(REOPEN_CLOSED_TAB).is_none());
        assert!(window.lookup_action(SWITCH_RECENT_TAB).is_none());
        assert!(window.lookup_action(SHOW_TABS).is_none());
    }
}

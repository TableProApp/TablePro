//! The window actions a workspace adds while it is open, and takes off
//! the window again when it goes.

use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;

use super::{WorkspaceInput, WorkspaceSender};
use crate::runtime::DeliverInput;
use crate::services::history_availability::HistoryAvailability;

/// Builds the input an action sends.
type ActionInput = fn() -> WorkspaceInput;

/// The two actions that need the query database, which opens on a
/// background task.
const HISTORY_ACTIONS: [&str; 2] = ["show-history", "show-saved-queries"];

/// Add the workspace's actions to the window's own action map, which GTK
/// exports as `win`, and return their names for `shutdown` to remove.
/// Each one sends its input through `input`, so one activated after the
/// workspace is gone is dropped rather than handled.
pub(super) fn install(window: &adw::ApplicationWindow, input: &WorkspaceSender) -> Vec<&'static str> {
    let entries: [(&'static str, ActionInput); 11] = [
        ("open-editor", || WorkspaceInput::NewEditorTab),
        ("close-current", || WorkspaceInput::CloseActiveWorkspaceTab),
        ("refresh-page", || WorkspaceInput::RefreshPage),
        ("save-changes", || WorkspaceInput::SaveActiveTab),
        ("undo-change", || WorkspaceInput::UndoActiveBrowseTab),
        ("redo-change", || WorkspaceInput::RedoActiveBrowseTab),
        ("reopen-closed-tab", || WorkspaceInput::ReopenClosedTab),
        ("open-filter", || WorkspaceInput::ShowFilterDialog),
        ("save-query", || WorkspaceInput::SaveActiveQuery),
        ("show-history", || WorkspaceInput::ShowHistory),
        ("show-saved-queries", || WorkspaceInput::ShowSavedQueries),
    ];
    let actions = entries.map(|(name, message)| {
        let input = input.clone();
        gio::ActionEntry::<adw::ApplicationWindow>::builder(name)
            .activate(move |_, _, _| input.deliver(message()))
            .build()
    });
    window.add_action_entries(actions);
    // Insensitive until the query database reports it is open.
    for name in HISTORY_ACTIONS {
        set_enabled(window, name, false);
    }
    entries.iter().map(|(name, _)| *name).collect()
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
                set_enabled(&window, name, state.is_ready());
            }
            drop(window);
            if let Some(failure) = state.failure() {
                tracing::warn!(error = failure, "query history stays unavailable");
            }
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
        let window = adw::ApplicationWindow::builder().build();
        let (input, _receiver) = crate::runtime::input_queue::<WorkspaceInput>();
        install(&window, &input);
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
        assert!(!enabled(), "stayed enabled after the database failed");

        gate.abort();
    }

    #[gtk4::test]
    fn workspace_actions_live_on_the_windows_own_map() {
        let window = adw::ApplicationWindow::builder().build();
        let (input, mut receiver) = crate::runtime::input_queue::<WorkspaceInput>();

        let names = install(&window, &input);

        assert!(names.contains(&"refresh-page"));
        WidgetExt::activate_action(&window, "win.open-editor", None).expect("win resolves to the window's own map");
        crate::test_support::drain_main_context();
        assert!(matches!(receiver.try_recv(), Ok(WorkspaceInput::NewEditorTab)));
    }
}

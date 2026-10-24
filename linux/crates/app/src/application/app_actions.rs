use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita::prelude::*;
use uuid::Uuid;

use super::TableProApplication;
use super::about_dialog::build_about_dialog;
use crate::runtime::DeliverInput;
use crate::ui::{PreferencesDialog, SessionWindowInput};

pub fn install_app_actions(app: &TableProApplication) {
    let new_window = gio::ActionEntry::builder("new-window")
        .activate(|app: &TableProApplication, _, _| app.open_launch_windows())
        .build();
    let quit = gio::ActionEntry::builder("quit")
        .activate(|app: &TableProApplication, _, _| app.request_quit())
        .build();
    let preferences = gio::ActionEntry::builder("preferences")
        .activate(|app: &TableProApplication, _, _| present_preferences(app))
        .build();
    let about = gio::ActionEntry::builder("about")
        .activate(|app: &TableProApplication, _, _| present_about(app))
        .build();
    // A notification's default action, with the window and the tab it
    // is about.
    let focus_tab = gio::ActionEntry::builder("focus-tab")
        .parameter_type(Some(&<(u32, String)>::static_variant_type()))
        .activate(|app: &TableProApplication, _, target| focus_tab(app, target))
        .build();
    app.add_action_entries([new_window, quit, preferences, about, focus_tab]);
}

/// Bring the tab forward in its window. A notification can outlive both,
/// and is clicked after a restart too, so one that names neither brings
/// TablePro forward instead.
fn focus_tab(app: &TableProApplication, target: Option<&glib::Variant>) {
    let named = target
        .and_then(|target| target.get::<(u32, String)>())
        .and_then(|(window_id, tab)| Some((window_id, Uuid::parse_str(&tab).ok()?)));
    let sender = named.and_then(|(window_id, tab)| Some((window_id, tab, app.imp().windows.sender(window_id)?)));
    match sender {
        Some((window_id, tab, sender)) => {
            sender.deliver(SessionWindowInput::FocusTab(tab));
            app.present_window(window_id);
        }
        None => {
            tracing::warn!(?target, "a notification named a window or tab that is gone");
            match app.active_window() {
                Some(window) => window.present(),
                None => app.activate(),
            }
        }
    }
}

fn present_preferences(app: &TableProApplication) {
    let Some(services) = app.services() else {
        return;
    };
    PreferencesDialog::new(
        &services.settings,
        &services.storage,
        services.history(),
        &services.tasks,
        services.file_revealer.clone(),
        services.mcp(),
        services.ai.clone(),
    )
    .present(app.active_window().as_ref());
}

fn present_about(app: &TableProApplication) {
    let Some(services) = app.services() else {
        return;
    };
    build_about_dialog(&services.drivers).present(app.active_window().as_ref());
}

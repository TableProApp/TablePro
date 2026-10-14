use gtk4::prelude::*;
use libadwaita::prelude::*;

use super::about_dialog::build_about_dialog;
use super::{TableProApplication, WindowLaunch};
use crate::ui::PreferencesDialog;

pub fn install_app_actions(app: &TableProApplication) {
    let new_window = gio::ActionEntry::builder("new-window")
        .activate(|app: &TableProApplication, _, _| {
            app.open_window(WindowLaunch::Picker);
        })
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
    app.add_action_entries([new_window, quit, preferences, about]);
}

fn present_preferences(app: &TableProApplication) {
    let Some(services) = app.services() else {
        return;
    };
    PreferencesDialog::new(
        &services.settings,
        &services.storage,
        services.history().store(),
        &services.tasks,
        services.file_revealer.clone(),
    )
    .present(app.active_window().as_ref());
}

fn present_about(app: &TableProApplication) {
    let Some(services) = app.services() else {
        return;
    };
    build_about_dialog(&services.drivers).present(app.active_window().as_ref());
}

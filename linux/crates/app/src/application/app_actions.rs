use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

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
        .activate(|app: &TableProApplication, _, _| about_dialog().present(app.active_window().as_ref()))
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
    )
    .present(app.active_window().as_ref());
}

fn about_dialog() -> adw::AboutDialog {
    let dialog = adw::AboutDialog::builder()
        .application_name(crate::i18n::gettext("TablePro"))
        .application_icon(crate::config::APP_ID)
        .developer_name(crate::i18n::gettext("TablePro Authors"))
        .version(crate::config::VERSION)
        .website("https://github.com/TableProApp/TablePro")
        .issue_url("https://github.com/TableProApp/TablePro/issues")
        .support_url("https://github.com/TableProApp/TablePro/discussions")
        .copyright(crate::i18n::gettext("© 2025–2026 TablePro Authors"))
        .license_type(gtk::License::Agpl30)
        .comments(crate::i18n::gettext(
            "A native Linux database client built with GTK4 + libadwaita.",
        ))
        .build();
    dialog.set_developers(&["TablePro Authors https://github.com/TableProApp/TablePro"]);
    dialog.set_translator_credits(&crate::i18n::gettext("translator-credits"));
    dialog
}

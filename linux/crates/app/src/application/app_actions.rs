use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::{TableProApplication, WindowLaunch};
use crate::ui::PreferencesDialog;

/// The application-wide shortcuts. No window or tab binds these keys:
/// GTK runs application accelerators before a focused widget sees the
/// key. AdwApplication adds `app.shortcuts` on `<Primary>question` from
/// `shortcuts-dialog.ui`.
pub const APP_ACCELS: &[(&str, &[&str])] = &[
    ("app.new-window", &["<Primary><Shift>n"]),
    ("app.quit", &["<Primary>q"]),
    ("app.preferences", &["<Primary>comma"]),
];

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
    for (action, accels) in APP_ACCELS {
        app.set_accels_for_action(action, accels);
    }
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

#[cfg(test)]
mod tests {
    use std::rc::Rc;
    use std::time::Duration;

    use gtk::gdk;
    use tablepro_session::runtime::CountingHold;

    use super::*;
    use crate::test_support::MemorySettings;
    use crate::ui::{BrowseTab, SqlEditor, SqlEditorInit, install_window_shortcuts};

    fn parse(accel: &str) -> (gdk::Key, gdk::ModifierType) {
        let (key, modifiers) = gtk::accelerator_parse(accel).expect("an accelerator GTK can parse");
        (key.to_lower(), modifiers)
    }

    fn keyval_triggers(trigger: &gtk::ShortcutTrigger, into: &mut Vec<(gdk::Key, gdk::ModifierType)>) {
        if let Some(keyval) = trigger.downcast_ref::<gtk::KeyvalTrigger>() {
            into.push((keyval.keyval().to_lower(), keyval.modifiers()));
        } else if let Some(pair) = trigger.downcast_ref::<gtk::AlternativeTrigger>() {
            keyval_triggers(&pair.first(), into);
            keyval_triggers(&pair.second(), into);
        }
    }

    /// Every key a shortcut controller on `widget` or below it binds.
    fn bound_keys(widget: &gtk::Widget) -> Vec<(gdk::Key, gdk::ModifierType)> {
        let mut keys = Vec::new();
        let mut widgets = crate::test_support::descendants(widget);
        widgets.push(widget.clone());
        for widget in widgets {
            let controllers = widget.observe_controllers();
            for index in 0..controllers.n_items() {
                let Some(controller) = controllers.item(index).and_downcast::<gtk::ShortcutController>() else {
                    continue;
                };
                for position in 0..controller.n_items() {
                    if let Some(trigger) = controller
                        .item(position)
                        .and_downcast::<gtk::Shortcut>()
                        .and_then(|shortcut| shortcut.trigger())
                    {
                        keyval_triggers(&trigger, &mut keys);
                    }
                }
            }
        }
        keys
    }

    #[gtk4::test]
    fn app_accels_do_not_collide_with_window_accels() {
        adw::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let runtime = crate::test_support::test_runtime();
        let settings = MemorySettings::new();
        let window = adw::ApplicationWindow::builder().build();
        install_window_shortcuts(&window);
        let browse: BrowseTab = glib::Object::new();
        let editor = SqlEditor::new(SqlEditorInit {
            initial_query: None,
            settings: settings.get().clone(),
            history: None,
            tasks: runtime.tasks(),
            session: crate::services::active_session::ActiveSession::new(),
            hold: Rc::new(CountingHold::new()),
            close_timeout: Duration::from_secs(1),
        });
        let mut bound = bound_keys(window.upcast_ref());
        bound.extend(bound_keys(browse.upcast_ref()));
        bound.extend(bound_keys(editor.upcast_ref()));
        assert!(
            bound.contains(&parse("<Primary>BackSpace")),
            "the grid's Set NULL key was not found, so the check reads nothing"
        );

        let reserved = APP_ACCELS
            .iter()
            .flat_map(|(_, accels)| accels.iter())
            .chain(std::iter::once(&"<Primary>question"));
        for accel in reserved {
            assert!(
                !bound.contains(&parse(accel)),
                "{accel} is bound in a window or a tab as well as by the application"
            );
        }
        drop(editor);
        runtime.shutdown();
    }

    #[test]
    fn app_accels_name_app_actions() {
        for (action, accels) in APP_ACCELS {
            assert!(action.starts_with("app."), "{action}");
            assert!(!accels.is_empty(), "{action} has no accelerator");
        }
    }
}

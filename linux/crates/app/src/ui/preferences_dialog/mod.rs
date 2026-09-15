mod imp;

use std::rc::Rc;

use gio::prelude::SettingsExtManual;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_storage::AppSettings;
use tablepro_storage::settings::keys;

use crate::ui::style_scheme_grid;

glib::wrapper! {
    pub struct PreferencesDialog(ObjectSubclass<imp::PreferencesDialog>)
        @extends adw::PreferencesDialog, adw::Dialog, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl PreferencesDialog {
    pub fn new(settings: &Rc<AppSettings>) -> Self {
        let dialog: Self = glib::Object::new();
        dialog.imp().settings.replace(Some(settings.clone()));
        dialog.bind(settings);
        dialog.connect_history_actions();
        dialog
    }

    /// Every row binds straight to GSettings, so a change reaches any
    /// other view through `changed::<key>` without a save step.
    fn bind(&self, settings: &Rc<AppSettings>) {
        let imp = self.imp();
        let gio_settings = settings.gio();

        gio_settings
            .bind(keys::DEFAULT_PAGE_SIZE, &imp.page_size_row.get(), "value")
            .build();
        gio_settings
            .bind(keys::CONFIRM_DESTRUCTIVE, &imp.confirm_row.get(), "active")
            .build();
        gio_settings
            .bind(keys::HISTORY_RETENTION_DAYS, &imp.retention_row.get(), "value")
            .build();
        gio_settings
            .bind(keys::QUERY_TIMEOUT_SECS, &imp.timeout_row.get(), "value")
            .build();
        gio_settings
            .bind(keys::USE_SYSTEM_FONT, &imp.system_font_row.get(), "active")
            .build();

        // The font row is only reachable when the system font is off, so
        // the switch drives its sensitivity with the value inverted.
        gio_settings
            .bind(keys::USE_SYSTEM_FONT, &imp.font_row.get(), "sensitive")
            .flags(gio::SettingsBindFlags::GET | gio::SettingsBindFlags::INVERT_BOOLEAN)
            .build();

        gio_settings
            .bind(keys::CUSTOM_FONT, &imp.font_button.get(), "font-desc")
            .mapping(|variant, _| {
                let description = variant.get::<String>()?;
                Some(gtk4::pango::FontDescription::from_string(&description).to_value())
            })
            .set_mapping(|value, _| {
                let description = value.get::<gtk4::pango::FontDescription>().ok()?;
                Some(description.to_str().to_variant())
            })
            .build();

        style_scheme_grid::populate(&imp.style_scheme_box.get(), settings);

        let path = tablepro_storage::query_history::db_path()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|| "$XDG_STATE_HOME/tablepro/history.db".to_owned());
        imp.storage_row.set_subtitle(&path);
        // AdwActionRow ellipsises a long subtitle, so the full path lives
        // in the tooltip.
        imp.storage_row.set_tooltip_text(Some(&path));
    }

    fn connect_history_actions(&self) {
        let imp = self.imp();

        let dialog = self.clone();
        imp.clear_button.connect_clicked(move |_| {
            let alert = adw::AlertDialog::new(
                Some(&crate::tr!("Clear all query history?")),
                Some(&crate::tr!(
                    "This permanently deletes every saved query, including pinned ones."
                )),
            );
            alert.add_response("cancel", &crate::tr!("Cancel"));
            alert.add_response("clear", &crate::tr!("Clear"));
            alert.set_response_appearance("clear", adw::ResponseAppearance::Destructive);
            alert.set_default_response(Some("cancel"));
            alert.set_close_response("cancel");
            alert.connect_response(None, move |alert, response| {
                alert.close();
                if response == "clear" {
                    relm4::spawn(async move {
                        if let Err(error) = tablepro_storage::query_history::clear_all().await {
                            tracing::warn!(%error, "could not clear the query history");
                        }
                    });
                }
            });
            alert.present(Some(&dialog));
        });

        let dialog = self.clone();
        imp.storage_button.connect_clicked(move |_| {
            let Some(path) = tablepro_storage::query_history::db_path() else {
                return;
            };
            let directory = path.parent().map(std::path::Path::to_path_buf).unwrap_or(path);
            let launcher = gtk4::FileLauncher::new(Some(&gio::File::for_path(&directory)));
            let window = dialog.root().and_downcast::<gtk4::Window>();
            launcher.launch(window.as_ref(), gio::Cancellable::NONE, |_| {});
        });
    }
}

#[cfg(test)]
mod tests {
    use tablepro_storage::EditorFont;

    use crate::test_support::MemorySettings;

    use super::*;

    #[gtk4::test]
    fn preferences_dialog_template_builds() {
        let settings = MemorySettings::new();

        let dialog = PreferencesDialog::new(settings.get());
        let imp = dialog.imp();

        assert_eq!(imp.page_size_row.title(), "Default page size");
        assert_eq!(imp.timeout_row.title(), "Query timeout (seconds)");
        assert!(imp.style_scheme_box.first_child().is_some(), "no style scheme previews");
    }

    #[gtk4::test]
    fn preference_rows_are_bound() {
        let settings = MemorySettings::new();
        settings.get().set_default_page_size(500).expect("store the page size");
        settings.get().set_confirm_destructive(false).expect("store the flag");

        let dialog = PreferencesDialog::new(settings.get());
        let imp = dialog.imp();

        assert_eq!(imp.page_size_row.value(), 500.0);
        assert!(!imp.confirm_row.is_active());

        imp.page_size_row.set_value(2_500.0);
        imp.confirm_row.set_active(true);

        assert_eq!(settings.get().default_page_size(), 2_500);
        assert!(settings.get().confirm_destructive());
    }

    #[gtk4::test]
    fn the_font_row_is_insensitive_while_the_system_font_is_on() {
        let settings = MemorySettings::new();

        let dialog = PreferencesDialog::new(settings.get());
        let imp = dialog.imp();

        assert!(!imp.font_row.is_sensitive());

        settings
            .get()
            .set_editor_font(&EditorFont::Custom("Monospace 11".to_owned()))
            .expect("store a custom font");

        assert!(imp.font_row.is_sensitive());
        assert_eq!(
            imp.font_button.font_desc().map(|font| font.to_str().to_string()),
            Some("Monospace 11".to_owned())
        );
    }

    #[gtk4::test]
    fn the_storage_row_names_the_history_database() {
        let settings = MemorySettings::new();

        let dialog = PreferencesDialog::new(settings.get());

        let subtitle = dialog.imp().storage_row.subtitle().unwrap_or_default();
        assert!(subtitle.contains("history.db"), "{subtitle}");
    }
}

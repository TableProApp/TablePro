mod imp;

use std::rc::Rc;

use gio::prelude::SettingsExtManual;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_session::runtime::Tasks;
use tablepro_storage::AppSettings;
use tablepro_storage::settings::keys;

use crate::ui::style_scheme_grid;

glib::wrapper! {
    pub struct PreferencesDialog(ObjectSubclass<imp::PreferencesDialog>)
        @extends adw::PreferencesDialog, adw::Dialog, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl PreferencesDialog {
    pub fn new(
        settings: &Rc<AppSettings>,
        storage: &crate::storage::SharedStorage,
        history: Option<tablepro_storage::QueryHistory>,
        tasks: &Tasks,
    ) -> Self {
        let dialog: Self = glib::Object::new();
        dialog.imp().settings.replace(Some(settings.clone()));
        dialog.bind(settings, storage);
        dialog.connect_history_actions(storage, history, tasks);
        dialog
    }

    /// Every row binds straight to GSettings, so a change reaches any
    /// other view through `changed::<key>` without a save step.
    fn bind(&self, settings: &Rc<AppSettings>, storage: &crate::storage::SharedStorage) {
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

        // The path is known from the configuration even before the
        // database opens, so the row is never blank.
        let path = storage.paths().history_database().display().to_string();
        imp.storage_row.set_subtitle(&path);
        // AdwActionRow ellipsises a long subtitle, so the full path lives
        // in the tooltip.
        imp.storage_row.set_tooltip_text(Some(&path));
    }

    fn connect_history_actions(
        &self,
        storage: &crate::storage::SharedStorage,
        history: Option<tablepro_storage::QueryHistory>,
        tasks: &Tasks,
    ) {
        let imp = self.imp();
        let history_path = storage.paths().history_database();

        // The database opens on a background task, so the button stays
        // insensitive until it is there to clear.
        imp.clear_button.set_sensitive(history.is_some());

        let dialog = self.clone();
        let tasks = tasks.clone();
        let history_for_clear = history;
        imp.clear_button.connect_clicked(move |_| {
            let alert = adw::AlertDialog::new(
                Some(&crate::i18n::gettext("Clear all query history?")),
                Some(&crate::i18n::gettext(
                    "This permanently deletes every saved query, including pinned ones.",
                )),
            );
            alert.add_response("cancel", &crate::i18n::gettext("Cancel"));
            alert.add_response("clear", &crate::i18n::gettext("Clear"));
            alert.set_response_appearance("clear", adw::ResponseAppearance::Destructive);
            alert.set_default_response(Some("cancel"));
            alert.set_close_response("cancel");
            let history_for_clear = history_for_clear.clone();
            let tasks = tasks.clone();
            alert.connect_response(None, move |alert, response| {
                alert.close();
                if response == "clear" {
                    let Some(history) = history_for_clear.clone() else {
                        return;
                    };
                    tasks.spawn_task(async move {
                        if let Err(error) = history.clear_all().await {
                            tracing::warn!(%error, "could not clear the query history");
                        }
                    });
                }
            });
            alert.present(Some(&dialog));
        });

        let dialog = self.clone();
        imp.storage_button.connect_clicked(move |_| {
            let path = history_path.clone();
            let directory = path.parent().map(std::path::Path::to_path_buf).unwrap_or(path);
            let launcher = gtk4::FileLauncher::new(Some(&gio::File::for_path(&directory)));
            let window = dialog.root().and_downcast::<gtk4::Window>();
            launcher.launch(window.as_ref(), gio::Cancellable::NONE, |_| {});
        });
    }
}

#[cfg(test)]
mod tests {
    use tablepro_storage::{EditorFont, StoragePaths};

    use crate::test_support::{MemorySettings, test_runtime};

    use super::*;

    fn test_storage() -> crate::storage::SharedStorage {
        // A temporary root keeps the dialog's storage row and history
        // actions away from the developer's own files.
        let root = std::env::temp_dir().join(format!("tablepro-prefs-{}", std::process::id()));
        let paths = StoragePaths::under(&root, "tablepro-test", "app.tablepro.TablePro.Devel");
        Rc::new(crate::storage::AppStorage::new(
            paths,
            std::sync::Arc::new(tablepro_storage::SecretStore::new(crate::config::secret_schema())),
        ))
    }

    #[gtk4::test]
    fn preferences_dialog_template_builds() {
        let settings = MemorySettings::new();

        let storage = test_storage();
        let runtime = test_runtime();
        let dialog = PreferencesDialog::new(settings.get(), &storage, None, &runtime.tasks());
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

        let storage = test_storage();
        let runtime = test_runtime();
        let dialog = PreferencesDialog::new(settings.get(), &storage, None, &runtime.tasks());
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

        let storage = test_storage();
        let runtime = test_runtime();
        let dialog = PreferencesDialog::new(settings.get(), &storage, None, &runtime.tasks());
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

        let storage = test_storage();
        let runtime = test_runtime();
        let dialog = PreferencesDialog::new(settings.get(), &storage, None, &runtime.tasks());

        let subtitle = dialog.imp().storage_row.subtitle().unwrap_or_default();
        assert!(subtitle.contains("history.db"), "{subtitle}");
    }
}

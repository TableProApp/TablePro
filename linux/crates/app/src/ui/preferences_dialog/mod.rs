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
            let dialog_for_toast = dialog.clone();
            // AdwAlertDialog closes itself before it emits, so there is
            // no close to do here.
            alert.connect_response(None, move |_, response| {
                if response != "clear" {
                    return;
                }
                let Some(history) = history_for_clear.clone() else {
                    return;
                };
                let clearing = tasks.spawn_task(async move { history.clear_all().await });
                let dialog = dialog_for_toast.clone();
                // A destructive action that reports nothing leaves the
                // user guessing whether it ran.
                glib::spawn_future_local(async move {
                    let message = match clearing.await {
                        Ok(Ok(removed)) => crate::i18n::ngettext_f(
                            "{count} query cleared",
                            "{count} queries cleared",
                            removed as u32,
                            &[("count", &removed.to_string())],
                        ),
                        Ok(Err(error)) => {
                            tracing::warn!(%error, "could not clear the query history");
                            crate::i18n::gettext("The query history could not be cleared.")
                        }
                        Err(failure) => {
                            tracing::warn!(%failure, "the clear-history task failed");
                            crate::i18n::gettext("The query history could not be cleared.")
                        }
                    };
                    dialog.add_toast(adw::Toast::new(&message));
                });
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

    /// The template lives in the embedded resources, so a test that
    /// builds the dialog has to register them first. Test order is not
    /// fixed, so it cannot rely on another test having done it.
    fn new_dialog(
        settings: &MemorySettings,
        storage: &crate::storage::SharedStorage,
        history: Option<tablepro_storage::QueryHistory>,
        tasks: &Tasks,
    ) -> PreferencesDialog {
        crate::register_test_resources();
        PreferencesDialog::new(settings.get(), storage, history, tasks)
    }

    fn test_storage(tasks: &Tasks) -> crate::storage::SharedStorage {
        // A temporary root keeps the dialog's storage row and history
        // actions away from the developer's own files.
        let root = std::env::temp_dir().join(format!("tablepro-prefs-{}", std::process::id()));
        let paths = StoragePaths::under(&root, "tablepro-test", "app.tablepro.TablePro.Devel");
        Rc::new(crate::storage::AppStorage::new(
            paths,
            std::sync::Arc::new(tablepro_storage::SecretStore::new(crate::config::secret_schema())),
            tasks,
        ))
    }

    #[gtk4::test]
    fn preferences_dialog_template_builds() {
        let settings = MemorySettings::new();

        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let dialog = new_dialog(&settings, &storage, None, &runtime.tasks());
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

        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let dialog = new_dialog(&settings, &storage, None, &runtime.tasks());
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

        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let dialog = new_dialog(&settings, &storage, None, &runtime.tasks());
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

        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let dialog = new_dialog(&settings, &storage, None, &runtime.tasks());

        let subtitle = dialog.imp().storage_row.subtitle().unwrap_or_default();
        assert!(subtitle.contains("history.db"), "{subtitle}");
    }

    #[gtk4::test]
    fn clear_history_is_insensitive_until_the_database_opens() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());

        let starting = new_dialog(&settings, &storage, None, &runtime.tasks());

        assert!(
            !starting.imp().clear_button.is_sensitive(),
            "Clear offered to clear a database that is not open"
        );
    }

    #[gtk4::test]
    fn clear_history_shows_toast_and_empties_store() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let paths = StoragePaths::under(root.path(), "tablepro-test", "app.tablepro.TablePro.Devel");
        let history = open_history(&runtime, &paths);
        record_one(&runtime, &history);
        assert_eq!(count(&runtime, &history), 1);

        let dialog = new_dialog(&settings, &storage, Some(history.clone()), &runtime.tasks());
        assert!(dialog.imp().clear_button.is_sensitive());
        let window = present_on_a_window(&dialog);
        dialog.imp().clear_button.emit_clicked();
        confirm_the_alert(&window);

        // The toast is posted once the clear has finished, so it is
        // the signal to wait on. Waiting on the row count instead ran
        // a database query on every spin of the main loop, and on a
        // loaded machine the budget went on that polling rather than
        // on the work, which failed the test for being busy.
        crate::test_support::wait_until(WAIT, || toast_text(&window).is_some())
            .unwrap_or_else(|_| panic!("clearing said nothing, and left {} entries", count(&runtime, &history)));

        let toast = toast_text(&window).unwrap_or_default();
        assert!(toast.contains("cleared"), "{toast}");
        assert_eq!(
            count(&runtime, &history),
            0,
            "the toast said the history was cleared while its rows were still there"
        );
        drop(window);
    }

    /// How long a test waits for work that crosses a thread. Long
    /// enough that a loaded machine cannot decide the outcome; a
    /// passing test returns as soon as its condition holds and never
    /// spends it.
    const WAIT: std::time::Duration = std::time::Duration::from_secs(30);

    /// An AdwDialog needs a real window to present into before its
    /// toast overlay renders anything.
    fn present_on_a_window(dialog: &PreferencesDialog) -> adw::Window {
        let window = adw::Window::new();
        window.present();
        dialog.present(Some(&window));
        crate::test_support::wait_until(WAIT, || dialog.imp().clear_button.is_mapped())
            .expect("the dialog never appeared");
        window
    }

    /// What the dialog's toast says, read off the label the overlay
    /// renders. AdwPreferencesDialog owns the overlay itself and does
    /// not hand it out.
    fn toast_text(window: &adw::Window) -> Option<String> {
        crate::test_support::drain_main_context();
        crate::test_support::descendants(window)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk4::Label>().ok())
            .map(|label| label.label().to_string())
            .find(|text| text.contains("cleared") || text.contains("could not be cleared"))
    }

    fn open_history(runtime: &crate::runtime::AppRuntime, paths: &StoragePaths) -> tablepro_storage::QueryHistory {
        block_on(runtime, tablepro_storage::QueryHistory::open(paths)).expect("open the history")
    }

    fn record_one(runtime: &crate::runtime::AppRuntime, history: &tablepro_storage::QueryHistory) {
        let entry = tablepro_storage::query_history::NewEntry {
            query: "SELECT 1".to_owned(),
            driver_id: "postgres".to_owned(),
            connection_id: uuid::Uuid::new_v4(),
            connection_name: "local".to_owned(),
            executed_at: std::time::SystemTime::now(),
            duration_ms: Some(1),
            rows_affected: Some(0),
            outcome: tablepro_storage::query_history::Outcome::Success,
        };
        block_on(runtime, history.record(entry)).expect("record");
    }

    fn count(runtime: &crate::runtime::AppRuntime, history: &tablepro_storage::QueryHistory) -> usize {
        block_on(
            runtime,
            history.search(tablepro_storage::query_history::SearchFilter {
                limit: 100,
                ..Default::default()
            }),
        )
        .expect("search")
        .len()
    }

    /// The test drives the runtime from outside it, which is the one
    /// place blocking on it cannot deadlock.
    #[expect(
        clippy::disallowed_methods,
        reason = "a GTK test has no runtime of its own, so it drives the app's from outside"
    )]
    fn block_on<F: std::future::Future>(runtime: &crate::runtime::AppRuntime, future: F) -> F::Output {
        runtime.tasks().handle().block_on(future)
    }

    /// Press Clear on the confirmation alert the button raised. The
    /// alert presents into the window's dialog host, not into the
    /// preferences dialog, so that is where it is.
    fn confirm_the_alert(window: &adw::Window) {
        crate::test_support::drain_main_context();
        let alert =
            crate::test_support::first_descendant_of_type::<adw::AlertDialog>(window).expect("the confirmation alert");
        alert.emit_by_name::<()>("response", &[&"clear"]);
        crate::test_support::drain_main_context();
    }
}

mod data_browser_group;
mod editor_page;
mod general_page;
mod history_group;
mod imp;

use std::rc::Rc;

use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_session::runtime::Tasks;
use tablepro_storage::AppSettings;

use crate::ui::file_reveal::FileRevealer;

#[cfg(test)]
pub(super) use self::{
    data_browser_group::DataBrowserGroup, editor_page::EditorPage, general_page::GeneralPage,
    history_group::HistoryGroup,
};

glib::wrapper! {
    pub struct PreferencesDialog(ObjectSubclass<imp::PreferencesDialog>)
        @extends adw::PreferencesDialog, adw::Dialog, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl PreferencesDialog {
    /// Every row binds straight to GSettings, so a change reaches any
    /// other view through `changed::<key>` without a save step.
    pub(crate) fn new(
        settings: &Rc<AppSettings>,
        storage: &crate::storage::SharedStorage,
        history: Option<tablepro_storage::QueryHistory>,
        tasks: &Tasks,
        revealer: Rc<dyn FileRevealer>,
    ) -> Self {
        let dialog: Self = glib::Object::new();
        let imp = dialog.imp();
        imp.settings.replace(Some(settings.clone()));
        imp.general_page.bind(settings, storage, history, tasks, revealer);
        imp.editor_page.bind(settings);
        let shown_in = dialog.downgrade();
        imp.general_page.history_group().connect_toast(move |_, toast| {
            if let Some(dialog) = shown_in.upgrade() {
                dialog.add_toast(toast.clone());
            }
        });
        dialog
    }
}

/// A storage under a temporary root, so the dialog's storage row and
/// history actions stay away from the developer's own files.
#[cfg(test)]
fn test_storage(tasks: &Tasks) -> crate::storage::SharedStorage {
    let root = std::env::temp_dir().join(format!("tablepro-prefs-{}", std::process::id()));
    let paths = tablepro_storage::StoragePaths::under(&root, "tablepro-test", "app.tablepro.TablePro.Devel");
    Rc::new(crate::storage::AppStorage::new(
        paths,
        std::sync::Arc::new(tablepro_storage::SecretStore::new(crate::config::secret_schema())),
        tasks,
    ))
}

#[cfg(test)]
mod tests {
    use tablepro_storage::StoragePaths;

    use super::*;
    use crate::test_support::{MemorySettings, assert_labelled, descendants, test_runtime, unlabelled_icon_buttons};
    use crate::ui::file_reveal::RecordingRevealer;

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
        PreferencesDialog::new(
            settings.get(),
            storage,
            history,
            tasks,
            Rc::new(RecordingRevealer::succeeding()),
        )
    }

    /// The dialog's pages, in the order it shows them. They are not in
    /// its widget tree until it is presented, so they come from the
    /// template.
    fn pages(dialog: &PreferencesDialog) -> [adw::PreferencesPage; 2] {
        let imp = dialog.imp();
        [imp.general_page.get().upcast(), imp.editor_page.get().upcast()]
    }

    #[gtk4::test]
    fn preferences_dialog_template_builds() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let dialog = new_dialog(&settings, &storage, None, &runtime.tasks());
        let [general, editor] = pages(&dialog);

        assert_eq!(general.title(), "General");
        assert_eq!(editor.title(), "Editor");
        assert_eq!(dialog.visible_page().as_ref(), Some(&general));
        dialog.set_visible_page(&editor);
        assert_eq!(
            dialog.visible_page().as_ref(),
            Some(&editor),
            "the Editor page is not in the dialog"
        );
    }

    #[gtk4::test]
    fn every_preferences_page_audits_clean() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let dialog = new_dialog(&settings, &storage, None, &runtime.tasks());

        for page in pages(&dialog) {
            let rows: Vec<adw::PreferencesRow> = descendants(&page)
                .into_iter()
                .filter_map(|widget| widget.downcast::<adw::PreferencesRow>().ok())
                .collect();
            assert!(!rows.is_empty(), "{} has no rows", page.title());
            for row in rows {
                assert_labelled(&row).unwrap_or_else(|problem| panic!("{}: {problem}", page.title()));
            }
            for group in descendants(&page)
                .into_iter()
                .filter_map(|widget| widget.downcast::<adw::PreferencesGroup>().ok())
            {
                assert!(!group.title().is_empty(), "{} has a group with no title", page.title());
            }
            assert_eq!(unlabelled_icon_buttons(&page), Vec::<String>::new(), "{}", page.title());
        }
    }

    #[gtk4::test]
    fn the_dialog_is_freed_once_dropped() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let dialog = new_dialog(&settings, &storage, None, &runtime.tasks());
        let history_group = dialog.imp().general_page.history_group().downgrade();
        let freed = dialog.downgrade();

        drop(dialog);
        crate::test_support::drain_main_context();

        assert!(freed.upgrade().is_none(), "the dialog outlived its last reference");
        assert!(
            history_group.upgrade().is_none(),
            "the history group outlived its dialog"
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
        assert!(clear_button(&dialog).is_sensitive());
        let window = present_on_a_window(&dialog);
        clear_button(&dialog).emit_clicked();
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

    fn clear_button(dialog: &PreferencesDialog) -> gtk4::Button {
        dialog.imp().general_page.history_group().imp().clear_button.get()
    }

    /// How long a test waits for work that crosses a thread. Long
    /// enough that a loaded machine cannot decide the outcome; a
    /// passing test returns as soon as its condition holds and never
    /// spends it.
    const WAIT: std::time::Duration = std::time::Duration::from_secs(30);

    /// An AdwDialog needs a real window to present into before its
    /// toast overlay renders anything.
    fn present_on_a_window(dialog: &PreferencesDialog) -> crate::test_support::OwnedWindow<adw::Window> {
        let window = crate::test_support::OwnedWindow::presented(adw::Window::new());
        dialog.present(Some(&*window));
        crate::test_support::wait_until(WAIT, || clear_button(dialog).is_mapped()).expect("the dialog never appeared");
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
            history.search_page(
                &tablepro_storage::query_history::HistoryQuery::default(),
                tablepro_storage::query_history::HistoryPageRequest::first(100),
            ),
        )
        .expect("search")
        .entries
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
        crate::test_support::respond(&alert, "clear");
        crate::test_support::drain_main_context();
    }
}

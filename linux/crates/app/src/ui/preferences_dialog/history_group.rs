use std::rc::Rc;
use std::sync::OnceLock;

use gio::prelude::SettingsExtManual;
use glib::subclass::Signal;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_session::runtime::Tasks;
use tablepro_storage::AppSettings;
use tablepro_storage::settings::keys;
use tokio::sync::watch;

use crate::services::history_availability::HistoryAvailability;
use crate::services::history_service::HistoryService;
use crate::ui::file_reveal::{FileRevealer, reveal_failure_toast};

mod imp {
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/preferences-history-group.ui")]
    pub struct HistoryGroup {
        /// Follows whether the query database opened, for as long as
        /// the group is shown.
        pub availability: std::cell::RefCell<Option<glib::JoinHandle<()>>>,
        #[template_child]
        pub save_history_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub retention_row: TemplateChild<adw::SpinRow>,
        #[template_child]
        pub clear_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub clear_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub storage_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub storage_button: TemplateChild<gtk4::Button>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for HistoryGroup {
        const NAME: &'static str = "TableProHistoryGroup";
        type Type = super::HistoryGroup;
        type ParentType = adw::PreferencesGroup;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for HistoryGroup {
        fn dispose(&self) {
            if let Some(watch) = self.availability.take() {
                watch.abort();
            }
        }

        fn signals() -> &'static [Signal] {
            static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| {
                vec![
                    Signal::builder("toast")
                        .param_types([adw::Toast::static_type()])
                        .build(),
                ]
            })
        }
    }

    impl WidgetImpl for HistoryGroup {}
    impl PreferencesGroupImpl for HistoryGroup {}
}

glib::wrapper! {
    /// The General page's query history rows: whether to record, how
    /// long to keep it, clearing it, and where the database is.
    pub struct HistoryGroup(ObjectSubclass<imp::HistoryGroup>)
        @extends adw::PreferencesGroup, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for HistoryGroup {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl HistoryGroup {
    pub(super) fn bind(
        &self,
        settings: &AppSettings,
        storage: &crate::storage::SharedStorage,
        history: HistoryService,
        tasks: &Tasks,
        revealer: Rc<dyn FileRevealer>,
    ) {
        let imp = self.imp();
        let gio_settings = settings.gio();
        // Off stops new records only; Clear is what removes the old ones.
        gio_settings
            .bind(keys::SAVE_QUERY_HISTORY, &imp.save_history_row.get(), "active")
            .build();
        gio_settings
            .bind(keys::HISTORY_RETENTION_DAYS, &imp.retention_row.get(), "value")
            .build();

        // The path is known from the configuration even before the
        // database opens, so the row is never blank.
        let history_path = storage.paths().history_database();
        let path = history_path.display().to_string();
        imp.storage_row.set_subtitle(&path);
        // AdwActionRow ellipsises a long subtitle, so the full path lives
        // in the tooltip.
        imp.storage_row.set_tooltip_text(Some(&path));

        let group = self.downgrade();
        let tasks = tasks.clone();
        let service = history.clone();
        imp.clear_button.connect_clicked(move |_| {
            if let (Some(group), Some(store)) = (group.upgrade(), service.store()) {
                group.confirm_clear(store, &tasks);
            }
        });
        self.follow_availability(history.availability());

        let group = self.downgrade();
        imp.storage_button.connect_clicked(move |_| {
            if let Some(group) = group.upgrade() {
                group.show_in_files(&history_path, revealer.as_ref());
            }
        });
    }

    /// AdwPreferencesDialog owns the toast overlay, so the group hands
    /// its toasts up rather than looking for one.
    pub(super) fn connect_toast<F: Fn(&Self, &adw::Toast) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "toast",
            false,
            glib::closure_local!(move |group: &Self, toast: adw::Toast| f(group, &toast)),
        )
    }

    /// The database opens on a background task: Clear waits for it, and
    /// a database that could not open says why where the group starts.
    fn follow_availability(&self, mut availability: watch::Receiver<HistoryAvailability>) {
        let group = self.downgrade();
        let following = glib::spawn_future_local(async move {
            loop {
                let state = availability.borrow_and_update().clone();
                let Some(group) = group.upgrade() else {
                    return;
                };
                group.show_availability(&state);
                drop(group);
                if availability.changed().await.is_err() {
                    return;
                }
            }
        });
        if let Some(previous) = self.imp().availability.replace(Some(following)) {
            previous.abort();
        }
    }

    fn show_availability(&self, state: &HistoryAvailability) {
        self.imp().clear_button.set_sensitive(state.is_ready());
        let reason = state.failure().map(|reason| {
            crate::i18n::gettext_f(
                "Query history and saved queries cannot be used. {reason}",
                &[("reason", reason)],
            )
        });
        self.set_description(reason.as_deref());
    }

    fn confirm_clear(&self, history: tablepro_storage::QueryHistory, tasks: &Tasks) {
        let alert = adw::AlertDialog::new(
            Some(&crate::i18n::gettext("Clear All Query History?")),
            Some(&crate::i18n::gettext(
                "This permanently deletes every saved query, including pinned ones.",
            )),
        );
        alert.add_response("cancel", &crate::i18n::gettext("Cancel"));
        alert.add_response("clear", &crate::i18n::gettext("Clear"));
        alert.set_response_appearance("clear", adw::ResponseAppearance::Destructive);
        alert.set_default_response(Some("cancel"));
        alert.set_close_response("cancel");
        let group = self.clone();
        let tasks = tasks.clone();
        // AdwAlertDialog closes itself before it emits, so there is
        // no close to do here.
        alert.connect_response(None, move |_, response| {
            if response != "clear" {
                return;
            }
            let history = history.clone();
            let clearing = tasks.spawn_task(async move { history.clear_all().await });
            let group = group.clone();
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
                group.emit_by_name::<()>("toast", &[&crate::ui::plain_toast(&message)]);
            });
        });
        alert.present(Some(self));
    }

    fn show_in_files(&self, history_path: &std::path::Path, revealer: &dyn FileRevealer) {
        let revealing = revealer.reveal(gio::File::for_path(history_path), self.root().and_downcast());
        let group = self.downgrade();
        glib::spawn_future_local(async move {
            let revealed = revealing.await;
            if let (Some(toast), Some(group)) = (reveal_failure_toast(&revealed), group.upgrade()) {
                group.emit_by_name::<()>("toast", &[&toast]);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use crate::test_support::{MemorySettings, SignalLog, drain_main_context, test_runtime, wait_until};
    use crate::ui::file_reveal::RecordingRevealer;

    use super::super::test_storage;
    use super::*;

    fn bound_group(
        settings: &MemorySettings,
        storage: &crate::storage::SharedStorage,
        root: &tempfile::TempDir,
        tasks: &Tasks,
        revealer: Rc<RecordingRevealer>,
    ) -> HistoryGroup {
        crate::register_test_resources();
        let group = HistoryGroup::default();
        group.bind(
            settings.get(),
            storage,
            super::super::test_history(root, tasks),
            tasks,
            revealer,
        );
        group
    }

    #[gtk4::test]
    fn preferences_history_switch_bound_to_setting() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let group = bound_group(
            &settings,
            &storage,
            &root,
            &runtime.tasks(),
            Rc::new(RecordingRevealer::succeeding()),
        );
        let row = group.imp().save_history_row.get();
        assert!(row.is_active(), "the row does not show the default");

        row.set_active(false);
        assert!(!settings.get().save_query_history());

        settings.get().set_save_query_history(true).expect("store the flag");
        assert!(row.is_active());
    }

    #[gtk4::test]
    fn the_storage_row_names_the_history_database() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let group = bound_group(
            &settings,
            &storage,
            &root,
            &runtime.tasks(),
            Rc::new(RecordingRevealer::succeeding()),
        );

        let subtitle = group.imp().storage_row.subtitle().unwrap_or_default();
        assert!(subtitle.contains("history.db"), "{subtitle}");
    }

    #[gtk4::test]
    fn preferences_show_in_files_reveals_the_database_file_not_its_folder() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let revealer = Rc::new(RecordingRevealer::succeeding());
        let root = tempfile::tempdir().expect("tempdir");
        let group = bound_group(&settings, &storage, &root, &runtime.tasks(), revealer.clone());

        group.imp().storage_button.emit_clicked();

        assert_eq!(revealer.revealed(), [storage.paths().history_database()]);
    }

    #[gtk4::test]
    fn a_failed_reveal_is_reported_as_a_toast() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let group = bound_group(
            &settings,
            &storage,
            &root,
            &runtime.tasks(),
            Rc::new(RecordingRevealer::failing()),
        );
        let toasts = SignalLog::connect(&group, "toast", |values| {
            values[1]
                .get::<adw::Toast>()
                .ok()
                .and_then(|toast| toast.title())
                .map(|title| title.to_string())
        });

        group.imp().storage_button.emit_clicked();
        wait_until(std::time::Duration::from_secs(5), || toasts.count() > 0).expect("the failure toast");

        assert_eq!(toasts.take(), [Some("Could not show the file in Files".to_owned())]);
    }

    #[gtk4::test]
    fn a_shown_file_raises_no_toast() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let group = bound_group(
            &settings,
            &storage,
            &root,
            &runtime.tasks(),
            Rc::new(RecordingRevealer::succeeding()),
        );
        let toasts = SignalLog::connect(&group, "toast", |_| ());

        group.imp().storage_button.emit_clicked();
        drain_main_context();

        assert_eq!(toasts.count(), 0);
    }

    #[gtk4::test]
    fn clear_follows_the_database_and_a_failure_says_why() {
        crate::register_test_resources();
        let group = HistoryGroup::default();
        let (state, availability) = watch::channel(HistoryAvailability::Starting);
        group.follow_availability(availability);
        let clear = group.imp().clear_button.get();
        drain_main_context();
        assert!(
            !clear.is_sensitive(),
            "Clear offered to clear a database that is not open"
        );
        assert!(group.description().unwrap_or_default().is_empty());

        state.send_replace(HistoryAvailability::Ready);
        drain_main_context();
        assert!(clear.is_sensitive(), "Clear stayed off after the database opened");

        state.send_replace(HistoryAvailability::Failed(
            "The disk that holds history.db is full.".to_owned(),
        ));
        drain_main_context();
        assert!(!clear.is_sensitive());
        assert_eq!(
            group.description().as_deref(),
            Some("Query history and saved queries cannot be used. The disk that holds history.db is full.")
        );
    }
}

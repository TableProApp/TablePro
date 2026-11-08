use std::rc::Rc;

use gio::prelude::SettingsExtManual;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_linux_platform::AppSettings;
use tablepro_linux_platform::settings::keys;
use tablepro_session::runtime::Tasks;

use super::history_group::HistoryGroup;
use crate::ui::file_reveal::FileRevealer;

mod imp {
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/preferences-general-page.ui")]
    pub struct GeneralPage {
        #[template_child]
        pub restore_session_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub history_group: TemplateChild<HistoryGroup>,
        #[template_child]
        pub privacy_group: TemplateChild<adw::PreferencesGroup>,
        #[template_child]
        pub share_usage_data_row: TemplateChild<adw::SwitchRow>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for GeneralPage {
        const NAME: &'static str = "TableProGeneralPage";
        type Type = super::GeneralPage;
        type ParentType = adw::PreferencesPage;

        fn class_init(klass: &mut Self::Class) {
            HistoryGroup::ensure_type();
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for GeneralPage {}
    impl WidgetImpl for GeneralPage {}
    impl PreferencesPageImpl for GeneralPage {}
}

glib::wrapper! {
    pub struct GeneralPage(ObjectSubclass<imp::GeneralPage>)
        @extends adw::PreferencesPage, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for GeneralPage {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl GeneralPage {
    // A build without the analytics secret sends nothing, so it shows no switch that would stop it.
    pub(super) fn bind(
        &self,
        settings: &Rc<AppSettings>,
        storage: &crate::storage::SharedStorage,
        history: crate::services::history_service::HistoryService,
        tasks: &Tasks,
        revealer: Rc<dyn FileRevealer>,
        can_share_usage_data: bool,
    ) {
        let imp = self.imp();
        settings
            .gio()
            .bind(keys::RESTORE_SESSION, &imp.restore_session_row.get(), "active")
            .build();
        imp.privacy_group.set_visible(can_share_usage_data);
        settings
            .gio()
            .bind(keys::SHARE_USAGE_DATA, &imp.share_usage_data_row.get(), "active")
            .build();
        imp.history_group.bind(settings, storage, history, tasks, revealer);
    }

    pub(super) fn history_group(&self) -> HistoryGroup {
        self.imp().history_group.get()
    }
}

#[cfg(test)]
mod tests {
    use libadwaita::prelude::*;

    use super::super::test_storage;
    use super::*;
    use crate::test_support::{MemorySettings, test_runtime};
    use crate::ui::file_reveal::RecordingRevealer;

    fn bound_page(
        settings: &MemorySettings,
        storage: &crate::storage::SharedStorage,
        root: &tempfile::TempDir,
        tasks: &Tasks,
    ) -> GeneralPage {
        page_with_usage_data(settings, storage, root, tasks, false)
    }

    fn page_with_usage_data(
        settings: &MemorySettings,
        storage: &crate::storage::SharedStorage,
        root: &tempfile::TempDir,
        tasks: &Tasks,
        can_share_usage_data: bool,
    ) -> GeneralPage {
        crate::register_test_resources();
        let page = GeneralPage::default();
        page.bind(
            settings.get(),
            storage,
            super::super::test_history(root, tasks),
            tasks,
            Rc::new(RecordingRevealer::succeeding()),
            can_share_usage_data,
        );
        page
    }

    fn groups(page: &GeneralPage) -> Vec<adw::PreferencesGroup> {
        crate::test_support::descendants(page)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::PreferencesGroup>().ok())
            .filter(WidgetExt::is_visible)
            .collect()
    }

    #[gtk4::test]
    fn usage_data_is_on_by_default_and_the_switch_turns_it_off() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let page = page_with_usage_data(&settings, &storage, &root, &runtime.tasks(), true);
        let row = page.imp().share_usage_data_row.get();
        let titles: Vec<String> = groups(&page).iter().map(|group| group.title().to_string()).collect();

        let by_default = (row.is_active(), settings.get().share_usage_data());
        row.set_active(false);

        assert_eq!(titles.last().map(String::as_str), Some("Privacy"));
        assert_eq!(by_default, (true, true));
        assert!(!settings.get().share_usage_data());
        assert_eq!(row.title(), "Share Usage Data");
        assert_eq!(
            row.subtitle().as_deref(),
            Some("Help improve TablePro with app activity and system information")
        );
    }

    #[gtk4::test]
    fn a_build_without_the_secret_shows_no_privacy_switch() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");

        let page = bound_page(&settings, &storage, &root, &runtime.tasks());

        let titles: Vec<String> = groups(&page).iter().map(|group| group.title().to_string()).collect();
        assert_eq!(titles, ["Startup", "Query History"]);
    }

    #[gtk4::test]
    fn general_page_contains_startup_and_history_groups() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let page = bound_page(&settings, &storage, &root, &runtime.tasks());

        let groups = groups(&page);
        let titles: Vec<String> = groups.iter().map(|group| group.title().to_string()).collect();

        assert_eq!(page.title(), "General");
        assert_eq!(titles, ["Startup", "Query History"]);
        assert!(groups[1].is::<HistoryGroup>());
    }

    #[gtk4::test]
    fn the_restore_session_row_is_bound() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let page = bound_page(&settings, &storage, &root, &runtime.tasks());
        let row = page.imp().restore_session_row.get();
        assert!(row.is_active(), "the row does not show the default");

        row.set_active(false);
        assert!(!settings.get().restore_session());

        settings.get().set_restore_session(true).expect("store the flag");
        assert!(row.is_active());
    }

    #[gtk4::test]
    fn the_page_binds_its_history_group() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let page = bound_page(&settings, &storage, &root, &runtime.tasks());
        let imp = page.imp();

        imp.history_group.imp().save_history_row.set_active(false);

        assert!(!settings.get().save_query_history());
    }
}

use std::rc::Rc;

use gio::prelude::SettingsExtManual;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_session::runtime::Tasks;
use tablepro_storage::AppSettings;
use tablepro_storage::settings::keys;

use super::data_browser_group::DataBrowserGroup;
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
        pub data_browser_group: TemplateChild<DataBrowserGroup>,
        #[template_child]
        pub history_group: TemplateChild<HistoryGroup>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for GeneralPage {
        const NAME: &'static str = "TableProGeneralPage";
        type Type = super::GeneralPage;
        type ParentType = adw::PreferencesPage;

        fn class_init(klass: &mut Self::Class) {
            DataBrowserGroup::ensure_type();
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
    /// The General page: startup, the data browser and the query history.
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
    pub(super) fn bind(
        &self,
        settings: &Rc<AppSettings>,
        storage: &crate::storage::SharedStorage,
        history: crate::services::history_service::HistoryService,
        tasks: &Tasks,
        revealer: Rc<dyn FileRevealer>,
    ) {
        let imp = self.imp();
        settings
            .gio()
            .bind(keys::RESTORE_SESSION, &imp.restore_session_row.get(), "active")
            .build();
        imp.data_browser_group.bind(settings);
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
        crate::register_test_resources();
        let page = GeneralPage::default();
        page.bind(
            settings.get(),
            storage,
            super::super::test_history(root, tasks),
            tasks,
            Rc::new(RecordingRevealer::succeeding()),
        );
        page
    }

    /// The page's groups, in the order it shows them.
    fn groups(page: &GeneralPage) -> Vec<adw::PreferencesGroup> {
        crate::test_support::descendants(page)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::PreferencesGroup>().ok())
            .collect()
    }

    #[gtk4::test]
    fn general_page_contains_the_data_browser_and_history_groups() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let page = bound_page(&settings, &storage, &root, &runtime.tasks());

        let groups = groups(&page);
        let titles: Vec<String> = groups.iter().map(|group| group.title().to_string()).collect();

        assert_eq!(page.title(), "General");
        assert_eq!(titles, ["Startup", "Data Browser", "Query History"]);
        assert!(groups[1].is::<DataBrowserGroup>());
        assert!(groups[2].is::<HistoryGroup>());
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
    fn the_page_binds_both_of_its_groups() {
        let settings = MemorySettings::new();
        let runtime = test_runtime();
        let storage = test_storage(&runtime.tasks());
        let root = tempfile::tempdir().expect("tempdir");
        let page = bound_page(&settings, &storage, &root, &runtime.tasks());
        let imp = page.imp();

        imp.data_browser_group.imp().confirm_row.set_active(false);
        imp.history_group.imp().save_history_row.set_active(false);

        assert!(!settings.get().confirm_bulk_delete());
        assert!(!settings.get().save_query_history());
    }
}

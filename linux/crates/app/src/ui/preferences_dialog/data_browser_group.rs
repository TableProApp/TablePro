use gio::prelude::SettingsExtManual;
use gtk4::glib;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_storage::AppSettings;
use tablepro_storage::settings::keys;

mod imp {
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/preferences-data-browser-group.ui")]
    pub struct DataBrowserGroup {
        #[template_child]
        pub page_size_row: TemplateChild<adw::SpinRow>,
        #[template_child]
        pub confirm_row: TemplateChild<adw::SwitchRow>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for DataBrowserGroup {
        const NAME: &'static str = "TableProDataBrowserGroup";
        type Type = super::DataBrowserGroup;
        type ParentType = adw::PreferencesGroup;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for DataBrowserGroup {}
    impl WidgetImpl for DataBrowserGroup {}
    impl PreferencesGroupImpl for DataBrowserGroup {}
}

glib::wrapper! {
    /// The General page's rows for the row paginator and the delete
    /// confirmation.
    pub struct DataBrowserGroup(ObjectSubclass<imp::DataBrowserGroup>)
        @extends adw::PreferencesGroup, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for DataBrowserGroup {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl DataBrowserGroup {
    pub(super) fn bind(&self, settings: &AppSettings) {
        let imp = self.imp();
        let gio_settings = settings.gio();
        gio_settings
            .bind(keys::DEFAULT_PAGE_SIZE, &imp.page_size_row.get(), "value")
            .build();
        gio_settings
            .bind(keys::CONFIRM_DESTRUCTIVE, &imp.confirm_row.get(), "active")
            .build();
    }
}

#[cfg(test)]
mod tests {
    use libadwaita::prelude::*;

    use super::*;
    use crate::test_support::MemorySettings;

    fn bound_group(settings: &MemorySettings) -> DataBrowserGroup {
        crate::register_test_resources();
        let group = DataBrowserGroup::default();
        group.bind(settings.get());
        group
    }

    #[gtk4::test]
    fn preference_rows_are_bound() {
        let settings = MemorySettings::new();
        settings.get().set_default_page_size(500).expect("store the page size");
        settings.get().set_confirm_destructive(false).expect("store the flag");

        let group = bound_group(&settings);
        let imp = group.imp();

        assert_eq!(imp.page_size_row.value(), 500.0);
        assert!(!imp.confirm_row.is_active());

        imp.page_size_row.set_value(2_500.0);
        imp.confirm_row.set_active(true);

        assert_eq!(settings.get().default_page_size(), 2_500);
        assert!(settings.get().confirm_destructive());
    }

    #[gtk4::test]
    fn the_group_is_titled_for_the_data_browser() {
        let settings = MemorySettings::new();
        let group = bound_group(&settings);

        assert_eq!(group.title(), "Data Browser");
        assert_eq!(group.imp().page_size_row.title(), "Default page size");
    }
}

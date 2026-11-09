use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_linux_platform::AppSettings;

use super::data_browser_group::DataBrowserGroup;

mod imp {
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/preferences-grid-page.ui")]
    pub struct GridPage {
        #[template_child]
        pub data_browser_group: TemplateChild<DataBrowserGroup>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for GridPage {
        const NAME: &'static str = "TableProGridPage";
        type Type = super::GridPage;
        type ParentType = adw::PreferencesPage;

        fn class_init(klass: &mut Self::Class) {
            DataBrowserGroup::ensure_type();
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for GridPage {}
    impl WidgetImpl for GridPage {}
    impl PreferencesPageImpl for GridPage {}
}

glib::wrapper! {
    pub struct GridPage(ObjectSubclass<imp::GridPage>)
        @extends adw::PreferencesPage, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for GridPage {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl GridPage {
    pub(super) fn bind(&self, settings: &AppSettings) {
        self.imp().data_browser_group.bind(settings);
    }
}

#[cfg(test)]
mod tests {
    use libadwaita::prelude::*;

    use super::*;
    use crate::test_support::MemorySettings;

    #[gtk4::test]
    fn the_grid_page_binds_its_data_browser_group() {
        crate::register_test_resources();
        let settings = MemorySettings::new();
        let page = GridPage::default();
        page.bind(settings.get());

        page.imp().data_browser_group.imp().confirm_row.set_active(false);

        assert_eq!(page.title(), "Data Grid");
        assert!(!settings.get().confirm_bulk_delete());
    }
}

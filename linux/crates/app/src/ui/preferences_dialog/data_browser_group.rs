use gio::prelude::SettingsExtManual;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_linux_platform::AppSettings;
use tablepro_linux_platform::settings::{GridRowHeight, keys};

mod imp {
    use libadwaita::prelude::*;
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/preferences-data-browser-group.ui")]
    pub struct DataBrowserGroup {
        #[template_child]
        pub page_size_row: TemplateChild<adw::SpinRow>,
        #[template_child]
        pub alternate_rows_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub confirm_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub row_numbers_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub row_height_row: TemplateChild<adw::ComboRow>,
        #[template_child]
        pub null_display_row: TemplateChild<adw::EntryRow>,
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

    impl ObjectImpl for DataBrowserGroup {
        fn constructed(&self) {
            self.parent_constructed();
            let threshold = crate::ui::data_grid::BULK_DELETE_CONFIRM_THRESHOLD;
            self.confirm_row.set_subtitle(&crate::i18n::ngettext_f(
                "Ask before deleting {n} or more rows at once",
                "Ask before deleting {n} or more rows at once",
                threshold,
                &[("n", &threshold.to_string())],
            ));
        }
    }
    impl WidgetImpl for DataBrowserGroup {}
    impl PreferencesGroupImpl for DataBrowserGroup {}
}

glib::wrapper! {
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
            .bind(keys::SHOW_ALTERNATE_ROWS, &imp.alternate_rows_row.get(), "active")
            .build();
        gio_settings
            .bind(keys::CONFIRM_BULK_DELETE, &imp.confirm_row.get(), "active")
            .build();
        gio_settings
            .bind(keys::SHOW_ROW_NUMBERS, &imp.row_numbers_row.get(), "active")
            .build();
        gio_settings
            .bind(keys::NULL_DISPLAY, &imp.null_display_row.get(), "text")
            .build();
        gio_settings
            .bind(keys::GRID_ROW_HEIGHT, &imp.row_height_row.get(), "selected")
            .mapping(|variant, _| {
                let height = variant.str()?;
                let index = GridRowHeight::ALL
                    .iter()
                    .position(|candidate| candidate.nick() == height)?;
                Some((index as u32).to_value())
            })
            .set_mapping(|value, _| {
                let index = value.get::<u32>().ok()?;
                Some(GridRowHeight::ALL.get(index as usize)?.nick().to_variant())
            })
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
        settings.get().set_confirm_bulk_delete(false).expect("store the flag");
        settings
            .get()
            .set_show_alternate_rows(false)
            .expect("store the stripes");

        let group = bound_group(&settings);
        let imp = group.imp();

        assert_eq!(imp.page_size_row.value(), 500.0);
        assert!(!imp.confirm_row.is_active());
        assert!(!imp.alternate_rows_row.is_active());

        imp.page_size_row.set_value(2_500.0);
        imp.confirm_row.set_active(true);
        imp.alternate_rows_row.set_active(true);

        assert_eq!(settings.get().default_page_size(), 2_500);
        assert!(settings.get().confirm_bulk_delete());
        assert!(settings.get().show_alternate_rows());
    }

    #[gtk4::test]
    fn the_group_is_titled_for_the_data_browser() {
        let settings = MemorySettings::new();
        let group = bound_group(&settings);

        assert_eq!(group.title(), "Data Browser");
        assert_eq!(group.imp().page_size_row.title(), "Default page size");
    }

    #[gtk4::test]
    fn the_confirm_row_names_the_rows_a_delete_asks_at() {
        let settings = MemorySettings::new();
        let group = bound_group(&settings);

        assert_eq!(
            group.imp().confirm_row.subtitle().as_deref(),
            Some("Ask before deleting 10 or more rows at once")
        );
    }

    #[gtk4::test]
    fn display_preferences_follow_changes_from_another_window() {
        let settings = MemorySettings::new();
        let first = bound_group(&settings);
        let second = bound_group(&settings);

        first.imp().row_height_row.set_selected(3);
        first.imp().row_numbers_row.set_active(false);
        first.imp().null_display_row.set_text("empty");

        assert_eq!(settings.get().grid_row_height(), "spacious");
        assert_eq!(second.imp().row_height_row.selected(), 3);
        assert!(!second.imp().row_numbers_row.is_active());
        assert_eq!(second.imp().null_display_row.text(), "empty");

        settings.get().set_grid_row_height("compact").expect("store the height");
        settings.get().set_show_row_numbers(true).expect("store the flag");
        settings.get().set_null_display("missing").expect("store the text");

        for group in [&first, &second] {
            assert_eq!(group.imp().row_height_row.selected(), 0);
            assert!(group.imp().row_numbers_row.is_active());
            assert_eq!(group.imp().null_display_row.text(), "missing");
        }
        second.imp().row_height_row.set_selected(1);
        assert_eq!(first.imp().row_height_row.selected(), 1);
        assert_eq!(settings.get().grid_row_height(), "normal");
    }

    #[gtk4::test]
    fn null_text_entry_limits_characters_without_cutting_unicode() {
        let settings = MemorySettings::new();
        let group = bound_group(&settings);
        let text = "界".repeat(21);

        group.imp().null_display_row.set_text(&text);

        assert_eq!(group.imp().null_display_row.text(), "界".repeat(20));
        assert_eq!(settings.get().null_display(), "界".repeat(20));
    }
}

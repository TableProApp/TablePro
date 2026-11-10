use gio::prelude::SettingsExtManual;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_linux_platform::AppSettings;
use tablepro_linux_platform::settings::{
    DateFormat, DefaultSort, GridRowHeight, GridSortDirection, RowCopyFormat, keys,
};

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
        pub grid_system_font_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub grid_font_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub grid_font_button: TemplateChild<gtk4::FontDialogButton>,
        #[template_child]
        pub row_numbers_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub auto_inspector_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub invisibles_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub date_format_row: TemplateChild<adw::ComboRow>,
        #[template_child]
        pub default_sort_row: TemplateChild<adw::ComboRow>,
        #[template_child]
        pub default_sort_direction_row: TemplateChild<adw::ComboRow>,
        #[template_child]
        pub row_copy_format_row: TemplateChild<adw::ComboRow>,
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
            .bind(keys::GRID_USE_SYSTEM_FONT, &imp.grid_system_font_row.get(), "active")
            .build();
        gio_settings
            .bind(keys::GRID_USE_SYSTEM_FONT, &imp.grid_font_row.get(), "sensitive")
            .flags(gio::SettingsBindFlags::GET | gio::SettingsBindFlags::INVERT_BOOLEAN)
            .build();
        gio_settings
            .bind(keys::GRID_FONT, &imp.grid_font_button.get(), "font-desc")
            .mapping(|variant, _| Some(gtk4::pango::FontDescription::from_string(variant.str()?).to_value()))
            .set_mapping(|value, _| {
                let description = value.get::<gtk4::pango::FontDescription>().ok()?;
                Some(description.to_str().to_variant())
            })
            .build();
        gio_settings
            .bind(keys::AUTO_SHOW_INSPECTOR, &imp.auto_inspector_row.get(), "active")
            .build();
        bind_choice(
            &imp.row_height_row.get(),
            gio_settings,
            keys::GRID_ROW_HEIGHT,
            GridRowHeight::ALL.map(GridRowHeight::nick),
        );
        gio_settings
            .bind(keys::SHOW_INVISIBLE_CHARACTERS, &imp.invisibles_row.get(), "active")
            .build();
        bind_choice(
            &imp.date_format_row.get(),
            gio_settings,
            keys::DATE_FORMAT,
            DateFormat::ALL.map(DateFormat::nick),
        );
        bind_choice(
            &imp.default_sort_row.get(),
            gio_settings,
            keys::DEFAULT_SORT,
            DefaultSort::ALL.map(DefaultSort::nick),
        );
        bind_choice(
            &imp.default_sort_direction_row.get(),
            gio_settings,
            keys::DEFAULT_SORT_DIRECTION,
            GridSortDirection::ALL.map(GridSortDirection::nick),
        );
        bind_choice(
            &imp.row_copy_format_row.get(),
            gio_settings,
            keys::ROW_COPY_FORMAT,
            RowCopyFormat::ALL.map(RowCopyFormat::nick),
        );
    }
}

fn bind_choice<const N: usize>(
    row: &adw::ComboRow,
    settings: &gio::Settings,
    key: &'static str,
    words: [&'static str; N],
) {
    settings
        .bind(key, row, "selected")
        .mapping(move |variant, _| {
            let word = variant.str()?;
            let index = words.iter().position(|candidate| *candidate == word)?;
            Some((index as u32).to_value())
        })
        .set_mapping(move |value, _| {
            let index = value.get::<u32>().ok()?;
            Some(words.get(index as usize)?.to_variant())
        })
        .build();
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
    fn automatic_details_switches_stay_in_sync() {
        let settings = MemorySettings::new();
        let first = bound_group(&settings);
        let second = bound_group(&settings);
        assert!(!first.imp().auto_inspector_row.is_active());

        first.imp().auto_inspector_row.set_active(true);
        assert!(settings.get().auto_show_inspector());
        assert!(second.imp().auto_inspector_row.is_active());
        settings.get().set_auto_show_inspector(false).expect("store the flag");
        assert!(!first.imp().auto_inspector_row.is_active());
        assert!(!second.imp().auto_inspector_row.is_active());
    }

    #[gtk4::test]
    fn invisible_character_switches_follow_each_other_and_external_settings() {
        let settings = MemorySettings::new();
        let first = bound_group(&settings);
        let second = bound_group(&settings);
        assert!(first.imp().invisibles_row.is_active());

        first.imp().invisibles_row.set_active(false);
        assert!(!settings.get().show_invisible_characters());
        assert!(!second.imp().invisibles_row.is_active());
        settings
            .get()
            .set_show_invisible_characters(true)
            .expect("store the flag");
        assert!(first.imp().invisibles_row.is_active());
        assert!(second.imp().invisibles_row.is_active());
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
    #[gtk4::test]
    fn cell_font_rows_bind_both_ways_across_windows() {
        use tablepro_linux_platform::EditorFont;
        let settings = MemorySettings::new();
        let first = bound_group(&settings);
        let second = bound_group(&settings);
        assert!(!first.imp().grid_font_row.is_sensitive());
        assert_eq!(
            first.imp().grid_font_row.activatable_widget(),
            Some(first.imp().grid_font_button.get().upcast())
        );

        first.imp().grid_system_font_row.set_active(false);
        first
            .imp()
            .grid_font_button
            .set_font_desc(&gtk4::pango::FontDescription::from_string("Sans Bold 15"));
        assert_eq!(settings.get().grid_font(), EditorFont::Custom("Sans Bold 15".into()));
        assert!(!second.imp().grid_system_font_row.is_active());
        assert!(second.imp().grid_font_row.is_sensitive());
        assert_eq!(
            first.imp().grid_font_button.font_desc(),
            second.imp().grid_font_button.font_desc()
        );

        settings.get().set_grid_font(&EditorFont::System).expect("system font");
        assert!(first.imp().grid_system_font_row.is_active());
        assert!(!second.imp().grid_font_row.is_sensitive());
    }

    #[gtk4::test]
    fn copy_format_rows_follow_every_choice_from_both_windows() {
        let settings = MemorySettings::new();
        let first = bound_group(&settings);
        let second = bound_group(&settings);

        for (index, format) in RowCopyFormat::ALL.into_iter().enumerate() {
            first.imp().row_copy_format_row.set_selected(index as u32);
            assert_eq!(settings.get().row_copy_format(), format);
            assert_eq!(second.imp().row_copy_format_row.selected(), index as u32);
        }
        for (index, format) in RowCopyFormat::ALL.into_iter().enumerate().rev() {
            settings
                .get()
                .set_row_copy_format(format.nick())
                .expect("store copy format");
            assert_eq!(first.imp().row_copy_format_row.selected(), index as u32);
            assert_eq!(second.imp().row_copy_format_row.selected(), index as u32);
        }
        second.imp().row_copy_format_row.set_selected(2);
        assert_eq!(first.imp().row_copy_format_row.selected(), 2);
        assert_eq!(settings.get().row_copy_format(), RowCopyFormat::Json);
    }
    #[gtk4::test]
    fn default_sort_rows_follow_other_windows_and_external_settings() {
        let settings = MemorySettings::new();
        let first = bound_group(&settings);
        let second = bound_group(&settings);
        first.imp().default_sort_row.set_selected(1);
        first.imp().default_sort_direction_row.set_selected(1);
        assert_eq!(settings.get().default_sort(), DefaultSort::PrimaryKey);
        assert_eq!(settings.get().default_sort_direction(), GridSortDirection::Descending);
        assert_eq!(second.imp().default_sort_row.selected(), 1);
        assert_eq!(second.imp().default_sort_direction_row.selected(), 1);

        settings.get().set_default_sort("first-column").expect("default sort");
        settings
            .get()
            .set_default_sort_direction("ascending")
            .expect("direction");
        for group in [&first, &second] {
            assert_eq!(group.imp().default_sort_row.selected(), 2);
            assert_eq!(group.imp().default_sort_direction_row.selected(), 0);
        }
    }

    #[gtk4::test]
    fn date_format_rows_follow_both_windows_and_external_settings() {
        let settings = MemorySettings::new();
        let first = bound_group(&settings);
        let second = bound_group(&settings);
        assert_eq!(first.imp().date_format_row.selected(), 0);
        assert_eq!(second.imp().date_format_row.selected(), 0);

        for (index, format) in DateFormat::ALL.into_iter().enumerate() {
            first.imp().date_format_row.set_selected(index as u32);
            assert_eq!(settings.get().date_format(), format);
            assert_eq!(second.imp().date_format_row.selected(), index as u32);
        }
        for (index, format) in DateFormat::ALL.into_iter().enumerate().rev() {
            settings
                .get()
                .set_date_format(format.nick())
                .expect("store date format");
            assert_eq!(first.imp().date_format_row.selected(), index as u32);
            assert_eq!(second.imp().date_format_row.selected(), index as u32);
        }
        second.imp().date_format_row.set_selected(2);
        assert_eq!(first.imp().date_format_row.selected(), 2);
        assert_eq!(settings.get().date_format(), DateFormat::UsLong);
    }
}

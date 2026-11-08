use gio::prelude::{SettingsExt, SettingsExtManual};

use gtk4::glib;
use gtk4::glib::prelude::{ToValue, ToVariant};
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::ComboRowExt;
use tablepro_linux_platform::AppSettings;
use tablepro_linux_platform::settings::keys;

/// The words the row height setting holds, in the combo's order.
const ROW_HEIGHTS: [&str; 4] = ["compact", "normal", "comfortable", "spacious"];

/// The words the default sort setting holds, in the combo's order.
const DEFAULT_SORTS: [&str; 3] = ["none", "primary-key", "first-column"];

/// The words the copy format setting holds, in the combo's order.
const ROW_COPY_FORMATS: [&str; 6] = ["rows", "rows-headers", "json", "csv", "csv-headers", "markdown"];

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
        // As the editor's font row: only reachable with the system font off.
        gio_settings
            .bind(keys::GRID_USE_SYSTEM_FONT, &imp.grid_font_row.get(), "sensitive")
            .flags(gio::SettingsBindFlags::GET | gio::SettingsBindFlags::INVERT_BOOLEAN)
            .build();
        gio_settings
            .bind(keys::GRID_FONT, &imp.grid_font_button.get(), "font-desc")
            .mapping(|variant, _| {
                let description = variant.get::<String>()?;
                Some(gtk4::pango::FontDescription::from_string(&description).to_value())
            })
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
            &ROW_HEIGHTS,
            1,
        );
        bind_choice(
            &imp.default_sort_row.get(),
            gio_settings,
            keys::DEFAULT_SORT,
            &DEFAULT_SORTS,
            0,
        );
        bind_choice(
            &imp.default_sort_direction_row.get(),
            gio_settings,
            keys::DEFAULT_SORT_DIRECTION,
            &["ascending", "descending"],
            0,
        );
        bind_choice(
            &imp.row_copy_format_row.get(),
            gio_settings,
            keys::ROW_COPY_FORMAT,
            &ROW_COPY_FORMATS,
            0,
        );
    }
}

/// A combo holds a position and the setting a word, so each change of
/// one is written to the other.
fn bind_choice(
    row: &adw::ComboRow,
    settings: &gio::Settings,
    key: &'static str,
    words: &'static [&'static str],
    fallback: u32,
) {
    let current = settings.string(key);
    row.set_selected(
        words
            .iter()
            .position(|word| *word == current)
            .map_or(fallback, |at| at as u32),
    );
    let stored = settings.clone();
    row.connect_selected_notify(move |row| {
        if let Some(word) = words.get(row.selected() as usize) {
            let _ = stored.set_string(key, word);
        }
    });
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
}

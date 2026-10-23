use std::rc::Rc;

use gio::prelude::SettingsExtManual;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_storage::AppSettings;
use tablepro_storage::settings::keys;

use crate::ui::style_scheme_grid;

mod imp {
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/preferences-editor-page.ui")]
    pub struct EditorPage {
        #[template_child]
        pub system_font_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub font_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub font_button: TemplateChild<gtk4::FontDialogButton>,
        #[template_child]
        pub style_scheme_box: TemplateChild<gtk4::FlowBox>,
        #[template_child]
        pub vim_row: TemplateChild<adw::SwitchRow>,
        #[template_child]
        pub timeout_row: TemplateChild<adw::SpinRow>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for EditorPage {
        const NAME: &'static str = "TableProEditorPage";
        type Type = super::EditorPage;
        type ParentType = adw::PreferencesPage;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for EditorPage {}
    impl WidgetImpl for EditorPage {}
    impl PreferencesPageImpl for EditorPage {}
}

glib::wrapper! {
    /// The Editor page: the font, the style scheme, Vim keybindings and
    /// the query timeout.
    pub struct EditorPage(ObjectSubclass<imp::EditorPage>)
        @extends adw::PreferencesPage, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for EditorPage {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl EditorPage {
    pub(super) fn bind(&self, settings: &Rc<AppSettings>) {
        let imp = self.imp();
        let gio_settings = settings.gio();

        gio_settings
            .bind(keys::QUERY_TIMEOUT_SECS, &imp.timeout_row.get(), "value")
            .build();
        gio_settings
            .bind(keys::USE_SYSTEM_FONT, &imp.system_font_row.get(), "active")
            .build();
        gio_settings
            .bind(keys::VIM_KEYBINDINGS, &imp.vim_row.get(), "active")
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
    }
}

#[cfg(test)]
mod tests {
    use libadwaita::prelude::*;
    use tablepro_storage::EditorFont;

    use super::*;
    use crate::test_support::{MemorySettings, descendants};

    fn bound_page(settings: &MemorySettings) -> EditorPage {
        crate::register_test_resources();
        let page = EditorPage::default();
        page.bind(settings.get());
        page
    }

    fn row_titles(page: &EditorPage) -> Vec<String> {
        descendants(page)
            .into_iter()
            .filter_map(|widget| widget.downcast::<adw::PreferencesRow>().ok())
            .map(|row| row.title().to_string())
            .collect()
    }

    #[gtk4::test]
    fn editor_page_contains_the_font_and_style_scheme_rows() {
        let settings = MemorySettings::new();
        let page = bound_page(&settings);

        assert_eq!(page.title(), "Editor");
        assert_eq!(
            row_titles(&page),
            [
                "Use the System Monospace Font",
                "Editor font",
                "Vim Keybindings",
                "Query timeout (seconds)"
            ]
        );
        assert!(
            page.imp().style_scheme_box.first_child().is_some(),
            "no style scheme previews"
        );
    }

    #[gtk4::test]
    fn the_font_row_is_insensitive_while_the_system_font_is_on() {
        let settings = MemorySettings::new();
        let page = bound_page(&settings);
        let imp = page.imp();

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
    fn the_vim_row_is_bound_and_off_by_default() {
        let settings = MemorySettings::new();
        let page = bound_page(&settings);
        let row = page.imp().vim_row.get();

        assert!(!row.is_active());
        row.set_active(true);

        assert!(settings.get().vim_keybindings());
    }

    #[gtk4::test]
    fn the_timeout_row_is_bound() {
        let settings = MemorySettings::new();
        let page = bound_page(&settings);
        let row = page.imp().timeout_row.get();

        row.set_value(45.0);

        assert_eq!(settings.get().query_timeout(), Some(std::time::Duration::from_secs(45)));
    }
}

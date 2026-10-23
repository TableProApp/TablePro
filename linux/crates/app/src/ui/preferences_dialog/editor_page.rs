use std::path::PathBuf;
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

use crate::i18n::gettext;
use crate::ui::file_reveal::FileRevealer;
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
        pub snippets_row: TemplateChild<adw::ActionRow>,
        #[template_child]
        pub snippets_button: TemplateChild<gtk4::Button>,
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

    impl ObjectImpl for EditorPage {
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
    impl WidgetImpl for EditorPage {}
    impl PreferencesPageImpl for EditorPage {}
}

glib::wrapper! {
    /// The Editor page: the font, the style scheme, Vim keybindings, the
    /// snippets folder and the query timeout.
    pub struct EditorPage(ObjectSubclass<imp::EditorPage>)
        @extends adw::PreferencesPage, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for EditorPage {
    fn default() -> Self {
        glib::Object::new()
    }
}

/// What the Snippets row opens, and what it opens it with.
pub(super) struct SnippetsFolder {
    pub folder: PathBuf,
    pub tasks: Tasks,
    pub opener: Rc<dyn FileRevealer>,
}

impl EditorPage {
    pub(super) fn bind(&self, settings: &Rc<AppSettings>, snippets: SnippetsFolder) {
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
        self.bind_snippets(snippets);
    }

    /// AdwPreferencesDialog owns the toast overlay, so the page hands its
    /// toasts up rather than looking for one.
    pub(super) fn connect_toast<F: Fn(&Self, &adw::Toast) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "toast",
            false,
            glib::closure_local!(move |page: &Self, toast: adw::Toast| f(page, &toast)),
        )
    }

    fn bind_snippets(&self, snippets: SnippetsFolder) {
        let imp = self.imp();
        let path = snippets.folder.display().to_string();
        imp.snippets_row.set_subtitle(&path);
        // AdwActionRow ellipsises a long subtitle, so the full path lives
        // in the tooltip.
        imp.snippets_row.set_tooltip_text(Some(&path));
        let snippets = Rc::new(snippets);
        let page = self.downgrade();
        imp.snippets_button.connect_clicked(move |_| {
            if let Some(page) = page.upgrade() {
                page.open_snippets_folder(&snippets);
            }
        });
    }

    /// The folder does not exist until the user first opens it.
    fn open_snippets_folder(&self, snippets: &SnippetsFolder) {
        let folder = snippets.folder.clone();
        let making = snippets
            .tasks
            .spawn_blocking_task(move || tablepro_storage::fs::ensure_user_dir(&folder));
        let opener = snippets.opener.clone();
        let folder = snippets.folder.clone();
        let page = self.downgrade();
        glib::spawn_future_local(async move {
            let made = match making.await {
                Ok(made) => made.map_err(|error| error.to_string()),
                Err(failure) => Err(failure.to_string()),
            };
            let Some(page) = page.upgrade() else {
                return;
            };
            if let Err(error) = made {
                tracing::warn!(%error, folder = %folder.display(), "could not make the snippets folder");
                page.toast(&gettext("Could not create the snippets folder"));
                return;
            }
            let opened = opener
                .open_folder(gio::File::for_path(&folder), page.root().and_downcast())
                .await;
            if let Err(error) = opened {
                tracing::warn!(%error, "could not open the snippets folder");
                page.toast(&gettext("Could not open the folder in Files"));
            }
        });
    }

    fn toast(&self, message: &str) {
        self.emit_by_name::<()>("toast", &[&crate::ui::plain_toast(message)]);
    }

    #[cfg(test)]
    fn snippets_folder_shown(&self) -> Option<String> {
        self.imp().snippets_row.subtitle().map(|path| path.to_string())
    }
}

#[cfg(test)]
mod tests {
    use tablepro_storage::EditorFont;

    use super::*;
    use crate::test_support::{MemorySettings, SignalLog, descendants, test_runtime, wait_until};
    use crate::ui::file_reveal::RecordingRevealer;

    const WAIT: std::time::Duration = std::time::Duration::from_secs(10);

    struct Bound {
        page: EditorPage,
        folder: PathBuf,
        opener: Rc<RecordingRevealer>,
        _root: tempfile::TempDir,
        _runtime: crate::runtime::AppRuntime,
    }

    fn bound(settings: &MemorySettings, opener: RecordingRevealer) -> Bound {
        crate::register_test_resources();
        let root = tempfile::tempdir().expect("a temporary folder");
        let folder = root.path().join("data").join("snippets");
        let runtime = test_runtime();
        let opener = Rc::new(opener);
        let page = EditorPage::default();
        page.bind(
            settings.get(),
            SnippetsFolder {
                folder: folder.clone(),
                tasks: runtime.tasks(),
                opener: opener.clone(),
            },
        );
        Bound {
            page,
            folder,
            opener,
            _root: root,
            _runtime: runtime,
        }
    }

    fn toast_titles(page: &EditorPage) -> SignalLog<Option<String>> {
        SignalLog::connect(page, "toast", |values| {
            values[1]
                .get::<adw::Toast>()
                .ok()
                .and_then(|toast| toast.title())
                .map(|title| title.to_string())
        })
    }

    fn bound_page(settings: &MemorySettings) -> EditorPage {
        let Bound { page, .. } = bound(settings, RecordingRevealer::succeeding());
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
                "Snippets folder",
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

    #[gtk4::test]
    fn the_snippets_row_shows_the_folder_and_open_folder_makes_and_opens_it() {
        let settings = MemorySettings::new();
        let bound = bound(&settings, RecordingRevealer::succeeding());
        assert_eq!(
            bound.page.snippets_folder_shown(),
            Some(bound.folder.display().to_string())
        );
        assert!(
            !bound.page.imp().snippets_row.uses_markup(),
            "a path with & reads as markup"
        );
        assert!(
            std::fs::metadata(&bound.folder).is_err(),
            "the folder was made before it was asked for"
        );

        bound.page.imp().snippets_button.emit_clicked();

        wait_until(WAIT, || bound.opener.opened() == [bound.folder.clone()]).expect("the folder opened");
        assert!(std::fs::metadata(&bound.folder).is_ok_and(|folder| folder.is_dir()));
        assert!(bound.opener.revealed().is_empty(), "it showed the folder in its parent");
    }

    #[gtk4::test]
    fn a_folder_the_file_manager_cannot_open_is_reported_as_a_toast() {
        let settings = MemorySettings::new();
        let bound = bound(&settings, RecordingRevealer::failing());
        let toasts = toast_titles(&bound.page);

        bound.page.imp().snippets_button.emit_clicked();

        wait_until(WAIT, || toasts.count() == 1).expect("a toast");
        assert_eq!(toasts.take(), [Some("Could not open the folder in Files".to_owned())]);
    }

    #[gtk4::test]
    fn a_folder_that_cannot_be_made_is_reported_as_a_toast() {
        let settings = MemorySettings::new();
        let bound = bound(&settings, RecordingRevealer::succeeding());
        let parent = bound.folder.parent().expect("a parent");
        std::fs::write(parent, "not a folder").expect("a file where the folder's parent goes");
        let toasts = toast_titles(&bound.page);

        bound.page.imp().snippets_button.emit_clicked();

        wait_until(WAIT, || toasts.count() == 1).expect("a toast");
        assert_eq!(toasts.take(), [Some("Could not create the snippets folder".to_owned())]);
        assert!(bound.opener.opened().is_empty(), "it opened a folder it could not make");
    }
}

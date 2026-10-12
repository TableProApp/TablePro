use std::path::PathBuf;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::{FileEndpoint, FileOpenMode};

mod imp {
    use std::cell::RefCell;
    use std::sync::OnceLock;

    use glib::subclass::Signal;
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/sqlite-file-row.ui")]
    pub struct SqliteFileRow {
        #[template_child]
        pub choose_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub create_button: TemplateChild<gtk4::Button>,
        pub endpoint: RefCell<Option<FileEndpoint>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for SqliteFileRow {
        const NAME: &'static str = "TableProSqliteFileRow";
        type Type = super::SqliteFileRow;
        type ParentType = adw::ActionRow;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for SqliteFileRow {
        fn signals() -> &'static [Signal] {
            static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| vec![Signal::builder("changed").build()])
        }

        fn constructed(&self) {
            self.parent_constructed();
            let row = self.obj();
            let weak = row.downgrade();
            self.choose_button.connect_clicked(move |_| {
                if let Some(row) = weak.upgrade() {
                    glib::spawn_future_local(async move { row.choose_existing().await });
                }
            });
            let weak = row.downgrade();
            self.create_button.connect_clicked(move |_| {
                if let Some(row) = weak.upgrade() {
                    glib::spawn_future_local(async move { row.choose_new().await });
                }
            });
        }
    }

    impl WidgetImpl for SqliteFileRow {}
    impl ListBoxRowImpl for SqliteFileRow {}
    impl PreferencesRowImpl for SqliteFileRow {}
    impl ActionRowImpl for SqliteFileRow {}
}

glib::wrapper! {
    /// The SQLite database file, opened as it is or created on connect.
    pub struct SqliteFileRow(ObjectSubclass<imp::SqliteFileRow>)
        @extends adw::ActionRow, adw::PreferencesRow, gtk4::ListBoxRow, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Actionable, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for SqliteFileRow {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl SqliteFileRow {
    pub fn endpoint(&self) -> Option<FileEndpoint> {
        self.imp().endpoint.borrow().clone()
    }

    pub fn set_endpoint(&self, endpoint: Option<FileEndpoint>) {
        let subtitle = match &endpoint {
            None => crate::i18n::gettext("No file chosen"),
            Some(file) if file.mode() == FileOpenMode::CreateNew => crate::i18n::gettext_f(
                "{path}, created when you connect",
                &[("path", &file.path().display().to_string())],
            ),
            Some(file) => file.path().display().to_string(),
        };
        self.set_subtitle(&subtitle);
        self.imp().endpoint.replace(endpoint);
        self.emit_by_name::<()>("changed", &[]);
    }

    /// Take a path the file chooser returned. The portal only hands out
    /// absolute paths, so a refusal here means it gave none at all.
    pub fn adopt_choice(&self, path: PathBuf, mode: FileOpenMode) {
        let endpoint = match mode {
            FileOpenMode::OpenExisting => FileEndpoint::open_existing(path),
            FileOpenMode::CreateNew => FileEndpoint::create_new(path),
        };
        match endpoint {
            Ok(endpoint) => self.set_endpoint(Some(endpoint)),
            Err(error) => tracing::warn!(%error, "the file chooser returned an unusable path"),
        }
    }

    pub fn connect_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "changed",
            false,
            glib::closure_local!(move |row: &Self| {
                f(row);
            }),
        )
    }

    async fn choose_existing(&self) {
        let dialog = file_dialog(&crate::i18n::gettext("Open Database File"));
        let chosen = dialog.open_future(self.parent_window().as_ref()).await;
        if let Some(path) = chosen.ok().and_then(|file| file.path()) {
            self.adopt_choice(path, FileOpenMode::OpenExisting);
        }
    }

    /// The save chooser asks before replacing a file that exists, and
    /// the driver then replaces it whole, so no second question here.
    async fn choose_new(&self) {
        let dialog = file_dialog(&crate::i18n::gettext("New Database File"));
        dialog.set_initial_name(Some("Untitled.sqlite3"));
        let chosen = dialog.save_future(self.parent_window().as_ref()).await;
        if let Some(path) = chosen.ok().and_then(|file| file.path()) {
            self.adopt_choice(path, FileOpenMode::CreateNew);
        }
    }

    fn parent_window(&self) -> Option<gtk4::Window> {
        self.root().and_downcast::<gtk4::Window>()
    }
}

fn file_dialog(title: &str) -> gtk4::FileDialog {
    let sqlite = gtk4::FileFilter::new();
    sqlite.set_name(Some(&crate::i18n::gettext("SQLite databases")));
    for mime in ["application/vnd.sqlite3", "application/x-sqlite3"] {
        sqlite.add_mime_type(mime);
    }
    for suffix in ["sqlite", "sqlite3", "db", "db3"] {
        sqlite.add_suffix(suffix);
    }
    let any = gtk4::FileFilter::new();
    any.set_name(Some(&crate::i18n::gettext("All files")));
    any.add_pattern("*");
    let filters = gio::ListStore::new::<gtk4::FileFilter>();
    filters.append(&sqlite);
    filters.append(&any);
    gtk4::FileDialog::builder()
        .title(title)
        .modal(true)
        .filters(&filters)
        .default_filter(&sqlite)
        .build()
}

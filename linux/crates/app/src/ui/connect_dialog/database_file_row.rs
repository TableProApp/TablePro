use std::path::{Path, PathBuf};

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::{DatabaseDriver, FileEndpoint, FileFormat, FileOpenMode};
use tablepro_session::runtime::Tasks;

use crate::services::file_location;

mod imp {
    use std::cell::{OnceCell, RefCell};
    use std::sync::OnceLock;

    use glib::subclass::Signal;
    use libadwaita::subclass::prelude::*;

    use super::*;

    #[derive(Default, gtk4::CompositeTemplate)]
    #[template(resource = "/app/tablepro/TablePro/ui/database-file-row.ui")]
    pub struct DatabaseFileRow {
        #[template_child]
        pub choose_button: TemplateChild<gtk4::Button>,
        #[template_child]
        pub create_button: TemplateChild<gtk4::Button>,
        pub endpoint: RefCell<Option<FileEndpoint>>,
        /// The engine's files, which the choosers offer first.
        pub files: RefCell<Option<DatabaseFiles>>,
        /// Reads the file a portal path stands for, off the GTK thread.
        pub tasks: OnceCell<Tasks>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for DatabaseFileRow {
        const NAME: &'static str = "TableProDatabaseFileRow";
        type Type = super::DatabaseFileRow;
        type ParentType = adw::ActionRow;

        fn class_init(klass: &mut Self::Class) {
            klass.bind_template();
        }

        fn instance_init(object: &glib::subclass::InitializingObject<Self>) {
            object.init_template();
        }
    }

    impl ObjectImpl for DatabaseFileRow {
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

    impl WidgetImpl for DatabaseFileRow {}
    impl ListBoxRowImpl for DatabaseFileRow {}
    impl PreferencesRowImpl for DatabaseFileRow {}
    impl ActionRowImpl for DatabaseFileRow {}
}

glib::wrapper! {
    /// A file engine's database file, opened as it is or created on
    /// connect.
    pub struct DatabaseFileRow(ObjectSubclass<imp::DatabaseFileRow>)
        @extends adw::ActionRow, adw::PreferencesRow, gtk4::ListBoxRow, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Actionable, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for DatabaseFileRow {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl DatabaseFileRow {
    pub fn endpoint(&self) -> Option<FileEndpoint> {
        self.imp().endpoint.borrow().clone()
    }

    /// Which engine's files the choosers offer.
    pub fn set_files(&self, files: Option<DatabaseFiles>) {
        self.imp().files.replace(files);
    }

    pub fn set_tasks(&self, tasks: Tasks) {
        let _ = self.imp().tasks.set(tasks);
    }

    pub fn set_endpoint(&self, endpoint: Option<FileEndpoint>) {
        self.set_subtitle(&subtitle(endpoint.as_ref(), None));
        if let Some(file) = &endpoint
            && file_location::is_portal_path(file.path())
        {
            self.show_host_path(file.path().to_path_buf());
        }
        self.imp().endpoint.replace(endpoint);
        self.emit_by_name::<()>("changed", &[]);
    }

    /// A portal path's folder is an id, so the row names the file the
    /// portal stands for once it is read.
    fn show_host_path(&self, path: PathBuf) {
        let Some(tasks) = self.imp().tasks.get() else {
            return;
        };
        let lookup = path.clone();
        let looking = tasks.spawn_blocking_task(move || file_location::portal_host_path_blocking(&lookup));
        let row = self.downgrade();
        glib::spawn_future_local(async move {
            let (Ok(Some(host)), Some(row)) = (looking.await, row.upgrade()) else {
                return;
            };
            let endpoint = row.endpoint();
            if endpoint.as_ref().is_some_and(|file| file.path() == path) {
                row.set_subtitle(&subtitle(endpoint.as_ref(), Some(&host)));
            }
        });
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
        let files = self.imp().files.borrow().clone();
        let dialog = database_file_dialog(&crate::i18n::gettext("Open Database File"), files.as_ref());
        let chosen = dialog.open_future(self.parent_window().as_ref()).await;
        if let Some(path) = chosen.ok().and_then(|file| file.path()) {
            self.adopt_choice(path, FileOpenMode::OpenExisting);
        }
    }

    /// The save chooser asks before replacing a file that exists, and
    /// the driver then replaces it whole, so no second question here.
    async fn choose_new(&self) {
        let files = self.imp().files.borrow().clone();
        let dialog = database_file_dialog(&crate::i18n::gettext("New Database File"), files.as_ref());
        dialog.set_initial_name(Some(&new_file_name(files.as_ref())));
        let chosen = dialog.save_future(self.parent_window().as_ref()).await;
        if let Some(path) = chosen.ok().and_then(|file| file.path()) {
            self.adopt_choice(path, FileOpenMode::CreateNew);
        }
    }

    fn parent_window(&self) -> Option<gtk4::Window> {
        self.root().and_downcast::<gtk4::Window>()
    }
}

/// The row's subtitle: the file, named by `host_path` when a portal
/// hands it over.
fn subtitle(endpoint: Option<&FileEndpoint>, host_path: Option<&Path>) -> String {
    let Some(file) = endpoint else {
        return crate::i18n::gettext("No file chosen");
    };
    let shown = file_location::display_path(file.path(), host_path);
    match file.mode() {
        FileOpenMode::CreateNew => crate::i18n::gettext_f("{path}, created when you connect", &[("path", &shown)]),
        FileOpenMode::OpenExisting => shown,
    }
}

/// The files one engine opens: its name, for the chooser's filter, and
/// the suffixes and types its files go by.
#[derive(Debug, Clone, PartialEq)]
pub struct DatabaseFiles {
    pub engine: String,
    pub format: FileFormat,
}

impl DatabaseFiles {
    /// The files `driver` opens, for a driver that opens one.
    pub(crate) fn of(driver: &dyn DatabaseDriver) -> Option<Self> {
        driver.capabilities().file_format().map(|format| Self {
            engine: driver.display_name().to_owned(),
            format: *format,
        })
    }
}

/// The name a new database is offered under, with the engine's suffix.
fn new_file_name(files: Option<&DatabaseFiles>) -> String {
    match files.and_then(|files| files.format.new_file_suffix()) {
        Some(suffix) => format!("Untitled.{suffix}"),
        None => "Untitled".to_owned(),
    }
}

/// The file chooser for an engine's databases, with every file a choice
/// when the filter misses it.
pub(crate) fn database_file_dialog(title: &str, files: Option<&DatabaseFiles>) -> gtk4::FileDialog {
    let any = gtk4::FileFilter::new();
    any.set_name(Some(&crate::i18n::gettext("All files")));
    any.add_pattern("*");
    let filters = gio::ListStore::new::<gtk4::FileFilter>();
    let builder = gtk4::FileDialog::builder().title(title).modal(true);
    let Some(files) = files else {
        filters.append(&any);
        return builder.filters(&filters).default_filter(&any).build();
    };
    let engine = gtk4::FileFilter::new();
    engine.set_name(Some(&crate::i18n::gettext_f(
        "{engine} databases",
        &[("engine", &files.engine)],
    )));
    for mime in files.format.mime_types {
        engine.add_mime_type(mime);
    }
    for suffix in files.format.suffixes {
        engine.add_suffix(suffix);
    }
    filters.append(&engine);
    filters.append(&any);
    builder.filters(&filters).default_filter(&engine).build()
}

#[cfg(test)]
mod tests {
    use tablepro_core::FileSignature;

    use super::*;

    #[test]
    fn a_new_database_is_offered_with_its_engines_suffix() {
        let files = DatabaseFiles {
            engine: "DuckDB".to_owned(),
            format: FileFormat {
                signature: FileSignature {
                    offset: 8,
                    bytes: b"DUCK",
                },
                suffixes: &["duckdb", "ddb"],
                mime_types: &[],
                empty_file_is_database: false,
            },
        };

        assert_eq!(new_file_name(Some(&files)), "Untitled.duckdb");
        assert_eq!(new_file_name(None), "Untitled");
    }

    #[test]
    fn a_portal_file_reads_as_its_host_path_or_its_name() {
        let portal = FileEndpoint::open_existing(PathBuf::from("/run/user/1000/doc/1a2b3c/app.db")).expect("absolute");
        let created = FileEndpoint::create_new(PathBuf::from("/run/user/1000/doc/1a2b3c/new.db")).expect("absolute");
        let local = FileEndpoint::open_existing(PathBuf::from("/home/me/app.db")).expect("absolute");

        assert_eq!(subtitle(Some(&portal), None), "app.db");
        assert_eq!(
            subtitle(Some(&portal), Some(Path::new("/srv/data/app.db"))),
            "/srv/data/app.db"
        );
        assert_eq!(subtitle(Some(&created), None), "new.db, created when you connect");
        assert_eq!(subtitle(Some(&local), None), "/home/me/app.db");
        assert_eq!(subtitle(None, None), "No file chosen");
    }
}

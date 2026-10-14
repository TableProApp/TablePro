use std::path::{Path, PathBuf};

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::{FileEndpoint, FileOpenMode};
use tablepro_session::runtime::Tasks;

use crate::services::file_location;

mod imp {
    use std::cell::{OnceCell, RefCell};
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
        /// Reads the file a portal path stands for, off the GTK thread.
        pub tasks: OnceCell<Tasks>,
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
        let dialog = sqlite_file_dialog(&crate::i18n::gettext("Open Database File"));
        let chosen = dialog.open_future(self.parent_window().as_ref()).await;
        if let Some(path) = chosen.ok().and_then(|file| file.path()) {
            self.adopt_choice(path, FileOpenMode::OpenExisting);
        }
    }

    /// The save chooser asks before replacing a file that exists, and
    /// the driver then replaces it whole, so no second question here.
    async fn choose_new(&self) {
        let dialog = sqlite_file_dialog(&crate::i18n::gettext("New Database File"));
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

/// The file chooser for a SQLite database, with every file a choice
/// when the filter misses it.
pub(crate) fn sqlite_file_dialog(title: &str) -> gtk4::FileDialog {
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

#[cfg(test)]
mod tests {
    use super::*;

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

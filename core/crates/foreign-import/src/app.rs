use std::path::PathBuf;
use std::sync::Arc;

use tokio_util::sync::CancellationToken;

use crate::{CollectedImport, ForeignAppDirs, ForeignHost, ForeignImportError, ForeignPlatform, apps};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ForeignApp {
    TablePlus,
    SequelAce,
    DBeaver,
    DataGrip,
    BeekeeperStudio,
    Navicat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasswordSource {
    // The app keeps passwords in the system keychain, which asks the user before another app reads them.
    Keychain,
    // The app keeps them in its own files under a fixed key, so they are decrypted while reading.
    AppFiles,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SavedQuerySupport {
    // Every saved query lands in a folder named after the app, for every connection.
    GlobalFolder,
    // Scripts land with the connection they run on; scripts with a default name start unchecked.
    Scripts,
    // Query consoles land with their data source; consoles with a default name start unchecked.
    Consoles,
    // The export file holds none.
    NotInExport,
}

impl ForeignApp {
    pub const ALL: [Self; 6] = [
        Self::TablePlus,
        Self::SequelAce,
        Self::DBeaver,
        Self::DataGrip,
        Self::BeekeeperStudio,
        Self::Navicat,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::TablePlus => "tableplus",
            Self::SequelAce => "sequelace",
            Self::DBeaver => "dbeaver",
            Self::DataGrip => "datagrip",
            Self::BeekeeperStudio => "beekeeperstudio",
            Self::Navicat => "navicat",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|app| app.id() == id)
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::TablePlus => "TablePlus",
            Self::SequelAce => "Sequel Ace",
            Self::DBeaver => "DBeaver",
            Self::DataGrip => "DataGrip",
            Self::BeekeeperStudio => "Beekeeper Studio",
            Self::Navicat => "Navicat",
        }
    }

    // Extensions of the export file the user picks, for an importer that reads one rather than the
    // app's own store.
    pub fn picked_file_extensions(self) -> Option<&'static [&'static str]> {
        match self {
            Self::Navicat => Some(&["ncx"]),
            _ => None,
        }
    }

    pub fn password_source(self) -> PasswordSource {
        match self {
            Self::TablePlus | Self::SequelAce | Self::DataGrip => PasswordSource::Keychain,
            Self::DBeaver | Self::BeekeeperStudio | Self::Navicat => PasswordSource::AppFiles,
        }
    }

    pub fn saved_query_support(self) -> SavedQuerySupport {
        match self {
            Self::TablePlus | Self::SequelAce | Self::BeekeeperStudio => SavedQuerySupport::GlobalFolder,
            Self::DBeaver => SavedQuerySupport::Scripts,
            Self::DataGrip => SavedQuerySupport::Consoles,
            Self::Navicat => SavedQuerySupport::NotInExport,
        }
    }

    pub fn runs_on(self, platform: ForeignPlatform) -> bool {
        self != Self::SequelAce || platform == ForeignPlatform::MacOs
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImportRequest {
    pub include_passwords: bool,
    pub include_saved_queries: bool,
    // A saved query past this many bytes is listed by size only.
    pub saved_query_byte_limit: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Inventory {
    pub connections: usize,
    pub saved_queries: usize,
}

pub(crate) trait AppReader {
    // Whether the app's files are where this platform keeps them.
    fn has_data(&self) -> bool;

    // Reads files only, never a keychain.
    fn inventory(&self) -> Inventory;

    fn collect(
        &self,
        request: &ImportRequest,
        cancel: &CancellationToken,
    ) -> Result<CollectedImport, ForeignImportError>;
}

// Every call reads files and may wait on a keychain prompt, so none runs on a UI thread.
#[derive(Clone)]
pub struct ForeignImporter {
    app: ForeignApp,
    dirs: ForeignAppDirs,
    host: Arc<dyn ForeignHost>,
    picked_file: Option<PathBuf>,
}

impl ForeignImporter {
    pub fn new(app: ForeignApp, dirs: ForeignAppDirs, host: Arc<dyn ForeignHost>) -> Self {
        Self {
            app,
            dirs,
            host,
            picked_file: None,
        }
    }

    #[must_use]
    pub fn with_file(self, path: PathBuf) -> Self {
        Self {
            picked_file: Some(path),
            ..self
        }
    }

    pub fn app(&self) -> ForeignApp {
        self.app
    }

    pub fn is_available_blocking(&self) -> bool {
        if self.app.picked_file_extensions().is_some() {
            return true;
        }
        if !self.app.runs_on(self.dirs.platform) {
            return false;
        }
        match self.host.installed(self.app) {
            Some(true) => true,
            // The macOS app looks past a missing bundle only for these two, whose data outlives it.
            Some(false) => matches!(self.app, ForeignApp::DBeaver | ForeignApp::DataGrip) && self.reader().has_data(),
            None => self.reader().has_data(),
        }
    }

    pub fn inventory_blocking(&self) -> Inventory {
        if !self.app.runs_on(self.dirs.platform) {
            return Inventory::default();
        }
        self.reader().inventory()
    }

    pub fn collect_blocking(
        &self,
        request: &ImportRequest,
        cancel: &CancellationToken,
    ) -> Result<CollectedImport, ForeignImportError> {
        if !self.app.runs_on(self.dirs.platform) {
            return Err(ForeignImportError::FileNotFound { app: self.app });
        }
        self.reader().collect(request, cancel)
    }

    fn reader(&self) -> Box<dyn AppReader> {
        let keychain = self.host.keychain();
        match self.app {
            ForeignApp::TablePlus => Box::new(apps::tableplus::TablePlus::locate(&self.dirs, keychain)),
            ForeignApp::SequelAce => Box::new(apps::sequel_ace::SequelAce::locate(&self.dirs, keychain)),
            ForeignApp::DBeaver => Box::new(apps::dbeaver::DBeaver::locate(&self.dirs)),
            ForeignApp::DataGrip => Box::new(apps::datagrip::DataGrip::locate(&self.dirs, keychain)),
            ForeignApp::BeekeeperStudio => Box::new(apps::beekeeper::Beekeeper::locate(&self.dirs)),
            ForeignApp::Navicat => Box::new(apps::navicat::Navicat::new(self.picked_file.clone())),
        }
    }
}

pub(crate) fn check_cancel(cancel: &CancellationToken) -> Result<(), ForeignImportError> {
    if cancel.is_cancelled() {
        Err(ForeignImportError::Cancelled)
    } else {
        Ok(())
    }
}

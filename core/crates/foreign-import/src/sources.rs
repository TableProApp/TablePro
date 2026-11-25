use std::sync::Arc;

use crate::{
    ForeignApp, ForeignAppDirs, ForeignHost, ForeignImportError, ForeignImporter, Inventory, PasswordSource,
    SavedQuerySupport,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanDepth {
    // Whether each app is there, with no file read past that: the launch probe.
    Presence,
    Inventory,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnreadableReason {
    pub code: &'static str,
    pub detail: String,
}

impl From<&ForeignImportError> for UnreadableReason {
    fn from(error: &ForeignImportError) -> Self {
        Self {
            code: error.code(),
            detail: error.to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceAvailability {
    Available,
    NotFound,
    // The app's data is there and could not be read, so its count is not known.
    Unreadable(UnreadableReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasswordOffer {
    DecryptedWhileReading,
    // DataGrip's KeePass file, which opens where its main key does.
    PasswordFile,
    // DBX's key, which Credential Manager hands over.
    KeyInCredentialManager,
    // A store this platform does not let another app read.
    SystemStore,
}

impl PasswordOffer {
    pub fn offered(self) -> bool {
        self != Self::SystemStore
    }
}

impl ForeignApp {
    pub fn password_offer(self, host: &dyn ForeignHost) -> PasswordOffer {
        match (self, self.password_source()) {
            (_, PasswordSource::AppFiles) => PasswordOffer::DecryptedWhileReading,
            (Self::DataGrip, _) => PasswordOffer::PasswordFile,
            (Self::Dbx, _) if host.credential_manager().is_some() => PasswordOffer::KeyInCredentialManager,
            _ => PasswordOffer::SystemStore,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignSource {
    pub app: ForeignApp,
    pub availability: SourceAvailability,
    // Zero unless the app is available, the scan read its inventory and it is not imported from a picked file.
    pub inventory: Inventory,
    pub password_offer: PasswordOffer,
    pub offers_saved_queries: bool,
}

impl ForeignSource {
    pub fn picks_file(&self) -> bool {
        self.app.picked_file_extensions().is_some()
    }

    // An app the user picks a file for, or one whose data could not be counted, waits for the user to tick it.
    pub fn starts_ticked(&self) -> bool {
        self.availability == SourceAvailability::Available && !self.picks_file() && self.inventory.connections > 0
    }
}

// Every app this platform has, in `ForeignApp::ALL` order. Reads files only, never a keychain.
pub fn sources_blocking(dirs: &ForeignAppDirs, host: Arc<dyn ForeignHost>, depth: ScanDepth) -> Vec<ForeignSource> {
    ForeignApp::ALL
        .into_iter()
        .filter(|app| app.runs_on(dirs.platform))
        .map(|app| source(app, dirs, &host, depth))
        .collect()
}

fn source(app: ForeignApp, dirs: &ForeignAppDirs, host: &Arc<dyn ForeignHost>, depth: ScanDepth) -> ForeignSource {
    let importer = ForeignImporter::new(app, dirs.clone(), Arc::clone(host));
    let (availability, inventory) = if !importer.is_available_blocking() {
        (SourceAvailability::NotFound, Inventory::default())
    } else if depth == ScanDepth::Presence || app.picked_file_extensions().is_some() {
        (SourceAvailability::Available, Inventory::default())
    } else {
        match importer.inventory_blocking() {
            Ok(inventory) => (SourceAvailability::Available, inventory),
            Err(error) => {
                tracing::warn!(
                    app = app.id(),
                    code = error.code(),
                    "another app's data could not be counted"
                );
                (SourceAvailability::Unreadable((&error).into()), Inventory::default())
            }
        }
    };
    ForeignSource {
        app,
        availability,
        inventory,
        password_offer: app.password_offer(host.as_ref()),
        offers_saved_queries: matches!(
            app.saved_query_support(),
            SavedQuerySupport::Scripts | SavedQuerySupport::Consoles
        ),
    }
}

// The row a dialog that takes one app selects first: the available one with the most connections, the earlier on a
// tie, so an app that is installed but empty never wins over one that has data.
pub fn preselect(sources: &[ForeignSource]) -> Option<ForeignApp> {
    sources
        .iter()
        .filter(|source| source.availability == SourceAvailability::Available)
        .fold(None::<&ForeignSource>, |best, source| match best {
            Some(best) if best.inventory.connections >= source.inventory.connections => Some(best),
            _ => Some(source),
        })
        .map(|source| source.app)
}

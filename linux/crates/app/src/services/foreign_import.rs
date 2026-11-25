// The disk side of importing from another app, run off the GTK thread.

use std::sync::Arc;

use tablepro_core::DriverRegistry;
use tablepro_foreign_import::review::{ImportReview, ReviewInputs};
use tablepro_foreign_import::{
    ForeignApp, ForeignAppDirs, ForeignImportError, ForeignImporter, ForeignSource, ImportRequest, PasswordSource,
    PlainHost, SavedQuerySupport, ScanDepth, sources_blocking,
};
use tablepro_storage::{ConnectionStore, StorageError};
use tokio_util::sync::CancellationToken;

// The core caps one saved query at this.
pub(crate) const SAVED_QUERY_BYTE_LIMIT: u64 = 1024 * 1024;

#[derive(Debug)]
pub(crate) enum ReadFailure {
    Import(ForeignImportError),
    Library(StorageError),
}

pub(crate) fn importer(app: ForeignApp, dirs: &ForeignAppDirs) -> ForeignImporter {
    ForeignImporter::new(app, dirs.clone(), Arc::new(PlainHost))
}

pub(crate) fn look_for_apps_blocking(dirs: &ForeignAppDirs, depth: ScanDepth) -> Vec<ForeignSource> {
    sources_blocking(dirs, Arc::new(PlainHost), depth)
}

// A keychain app's passwords are asked for anyway, so its review says they stayed behind.
pub(crate) fn default_request(app: ForeignApp) -> ImportRequest {
    let offered = app.password_offer(&PlainHost).offered();
    ImportRequest {
        include_passwords: offered || app.password_source() == PasswordSource::Keychain,
        include_saved_queries: matches!(
            app.saved_query_support(),
            SavedQuerySupport::Scripts | SavedQuerySupport::Consoles
        ),
        saved_query_byte_limit: SAVED_QUERY_BYTE_LIMIT,
    }
}

// The list read here is the one the review checks duplicates against and the write expects.
pub(crate) struct ReviewRead {
    pub importer: ForeignImporter,
    pub request: ImportRequest,
    pub cancel: CancellationToken,
    pub connections: ConnectionStore,
    pub drivers: Arc<DriverRegistry>,
    pub dirs: ForeignAppDirs,
}

impl ReviewRead {
    pub(crate) fn run_blocking(&self) -> Result<ImportReview, ReadFailure> {
        let collected = self
            .importer
            .collect_blocking(&self.request, &self.cancel)
            .map_err(ReadFailure::Import)?;
        let library = self.connections.list_blocking().map_err(ReadFailure::Library)?;
        let file_exists = |path: &std::path::Path| path.exists();
        Ok(ImportReview::analyze(
            collected,
            ReviewInputs {
                drivers: &self.drivers,
                library,
                dirs: &self.dirs,
                file_exists: &file_exists,
            },
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_guide_asks_for_what_each_app_offers() {
        let dbeaver = default_request(ForeignApp::DBeaver);
        assert!(dbeaver.include_passwords);
        assert!(dbeaver.include_saved_queries);

        let tableplus = default_request(ForeignApp::TablePlus);
        assert!(
            tableplus.include_passwords,
            "a keychain app is asked, so the review says its passwords stayed behind"
        );

        let navicat = default_request(ForeignApp::Navicat);
        assert!(!navicat.include_saved_queries, "an export file holds no saved queries");
    }
}

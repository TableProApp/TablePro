// The disk side of importing from another app, run off the GTK thread.

use std::sync::Arc;

use tablepro_core::DriverRegistry;
use tablepro_foreign_import::review::{ImportReview, ReviewInputs};
use tablepro_foreign_import::{
    ForeignApp, ForeignAppDirs, ForeignImportError, ForeignImporter, ImportRequest, Inventory, PlainHost,
};
use tablepro_storage::{ConnectionStore, StorageError};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone, Copy)]
pub(crate) struct AppSource {
    pub app: ForeignApp,
    pub available: bool,
    pub inventory: Inventory,
}

#[derive(Debug)]
pub(crate) enum ReadFailure {
    Import(ForeignImportError),
    Library(StorageError),
}

pub(crate) fn importer(app: ForeignApp, dirs: &ForeignAppDirs) -> ForeignImporter {
    ForeignImporter::new(app, dirs.clone(), Arc::new(PlainHost))
}

pub(crate) fn look_for_apps_blocking(dirs: &ForeignAppDirs) -> Vec<AppSource> {
    ForeignApp::ALL
        .into_iter()
        .filter(|app| app.runs_on(dirs.platform))
        .map(|app| {
            let importer = importer(app, dirs);
            let available = importer.is_available_blocking();
            let inventory = if available && app.picked_file_extensions().is_none() {
                importer.inventory_blocking()
            } else {
                Inventory::default()
            };
            AppSource {
                app,
                available,
                inventory,
            }
        })
        .collect()
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

use std::sync::OnceLock;

use tablepro_storage::StoragePaths;

pub mod change_tracker;
pub mod column_widths;
pub mod connection_monitor;
pub mod connection_service;
pub mod database_service;
pub mod filter_settings;
pub mod history_availability;
pub mod history_service;
pub mod secret_labels;
pub mod secret_save_report;
pub mod single_instance;
pub mod structure_tracker;
pub mod workspace_state;

static PATHS: OnceLock<StoragePaths> = OnceLock::new();

/// `run()` installs the resolved paths before any component starts, so
/// the file-backed services below never resolve a directory themselves.
/// FA 3 replaces this with the services object.
pub fn install_paths(paths: StoragePaths) {
    let _ = PATHS.set(paths);
}

pub(crate) fn paths() -> Option<&'static StoragePaths> {
    PATHS.get()
}

/// Serialise and write durably at 0600, reporting where it failed.
pub(crate) fn write_json<T: serde::Serialize>(path: &std::path::Path, value: &T, what: &str) {
    let bytes = match serde_json::to_vec_pretty(value) {
        Ok(bytes) => bytes,
        Err(error) => {
            tracing::warn!(%error, what, "could not serialise state");
            return;
        }
    };
    if let Err(error) = tablepro_storage::fs::write_private_blocking(path, &bytes) {
        tracing::warn!(%error, what, "could not save state");
    }
}

use std::rc::Rc;
use std::sync::Arc;

use thiserror::Error;

use tablepro_core::DriverRegistry;
use tablepro_storage::{AppSettings, StoragePaths};

pub mod application;
pub mod config;
pub mod i18n;
pub mod logging;
mod persistence;
pub mod runtime;
mod services;
pub mod storage;
// Public for the save tests that run a tracker against a real server.
pub use services::{change_tracker, tab_tracker_handle, tracker_edit};
#[cfg(test)]
mod test_support;
mod ui;
mod workspace;

use application::{AppServices, TableProApplication};

#[derive(Debug, Error)]
pub enum StartupError {
    #[error("could not start logging: {0}")]
    Logging(#[from] logging::LoggingError),
    #[error("could not start the background runtime: {0}")]
    Runtime(#[source] std::io::Error),
    #[error("could not register the embedded resources: {0}")]
    Resources(#[source] glib::Error),
    #[error("could not open the settings schema: {0}")]
    Settings(#[from] tablepro_storage::SettingsError),
}

/// Start the application and return its exit code once the last window
/// and the last background close are gone.
pub fn run() -> Result<glib::ExitCode, StartupError> {
    // SAFETY: nothing above spawns a thread; the tokio runtime and GTK start later.
    let translations = unsafe { i18n::init() };
    logging::init(config::profile())?;
    if let Err(error) = translations {
        tracing::warn!(%error, "translations unavailable; falling back to the source strings");
    }

    let runtime = runtime::AppRuntime::build().map_err(StartupError::Runtime)?;
    gio::resources_register_include!("tablepro.gresource").map_err(StartupError::Resources)?;
    let settings = Rc::new(AppSettings::open(config::SCHEMA_ID)?);
    let paths = StoragePaths::from_glib(config::storage_dir_name(), config::APP_ID);
    let drivers = build_registry();
    tracing::info!(drivers = drivers.len(), "starting tablepro");

    let application = TableProApplication::new(AppServices::production(drivers, settings, paths, runtime.tasks()));
    let code = gio::prelude::ApplicationExtManual::run(&application);
    drop(application);

    // The main loop has returned, so nothing is producing work any
    // more. Give what is in flight a moment to finish rather than
    // dropping it mid-write.
    runtime.shutdown();
    Ok(code)
}

fn build_registry() -> DriverRegistry {
    let mut r = DriverRegistry::new();
    r.register(Arc::new(drivers_clickhouse::ClickhouseDriver));
    r.register(Arc::new(drivers_mssql::MssqlDriver));
    r.register(Arc::new(drivers_mysql::MysqlDriver));
    r.register(Arc::new(drivers_postgres::PgDriver));
    r.register(Arc::new(drivers_sqlite::SqliteDriver));
    r
}

#[cfg(test)]
pub(crate) fn register_test_resources() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        gio::resources_register_include!("tablepro.gresource").expect("embedded resources");
    });
}

#[cfg(test)]
mod tests {
    use glib::prelude::ObjectExt;
    use libadwaita as adw;

    use super::register_test_resources;
    use super::*;

    #[test]
    fn resources_contain_style_css() {
        register_test_resources();

        let data = gio::resources_lookup_data(
            &format!("{}/style.css", config::RESOURCE_BASE_PATH),
            gio::ResourceLookupFlags::NONE,
        )
        .expect("style.css is embedded at the resource base path");

        assert!(String::from_utf8_lossy(&data).contains(".tp-cell-modified"));
    }

    #[gtk4::test]
    fn shortcuts_dialog_resource_builds() {
        adw::init().expect("libadwaita initialises under the test backend");
        register_test_resources();

        let builder = gtk4::Builder::from_resource(&format!("{}/shortcuts-dialog.ui", config::RESOURCE_BASE_PATH));
        let dialog = builder
            .object::<adw::ShortcutsDialog>("shortcuts_dialog")
            .expect("shortcuts_dialog is an AdwShortcutsDialog");

        assert_eq!(dialog.type_().name(), "AdwShortcutsDialog");
    }
}

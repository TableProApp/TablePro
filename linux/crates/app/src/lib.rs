use std::sync::Arc;

use libadwaita as adw;
use relm4::RelmApp;
use thiserror::Error;

use tablepro_core::DriverRegistry;

pub mod config;
pub mod i18n;
pub mod logging;
mod persistence;
pub mod runtime;
mod services;
pub mod session;
pub mod storage;
#[cfg(test)]
mod test_support;
mod ui;
mod workspace;

#[derive(Debug, Error)]
enum StartupError {
    #[error("could not start the background runtime: {0}")]
    Runtime(#[source] std::io::Error),
    #[error("could not register the embedded resources: {0}")]
    Resources(#[source] glib::Error),
    #[error("could not open the settings schema: {0}")]
    Settings(#[from] tablepro_storage::SettingsError),
    #[error("could not start logging: {0}")]
    Logging(#[from] logging::LoggingError),
}

pub fn run() -> glib::ExitCode {
    // SAFETY: nothing above spawns a thread; the tokio runtime and GTK start later.
    let translations = unsafe { i18n::init() };

    if let Err(error) = logging::init(config::profile()) {
        // Nothing is journalling yet, so this is the one place that has
        // to reach the session log by another route.
        glib::g_critical!("tablepro", "{error}");
        return glib::ExitCode::FAILURE;
    }
    if let Err(error) = translations {
        tracing::warn!(%error, "translations unavailable; falling back to the source strings");
    }

    match start() {
        Ok(()) => glib::ExitCode::SUCCESS,
        Err(error) => {
            tracing::error!(%error, "TablePro could not start");
            glib::ExitCode::FAILURE
        }
    }
}

fn start() -> Result<(), StartupError> {
    // Single-instance gate: belt-and-suspenders flock on top of
    // gtk::Application's DBus-based uniqueness, since the latter
    // silently lets two processes through when DBus is unavailable.
    // A second instance corrupts workspace_state.json via concurrent
    // read-modify-write. Hold the lock through the entire `start`.
    let paths = tablepro_storage::StoragePaths::from_glib(config::storage_dir_name(), config::APP_ID);
    services::install_paths(paths.clone());

    let _instance_lock = match services::single_instance::acquire(&paths) {
        Ok(lock) => Some(lock),
        Err(services::single_instance::LockError::AlreadyRunning) => {
            tracing::info!("another TablePro instance is running; exiting");
            return Ok(());
        }
        Err(e) => {
            // No XDG runtime, cache or HOME: proceed without the
            // lock. gtk::Application's uniqueness still applies.
            tracing::warn!(error = %e, "single-instance lock unavailable; relying on DBus uniqueness");
            None
        }
    };

    let settings = std::rc::Rc::new(tablepro_storage::AppSettings::open(config::SCHEMA_ID)?);
    let runtime = runtime::AppRuntime::build().map_err(StartupError::Runtime)?;
    let tasks = runtime.tasks();
    // The database migrates and prunes on open, which is too slow to
    // hold up the first window. The menu item that needs it stays
    // disabled until the service reports Ready.
    let history =
        services::history_service::HistoryService::start(paths.clone(), settings.history_retention_days(), &tasks);
    let storage = std::rc::Rc::new(storage::AppStorage::new(
        paths,
        std::sync::Arc::new(tablepro_storage::SecretStore::new(config::secret_schema())),
        &tasks,
    ));

    let registry = Arc::new(build_registry());
    tracing::info!(drivers = registry.len(), "starting tablepro");

    gio::resources_register_include!("tablepro.gresource").map_err(StartupError::Resources)?;

    let app = RelmApp::from_app(
        adw::Application::builder()
            .application_id(config::APP_ID)
            .resource_base_path(config::RESOURCE_BASE_PATH)
            .build(),
    );
    app.run::<ui::App>(ui::AppInit {
        registry,
        settings,
        storage,
        tasks,
        history,
    });

    // The main loop has returned, so nothing is producing work any
    // more. Give what is in flight a moment to finish rather than
    // dropping it mid-write.
    runtime.shutdown();
    Ok(())
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
    use gio::prelude::ApplicationExt;

    use super::register_test_resources;
    use glib::prelude::ObjectExt;

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

    #[gtk4::test]
    fn application_uses_explicit_resource_base_path() {
        let app = adw::Application::builder()
            .application_id(config::APP_ID)
            .resource_base_path(config::RESOURCE_BASE_PATH)
            .build();

        assert_eq!(app.resource_base_path().as_deref(), Some(config::RESOURCE_BASE_PATH));
    }
}

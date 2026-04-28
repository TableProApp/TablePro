use std::sync::Arc;

use relm4::RelmApp;

use tablepro_core::DriverRegistry;

mod i18n;
mod services;
mod ui;

const APP_ID: &str = "com.tablepro.linux";

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env().add_directive(tracing::Level::INFO.into()))
        .with_target(false)
        .init();

    i18n::init();

    // Single-instance gate: belt-and-suspenders flock on top of
    // gtk::Application's DBus-based uniqueness, since the latter
    // silently lets two processes through when DBus is unavailable.
    // A second instance corrupts workspace_state.json via concurrent
    // read-modify-write. Hold the lock through the entire `main`.
    let _instance_lock = match services::single_instance::acquire() {
        Ok(lock) => Some(lock),
        Err(services::single_instance::LockError::AlreadyRunning) => {
            tracing::info!("another TablePro instance is running; exiting");
            return;
        }
        Err(e) => {
            // No XDG runtime / cache / HOME — proceed without the
            // lock. gtk::Application's uniqueness still applies.
            tracing::warn!(error = %e, "single-instance lock unavailable; relying on DBus uniqueness");
            None
        }
    };

    let prefs = services::preferences::load();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
        .expect("history runtime");
    runtime.block_on(async {
        if let Err(e) = tablepro_storage::query_history::init().await {
            tracing::warn!(error = %e, "history init failed; feature disabled");
        } else if let Err(e) = tablepro_storage::query_history::prune_older_than(prefs.history_retention_days).await {
            tracing::warn!(error = %e, "history prune failed");
        }
    });

    let registry = Arc::new(build_registry());
    tracing::info!(drivers = registry.len(), "starting tablepro-app");

    let app = RelmApp::new(APP_ID);
    app.run::<ui::App>(registry);

    // Explicit ordered shutdown: `app.run` returned (window closed),
    // so let the tokio runtime's worker threads finish in-flight
    // tasks rather than getting cancelled mid-flight by an abrupt
    // mem::forget-style leak. The previous `mem::forget(runtime)`
    // was a workaround for an sqlx-pool reaper concern that no
    // longer applies — the history pool sits in a global OnceLock
    // and stays usable from relm4's runtime; this runtime here is
    // only used for the startup init / prune block_on above.
    runtime.shutdown_timeout(std::time::Duration::from_secs(2));
}

fn build_registry() -> DriverRegistry {
    let mut r = DriverRegistry::new();
    r.register(Arc::new(drivers_mysql::MysqlDriver));
    r.register(Arc::new(drivers_postgres::PgDriver));
    r.register(Arc::new(drivers_sqlite::SqliteDriver));
    r
}

use std::sync::Arc;

use relm4::RelmApp;

use tablepro_core::DriverRegistry;

pub mod config;
mod i18n;
pub mod logging;
mod services;
mod ui;

const MIN_ASYNC_WORKERS: usize = 2;
const MAX_ASYNC_WORKERS: usize = 4;

pub fn run() {
    glib::set_prgname(Some(config::APP_ID));
    tablepro_transport::install_crypto_provider();
    i18n::init();

    if let Err(error) = logging::init(config::profile()) {
        glib::g_critical!("bookie", "{error}");
        return;
    }
    tablepro_policy::withhold_panic_messages();
    configure_async_runtime();
    if let Err(error) = gtk4::gio::resources_register_include!("tablepro.gresource") {
        tracing::error!(%error, "could not register application resources");
        return;
    }

    // Single-instance gate: belt-and-suspenders flock on top of
    // gtk::Application's DBus-based uniqueness, since the latter
    // silently lets two processes through when DBus is unavailable.
    // A second instance corrupts workspace_state.json via concurrent
    // read-modify-write. Hold the lock through the entire `main`.
    let _instance_lock = match services::single_instance::acquire() {
        Ok(lock) => Some(lock),
        Err(services::single_instance::LockError::AlreadyRunning) => {
            services::single_instance::raise_running_instance(config::APP_ID);
            return;
        }
        Err(e) => {
            // No XDG runtime / cache / HOME — proceed without the
            // lock. gtk::Application's uniqueness still applies.
            tracing::warn!(error = %e, "single-instance lock unavailable; relying on DBus uniqueness");
            None
        }
    };

    let preferences = services::preferences::PreferencesStore::new();
    let prefs = preferences.load();
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
    {
        Ok(runtime) => Some(runtime),
        Err(e) => {
            tracing::warn!(error = %e, "history runtime unavailable; feature disabled");
            None
        }
    };
    let history_open = runtime.as_ref().map(|runtime| {
        let retention_days = prefs.history_retention_days;
        runtime.spawn(async move {
            match tablepro_storage::query_history::HistoryStore::open_default().await {
                Ok(store) => {
                    let pruning = store.clone();
                    tokio::spawn(async move {
                        if let Err(e) = pruning.prune_older_than(retention_days).await {
                            tracing::warn!(error = %e, "history prune failed");
                        }
                    });
                    Some(store)
                }
                Err(e) => {
                    tracing::warn!(error = %e, "history init failed; feature disabled");
                    None
                }
            }
        })
    });

    let registry = Arc::new(build_registry());
    let persistence = services::persistence_stores::PersistenceStores::open();
    let workspace = services::workspace_state::create_store();
    workspace.discard_preview_tabs();
    let database = Arc::new(services::database_service::DatabaseService::new());
    tracing::info!(drivers = registry.len(), "starting tablepro-app");

    let approval_router = services::approval_router::ApprovalRouter::new(
        Arc::new(services::gtk_approval::GtkApprovalSink),
        Arc::new(services::gtk_approval::GtkApprovalSink),
    );
    database.set_approval_sink(Arc::new(approval_router));

    let mcp_server = services::mcp_service::start_background(database.clone());
    let mcp_bridge = mcp_server.as_ref().map(|server| server.bridge.clone());
    enable_system_openssh(database.clone());
    let history = history_open.and_then(|task| runtime.as_ref()?.block_on(task).ok().flatten());

    let app = initialize_ui();
    services::ui_stall::install_from_env();
    app.run::<ui::App>(ui::AppInit {
        registry,
        persistence: persistence.clone(),
        workspace,
        history,
        database,
        preferences: preferences.clone(),
        mcp_bridge,
    });

    if let Some(server) = mcp_server {
        server.shutdown();
    }
    persistence.flush();
    if let Err(error) = preferences.flush() {
        tracing::warn!(%error, "preferences flush failed");
    }

    // Dropping a tokio runtime cancels its in-flight tasks at once;
    // shutdown_timeout lets the worker threads finish first.
    if let Some(runtime) = runtime {
        runtime.shutdown_timeout(std::time::Duration::from_secs(2));
    }
}

fn configure_async_runtime() {
    let available = std::thread::available_parallelism()
        .ok()
        .map(std::num::NonZeroUsize::get);
    let workers = async_worker_threads(available);
    if relm4::RELM_THREADS.set(workers).is_err() {
        tracing::warn!(workers, "async runtime was configured before startup");
    }
}

fn async_worker_threads(available: Option<usize>) -> usize {
    available.map_or(MIN_ASYNC_WORKERS, |count| {
        count.clamp(MIN_ASYNC_WORKERS, MAX_ASYNC_WORKERS)
    })
}

fn initialize_ui() -> RelmApp<<ui::App as relm4::Component>::Input> {
    use gtk4::prelude::*;

    let app = RelmApp::new(config::APP_ID);
    sourceview5::init();
    let application = relm4::main_application();
    application.set_flags(gtk4::gio::ApplicationFlags::HANDLES_OPEN);
    application.connect_activate(|app| {
        if let Some(window) = app.active_window() {
            tracing::info!("main window activated");
            window.present();
        }
    });
    app
}

fn build_registry() -> DriverRegistry {
    let mut r = DriverRegistry::new();
    r.register(Arc::new(drivers_clickhouse::ClickhouseDriver));
    #[cfg(feature = "duckdb")]
    r.register(Arc::new(drivers_duckdb::DuckdbDriver));
    r.register(Arc::new(drivers_mongodb::MongodbDriver));
    r.register(Arc::new(drivers_mssql::MssqlDriver));
    r.register(Arc::new(drivers_mysql::MysqlDriver));
    r.register(Arc::new(drivers_postgres::PgDriver));
    r.register(Arc::new(drivers_redis::RedisDriver));
    r.register(Arc::new(drivers_sqlite::SqliteDriver));
    r
}

fn enable_system_openssh(database: Arc<services::database_service::DatabaseService>) {
    database.enable_builtin_ssh_prompter(Arc::new(ui::GtkPrompter));
    relm4::spawn(async move {
        match tablepro_transport::system_openssh(Arc::new(ui::GtkPrompter)).await {
            Ok(openssh) => database.enable_system_openssh(openssh),
            Err(error) => tracing::info!(error = %error, "system OpenSSH connections are unavailable"),
        }
    });
}

#[cfg(test)]
mod tests {
    use super::async_worker_threads;

    #[test]
    fn database_commands_never_share_a_single_async_worker() {
        assert_eq!(async_worker_threads(None), 2);
        assert_eq!(async_worker_threads(Some(1)), 2);
        assert_eq!(async_worker_threads(Some(3)), 3);
        assert_eq!(async_worker_threads(Some(64)), 4);
    }
}

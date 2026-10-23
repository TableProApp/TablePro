use std::io::Write;
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
const MIN_GTK: (u32, u32, u32) = (4, 24, 0);
const MIN_ADWAITA: (u32, u32, u32) = (1, 10, 0);
const MIN_SOURCEVIEW: (u32, u32, u32) = (5, 22, 0);

pub fn run() {
    initialize_toolkit_or_exit();
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

fn initialize_toolkit_or_exit() {
    if let Err(error) = gtk4::init() {
        let _ = writeln!(std::io::stderr(), "BookiE could not open a graphical display: {error}");
        std::process::exit(1);
    }
    let gtk = (gtk4::major_version(), gtk4::minor_version(), gtk4::micro_version());
    let adwaita = (
        libadwaita::major_version(),
        libadwaita::minor_version(),
        libadwaita::micro_version(),
    );
    let sourceview = (
        sourceview5::major_version(),
        sourceview5::minor_version(),
        sourceview5::micro_version(),
    );
    if toolkit_is_supported(gtk, adwaita, sourceview) {
        return;
    }
    let _ = writeln!(
        std::io::stderr(),
        "BookiE needs GTK 4.24, libadwaita 1.10 and GtkSourceView 5.22 or newer; this system has GTK {}.{}.{}, \
         libadwaita {}.{}.{} and GtkSourceView {}.{}.{}",
        gtk.0,
        gtk.1,
        gtk.2,
        adwaita.0,
        adwaita.1,
        adwaita.2,
        sourceview.0,
        sourceview.1,
        sourceview.2
    );
    std::process::exit(1);
}

fn toolkit_is_supported(gtk: (u32, u32, u32), adwaita: (u32, u32, u32), sourceview: (u32, u32, u32)) -> bool {
    gtk >= MIN_GTK && adwaita >= MIN_ADWAITA && sourceview >= MIN_SOURCEVIEW
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
    #[cfg(test)]
    let app = app.with_args(vec!["bookie".to_owned()]);
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
    use super::{MIN_ADWAITA, MIN_GTK, MIN_SOURCEVIEW, async_worker_threads, toolkit_is_supported};

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn startup_reaches_the_application_loop_with_supported_toolkits() {
        let reached = std::rc::Rc::new(std::cell::Cell::new(false));
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        glib::timeout_add_local(std::time::Duration::from_millis(25), {
            let reached = reached.clone();
            move || {
                use gtk4::prelude::*;
                let app = relm4::main_application();
                if app.active_window().is_some_and(|window| window.is_mapped()) {
                    reached.set(true);
                    app.quit();
                    return glib::ControlFlow::Break;
                }
                if std::time::Instant::now() >= deadline {
                    app.quit();
                    return glib::ControlFlow::Break;
                }
                glib::ControlFlow::Continue
            }
        });
        super::run();
        assert!(reached.get());
    }

    #[test]
    fn database_commands_never_share_a_single_async_worker() {
        assert_eq!(async_worker_threads(None), 2);
        assert_eq!(async_worker_threads(Some(1)), 2);
        assert_eq!(async_worker_threads(Some(3)), 3);
        assert_eq!(async_worker_threads(Some(64)), 4);
    }

    #[test]
    fn toolkit_floor_accepts_equal_or_newer_libraries_and_rejects_older_ones() {
        let floor = (MIN_GTK, MIN_ADWAITA, MIN_SOURCEVIEW);
        assert!(toolkit_is_supported(floor.0, floor.1, floor.2));
        assert!(toolkit_is_supported((4, 24, 1), (1, 10, 0), (5, 22, 0)));
        assert!(toolkit_is_supported((4, 26, 0), (1, 11, 0), (5, 24, 0)));
        assert!(toolkit_is_supported((5, 0, 0), (2, 0, 0), (6, 0, 0)));
        assert!(!toolkit_is_supported((4, 22, 4), floor.1, floor.2));
        assert!(!toolkit_is_supported((3, 99, 0), floor.1, floor.2));
        assert!(!toolkit_is_supported(floor.0, (1, 9, 1), floor.2));
        assert!(!toolkit_is_supported(floor.0, (0, 99, 0), floor.2));
        assert!(!toolkit_is_supported(floor.0, floor.1, (5, 18, 0)));
        assert!(!toolkit_is_supported(floor.0, floor.1, (4, 99, 0)));
    }
}

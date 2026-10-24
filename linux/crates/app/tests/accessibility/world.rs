//! A TablePro over fakes, driven on the main context the way a user's
//! clicks drive it.

use std::path::Path;
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use tablepro_app::application::{AppServices, AppServicesParts, TableProApplication, WindowLaunch};
use tablepro_app::runtime::AppRuntime;
use tablepro_app::storage::AppStorage;
use tablepro_core::{AuthMode, DriverRegistry, LivenessPolicy, TlsConfig};
use tablepro_session::fakes::FakeConnector;
use tablepro_session::operation::DefaultDeadlines;
use tablepro_storage::{
    AppSettings, ConnectionColor, ConnectionIcon, ConnectionTagName, SavedConnection, StoragePaths,
};
use tablepro_test_support::FakeSecretVault;

/// Long enough for a page to settle on a loaded CI runner.
const WAIT: Duration = Duration::from_secs(20);

/// One application with a saved connection in its list. Its id is its
/// own, so a TablePro the developer has open never answers for it on the
/// session bus.
pub struct World {
    pub app: TableProApplication,
    pub saved: SavedConnection,
    runtime: Option<AppRuntime>,
    _dir: tempfile::TempDir,
}

impl World {
    pub fn start(name: &str, drivers: DriverRegistry, connector: FakeConnector) -> Result<Self, String> {
        let dir = tempfile::tempdir().map_err(|error| format!("no temporary directory: {error}"))?;
        let runtime = AppRuntime::build().map_err(|error| format!("no runtime: {error}"))?;
        let settings = Rc::new(settings(dir.path())?);
        let paths = StoragePaths::under(dir.path(), "tablepro", tablepro_app::config::APP_ID);
        let storage = AppStorage::new(paths, Arc::new(FakeSecretVault::new()), &runtime.tasks());
        // A tag, so its pills and its rows are audited too.
        let tag = storage
            .connections()
            .create_tag_blocking(
                ConnectionTagName::new("production").map_err(|error| error.to_string())?,
                ConnectionColor::Red,
            )
            .map_err(|error| format!("could not save the tag: {error}"))?;
        let saved = SavedConnection {
            tags: vec![tag.id],
            icon: Some(ConnectionIcon::Server),
            ..saved_connection(&dir.path().join("fake.db"))
        };
        storage
            .connections()
            .upsert_blocking(saved.clone())
            .map_err(|error| format!("could not save the connection: {error}"))?;
        let liveness = LivenessPolicy::DESKTOP;
        let services = AppServices::new(AppServicesParts {
            drivers,
            connector: Arc::new(connector),
            deadlines: Arc::new(DefaultDeadlines::new(liveness)),
            liveness,
            settings,
            storage,
            tasks: runtime.tasks(),
        });
        let app = TableProApplication::new(services);
        app.set_application_id(Some(&format!(
            "{}.Test.Accessibility.{name}",
            tablepro_app::config::APP_ID
        )));
        app.register(gio::Cancellable::NONE)
            .map_err(|error| format!("could not register the application: {error}"))?;
        Ok(Self {
            app,
            saved,
            runtime: Some(runtime),
            _dir: dir,
        })
    }

    pub fn open(&self, launch: WindowLaunch) -> Result<adw::ApplicationWindow, String> {
        self.app
            .open_window(launch)
            .ok_or_else(|| "the application opened no window".to_owned())
    }
}

impl Drop for World {
    fn drop(&mut self) {
        for window in self.app.windows() {
            window.destroy();
        }
        drain_main_context();
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown();
        }
    }
}

/// Run the main context until `ready` holds.
pub fn wait_until(what: &str, mut ready: impl FnMut() -> bool) -> Result<(), String> {
    let context = glib::MainContext::default();
    let wake = glib::timeout_add_local(Duration::from_millis(10), || glib::ControlFlow::Continue);
    let deadline = Instant::now() + WAIT;
    let outcome = loop {
        if ready() {
            break Ok(());
        }
        if Instant::now() >= deadline {
            break Err(format!("timed out waiting for {what}"));
        }
        context.iteration(true);
    };
    wake.remove();
    outcome
}

pub fn drain_main_context() {
    let context = glib::MainContext::default();
    while context.iteration(false) {}
}

fn saved_connection(database: &Path) -> SavedConnection {
    SavedConnection {
        id: uuid::Uuid::new_v4(),
        name: "Fake".to_owned(),
        driver_id: "fake".to_owned(),
        host: String::new(),
        port: 0,
        database: database.display().to_string(),
        username: String::new(),
        tls: TlsConfig::verify_full(),
        safe_mode: tablepro_core::SafeModeLevel::Off,
        external_access: tablepro_core::ExternalAccess::ReadOnly,
        ai_policy: tablepro_core::AiPolicy::Ask,
        auth_mode: AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group: None,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
    }
}

/// The schema compiled into the world's own directory behind a memory
/// backend, so a run never reads or writes the developer's settings.
fn settings(dir: &Path) -> Result<AppSettings, String> {
    let schemas = dir.join("schemas");
    std::fs::create_dir_all(&schemas).map_err(|error| format!("could not create the schema directory: {error}"))?;
    crate::settings_schema::compile(&schemas, &[tablepro_app::config::APP_ID])?;
    AppSettings::with_backend(
        tablepro_app::config::APP_ID,
        &schemas,
        &gio::memory_settings_backend_new(),
    )
    .map_err(|error| format!("could not open the settings: {error}"))
}

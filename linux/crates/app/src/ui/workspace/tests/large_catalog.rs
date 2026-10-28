//! The connection tree and the editor's completion over 50,000 tables on
//! a real server: PostgreSQL with 100 schemas of 500 tables, the default
//! schema among them, and MySQL with one database of 50,000. The tree
//! lists the session under its connection with the default schema open
//! while the search is typed. Each step has a time bound, the main loop
//! may never stall past `STALL_LIMIT`, and the catalog may not raise the
//! resident peak past `MEMORY_LIMIT`.
//!
//! The peak is the whole process's, so the case needs a process to
//! itself, which nextest gives every test.

use std::cell::RefCell;
use std::collections::HashSet;
use std::ops::Range;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use secrecy::SecretString;
use sourceview5::prelude::*;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_core::statement::{GuardedStatement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, Credentials, DatabaseDriver,
    ForeignKeyMode, LivenessPolicy, NetworkEndpoint, NetworkTarget, TlsConfig, WorkspaceSettings, WriteBatch,
    WriteKind,
};
use tablepro_driver_mysql::MysqlDriver;
use tablepro_driver_postgres::PgDriver;
use tablepro_net::DirectTcpTransport;
use tablepro_session::runtime::{CountingHold, Tasks};
use tablepro_session::{
    ConnectRequest, ConnectServices, ConnectionMetadata, Connector, DefaultDeadlines, DriverConnector,
    NoStoredCredentials, RequestTarget, Session, SessionDeps, SessionKey,
};
use tablepro_ssh::{SshRuntimeCell, SshServices};
use tablepro_test_fixtures::{FixtureCredentials, HbaMode, MysqlFixture, MysqlFlavour, MysqlOptions, PostgresFixture};
use tablepro_test_support::conformance::ResidentPeak;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

use super::super::sidebar::tests::{found, listed};
use super::super::sidebar::{ConnectionTree, SidebarAffordances, SidebarView, list_catalog};
use crate::services::active_session::ActiveSession;
use crate::services::saved_connection_list::SavedConnectionList;
use crate::test_support::{
    MemorySettings, StallProbe, after_next_frame, descendants, finish_on_main, test_runtime, wait_until,
};
use crate::ui::editor::{SqlEditor, SqlEditorInit};

const TABLES: usize = 50_000;

/// PostgreSQL's schemas, each holding an equal share of the tables.
const SCHEMAS: usize = 100;

/// Tables are named for what a tenant's schema holds, and numbered
/// across the whole catalog, so a list shows which schema it came from.
const KINDS: [&str; 10] = [
    "accounts",
    "audit_log",
    "customers",
    "events",
    "invoices",
    "orders",
    "payments",
    "products",
    "sessions",
    "users",
];

/// The search typed into the sidebar, a key at a time, then cleared.
const SEARCHES: [&str; 3] = ["i", "in", ""];

/// The key typed while the completion list after `FROM ` shows.
const NARROW: &str = "i";

/// The table whose tab is in front during the searches, one of the
/// default schema's that every search keeps.
const OPEN_TABLE: usize = 4;

/// Connections that fill the catalog at once.
const FILLERS: usize = 4;

/// MySQL creates a table in milliseconds, so 50,000 take minutes. The
/// `ci` nextest profile gives these cases longer than this.
const SETUP_LIMIT: Duration = Duration::from_secs(600);
const STEP_LIMIT: Duration = Duration::from_secs(30);

/// What a user sees as a frozen window.
const STALL_LIMIT: Duration = Duration::from_millis(100);

// The time bounds sit three to five times over the first CI run of a
// debug build, the slower engine of the two: listing 624 ms, a search
// key 62 ms, completion 2.6 s after MySQL's dot, a key typed into it
// 57 ms.

/// From asking for every schema's tables to the tree listing them.
const LISTING_LIMIT: Duration = Duration::from_secs(3);

/// From a key in the tree's search to the rows it leaves.
const SEARCH_LIMIT: Duration = Duration::from_millis(250);

/// From asking for completion to the list on screen, the catalog read
/// included where the session has not read that list yet.
const COMPLETION_LIMIT: Duration = Duration::from_secs(8);

/// From a key typed in the completion's word to the list it leaves.
const NARROW_LIMIT: Duration = Duration::from_millis(250);

/// How far the catalog in the session, the tree and the completion
/// lists may raise the process's resident peak: twice what MySQL's
/// 50,000 tables took in the first CI run, 128 MiB.
const MEMORY_LIMIT: u64 = 256 * 1024 * 1024;

#[gtk4::test]
#[ignore = "requires docker"]
fn postgres_100_schemas_of_500_tables_list_search_and_complete() {
    large_catalog_case(Engine::Postgres);
}

#[gtk4::test]
#[ignore = "requires docker"]
fn mysql_database_of_50000_tables_lists_searches_and_completes() {
    large_catalog_case(Engine::Mysql);
}

fn large_catalog_case(engine: Engine) {
    adw::init().expect("libadwaita initialises under the test backend");
    crate::register_test_resources();
    if let Some(settings) = gtk4::Settings::default() {
        settings.set_gtk_enable_animations(false);
    }
    let runtime = test_runtime();
    let tasks = runtime.tasks();
    let catalog = Catalog::of(engine);
    let mut server = Server::start(engine, &catalog);
    let started = server.started();
    // The connect reads the default schema's list, which on MySQL is
    // every table, so the peak counts from before it.
    let peak = ResidentPeak::start().expect("the resident peak");
    let session = connect(&started.request, &tasks);
    let screen = Screen::new(&session, &tasks);
    let probe = StallProbe::start();

    let listing = screen.list(&probe, &session, &tasks, catalog.objects.len());
    screen.open_schema(catalog.default_schema());
    // A table tab in front keeps its row selected through the searches.
    screen.tree.select(Some(&screen.key), catalog.objects.get(OPEN_TABLE));
    let searches = SEARCHES.map(|query| screen.search(&probe, query, catalog.matching(query)));
    let from = screen.complete(&probe, "SELECT * FROM ", catalog.default_names());
    let narrow = screen.narrow(&probe, NARROW, catalog.default_names());
    let qualified = screen.complete(
        &probe,
        &format!("SELECT * FROM {}.", catalog.probed_schema()),
        catalog.names_in(catalog.probed_schema()),
    );
    let growth = peak.growth().expect("the resident peak");

    let measured = Measured {
        engine,
        fill: started.filled,
        listing,
        searches,
        from,
        narrow,
        qualified,
        growth,
    };
    report(&measured);
    drop(screen);
    let closed = finish_on_main(
        STEP_LIMIT,
        tasks.spawn_task(async move { session.begin_shutdown().await }),
    )
    .expect("the session closes");
    assert!(matches!(closed, Ok(Ok(_))), "the session did not close: {closed:?}");
    drop(server);
    runtime.shutdown();
    check_bounds(&measured);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Engine {
    Postgres,
    Mysql,
}

/// The catalog the server is filled with.
struct Catalog {
    /// Each schema and the tables it holds, by their index.
    schemas: Vec<(String, Range<usize>)>,
    objects: Vec<TableRef>,
}

impl Catalog {
    fn of(engine: Engine) -> Self {
        let schemas: Vec<(String, Range<usize>)> = match engine {
            Engine::Postgres => {
                let share = TABLES / SCHEMAS;
                (0..SCHEMAS)
                    .map(|schema| {
                        let name = if schema == 0 {
                            "public".to_owned()
                        } else {
                            format!("tenant_{schema:03}")
                        };
                        (name, schema * share..(schema + 1) * share)
                    })
                    .collect()
            }
            Engine::Mysql => vec![(MYSQL_DATABASE.to_owned(), 0..TABLES)],
        };
        let objects = schemas
            .iter()
            .flat_map(|(schema, tables)| {
                tables
                    .clone()
                    .map(move |index| TableRef::new(Some(schema.clone()), table_name(index)))
            })
            .collect();
        Self { schemas, objects }
    }

    /// The tables the sidebar's search keeps for `query`.
    fn matching(&self, query: &str) -> u32 {
        let count = self
            .objects
            .iter()
            .filter(|table| {
                let schema = table.schema.as_deref().unwrap_or_default();
                format!("{schema}.{}", table.name).contains(query)
            })
            .count();
        u32::try_from(count).unwrap_or(u32::MAX)
    }

    fn names_in(&self, schema: &str) -> HashSet<String> {
        self.schemas
            .iter()
            .filter(|(name, _)| name == schema)
            .flat_map(|(_, tables)| tables.clone().map(table_name))
            .collect()
    }

    /// The tables of the schema the connection starts in.
    fn default_names(&self) -> HashSet<String> {
        self.names_in(self.default_schema())
    }

    fn default_schema(&self) -> &str {
        self.schemas.first().map_or("", |(schema, _)| schema.as_str())
    }

    /// The schema typed before a dot: one of PostgreSQL's tenants, and
    /// MySQL's only database.
    fn probed_schema(&self) -> &str {
        let at = (self.schemas.len() / 2).min(self.schemas.len().saturating_sub(1));
        self.schemas.get(at).map_or("", |(schema, _)| schema.as_str())
    }
}

fn table_name(index: usize) -> String {
    format!("{}_{:05}", KINDS[index % KINDS.len()], index / KINDS.len())
}

const MYSQL_DATABASE: &str = "tablepro";

/// A server started and filled on a thread of its own, which keeps it
/// until the server is dropped, so a test that fails does not leave it
/// running. testcontainers' exec is not `Send`, so the thread runs a
/// current-thread runtime rather than the app's.
struct Server {
    ready: Option<oneshot::Receiver<Result<Started, String>>>,
    stop: Option<oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

struct Started {
    request: ConnectRequest,
    filled: Duration,
}

enum Fixture {
    Postgres(PostgresFixture),
    Mysql(MysqlFixture),
}

impl Server {
    fn start(engine: Engine, catalog: &Catalog) -> Self {
        let (ready, started) = oneshot::channel();
        let (stop, stopping) = oneshot::channel::<()>();
        let schemas = catalog.schemas.clone();
        let thread = std::thread::spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                Ok(runtime) => runtime,
                Err(error) => {
                    let _ = ready.send(Err(error.to_string()));
                    return;
                }
            };
            runtime.block_on(serve(engine, schemas, ready, stopping));
        });
        Self {
            ready: Some(started),
            stop: Some(stop),
            thread: Some(thread),
        }
    }

    /// Wait for the server to start and its tables to be created.
    fn started(&mut self) -> Started {
        let ready = self.ready.take().expect("the server is waited for once");
        finish_on_main(SETUP_LIMIT, ready)
            .expect("the server starts and fills within the setup limit")
            .expect("the server's thread ends only after it answers")
            .unwrap_or_else(|error| panic!("the server did not start: {error}"))
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let Some(thread) = self.thread.take() else {
            return;
        };
        if wait_until(STEP_LIMIT, || thread.is_finished()).is_err() {
            tracing::warn!("the test's container was not removed");
            return;
        }
        let _ = thread.join();
    }
}

/// Start the server and fill it, unless the test stops first, then hold
/// it until the test is done with it.
async fn serve(
    engine: Engine,
    schemas: Vec<(String, Range<usize>)>,
    ready: oneshot::Sender<Result<Started, String>>,
    mut stopping: oneshot::Receiver<()>,
) {
    let fixture = tokio::select! {
        fixture = Fixture::start(engine) => fixture,
        _ = &mut stopping => return,
    };
    let fixture = match fixture {
        Ok(fixture) => fixture,
        Err(error) => {
            let _ = ready.send(Err(error));
            return;
        }
    };
    let filling = Instant::now();
    tokio::select! {
        filled = fixture.fill(&schemas) => {
            let started = filled.map(|()| Started {
                request: fixture.request(),
                filled: filling.elapsed(),
            });
            let _ = ready.send(started);
            let _ = stopping.await;
        }
        _ = &mut stopping => {}
    }
    drop(fixture);
}

impl Fixture {
    async fn start(engine: Engine) -> Result<Self, String> {
        match engine {
            Engine::Postgres => PostgresFixture::start(HbaMode::Password)
                .await
                .map(Self::Postgres)
                .map_err(|error| error.to_string()),
            // The fill is DDL only: no binary log, no flush per commit
            // and no file per table.
            Engine::Mysql => MysqlFixture::start_with(
                MysqlOptions::new(MysqlFlavour::Mysql)
                    .allowing_plaintext()
                    .with_server_argument("--skip-log-bin")
                    .with_server_argument("--innodb-flush-log-at-trx-commit=0")
                    .with_server_argument("--innodb-file-per-table=OFF"),
                None,
            )
            .await
            .map(Self::Mysql)
            .map_err(|error| error.to_string()),
        }
    }

    fn driver(&self) -> Arc<dyn DatabaseDriver> {
        match self {
            Self::Postgres(_) => Arc::new(PgDriver),
            Self::Mysql(_) => Arc::new(MysqlDriver),
        }
    }

    fn endpoint(&self) -> NetworkEndpoint {
        let (host, port) = match self {
            Self::Postgres(fixture) => (fixture.host(), fixture.port()),
            Self::Mysql(fixture) => (fixture.host(), fixture.port()),
        };
        NetworkEndpoint::new(host, port).expect("a valid endpoint")
    }

    fn database(&self) -> String {
        match self {
            Self::Postgres(fixture) => fixture.database().to_owned(),
            Self::Mysql(fixture) => fixture.database().to_owned(),
        }
    }

    fn credentials(&self) -> Credentials {
        let FixtureCredentials { username, password } = match self {
            Self::Postgres(fixture) => fixture.password_credentials(),
            Self::Mysql(fixture) => fixture.password_credentials(),
        };
        Credentials::Password {
            username,
            password: SecretString::from(password),
        }
    }

    fn request(&self) -> ConnectRequest {
        let driver = self.driver();
        ConnectRequest {
            metadata: ConnectionMetadata {
                id: uuid::Uuid::new_v4(),
                name: "Large catalog".to_owned(),
                driver_id: driver.id().to_owned(),
            },
            driver,
            target: RequestTarget::Network {
                endpoint: self.endpoint(),
                ssh: None,
                credentials: self.credentials(),
                database: Some(self.database()),
                tls: TlsConfig::disabled(),
                options: Default::default(),
            },
            workspace_settings: WorkspaceSettings::workspace(false),
            safe_mode: tablepro_core::SafeModeLevel::Off,
        }
    }

    async fn admin(&self) -> Result<Arc<dyn Connection>, String> {
        let liveness = LivenessPolicy::DESKTOP;
        let options = ConnectOptions {
            target: ConnectTarget::Network(NetworkTarget {
                transport: Arc::new(DirectTcpTransport::new(self.endpoint(), &liveness)),
                credentials: self.credentials(),
                database: Some(self.database()),
                tls: TlsConfig::disabled(),
                options: Default::default(),
            }),
            workspace_settings: WorkspaceSettings::workspace(false),
            liveness,
            environment: ConnectEnvironment::new("large-catalog-fill"),
        };
        self.driver()
            .connect(options, CancellationToken::new())
            .await
            .map_err(|error| error.to_string())
    }

    /// Create every schema's tables. PostgreSQL's are shared out among
    /// `FILLERS` connections, a schema to each in turn. MySQL's are
    /// written out and run by clients inside the container: a round trip
    /// per table from here would take longer than the case may run.
    async fn fill(&self, schemas: &[(String, Range<usize>)]) -> Result<(), String> {
        match self {
            Self::Postgres(_) => {
                let mut shares: Vec<Vec<Vec<String>>> = (0..FILLERS).map(|_| Vec::new()).collect();
                for (at, (schema, tables)) in schemas.iter().enumerate() {
                    if let Some(share) = shares.get_mut(at % FILLERS) {
                        share.extend(postgres_schema_job(schema, tables.clone()));
                    }
                }
                let fills = shares.into_iter().map(|share| async move {
                    let connection = self.admin().await?;
                    for batch in share {
                        apply(connection.as_ref(), batch).await?;
                    }
                    connection.close().await.map_err(|error| error.to_string())
                });
                futures::future::try_join_all(fills).await.map(|_| ())
            }
            Self::Mysql(fixture) => {
                let [(database, tables)] = schemas else {
                    return Err("MySQL's tables go in one database".to_owned());
                };
                if database != fixture.database() {
                    return Err(format!("MySQL's tables go in {}", fixture.database()));
                }
                let script = mysql_fill_script(database, tables.clone());
                let output = fixture
                    .exec(&["bash", "-c", script.as_str()])
                    .await
                    .map_err(|error| error.to_string())?;
                if output.succeeded() {
                    Ok(())
                } else {
                    Err(format!("the tables were not created: {}", output.stderr_text()))
                }
            }
        }
    }
}

/// One schema, then its tables a block at a time: a round trip per
/// table would take longer than the case may run, and a transaction
/// that creates them all would hold more locks than the server keeps.
fn postgres_schema_job(schema: &str, tables: Range<usize>) -> Vec<Vec<String>> {
    let indexes: Vec<usize> = tables.collect();
    let mut job = Vec::new();
    if schema != "public" {
        job.push(vec![format!("CREATE SCHEMA {schema}")]);
    }
    for block in indexes.chunks(100) {
        let creates: String = block
            .iter()
            .map(|&index| {
                format!(
                    "CREATE TABLE {schema}.{} (id integer PRIMARY KEY, created_at timestamptz);",
                    table_name(index)
                )
            })
            .collect();
        job.push(vec![format!("DO $fill$ BEGIN {creates} END $fill$")]);
    }
    job
}

/// A bash script that creates `tables` in `database` as `table_name`
/// names them, through `FILLERS` clients at once. They are MEMORY
/// tables: the catalog lists them as any other, and each takes about
/// half the time an InnoDB one does.
fn mysql_fill_script(database: &str, tables: Range<usize>) -> String {
    let kinds = KINDS.join(" ");
    let share = tables.len().div_ceil(FILLERS);
    let (start, end) = (tables.start, tables.end);
    format!(
        r#"set -o pipefail
kinds=({kinds})
create() {{
  local at=$1
  while (( at < $2 )); do
    printf 'CREATE TABLE `%s_%05d` (id int PRIMARY KEY, created_at timestamp NULL) ENGINE=MEMORY;\n' \
      "${{kinds[at % {count}]}}" $(( at / {count} ))
    (( at++ ))
  done
}}
pids=()
for (( from = {start}; from < {end}; from += {share} )); do
  to=$(( from + {share} < {end} ? from + {share} : {end} ))
  create "$from" "$to" | MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --user=root {database} &
  pids+=($!)
done
failed=0
for pid in "${{pids[@]}}"; do wait "$pid" || failed=1; done
exit $failed
"#,
        count = KINDS.len(),
    )
}

async fn apply(connection: &dyn Connection, sql: Vec<String>) -> Result<(), String> {
    let steps = sql
        .iter()
        .map(|sql| {
            let mut builder = StatementBuilder::new();
            builder.push_sql(sql);
            GuardedStatement::unguarded(builder.finish())
        })
        .collect();
    let batch = WriteBatch::new(
        WriteKind::SchemaChanges,
        TableRef::unqualified("catalog"),
        steps,
        ForeignKeyMode::Enforced,
    );
    let options = CallOptions::new(
        Some(tokio::time::Instant::now() + SETUP_LIMIT),
        CancellationToken::new(),
    );
    connection
        .write_batch(&batch, options)
        .await
        .map(|_| ())
        .map_err(|error| error.to_string())
}

/// A session over a connection the app's own connector opens, so the
/// connect reads the schemas and the default schema's tables as it does
/// for a user.
fn connect(request: &ConnectRequest, tasks: &Tasks) -> Arc<Session> {
    let liveness = LivenessPolicy::DESKTOP;
    let deadlines = Arc::new(DefaultDeadlines::new(liveness));
    let connector = Arc::new(DriverConnector::new(
        ConnectServices {
            environment: ConnectEnvironment::new("test"),
            ssh: unused_ssh(),
            liveness,
        },
        deadlines.clone(),
    ));
    let establish = connector.establish(
        request.clone(),
        CredentialInteraction::Unattended,
        CancellationToken::new(),
    );
    let pending = finish_on_main(STEP_LIMIT, tasks.spawn_task(establish))
        .expect("the connect ends")
        .expect("the connect's task ends")
        .unwrap_or_else(|error| panic!("the session did not connect: {error}"));
    Session::start(
        pending,
        SessionDeps {
            connector,
            credentials: Arc::new(NoStoredCredentials),
            deadlines,
            tasks: tasks.clone(),
            prompter: None,
        },
    )
}

/// The connection goes straight to the server, so ssh never starts.
fn unused_ssh() -> SshServices {
    SshServices {
        runtime: Arc::new(SshRuntimeCell::new(std::env::temp_dir().join("tablepro-large-catalog"))),
        ssh_program: PathBuf::from("ssh"),
        ssh_keygen_program: PathBuf::from("ssh-keygen"),
        askpass_program: PathBuf::from("/nonexistent/tablepro-askpass"),
        config_file: None,
    }
}

/// What one step took, from the action to its result on screen, and
/// the longest the main loop stalled meanwhile.
#[derive(Debug, Clone, Copy)]
struct Step {
    took: Duration,
    stall: Duration,
    /// The CPU time the GTK thread spent on the step. A loaded machine
    /// stretches the stall but not this, which tells the two apart.
    cpu: Duration,
    /// False when the result never showed within `STEP_LIMIT`.
    finished: bool,
}

/// The connection tree and an editor side by side in a window on
/// screen. Each completion opens in an editor of its own, as in a new
/// editor tab.
struct Screen {
    window: gtk4::Window,
    panes: gtk4::Paned,
    tree: ConnectionTree,
    entry: gtk4::SearchEntry,
    key: SessionKey,
    sidebar: SidebarView,
    editor: RefCell<Option<SqlEditor>>,
    session: Arc<Session>,
    tasks: Tasks,
    settings: MemorySettings,
    _store: tempfile::TempDir,
}

impl Screen {
    fn new(session: &Arc<Session>, tasks: &Tasks) -> Self {
        let store = tempfile::tempdir().expect("a temporary directory");
        let connections = tablepro_storage::ConnectionStore::new(&tablepro_storage::StoragePaths::under(
            store.path(),
            "tablepro",
            crate::config::APP_ID,
        ));
        let tree = ConnectionTree::new(SavedConnectionList::follow(
            &connections,
            Arc::new(tablepro_core::DriverRegistry::new()),
        ));
        let entry = gtk4::SearchEntry::new();
        tree.follow_search(&entry);
        let sidebar = SidebarView::new(|_| {}, SidebarAffordances::for_session(session), Some(tasks.clone()));
        let key = SessionKey::Saved(uuid::Uuid::new_v4());
        tree.add_session(&key, "Large catalog", &sidebar);
        let column = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        column.append(&entry);
        column.append(&tree.widget());
        let panes = gtk4::Paned::new(gtk4::Orientation::Horizontal);
        panes.set_start_child(Some(&column));
        panes.set_position(300);
        let window = gtk4::Window::new();
        window.set_default_size(1100, 700);
        window.set_child(Some(&panes));
        window.set_titlebar(Some(&header_bar()));
        window.present();
        // The workspace's header draws icons long before a list lands,
        // so the icon theme is loaded before anything is measured.
        after_next_frame(&window);
        Self {
            window,
            panes,
            tree,
            entry,
            key,
            sidebar,
            editor: RefCell::new(None),
            session: session.clone(),
            tasks: tasks.clone(),
            settings: MemorySettings::new(),
            _store: store,
        }
    }

    /// The tree's list on screen: the tree, or what the search finds.
    fn shown_page(&self) -> Option<String> {
        self.tree
            .widget()
            .downcast::<gtk4::Stack>()
            .ok()
            .and_then(|pages| pages.visible_child_name())
            .map(|name| name.to_string())
    }

    /// Open the schema `name` under the session's connection, as a user
    /// opens the one they work in. MySQL's lone database opens itself.
    fn open_schema(&self, name: &str) {
        let Some(rows) = descendants(&self.tree.widget())
            .into_iter()
            .find_map(|widget| widget.downcast::<gtk4::ListView>().ok())
            .and_then(|list| list.model())
            .and_then(|selection| selection.downcast::<gtk4::SingleSelection>().ok())
            .and_then(|selection| selection.model())
            .and_then(|model| model.downcast::<gtk4::TreeListModel>().ok())
        else {
            panic!("the tree's rows");
        };
        let schema = (0..rows.n_items())
            .filter_map(|at| rows.row(at))
            .find(|row| row.depth() == 1 && row.item().is_some_and(|item| item.property::<String>("title") == name));
        schema.expect("the default schema's row").set_expanded(true);
        after_next_frame(&self.window);
    }

    /// A new editor in place of the last, on screen with the focus,
    /// which GtkSourceView needs before it starts a completion.
    fn open_editor(&self) -> sourceview5::View {
        let active = ActiveSession::new();
        active.replace(self.session.clone());
        let editor = SqlEditor::new(SqlEditorInit {
            initial_query: None,
            settings: self.settings.get().clone(),
            history: None,
            tasks: self.tasks.clone(),
            session: active,
            hold: Rc::new(CountingHold::new()),
            close_timeout: Duration::from_secs(5),
            snippets: crate::test_support::builtin_snippets_only(),
        });
        self.panes.set_end_child(Some(&editor));
        if let Some(previous) = self.editor.replace(Some(editor.clone())) {
            previous.shutdown();
        }
        let view = editor_view(&editor);
        view.grab_focus();
        wait_until(STEP_LIMIT, || view.is_mapped() && view.has_focus()).expect("the editor on screen with the focus");
        view
    }

    fn view(&self) -> sourceview5::View {
        let editor = self.editor.borrow().clone().expect("an editor is open");
        editor_view(&editor)
    }

    /// Run `action`, then wait for `done` and the frame that shows it.
    fn step(&self, probe: &StallProbe, name: &str, action: impl FnOnce(), done: impl FnMut() -> bool) -> Step {
        let _ = probe.take();
        let started = Instant::now();
        let spent = thread_cpu();
        action();
        let finished = wait_until(STEP_LIMIT, done).is_ok();
        after_next_frame(&self.window);
        let took = started.elapsed();
        let cpu = thread_cpu().saturating_sub(spent);
        if !finished {
            tracing::warn!(step = name, "the step did not finish");
        }
        Step {
            took,
            stall: probe.take(),
            cpu,
            finished,
        }
    }

    /// Every schema's tables, read, indexed and listed under the
    /// connection the way the workspace does once they land.
    fn list(&self, probe: &StallProbe, session: &Arc<Session>, tasks: &Tasks, expected: usize) -> Step {
        let expected = u32::try_from(expected).unwrap_or(u32::MAX);
        self.step(
            probe,
            "the first listing",
            || {
                let sidebar = self.sidebar.clone();
                let session = session.clone();
                let runtime = tasks.clone();
                let read = tasks.spawn_task(async move {
                    let objects = session
                        .objects(ObjectScope::AllSchemas)
                        .await
                        .map_err(|error| error.to_string())?;
                    list_catalog(session, runtime, objects, Arc::from([]))
                        .await
                        .map_err(|failure| failure.to_string())
                });
                glib::spawn_future_local(async move {
                    match read.await {
                        Ok(Ok(listing)) => sidebar.show(listing.index),
                        other => panic!("the catalog could not be listed: {other:?}"),
                    }
                });
            },
            || listed(&self.sidebar) == expected,
        )
    }

    /// Type `query`, as the search entry sends it once the user pauses,
    /// until the tree shows what it finds, or shows itself again for an
    /// empty search.
    fn search(&self, probe: &StallProbe, query: &str, expected: u32) -> Step {
        self.step(
            probe,
            &format!("the search for {query:?}"),
            || {
                self.entry.set_text(query);
                self.entry.emit_by_name::<()>("search-changed", &[]);
            },
            || {
                if query.is_empty() {
                    self.shown_page().as_deref() == Some("tree") && found(&self.sidebar) == 0
                } else {
                    self.shown_page().as_deref() == Some("found") && found(&self.sidebar) == expected
                }
            },
        )
    }

    /// Put `text` in the editor and ask for completion at its end, as
    /// Ctrl+Space does, until the list shows tables from `names` and only
    /// those.
    fn complete(&self, probe: &StallProbe, text: &str, names: HashSet<String>) -> Step {
        let view = self.open_editor();
        let completion = view.completion();
        let buffer = view.buffer();
        buffer.set_text(text);
        buffer.place_cursor(&buffer.end_iter());
        let shown = view.clone();
        self.step(
            probe,
            &format!("the completion after {text:?}"),
            || completion.show(),
            move || {
                let tables = shown_tables(&shown);
                !tables.is_empty() && tables.iter().all(|table| names.contains(table))
            },
        )
    }

    /// Type `key` while the completion list shows, until every table it
    /// shows holds what is typed.
    fn narrow(&self, probe: &StallProbe, key: &str, names: HashSet<String>) -> Step {
        let shown = self.view();
        let buffer = shown.buffer();
        let typed = key.to_owned();
        self.step(
            probe,
            &format!("the completion narrowed by {key:?}"),
            || {
                buffer.insert_interactive_at_cursor(key, true);
            },
            move || {
                let tables = shown_tables(&shown);
                !tables.is_empty()
                    && tables
                        .iter()
                        .all(|table| names.contains(table) && table.contains(typed.as_str()))
            },
        )
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        self.tree.shutdown();
        self.sidebar.shutdown();
        if let Some(editor) = self.editor.take() {
            editor.shutdown();
        }
        crate::test_support::drop_focus(&self.window);
        self.window.destroy();
    }
}

/// A header with the icons the tree's rows draw.
fn header_bar() -> gtk4::HeaderBar {
    let header = gtk4::HeaderBar::new();
    for icon in [
        crate::ui::icons::VIEW_GRID,
        crate::ui::icons::VIEW_LIST,
        crate::ui::icons::VIEW_PAGED,
        crate::ui::icons::DRIVE_HARDDISK,
        crate::ui::icons::NETWORK_SERVER,
        crate::ui::icons::MEDIA_EJECT,
    ] {
        header.pack_start(&gtk4::Button::from_icon_name(icon));
    }
    header
}

fn editor_view(editor: &SqlEditor) -> sourceview5::View {
    descendants(editor)
        .into_iter()
        .find_map(|widget| widget.downcast::<sourceview5::View>().ok())
        .expect("the editor's source view")
}

/// The names of the tables the completion list shows now: its keywords
/// and schemas carry no table's name.
fn shown_tables(view: &sourceview5::View) -> Vec<String> {
    descendants(view)
        .into_iter()
        .filter(WidgetExt::is_mapped)
        .filter_map(|widget| widget.downcast::<sourceview5::CompletionCell>().ok())
        .filter(|cell| cell.column() == sourceview5::CompletionColumn::TypedText)
        .filter_map(|cell| cell.text())
        .map(|text| text.to_string())
        .filter(|text| KINDS.iter().any(|kind| text.starts_with(&format!("{kind}_"))))
        .collect()
}

struct Measured {
    engine: Engine,
    fill: Duration,
    listing: Step,
    searches: [Step; SEARCHES.len()],
    from: Step,
    narrow: Step,
    qualified: Step,
    growth: u64,
}

impl Measured {
    fn steps(&self) -> Vec<(String, Step, Duration)> {
        let mut steps = vec![("the first listing".to_owned(), self.listing, LISTING_LIMIT)];
        for (query, search) in SEARCHES.iter().zip(self.searches) {
            steps.push((format!("the search for {query:?}"), search, SEARCH_LIMIT));
        }
        steps.push(("the completion after FROM".to_owned(), self.from, COMPLETION_LIMIT));
        steps.push((
            format!("the completion narrowed by {NARROW:?}"),
            self.narrow,
            NARROW_LIMIT,
        ));
        steps.push((
            "the completion after a schema's dot".to_owned(),
            self.qualified,
            COMPLETION_LIMIT,
        ));
        steps
    }
}

fn check_bounds(measured: &Measured) {
    let mut missed = Vec::new();
    for (name, step, limit) in measured.steps() {
        if !step.finished {
            missed.push(format!("{name} never showed its result"));
        } else if step.took > limit {
            missed.push(format!("{name} took {:?}, past {limit:?}", step.took));
        }
        if step.stall > STALL_LIMIT {
            missed.push(format!(
                "{name} stalled the main loop for {:?}, past {STALL_LIMIT:?}",
                step.stall
            ));
        }
    }
    if measured.growth > MEMORY_LIMIT {
        missed.push(format!(
            "the catalog raised the resident peak by {}, past {}",
            mebibytes(measured.growth),
            mebibytes(MEMORY_LIMIT)
        ));
    }
    assert!(missed.is_empty(), "{:?}: {}", measured.engine, missed.join("; "));
}

/// The numbers the bounds are set from, which nextest shows for a
/// passing run too.
fn report(measured: &Measured) {
    let steps: Vec<String> = measured
        .steps()
        .into_iter()
        .map(|(name, step, _)| {
            format!(
                "{name} {:.1?} (stall {:.1?}, GTK thread {:.1?})",
                step.took, step.stall, step.cpu
            )
        })
        .collect();
    eprintln!(
        "{:?} catalog of {TABLES} tables: filled in {:.1?}; {}; peak +{}",
        measured.engine,
        measured.fill,
        steps.join(", "),
        mebibytes(measured.growth),
    );
}

fn thread_cpu() -> Duration {
    let spent = rustix::time::clock_gettime(rustix::time::ClockId::ThreadCPUTime);
    Duration::new(
        u64::try_from(spent.tv_sec).unwrap_or_default(),
        u32::try_from(spent.tv_nsec).unwrap_or_default(),
    )
}

fn mebibytes(bytes: u64) -> String {
    format!("{:.1} MiB", bytes as f64 / (1024.0 * 1024.0))
}

#[test]
fn the_catalog_spreads_its_tables_as_the_issue_describes() {
    let postgres = Catalog::of(Engine::Postgres);
    let mysql = Catalog::of(Engine::Mysql);

    assert_eq!(postgres.schemas.len(), SCHEMAS);
    assert!(
        postgres
            .schemas
            .iter()
            .all(|(_, tables)| tables.len() == TABLES / SCHEMAS)
    );
    assert_eq!(postgres.objects.len(), TABLES);
    assert_eq!(mysql.schemas.len(), 1);
    assert_eq!(mysql.objects.len(), TABLES);
    let names: HashSet<&str> = postgres.objects.iter().map(|table| table.name.as_str()).collect();
    assert_eq!(names.len(), TABLES, "a table name repeats across schemas");
    assert_eq!(postgres.probed_schema(), "tenant_050");
    assert_eq!(mysql.probed_schema(), MYSQL_DATABASE);
    assert_eq!(postgres.matching(""), 50_000);
    let open = &postgres.objects[OPEN_TABLE];
    assert!(
        SEARCHES
            .iter()
            .all(|query| format!("public.{}", open.name).contains(query)),
        "{} leaves a search",
        open.name
    );
}

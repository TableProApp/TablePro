//! sqlx logs every statement it runs, values included, and a slow one
//! as a warning. Neither may reach the app's logs from a user's
//! database, so the driver turns both off.
//!
//! This is a test binary of its own because it installs the global
//! subscriber: sqlx logs from the connection's worker thread, which a
//! thread-local subscriber never sees.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use drivers_sqlite::SqliteDriver;
use sqlx::Connection as _;
use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, DatabaseDriver, FileEndpoint, LivenessPolicy,
    RowLimit, WorkspaceSettings,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;
use tracing::Subscriber;
use tracing_subscriber::Layer;
use tracing_subscriber::layer::{Context, SubscriberExt};

/// Counts events whose target is sqlx's statement logger.
struct QueryEvents(Arc<AtomicUsize>);

impl<S: Subscriber> Layer<S> for QueryEvents {
    fn on_event(&self, event: &tracing::Event<'_>, _context: Context<'_, S>) {
        if event.metadata().target() == "sqlx::query" {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
}

fn recorded() -> Arc<AtomicUsize> {
    static RECORDED: OnceLock<Arc<AtomicUsize>> = OnceLock::new();
    RECORDED
        .get_or_init(|| {
            let counter = Arc::new(AtomicUsize::new(0));
            let subscriber = tracing_subscriber::registry().with(QueryEvents(counter.clone()));
            let _ = tracing::subscriber::set_global_default(subscriber);
            counter
        })
        .clone()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sqlite_emits_no_sqlx_query_events() {
    let events = recorded();
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("logging.sqlite3");
    let create = SqliteConnectOptions::new().filename(&path).create_if_missing(true);
    SqliteConnection::connect_with(&create)
        .await
        .unwrap()
        .close()
        .await
        .unwrap();
    let options = ConnectOptions {
        target: ConnectTarget::File(FileEndpoint::open_existing(path).unwrap()),
        workspace_settings: WorkspaceSettings::workspace(false),
        liveness: LivenessPolicy::DESKTOP,
        environment: ConnectEnvironment::new("test"),
    };
    let connection = SqliteDriver.connect(options, CancellationToken::new()).await.unwrap();
    let before = events.load(Ordering::SeqCst);

    // Grow the read until one run passes sqlx's one-second slow
    // statement threshold, which is the warning most likely to leak.
    let mut rows: u64 = 1_000_000;
    let longest = loop {
        let mut builder = StatementBuilder::new();
        builder.push_sql(&format!(
            "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < {rows}) SELECT count(*) FROM r"
        ));
        let started = Instant::now();
        connection
            .query_bound(
                &builder.finish(),
                RowLimit::EDITOR_DEFAULT,
                CallOptions::new(Some(Instant::now() + Duration::from_secs(60)), CancellationToken::new()),
            )
            .await
            .unwrap();
        let took = started.elapsed();
        if took >= Duration::from_millis(1200) || rows >= 1_000_000_000 {
            break took;
        }
        rows *= 2;
    };
    connection.close().await.unwrap();

    assert!(
        longest >= Duration::from_millis(1200),
        "the slowest read took only {longest:?}"
    );
    assert_eq!(events.load(Ordering::SeqCst), before, "sqlx logged a statement");
}

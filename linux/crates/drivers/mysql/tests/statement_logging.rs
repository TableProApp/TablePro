//! sqlx logs every statement it runs, values included, and a slow one
//! as a warning. Neither may reach the app's logs from a user's
//! database, so the driver turns both off.
//!
//! This is a test binary of its own because it installs the global
//! subscriber, which sees events from every task.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use drivers_mysql::MysqlDriver;
use secrecy::SecretString;
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Credentials, DatabaseDriver, NetworkEndpoint,
    NetworkTarget, RowLimit, TlsConfig, UserSql, WorkspaceSettings,
};
use tablepro_net::DirectTcpTransport;
use tablepro_test_fixtures::{MysqlFixture, MysqlFlavour, MysqlOptions};
use tablepro_test_support::conformance::test_liveness;
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn mysql_emits_no_sqlx_query_events() {
    let events = Arc::new(AtomicUsize::new(0));
    let subscriber = tracing_subscriber::registry().with(QueryEvents(events.clone()));
    tracing::subscriber::set_global_default(subscriber).unwrap();
    let fixture = MysqlFixture::start_with(MysqlOptions::new(MysqlFlavour::Mysql).allowing_plaintext(), None)
        .await
        .unwrap();
    let liveness = test_liveness();
    let credentials = fixture.password_credentials();
    let options = ConnectOptions {
        target: ConnectTarget::Network(NetworkTarget {
            transport: Arc::new(DirectTcpTransport::new(
                NetworkEndpoint::new(fixture.host(), fixture.port()).unwrap(),
                &liveness,
            )),
            credentials: Credentials::Password {
                username: credentials.username.clone(),
                password: SecretString::from(credentials.password.clone()),
            },
            database: Some(fixture.database().to_owned()),
            tls: TlsConfig::disabled(),
        }),
        workspace_settings: WorkspaceSettings::workspace(false),
        liveness,
        environment: ConnectEnvironment::new("test"),
    };
    let connection = MysqlDriver.connect(options, CancellationToken::new()).await.unwrap();

    // Past sqlx's one-second slow statement threshold, which is the
    // warning most likely to leak, through both the pool and an editor.
    let mut builder = StatementBuilder::new();
    builder.push_sql("SELECT SLEEP(1.2)");
    connection
        .query_bound(
            &builder.finish(),
            RowLimit::EDITOR_DEFAULT,
            CallOptions::new(Some(Instant::now() + Duration::from_secs(30)), CancellationToken::new()),
        )
        .await
        .unwrap();
    let session = connection
        .open_editor_session(Default::default(), CancellationToken::new())
        .await
        .unwrap();
    session
        .run(
            UserSql::new("SELECT SLEEP(1.2)"),
            tablepro_core::RunOptions::new(CancellationToken::new()),
            Box::new(Discard),
        )
        .await
        .unwrap();
    session.close().await;
    connection.close().await.unwrap();

    assert_eq!(events.load(Ordering::SeqCst), 0, "sqlx logged a statement");
}

struct Discard;

#[async_trait::async_trait]
impl tablepro_core::ResultSink for Discard {
    async fn accept(&mut self, _event: tablepro_core::ResultEvent) -> tablepro_core::SinkFlow {
        tablepro_core::SinkFlow::Continue
    }
}

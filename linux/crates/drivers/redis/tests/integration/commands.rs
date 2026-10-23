//! What only Redis does: its logins and numbered databases, its editor's
//! commands and transactions, and keys and values of any bytes.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::keyspace::{KeyScan, KeyWindow};
use tablepro_core::meta::{KeyKind, ObjectKind};
use tablepro_core::{
    ConfigError, Credentials, DatabaseDriver, DriverError, EditorSessionState, ErrorCategory, LivenessPolicy,
    NetworkEndpoint, ReadStatement, ResultEvent, ResultSink, RunEnd, RunOptions, ServerCode, SinkFlow, TimeoutPhase,
    TlsConfig, TransactionState, UnsupportedFeature, UserSql, Value, WorkspaceSettings,
};
use tablepro_driver_redis::{RedisDriver, key_text};
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::test_liveness;
use tokio_util::sync::CancellationToken;

use crate::support::{
    CALL, connect, editor, fixture_options, options_over, password, rows, run, run_with, start, unique, within,
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_wrong_password_is_refused_as_the_login() {
    let fixture = start().await;
    let wrong = Credentials::Password {
        username: "tablepro".to_owned(),
        password: SecretString::from("not-the-password".to_owned()),
    };

    let outcome = RedisDriver
        .connect(fixture_options(&fixture, wrong, None), CancellationToken::new())
        .await;

    let error = outcome.err().expect("the login was refused");
    assert_eq!(error.category(), ErrorCategory::Authentication, "{error:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn no_password_on_a_server_that_wants_one_is_refused_as_the_login() {
    let fixture = start().await;
    let none = Credentials::Password {
        username: String::new(),
        password: SecretString::from(String::new()),
    };

    let outcome = RedisDriver
        .connect(fixture_options(&fixture, none, None), CancellationToken::new())
        .await;

    let error = outcome.err().expect("the login was refused");
    assert_eq!(error.category(), ErrorCategory::Authentication, "{error:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_password_alone_logs_in_as_the_default_user() {
    let fixture = start().await;
    let options = fixture_options(&fixture, password(&fixture.default_user_credentials()), None);

    let connection = RedisDriver
        .connect(options, CancellationToken::new())
        .await
        .expect("a connection");

    connection.probe(within(CALL)).await.expect("the server answers");
    let (major, minor) = fixture.version().reported();
    let server = connection.server_info();
    assert_eq!((server.major, server.minor), (major, minor), "{server:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_server_that_never_answers_info_times_out_the_connect() {
    let fixture = start().await;
    let liveness = LivenessPolicy {
        login_timeout: Duration::from_secs(1),
        ..test_liveness()
    };
    let endpoint = NetworkEndpoint::new(fixture.host(), fixture.port()).expect("a valid endpoint");
    let fault = Arc::new(FaultTransport::direct(endpoint, &liveness).expect("a fault transport"));
    fault.stall_reads_after_write_containing("INFO");
    let options = options_over(
        fault.clone(),
        password(&fixture.password_credentials()),
        None,
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(false),
        liveness,
    );

    let connected = tokio::time::timeout(CALL, RedisDriver.connect(options, CancellationToken::new()))
        .await
        .expect("the connect to end at the login timeout");

    let error = connected.err();
    assert!(
        matches!(
            error,
            Some(DriverError::Timeout {
                phase: TimeoutPhase::Login,
                ..
            })
        ),
        "{error:?}"
    );
    assert_eq!(fault.stalls_triggered(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_login_that_may_only_read_is_alive_to_the_probe() {
    let fixture = start().await;
    let admin = connect(&fixture).await;
    let (granted, _) = run(
        editor(admin.as_ref()).await.as_ref(),
        "ACL SETUSER tp_reader on >tp_reader_pw ~* +@read",
    )
    .await;
    assert_eq!(granted.end, RunEnd::Completed);
    let reader = Credentials::Password {
        username: "tp_reader".to_owned(),
        password: SecretString::from("tp_reader_pw".to_owned()),
    };

    let connection = RedisDriver
        .connect(fixture_options(&fixture, reader, None), CancellationToken::new())
        .await
        .expect("a connection that may only read");

    connection
        .probe(within(CALL))
        .await
        .expect("a NOPERM to PING is the server answering");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn the_connection_opens_the_database_it_names() {
    let fixture = start().await;
    let credentials = password(&fixture.password_credentials());
    let third = RedisDriver
        .connect(
            fixture_options(&fixture, credentials.clone(), Some("3")),
            CancellationToken::new(),
        )
        .await
        .expect("a connection to database 3");
    let first = RedisDriver
        .connect(fixture_options(&fixture, credentials, None), CancellationToken::new())
        .await
        .expect("a connection to database 0");
    let key = unique("database");
    let session = editor(third.as_ref()).await;
    run(session.as_ref(), &format!("SET {key} three")).await;

    let pattern = KeyScan::sidebar(Some(key.clone()));
    let in_third = third.scan_keys(&pattern, within(CALL)).await.expect("a listing");
    let in_first = first.scan_keys(&pattern, within(CALL)).await.expect("a listing");

    assert_eq!(in_third.keys.len(), 1);
    assert!(in_first.keys.is_empty(), "{:?}", in_first.keys);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_database_that_is_not_a_number_is_refused_before_connecting() {
    let fixture = start().await;
    let options = fixture_options(&fixture, password(&fixture.password_credentials()), Some("sales"));

    let outcome = RedisDriver.connect(options, CancellationToken::new()).await;

    assert_eq!(outcome.err(), Some(DriverError::Config(ConfigError::DatabaseNumber)));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn multi_holds_a_transaction_until_exec() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let key = unique("multi");

    let (opened, _) = run(session.as_ref(), "MULTI").await;
    let (queued, queued_events) = run(session.as_ref(), &format!("INCR {key}")).await;
    let (executed, executed_events) = run(session.as_ref(), "EXEC").await;

    assert_eq!(opened.transaction_state, TransactionState::InTransaction);
    assert_eq!(queued.transaction_state, TransactionState::InTransaction);
    assert_eq!(rows(&queued_events), vec![vec![Value::Text("QUEUED".to_owned())]]);
    assert_eq!(executed.transaction_state, TransactionState::Idle);
    assert_eq!(rows(&executed_events), vec![vec![Value::Int(1), Value::Int(1)]]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_command_that_cannot_be_queued_fails_the_transaction() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;

    run(session.as_ref(), "MULTI").await;
    let (refused, _) = run(session.as_ref(), "NOSUCHCOMMAND").await;
    let (executed, _) = run(session.as_ref(), "EXEC").await;

    assert_eq!(refused.transaction_state, TransactionState::Failed);
    assert!(matches!(executed.end, RunEnd::Failed(_)), "{:?}", executed.end);
    assert_eq!(executed.transaction_state, TransactionState::Idle);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_refused_exec_or_discard_is_read_as_the_server_reads_it() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;

    run(session.as_ref(), "MULTI").await;
    let (nested, _) = run(session.as_ref(), "MULTI").await;
    let (refused_discard, _) = run(session.as_ref(), "DISCARD extra").await;
    let (aborted, _) = run(session.as_ref(), "EXEC").await;
    run(session.as_ref(), "MULTI").await;
    let (refused_exec, _) = run(session.as_ref(), "EXEC extra").await;
    let (after, _) = run(session.as_ref(), "EXEC").await;

    assert_eq!(nested.transaction_state, TransactionState::InTransaction);
    assert_eq!(refused_discard.transaction_state, TransactionState::Failed);
    assert_eq!(aborted.transaction_state, TransactionState::Idle);
    assert_eq!(refused_exec.transaction_state, TransactionState::Idle);
    let RunEnd::Failed(DriverError::Server(diagnostics)) = &after.end else {
        panic!("EXEC with no MULTI ended {:?}", after.end);
    };
    assert_eq!(
        diagnostics.code,
        Some(ServerCode::Redis {
            prefix: "ERR".to_owned()
        })
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_run_stopped_before_it_starts_sends_nothing() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let key = unique("unsent");
    let cancel = CancellationToken::new();
    cancel.cancel();

    let (summary, events) = run_with(session.as_ref(), &format!("SET {key} 1"), RunOptions::new(cancel)).await;

    assert_eq!(summary.end, RunEnd::Cancelled);
    assert!(rows(&events).is_empty(), "{events:?}");
    assert_eq!(session.state(), EditorSessionState::Ready);
    let (_, events) = run(session.as_ref(), &format!("EXISTS {key}")).await;
    assert_eq!(rows(&events), vec![vec![Value::Int(0)]]);
}

/// A grid that never takes what it is handed.
struct Stuck;

#[async_trait]
impl ResultSink for Stuck {
    async fn accept(&mut self, _event: ResultEvent) -> SinkFlow {
        std::future::pending().await
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_stop_ends_a_run_whose_results_nobody_takes() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let cancel = CancellationToken::new();

    let running = session.run(UserSql::new("PING"), RunOptions::new(cancel.clone()), Box::new(Stuck));
    let stop = async {
        tokio::time::sleep(Duration::from_millis(300)).await;
        cancel.cancel();
    };
    let (summary, ()) = tokio::time::timeout(CALL, async { tokio::join!(running, stop) })
        .await
        .expect("the stop to end the run");

    assert_eq!(summary.expect("the run's summary").end, RunEnd::Cancelled);
    assert_eq!(session.state(), EditorSessionState::Ready);
    let (ping, _) = run(session.as_ref(), "PING").await;
    assert_eq!(ping.end, RunEnd::Completed);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn an_export_whose_rows_nobody_takes_ends_at_its_deadline() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let read = ReadStatement::User(UserSql::new("PING"));

    let exported = tokio::time::timeout(
        CALL,
        connection.stream_read(&read, Box::new(Stuck), within(Duration::from_millis(500))),
    )
    .await
    .expect("the deadline to end the export");

    let error = exported.err();
    assert!(matches!(error, Some(DriverError::Timeout { .. })), "{error:?}");
    connection
        .probe(within(CALL))
        .await
        .expect("the workspace link is still up");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_command_that_streams_pushes_is_refused_and_the_session_stays_ready() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;

    let (summary, _) = run(session.as_ref(), "SUBSCRIBE news").await;

    assert_eq!(
        summary.end,
        RunEnd::Failed(DriverError::Unsupported {
            feature: UnsupportedFeature::EditorCommand { command: "SUBSCRIBE" }
        })
    );
    assert_eq!(session.state(), EditorSessionState::Ready);
    let (ping, events) = run(session.as_ref(), "PING").await;
    assert_eq!(ping.end, RunEnd::Completed);
    assert_eq!(rows(&events), vec![vec![Value::Text("PONG".to_owned())]]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_failed_command_stops_the_rest_of_the_text() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let (text, after) = (unique("text"), unique("after"));

    let (summary, _) = run(session.as_ref(), &format!("SET {text} abc\nINCR {text}\nSET {after} 1")).await;

    let RunEnd::Failed(DriverError::Server(diagnostics)) = &summary.end else {
        panic!("the run ended {:?}", summary.end);
    };
    assert_eq!(
        diagnostics.code,
        Some(ServerCode::Redis {
            prefix: "ERR".to_owned()
        })
    );
    let (_, events) = run(session.as_ref(), &format!("EXISTS {after}")).await;
    assert_eq!(rows(&events), vec![vec![Value::Int(0)]]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_key_of_any_bytes_is_listed_and_read_back() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let prefix = unique("bytes");

    let (written, _) = run(
        session.as_ref(),
        &format!("SET \"{prefix}\\xff\\x00raw\" \"\\xfe value\""),
    )
    .await;
    assert_eq!(written.end, RunEnd::Completed);
    let listing = connection
        .scan_keys(&KeyScan::sidebar(Some(format!("{prefix}*"))), within(CALL))
        .await
        .expect("a listing");

    let mut name = prefix.as_bytes().to_vec();
    name.extend_from_slice(b"\xff\x00raw");
    let shown = key_text(&name);
    assert_eq!(listing.keys.len(), 1);
    assert_eq!(listing.keys[0].name, shown);
    assert_eq!(listing.keys[0].kind, ObjectKind::Key(KeyKind::String));
    let page = connection
        .read_key(&shown, &KeyWindow::first(), within(CALL))
        .await
        .expect("a read")
        .expect("the key");
    assert_eq!(page.rows.rows, vec![vec![Value::Bytes(b"\xfe value".to_vec())]]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_long_string_reads_its_first_megabyte_and_says_it_was_cut() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let key = unique("long");
    run(session.as_ref(), &format!("SETRANGE {key} 1999999 x")).await;

    let page = connection
        .read_key(&key, &KeyWindow::first(), within(CALL))
        .await
        .expect("a read")
        .expect("the key");

    assert_eq!(page.length, Some(2_000_000));
    assert!(page.rows.truncated);
    let Some(Value::Text(value)) = page.rows.cell(0, 0) else {
        panic!("the value is {:?}", page.rows.cell(0, 0));
    };
    assert_eq!(value.len(), 1024 * 1024);
    assert_eq!(page.next, None);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn the_workspace_link_opens_again_after_the_server_drops_it() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    connection
        .scan_keys(&KeyScan::sidebar(None), within(CALL))
        .await
        .expect("a listing");

    let killed = fixture
        .cli(&["CLIENT", "KILL", "SKIPME", "yes", "TYPE", "normal"])
        .await
        .expect("redis-cli ran");
    assert!(killed.succeeded(), "{}", killed.stderr_text());
    let first = connection.scan_keys(&KeyScan::sidebar(None), within(CALL)).await;
    let second = connection.scan_keys(&KeyScan::sidebar(None), within(CALL)).await;

    assert!(
        first.is_ok() || matches!(&first, Err(error) if error.category() == ErrorCategory::ConnectionLost),
        "{first:?}"
    );
    assert!(second.is_ok(), "{second:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn info_reads_as_one_value_and_counts_as_a_result() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;

    let (summary, events) = run(session.as_ref(), "INFO server").await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert!(
        matches!(events.first(), Some(ResultEvent::ResultSetStarted { .. })),
        "{events:?}"
    );
    let rows = rows(&events);
    assert!(
        matches!(rows.as_slice(), [row] if matches!(row.first(), Some(Value::Text(text)) if text.contains("redis_version"))),
        "{rows:?}"
    );
}

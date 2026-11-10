// Logins whose profile holds settings the driver would change: the server refuses a whole request that changes one.

use std::time::Duration;

use tablepro_core::value::{SqlDecimal, UndecodableReason, UndecodedValue};
use tablepro_core::{
    CallOptions, ConnectOptions, Connection, DriverError, ReadOnlyRefusal, RowLimit, RunEnd, RunOptions, ServerCode,
    TimeoutPhase, TlsConfig, Value, WorkspaceSettings, WriteKind,
};
use tablepro_test_fixtures::{ClickHouseFixture, FixtureCredentials};
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::support::{
    apply, connect, connect_with, count, direct, options_over, password, quoted, rows, run, run_ok, run_with, session,
    setup, start, statement, unique,
};

fn options_for(
    fixture: &ClickHouseFixture,
    credentials: &FixtureCredentials,
    settings: WorkspaceSettings,
) -> ConnectOptions {
    let liveness = test_liveness();
    options_over(
        direct(fixture.host(), fixture.http_port(), &liveness),
        password(credentials),
        TlsConfig::disabled(),
        settings,
        liveness,
    )
}

fn decimal(text: &str) -> Value {
    Value::Decimal(text.parse::<SqlDecimal>().expect("a decimal"))
}

// Long enough that only a stop ends it; the marker finds it in `system.processes`.
fn endless(marker: &str) -> String {
    format!("SELECT count() FROM numbers(100000000000000) WHERE toString(number) != '{marker}'")
}

async fn wait_until_gone(owner: &dyn Connection, marker: &str) {
    let running = format!(
        "SELECT count() FROM system.processes WHERE query LIKE '%{marker}%' AND query NOT LIKE '%system.processes%'"
    );
    let give_up = Instant::now() + Duration::from_secs(10);
    while count(owner, &running).await > 0 {
        assert!(
            Instant::now() < give_up,
            "the stopped query {marker} still runs on the server"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_login_at_readonly_1_connects_and_reads_no_value_as_null_that_is_not() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    let qualified = quoted(&unique("readonly"));
    setup(
        owner.as_ref(),
        &[
            &format!(
                "CREATE TABLE {qualified} (id Int32, amount Decimal(10, 2), ratio Float64) \
                 ENGINE = MergeTree ORDER BY id"
            ),
            &format!("INSERT INTO {qualified} VALUES (1, 1.5, nan)"),
        ],
    )
    .await;
    let out_of_range = Value::Undecodable(Box::new(UndecodedValue {
        type_name: "Float64".to_owned(),
        reason: UndecodableReason::OutOfRange,
    }));

    let logins = [
        (fixture.readonly_credentials(), false),
        (fixture.lenient_readonly_credentials(), true),
    ];
    for (credentials, quotes_nan) in logins {
        for read_only in [false, true] {
            let settings = WorkspaceSettings::workspace(read_only);
            let reader = connect_with(options_for(&fixture, &credentials, settings)).await;
            let context = format!("{}, read_only {read_only}", credentials.username);

            let read = rows(reader.as_ref(), &format!("SELECT id, amount, ratio FROM {qualified}")).await;

            let [row] = read.as_slice() else {
                panic!("{context} read {read:?}");
            };
            assert_eq!(row[..2], [Value::Int(1), decimal("1.50")], "{context}");
            if quotes_nan {
                assert!(
                    matches!(row[2], Value::Float64(ratio) if ratio.is_nan()),
                    "{context}: {row:?}"
                );
            } else {
                assert_eq!(row[2], out_of_range, "{context}");
            }
            reader.close().await.expect("a close");
        }
    }
    owner.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_login_at_readonly_1_runs_sql_within_its_bounds_and_cannot_write() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    let qualified = quoted(&unique("readonly"));
    setup(
        owner.as_ref(),
        &[&format!(
            "CREATE TABLE {qualified} (id Int32) ENGINE = MergeTree ORDER BY id"
        )],
    )
    .await;
    let mut settings = WorkspaceSettings::workspace(false);
    settings.statement_timeout = Duration::from_secs(1);
    let reader = connect_with(options_for(&fixture, &fixture.readonly_credentials(), settings)).await;

    let editor = session(reader.as_ref()).await;
    let level = run_ok(editor.as_ref(), "SELECT getSetting('readonly')").await;
    let in_editor = unique("editor");
    let options = RunOptions::new(CancellationToken::new()).with_deadline(Some(Duration::from_secs(1)));
    let (stopped, _) = run_with(editor.as_ref(), &endless(&in_editor), options).await;
    wait_until_gone(owner.as_ref(), &in_editor).await;
    editor.close().await;
    let in_grid = unique("grid");
    let unbounded = CallOptions::new(None, CancellationToken::new());
    let timed_out = reader
        .query_bound(&statement(&endless(&in_grid)), RowLimit::EDITOR_DEFAULT, unbounded)
        .await;
    wait_until_gone(owner.as_ref(), &in_grid).await;
    let refused = apply(
        reader.as_ref(),
        WriteKind::RowChanges,
        &[&format!("INSERT INTO {qualified} VALUES (1)")],
    )
    .await;

    assert_eq!(level.rows(), vec![vec![Value::Int(1)]]);
    assert!(matches!(stopped.end, RunEnd::TimedOut { .. }), "{:?}", stopped.end);
    assert!(
        matches!(
            timed_out,
            Err(DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                ..
            })
        ),
        "the statement timeout let the read run: {timed_out:?}"
    );
    assert!(
        matches!(&refused, Err(DriverError::RolledBack { statement_index: 0, source })
            if matches!(&**source, DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_)))),
        "{refused:?}"
    );
    reader.close().await.expect("a close");
    owner.close().await.expect("a close");
}

// The lenient profile lets the session run `SET readonly = 0`; the next request carries `readonly=1` again.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_read_only_connection_puts_back_the_readonly_level_a_session_lifted() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    let qualified = quoted(&unique("lifted"));
    setup(
        owner.as_ref(),
        &[&format!(
            "CREATE TABLE {qualified} (id Int32) ENGINE = MergeTree ORDER BY id"
        )],
    )
    .await;
    let settings = WorkspaceSettings::workspace(true);
    let reader = connect_with(options_for(&fixture, &fixture.lenient_readonly_credentials(), settings)).await;
    let editor = session(reader.as_ref()).await;

    run_ok(editor.as_ref(), "SET readonly = 0").await;
    let (inserted, _) = run(editor.as_ref(), &format!("INSERT INTO {qualified} VALUES (1)")).await;

    assert!(
        matches!(
            &inserted.end,
            RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_)))
        ),
        "{:?}",
        inserted.end
    );
    assert_eq!(
        count(owner.as_ref(), &format!("SELECT count() FROM {qualified}")).await,
        0
    );
    editor.close().await;
    reader.close().await.expect("a close");
    owner.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_login_whose_profile_holds_mutations_sync_at_0_is_refused_a_mutation_rather_than_told_it_saved() {
    let fixture = start().await;
    let owner = connect(&fixture, false).await;
    let qualified = quoted(&unique("unsynced"));
    setup(
        owner.as_ref(),
        &[
            &format!("CREATE TABLE {qualified} (id Int32, n Int32) ENGINE = MergeTree ORDER BY id"),
            &format!("INSERT INTO {qualified} VALUES (1, 0)"),
        ],
    )
    .await;
    let settings = WorkspaceSettings::workspace(false);
    let writer = connect_with(options_for(&fixture, &fixture.unsynced_credentials(), settings)).await;

    let inserted = apply(
        writer.as_ref(),
        WriteKind::RowChanges,
        &[&format!("INSERT INTO {qualified} VALUES (2, 0)")],
    )
    .await;
    let updated = apply(
        writer.as_ref(),
        WriteKind::RowChanges,
        &[&format!("ALTER TABLE {qualified} UPDATE n = 1 WHERE id = 1")],
    )
    .await;

    assert!(inserted.is_ok(), "{inserted:?}");
    assert!(
        matches!(&updated, Err(DriverError::RolledBack { statement_index: 0, source })
            if matches!(&**source, DriverError::Server(diagnostics)
                if diagnostics.code == Some(ServerCode::ClickHouse { code: 452 }))),
        "{updated:?}"
    );
    assert_eq!(
        count(owner.as_ref(), &format!("SELECT count() FROM {qualified} WHERE n = 1")).await,
        0
    );
    writer.close().await.expect("a close");
    owner.close().await.expect("a close");
}

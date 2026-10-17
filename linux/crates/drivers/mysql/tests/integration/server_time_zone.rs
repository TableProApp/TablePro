//! A server whose own zone is not UTC. The workspace reads TIMESTAMP in
//! UTC, but a save or a schema change has to mean what the same SQL
//! means from any other client, which runs in the server's zone.

use std::sync::Arc;

use chrono::NaiveDate;
use tablepro_core::dialect::{BindTarget, SqlDialect};
use tablepro_core::statement::{GuardedStatement, RowGuard, StatementBuilder};
use tablepro_core::value::{OffsetTimestamp, Temporal};
use tablepro_core::{Connection, DriverError, ForeignKeyMode, Value, WriteBatch, WriteKind, WriteReport};
use tablepro_test_fixtures::{MysqlFixture, MysqlFlavour, MysqlOptions};

use crate::support::{
    CALL, FLAVOURS, apply_on, connect, connect_root, rows, run_ok, scalar, session, session_scalar, setup, start_with,
    table, text, within,
};

fn instant(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> Value {
    let stamp = NaiveDate::from_ymd_opt(year, month, day)
        .and_then(|date| date.and_hms_opt(hour, minute, 0))
        .expect("a valid time");
    Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(
        stamp.and_utc().fixed_offset(),
    )))
}

/// `UPDATE <table> SET v = <v> WHERE at = <at>`, with `at` bound the way
/// the grid binds a TIMESTAMP key.
async fn update_by_instant(
    connection: &dyn Connection,
    name: &str,
    v: i64,
    at: Value,
) -> Result<WriteReport, DriverError> {
    let dialect = connection.dialect();
    let columns = connection
        .fetch_columns(&table(name), within(CALL))
        .await
        .expect("the columns");
    let column = |wanted: &str| {
        columns
            .iter()
            .find(|column| column.name == wanted)
            .cloned()
            .expect("the column")
    };
    let mut builder = StatementBuilder::new();
    builder.push_sql(&format!("UPDATE {} SET v = ", dialect.quote_identifier(name)));
    builder
        .push_value(dialect.as_ref(), Value::Int(v), BindTarget::Column(&column("v")))
        .expect("v binds");
    builder.push_sql(" WHERE at = ");
    builder
        .push_value(dialect.as_ref(), at, BindTarget::Column(&column("at")))
        .expect("at binds");
    let step = GuardedStatement {
        statement: builder.finish(),
        guard: RowGuard::AffectedExactly(1),
    };
    let batch = WriteBatch::new(WriteKind::RowChanges, table(name), vec![step], ForeignKeyMode::Enforced);
    connection.write_batch(&batch, within(CALL)).await
}

/// An INSERT of `at` as the grid writes it, leaving `created` to its
/// default.
async fn insert_instant(connection: &dyn Connection, at: Value) {
    let dialect: Arc<dyn SqlDialect> = connection.dialect();
    let columns = connection
        .fetch_columns(&table("stamped"), within(CALL))
        .await
        .expect("the columns");
    let at_column = columns.iter().find(|column| column.name == "at").expect("at");
    let mut builder = StatementBuilder::new();
    builder.push_sql("INSERT INTO stamped (id, at) VALUES (1, ");
    builder
        .push_value(dialect.as_ref(), at, BindTarget::Column(at_column))
        .expect("at binds");
    builder.push_sql(")");
    let step = GuardedStatement {
        statement: builder.finish(),
        guard: RowGuard::AffectedExactly(1),
    };
    let batch = WriteBatch::new(
        WriteKind::RowChanges,
        table("stamped"),
        vec![step],
        ForeignKeyMode::Enforced,
    );
    connection.write_batch(&batch, within(CALL)).await.expect("the insert");
}

/// The server's zone is +07:00. CURRENT_TIMESTAMP into a DATETIME and an
/// ALTER from DATETIME to TIMESTAMP have to use it, while a TIMESTAMP
/// still reads as its instant.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn writes_and_ddl_use_the_servers_zone() {
    for flavour in FLAVOURS {
        let fixture = start_with(
            MysqlOptions::new(flavour)
                .allowing_plaintext()
                .with_server_argument("--default-time-zone=+07:00"),
        )
        .await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE stamped (id int PRIMARY KEY, created datetime DEFAULT CURRENT_TIMESTAMP, \
                 at timestamp NULL)",
                "CREATE TABLE converted (id int PRIMARY KEY, d datetime NULL)",
                "INSERT INTO converted VALUES (1, '2025-01-01 10:00:00')",
            ],
        )
        .await;

        insert_instant(connection.as_ref(), instant(2025, 1, 1, 5, 0)).await;
        apply_on(
            connection.as_ref(),
            WriteKind::SchemaChanges,
            &table("converted"),
            &["ALTER TABLE converted MODIFY d timestamp NULL"],
        )
        .await
        .expect("the ALTER");

        let editor = session(connection.as_ref()).await;
        assert_eq!(
            session_scalar(editor.as_ref(), "SELECT @@session.time_zone").await,
            "+07:00",
            "{flavour:?}"
        );
        let drift = session_scalar(
            editor.as_ref(),
            "SELECT ABS(TIMESTAMPDIFF(MINUTE, created, NOW())) FROM stamped",
        )
        .await;
        assert!(
            drift.parse::<i64>().is_ok_and(|minutes| minutes < 5),
            "{flavour:?}: CURRENT_TIMESTAMP stored {drift} minutes away from the server's wall time"
        );
        assert_eq!(
            session_scalar(editor.as_ref(), "SELECT DATE_FORMAT(at, '%Y-%m-%d %H:%i') FROM stamped").await,
            "2025-01-01 12:00",
            "{flavour:?}: the TIMESTAMP holds another instant"
        );
        assert_eq!(
            session_scalar(
                editor.as_ref(),
                "SELECT DATE_FORMAT(d, '%Y-%m-%d %H:%i') FROM converted"
            )
            .await,
            "2025-01-01 10:00",
            "{flavour:?}: the ALTER moved the wall time other clients see"
        );
        editor.close().await;

        assert_eq!(
            scalar(connection.as_ref(), "SELECT at FROM stamped").await,
            instant(2025, 1, 1, 5, 0),
            "{flavour:?}: a TIMESTAMP reads as its instant"
        );
        for _ in 0..drivers_mysql::WORKSPACE_POOL_MAX_SIZE {
            assert_eq!(
                text(&scalar(connection.as_ref(), "SELECT @@session.time_zone").await),
                "+00:00",
                "{flavour:?}: a write left a pool connection in the server's zone"
            );
        }
        connection.close().await.expect("a close");
    }
}

/// Load the named zones and make America/New_York the server's zone.
async fn new_york(fixture: &MysqlFixture) {
    let root = fixture.root_credentials();
    let load = match fixture.flavour() {
        MysqlFlavour::Mysql => "mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | mysql -uroot mysql",
        MysqlFlavour::Mariadb => "mariadb-tzinfo-to-sql /usr/share/zoneinfo 2>/dev/null | mariadb -uroot mysql",
    };
    let output = fixture
        .exec(&["sh", "-c", &format!("export MYSQL_PWD='{}'; {load}", root.password)])
        .await
        .expect("the zone tables load");
    assert!(output.succeeded(), "{}", output.stderr_text());
    let root = connect_root(fixture).await;
    setup(root.as_ref(), &["SET GLOBAL time_zone = 'America/New_York'"]).await;
    root.close().await.expect("a close");
}

/// 2024-11-03 01:30 happens twice in New York, at 05:30Z and at 06:30Z.
/// A save in that zone cannot tell them apart, so it refuses rather than
/// write to the other row.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn an_instant_in_a_repeated_hour_is_refused() {
    for flavour in FLAVOURS {
        let fixture = start_with(MysqlOptions::new(flavour).allowing_plaintext()).await;
        new_york(&fixture).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &["CREATE TABLE fallback (at timestamp NOT NULL PRIMARY KEY, v int NOT NULL)"],
        )
        .await;
        let editor = session(connection.as_ref()).await;
        run_ok(
            editor.as_ref(),
            "SET time_zone = '+00:00'; INSERT INTO fallback VALUES \
             ('2024-11-03 05:30:00', 1), ('2024-11-03 06:30:00', 2), ('2024-11-03 08:30:00', 3)",
        )
        .await;
        editor.close().await;

        let second = update_by_instant(connection.as_ref(), "fallback", 20, instant(2024, 11, 3, 6, 30)).await;
        assert!(
            matches!(&second, Err(DriverError::RolledBack { source, .. }) if matches!(**source, DriverError::Unsupported { .. })),
            "{flavour:?}: {second:?}"
        );
        update_by_instant(connection.as_ref(), "fallback", 30, instant(2024, 11, 3, 8, 30))
            .await
            .expect("an hour that does not repeat");

        assert_eq!(
            rows(connection.as_ref(), "SELECT v FROM fallback ORDER BY at").await,
            [vec![Value::Int(1)], vec![Value::Int(2)], vec![Value::Int(30)]],
            "{flavour:?}"
        );
        connection.close().await.expect("a close");
    }
}

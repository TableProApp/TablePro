//! A value reads back as the storage class it is stored in, and the
//! declared type decides only how the column presents it.

use std::sync::Arc;
use std::time::Duration;

use drivers_sqlite::SqliteDriver;
use sqlx::Connection as _;
use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use tablepro_core::column::{BoolStorage, ColumnKind, TemporalZone};
use tablepro_core::meta::TableRef;
use tablepro_core::statement::{GuardedStatement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, DatabaseDriver, FileEndpoint,
    ForeignKeyMode, LivenessPolicy, QueryResult, RowLimit, Value, WorkspaceSettings, WriteBatch, WriteKind,
};
use tempfile::TempDir;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

/// A database file that exists before the driver opens it, and the
/// connection to it. The helpers return their failures, because the
/// workspace lints deny `expect` outside a test body.
async fn open() -> Result<(TempDir, Arc<dyn Connection>), String> {
    let directory = tempfile::tempdir().map_err(|error| error.to_string())?;
    let path = directory.path().join("values.sqlite3");
    let create = SqliteConnectOptions::new().filename(&path).create_if_missing(true);
    SqliteConnection::connect_with(&create)
        .await
        .map_err(|error| error.to_string())?
        .close()
        .await
        .map_err(|error| error.to_string())?;
    let options = ConnectOptions {
        target: ConnectTarget::File(FileEndpoint::open_existing(path).map_err(|error| error.to_string())?),
        workspace_settings: WorkspaceSettings::workspace(false),
        liveness: LivenessPolicy::DESKTOP,
        environment: ConnectEnvironment::new("test"),
    };
    let connection = SqliteDriver
        .connect(options, CancellationToken::new())
        .await
        .map_err(|error| error.to_string())?;
    Ok((directory, connection))
}

fn call() -> CallOptions {
    CallOptions::new(Some(Instant::now() + Duration::from_secs(30)), CancellationToken::new())
}

async fn apply(connection: &dyn Connection, statements: &[&str]) -> Result<(), String> {
    let steps = statements
        .iter()
        .map(|sql| {
            let mut builder = StatementBuilder::new();
            builder.push_sql(sql);
            GuardedStatement::unguarded(builder.finish())
        })
        .collect();
    let batch = WriteBatch::new(
        WriteKind::SchemaChanges,
        TableRef::unqualified("t"),
        steps,
        ForeignKeyMode::Enforced,
    );
    connection
        .write_batch(&batch, call())
        .await
        .map(|_| ())
        .map_err(|error| error.to_string())
}

async fn query(connection: &dyn Connection, sql: &str) -> Result<QueryResult, String> {
    let mut builder = StatementBuilder::new();
    builder.push_sql(sql);
    connection
        .query_bound(&builder.finish(), RowLimit::EDITOR_DEFAULT, call())
        .await
        .map_err(|error| error.to_string())
}

#[tokio::test]
async fn a_value_keeps_the_storage_class_it_was_written_with() {
    let (_directory, connection) = open().await.expect("a database file");
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE loose (id integer primary key, anything integer)",
            "INSERT INTO loose (id, anything) VALUES (1, 42), (2, 'text in an integer column'),
             (3, 1.5), (4, x'deadbeef'), (5, NULL)",
        ],
    )
    .await
    .expect("the rows");

    let q = query(connection.as_ref(), "SELECT anything FROM loose ORDER BY id")
        .await
        .expect("the rows read back");

    assert_eq!(q.rows[0][0], Value::Int(42));
    // SQLite lets a column hold any storage class, so text in an
    // integer column reads as the text it holds, not as a null.
    assert_eq!(q.rows[1][0], Value::Text("text in an integer column".into()));
    assert_eq!(q.rows[2][0], Value::Float64(1.5));
    assert_eq!(q.rows[3][0], Value::Bytes(vec![0xde, 0xad, 0xbe, 0xef]));
    assert_eq!(q.rows[4][0], Value::Null);
    connection.close().await.expect("the close");
}

#[tokio::test]
async fn a_declared_type_presents_the_value_without_changing_it() {
    let (_directory, connection) = open().await.expect("a database file");
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE typed (
                id integer primary key,
                flag boolean,
                day date,
                moment datetime,
                written date
            )",
            "INSERT INTO typed (id, flag, day, moment, written)
             VALUES (1, 1, '2024-06-15', '2024-06-15 13:45:30', 'not a date at all')",
        ],
    )
    .await
    .expect("the table");

    let q = query(connection.as_ref(), "SELECT flag, day, moment, written FROM typed")
        .await
        .expect("the row read back");
    let row = &q.rows[0];

    // The values are what is stored: an integer and three texts. Read
    // as a date and written back, the text would come back respelt.
    assert_eq!(row[0], Value::Int(1));
    assert_eq!(row[1], Value::Text("2024-06-15".into()));
    assert_eq!(row[2], Value::Text("2024-06-15 13:45:30".into()));
    assert_eq!(row[3], Value::Text("not a date at all".into()));
    // The kinds are what the declarations say, and they are what shows
    // a checkbox and a date.
    let kinds: Vec<&ColumnKind> = q.columns.iter().map(|column| &column.column_type.kind).collect();
    assert_eq!(kinds[0], &ColumnKind::Bool(BoolStorage::Integer));
    assert_eq!(kinds[1], &ColumnKind::Date);
    assert!(
        matches!(
            kinds[2],
            ColumnKind::Timestamp {
                zone: TemporalZone::Naive,
                ..
            }
        ),
        "{:?}",
        kinds[2]
    );
    connection.close().await.expect("the close");
}

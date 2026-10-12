//! The CSV import end to end: read a file, map its fields onto a
//! table's columns, build the INSERTs and save them, then read the rows
//! back out of the database.

use std::sync::Arc;
use std::time::Duration;

use drivers_sqlite::SqliteDriver;
use sqlx::Connection as _;
use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use tablepro_core::dml::build_insert;
use tablepro_core::import::{CsvImportOptions, read_csv, row_to_cells, suggest_mapping};
use tablepro_core::meta::TableRef;
use tablepro_core::statement::{GuardedStatement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, DatabaseDriver, FileEndpoint,
    ForeignKeyMode, LivenessPolicy, QueryResult, RowLimit, Value, WorkspaceSettings, WriteBatch, WriteKind,
    WriteReport,
};
use tempfile::TempDir;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

/// The helpers cannot use `expect`, which the workspace lints deny
/// outside a `#[test]` body, so they hand their failures back.
async fn open() -> Result<(TempDir, Arc<dyn Connection>), String> {
    let directory = tempfile::tempdir().map_err(|error| error.to_string())?;
    let path = directory.path().join("import.sqlite3");
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

fn plain(sql: &str) -> GuardedStatement {
    let mut builder = StatementBuilder::new();
    builder.push_sql(sql);
    GuardedStatement::unguarded(builder.finish())
}

async fn save(
    connection: &dyn Connection,
    kind: WriteKind,
    table: &str,
    steps: Vec<GuardedStatement>,
) -> Result<WriteReport, String> {
    let batch = WriteBatch::new(kind, TableRef::unqualified(table), steps, ForeignKeyMode::Enforced);
    connection
        .write_batch(&batch, call())
        .await
        .map_err(|error| error.to_string())
}

async fn create(connection: &dyn Connection, sql: &str) -> Result<WriteReport, String> {
    save(connection, WriteKind::SchemaChanges, "t", vec![plain(sql)]).await
}

async fn query(connection: &dyn Connection, sql: &str) -> Result<QueryResult, String> {
    let mut builder = StatementBuilder::new();
    builder.push_sql(sql);
    connection
        .query_bound(&builder.finish(), RowLimit::EDITOR_DEFAULT, call())
        .await
        .map_err(|error| error.to_string())
}

/// Run `csv` into `table`, mapping by header name, and return how many
/// rows each statement reported.
async fn import(
    connection: &dyn Connection,
    table: &str,
    csv: &[u8],
    options: &CsvImportOptions,
) -> Result<Vec<Option<u64>>, String> {
    let table_ref = TableRef::unqualified(table);
    let columns = connection
        .fetch_columns(&table_ref, call())
        .await
        .map_err(|error| error.to_string())?;
    let sheet = read_csv(csv, options, None).map_err(|error| error.to_string())?;
    let mapping = suggest_mapping(&sheet.headers, &columns);
    let dialect = connection.dialect();

    let mut steps = Vec::new();
    for (index, row) in sheet.rows.iter().enumerate() {
        let cells = row_to_cells(row, &mapping, &columns, options, index + 2).map_err(|error| error.reason)?;
        let statement =
            build_insert(dialect.as_ref(), &table_ref, &columns, &cells).map_err(|error| error.to_string())?;
        steps.push(GuardedStatement::unguarded(statement));
    }
    let report = save(connection, WriteKind::RowChanges, table, steps).await?;
    Ok(report.rows_affected)
}

#[tokio::test]
async fn a_file_lands_in_the_table_with_its_values_typed() {
    let (_directory, connection) = open().await.expect("a database file");
    create(
        connection.as_ref(),
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, score REAL, note TEXT)",
    )
    .await
    .expect("the table");

    let affected = import(
        connection.as_ref(),
        "people",
        b"id,name,score,note\n1,ada,9.5,first\n2,grace,8.25,\n",
        &CsvImportOptions::default(),
    )
    .await
    .expect("the import");

    assert_eq!(affected, vec![Some(1), Some(1)]);
    let rows = query(
        connection.as_ref(),
        "SELECT id, name, score, note FROM people ORDER BY id",
    )
    .await
    .expect("the rows");
    assert_eq!(rows.rows.len(), 2);
    assert_eq!(rows.rows[0][0], Value::Int(1));
    assert_eq!(rows.rows[0][1], Value::Text("ada".into()));
    assert_eq!(rows.rows[0][2], Value::Float64(9.5));
    assert_eq!(rows.rows[1][3], Value::Text(String::new()));
    connection.close().await.expect("the close");
}

#[tokio::test]
async fn a_column_the_file_does_not_name_keeps_its_default() {
    let (_directory, connection) = open().await.expect("a database file");
    create(
        connection.as_ref(),
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, status TEXT NOT NULL DEFAULT 'new')",
    )
    .await
    .expect("the table");

    import(
        connection.as_ref(),
        "notes",
        b"id,body\n1,hello\n",
        &CsvImportOptions::default(),
    )
    .await
    .expect("the import");

    let rows = query(connection.as_ref(), "SELECT status FROM notes")
        .await
        .expect("the rows");
    assert_eq!(rows.rows[0][0], Value::Text("new".into()));
    connection.close().await.expect("the close");
}

#[tokio::test]
async fn a_row_the_table_cannot_hold_leaves_the_table_as_it_was() {
    let (_directory, connection) = open().await.expect("a database file");
    create(
        connection.as_ref(),
        "CREATE TABLE counts (id INTEGER PRIMARY KEY, total INTEGER NOT NULL)",
    )
    .await
    .expect("the table");

    // The second row has no total, and the column refuses NULL, so the
    // whole file has to roll back rather than land halfway.
    let outcome = import(
        connection.as_ref(),
        "counts",
        b"id,total\n1,5\n2,\n",
        &CsvImportOptions::default(),
    )
    .await;

    assert!(outcome.is_err(), "the import reported success: {outcome:?}");
    let rows = query(connection.as_ref(), "SELECT COUNT(*) FROM counts")
        .await
        .expect("the count");
    assert_eq!(rows.rows[0][0], Value::Int(0), "a failed import left rows behind");
    connection.close().await.expect("the close");
}

#[tokio::test]
async fn a_value_the_column_cannot_parse_is_refused_before_anything_runs() {
    let (_directory, connection) = open().await.expect("a database file");
    create(
        connection.as_ref(),
        "CREATE TABLE stamps (id INTEGER PRIMARY KEY, at DATE)",
    )
    .await
    .expect("the table");

    let outcome = import(
        connection.as_ref(),
        "stamps",
        b"id,at\n1,not a date\n",
        &CsvImportOptions::default(),
    )
    .await;

    assert!(outcome.is_err(), "a bad date imported: {outcome:?}");
    let rows = query(connection.as_ref(), "SELECT COUNT(*) FROM stamps")
        .await
        .expect("the count");
    assert_eq!(rows.rows[0][0], Value::Int(0));
    connection.close().await.expect("the close");
}

#[tokio::test]
async fn a_semicolon_file_without_a_header_imports_by_position() {
    let (_directory, connection) = open().await.expect("a database file");
    create(connection.as_ref(), "CREATE TABLE pairs (a TEXT, b TEXT)")
        .await
        .expect("the table");
    let options = CsvImportOptions {
        delimiter: tablepro_core::export::CsvDelimiter::Semicolon,
        has_header: false,
        null_marker: String::new(),
    };

    // With no header there is nothing to match names against, so the
    // mapping is empty and every column keeps its default. That is the
    // honest outcome: the dialog is where the user maps by hand.
    let sheet = read_csv(b"one;two\n", &options, None).expect("the file");
    assert_eq!(sheet.headers, vec!["Column 1", "Column 2"]);

    let table = TableRef::unqualified("pairs");
    let columns = connection.fetch_columns(&table, call()).await.expect("the columns");
    let mapping = vec![Some(0), Some(1)];
    let cells = row_to_cells(&sheet.rows[0], &mapping, &columns, &options, 1).expect("the cells");
    let dialect = connection.dialect();
    let statement = build_insert(dialect.as_ref(), &table, &columns, &cells).expect("the insert");
    save(
        connection.as_ref(),
        WriteKind::RowChanges,
        "pairs",
        vec![GuardedStatement::unguarded(statement)],
    )
    .await
    .expect("the import");

    let rows = query(connection.as_ref(), "SELECT a, b FROM pairs")
        .await
        .expect("the rows");
    assert_eq!(rows.rows[0][0], Value::Text("one".into()));
    assert_eq!(rows.rows[0][1], Value::Text("two".into()));
    connection.close().await.expect("the close");
}

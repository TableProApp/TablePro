//! The CSV import end to end: read a file, map its fields onto a
//! table's columns, build the INSERTs and run them, then read the rows
//! back out of the database.

use drivers_sqlite::SqliteDriver;
use tablepro_core::dml::build_insert;
use tablepro_core::import::{CsvImportOptions, read_csv, row_to_cells, suggest_mapping};
use tablepro_core::meta::TableRef;
use tablepro_core::{ConnectOptions, DatabaseDriver, Value};

/// The helpers cannot use `expect`, which the workspace lints deny
/// outside a `#[test]` body, so they hand their failures back.
async fn open() -> Result<Box<dyn tablepro_core::Connection>, tablepro_core::DriverError> {
    let options = ConnectOptions {
        database: ":memory:".into(),
        ..Default::default()
    };
    SqliteDriver.connect(options).await
}

/// Run `csv` into `table`, mapping by header name, and return how many
/// rows each statement reported.
async fn import(
    connection: &dyn tablepro_core::Connection,
    table: &str,
    csv: &[u8],
    options: &CsvImportOptions,
) -> Result<Vec<u64>, String> {
    let columns = connection
        .fetch_columns(None, table)
        .await
        .map_err(|error| error.to_string())?;
    let sheet = read_csv(csv, options, None).map_err(|error| error.to_string())?;
    let mapping = suggest_mapping(&sheet.headers, &columns);
    let dialect = tablepro_core::dialect::dialect_for("sqlite");
    let table_ref = TableRef {
        schema: None,
        name: table.to_owned(),
    };

    let mut statements = Vec::new();
    for (index, row) in sheet.rows.iter().enumerate() {
        let cells = row_to_cells(row, &mapping, &columns, options, index + 2).map_err(|error| error.reason)?;
        let statement = build_insert(dialect, &table_ref, &columns, &cells).map_err(|error| error.to_string())?;
        let (sql, params) = statement.into_parts();
        statements.push((sql, params.into_iter().map(|p| p.value().clone()).collect::<Vec<_>>()));
    }
    connection
        .execute_in_transaction(&statements)
        .await
        .map_err(|error| error.to_string())
}

#[tokio::test]
async fn a_file_lands_in_the_table_with_its_values_typed() {
    let connection = open().await.expect("an in-memory database");
    connection
        .execute("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, score REAL, note TEXT)")
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

    assert_eq!(affected, vec![1, 1]);
    let rows = connection
        .query("SELECT id, name, score, note FROM people ORDER BY id")
        .await
        .expect("the rows");
    assert_eq!(rows.rows.len(), 2);
    assert_eq!(rows.rows[0][0], Value::Int(1));
    assert_eq!(rows.rows[0][1], Value::Text("ada".into()));
    assert_eq!(rows.rows[0][2], Value::Float64(9.5));
    assert_eq!(rows.rows[1][3], Value::Text(String::new()));
}

#[tokio::test]
async fn a_column_the_file_does_not_name_keeps_its_default() {
    let connection = open().await.expect("an in-memory database");
    connection
        .execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, status TEXT NOT NULL DEFAULT 'new')")
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

    let rows = connection.query("SELECT status FROM notes").await.expect("the rows");
    assert_eq!(rows.rows[0][0], Value::Text("new".into()));
}

#[tokio::test]
async fn a_row_the_table_cannot_hold_leaves_the_table_as_it_was() {
    let connection = open().await.expect("an in-memory database");
    connection
        .execute("CREATE TABLE counts (id INTEGER PRIMARY KEY, total INTEGER NOT NULL)")
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
    let rows = connection
        .query("SELECT COUNT(*) FROM counts")
        .await
        .expect("the count");
    assert_eq!(rows.rows[0][0], Value::Int(0), "a failed import left rows behind");
}

#[tokio::test]
async fn a_value_the_column_cannot_parse_is_refused_before_anything_runs() {
    let connection = open().await.expect("an in-memory database");
    connection
        .execute("CREATE TABLE stamps (id INTEGER PRIMARY KEY, at DATE)")
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
    let rows = connection
        .query("SELECT COUNT(*) FROM stamps")
        .await
        .expect("the count");
    assert_eq!(rows.rows[0][0], Value::Int(0));
}

#[tokio::test]
async fn a_semicolon_file_without_a_header_imports_by_position() {
    let connection = open().await.expect("an in-memory database");
    connection
        .execute("CREATE TABLE pairs (a TEXT, b TEXT)")
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

    let columns = connection.fetch_columns(None, "pairs").await.expect("the columns");
    let mapping = vec![Some(0), Some(1)];
    let cells = row_to_cells(&sheet.rows[0], &mapping, &columns, &options, 1).expect("the cells");
    let statement = build_insert(
        tablepro_core::dialect::dialect_for("sqlite"),
        &TableRef {
            schema: None,
            name: "pairs".to_owned(),
        },
        &columns,
        &cells,
    )
    .expect("the insert");
    let (sql, params) = statement.into_parts();
    connection
        .execute_in_transaction(&[(sql, params.into_iter().map(|p| p.value().clone()).collect())])
        .await
        .expect("the import");

    let rows = connection.query("SELECT a, b FROM pairs").await.expect("the rows");
    assert_eq!(rows.rows[0][0], Value::Text("one".into()));
    assert_eq!(rows.rows[0][1], Value::Text("two".into()));
}

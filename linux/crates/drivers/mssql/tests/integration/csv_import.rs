//! The CSV import against SQL Server, through the same plan the app
//! runs.

use tablepro_core::import::CsvImportOptions;
use tablepro_core::{DriverError, Value};
use tablepro_test_support::{CsvImportFailure, import_csv};

use crate::support::{CALL, connect, dbo, rows, setup, start, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn an_identity_column_is_numbered_by_the_server() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE dbo.people (id int IDENTITY(1,1) PRIMARY KEY, name nvarchar(50))"],
    )
    .await;

    import_csv(
        connection.as_ref(),
        &dbo("people"),
        b"id,name\n100,ada\n",
        &CsvImportOptions::default(),
        within(CALL),
    )
    .await
    .expect("the import");

    assert_eq!(
        rows(connection.as_ref(), "SELECT id, name FROM dbo.people").await,
        vec![vec![Value::Int(1), Value::Text("ada".to_owned())]],
        "IDENTITY refuses a value without IDENTITY_INSERT, so the server numbers the row"
    );
}

/// The file as `id,label,taken` rows, one per id.
fn readings(ids: impl IntoIterator<Item = u32>) -> String {
    let mut csv = String::from("id,label,taken\n");
    for id in ids {
        csv.push_str(&format!("{id},reading {id},2024-01-02\n"));
    }
    csv
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_large_file_lands_in_a_few_multi_row_statements() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE dbo.readings (id int PRIMARY KEY, label nvarchar(50) NOT NULL, taken date)"],
    )
    .await;

    let report = import_csv(
        connection.as_ref(),
        &dbo("readings"),
        readings(1..=2_500).as_bytes(),
        &CsvImportOptions::default(),
        within(CALL),
    )
    .await
    .expect("the import");

    // Three columns and SQL Server's 2,000 parameters make 666 rows a
    // statement.
    assert_eq!(report.rows_affected.len(), 4, "{report:?}");
    assert_eq!(
        rows(
            connection.as_ref(),
            "SELECT count(*), min(id), max(id) FROM dbo.readings"
        )
        .await,
        vec![vec![Value::Int(2_500), Value::Int(1), Value::Int(2_500)]]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_row_that_fails_in_a_later_statement_rolls_the_whole_file_back() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE dbo.readings (id int PRIMARY KEY, label nvarchar(50) NOT NULL, taken date)"],
    )
    .await;

    // Line 1,202 repeats the first id, inside the second statement of
    // 666 rows.
    let outcome = import_csv(
        connection.as_ref(),
        &dbo("readings"),
        readings((1..=1_200).chain([1]).chain(1_201..=1_500)).as_bytes(),
        &CsvImportOptions::default(),
        within(CALL),
    )
    .await;

    assert!(
        matches!(
            outcome,
            Err(CsvImportFailure::Driver(DriverError::RolledBack {
                statement_index: 1,
                ..
            }))
        ),
        "{outcome:?}"
    );
    assert_eq!(
        rows(connection.as_ref(), "SELECT count(*) FROM dbo.readings").await,
        vec![vec![Value::Int(0)]]
    );
}

/// SQL Server types the rows of a multi-row VALUES as UNION ALL types
/// them, so a value at full precision beside a shorter one must not be
/// narrowed to a type both fit.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_decimal_at_full_precision_keeps_every_digit_beside_shorter_ones() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.fractions (id int PRIMARY KEY, v decimal(38, 38))",
            "CREATE TABLE dbo.amounts (id int PRIMARY KEY, v decimal(38, 2))",
        ],
    )
    .await;
    let files: [(&str, &[u8]); 2] = [
        (
            "fractions",
            b"id,v\n1,0.12345678901234567890123456789012345678\n2,0\n3,0.5\n",
        ),
        ("amounts", b"id,v\n1,123456789012345678901234567890123456.78\n2,1\n"),
    ];
    for (table, csv) in files {
        import_csv(
            connection.as_ref(),
            &dbo(table),
            csv,
            &CsvImportOptions::default(),
            within(CALL),
        )
        .await
        .unwrap_or_else(|failure| panic!("the import into {table}: {failure:?}"));
    }

    let text = |rows: Vec<Vec<Value>>| -> Vec<String> {
        rows.into_iter()
            .map(|row| match row.into_iter().next() {
                Some(Value::Text(text)) => text,
                other => panic!("{other:?}"),
            })
            .collect()
    };
    assert_eq!(
        text(
            rows(
                connection.as_ref(),
                "SELECT CAST(v AS nvarchar(60)) FROM dbo.fractions ORDER BY id"
            )
            .await
        ),
        [
            "0.12345678901234567890123456789012345678",
            "0.00000000000000000000000000000000000000",
            "0.50000000000000000000000000000000000000"
        ]
    );
    assert_eq!(
        text(
            rows(
                connection.as_ref(),
                "SELECT CAST(v AS nvarchar(60)) FROM dbo.amounts ORDER BY id"
            )
            .await
        ),
        ["123456789012345678901234567890123456.78", "1.00"]
    );
}

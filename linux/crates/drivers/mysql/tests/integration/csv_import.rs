//! The CSV import against MySQL, through the same plan the app runs.

use tablepro_core::import::CsvImportOptions;
use tablepro_core::{DriverError, Value};
use tablepro_test_fixtures::MysqlFlavour;
use tablepro_test_support::{CsvImportFailure, import_csv};

use crate::support::{CALL, connect, rows, setup, start, table, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_file_keeps_its_ids_for_an_auto_increment_column() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE people (id int AUTO_INCREMENT PRIMARY KEY, name text)"],
    )
    .await;

    import_csv(
        connection.as_ref(),
        &table("people"),
        b"id,name\n100,ada\n",
        &CsvImportOptions::default(),
        within(CALL),
    )
    .await
    .expect("the import");

    assert_eq!(
        rows(connection.as_ref(), "SELECT id FROM people").await,
        vec![vec![Value::Int(100)]]
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
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE readings (id int PRIMARY KEY, label text NOT NULL, taken date) ENGINE = InnoDB"],
    )
    .await;

    let report = import_csv(
        connection.as_ref(),
        &table("readings"),
        readings(1..=2_500).as_bytes(),
        &CsvImportOptions::default(),
        within(CALL),
    )
    .await
    .expect("the import");

    assert_eq!(report.rows_affected, vec![Some(1_000), Some(1_000), Some(500)]);
    assert_eq!(
        rows(connection.as_ref(), "SELECT count(*), min(id), max(id) FROM readings").await,
        vec![vec![Value::Int(2_500), Value::Int(1), Value::Int(2_500)]]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_row_that_fails_in_a_later_statement_rolls_the_whole_file_back() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE readings (id int PRIMARY KEY, label text NOT NULL, taken date) ENGINE = InnoDB"],
    )
    .await;

    // Line 1,202 repeats the first id, inside the second statement.
    let outcome = import_csv(
        connection.as_ref(),
        &table("readings"),
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
        rows(connection.as_ref(), "SELECT count(*) FROM readings").await,
        vec![vec![Value::Int(0)]]
    );
}

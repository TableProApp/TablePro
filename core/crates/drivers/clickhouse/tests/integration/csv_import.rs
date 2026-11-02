//! The CSV import against ClickHouse, through the same plan the app
//! runs.

use tablepro_core::import::CsvImportOptions;
use tablepro_test_support::import_csv;

use crate::support::{CALL, connect, count, quoted, setup, start, table, unique, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_large_file_lands_in_a_few_parts_rather_than_one_per_row() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("readings");
    setup(
        connection.as_ref(),
        &[&format!(
            "CREATE TABLE {} (id UInt32, label String, taken Date) ENGINE = MergeTree ORDER BY id",
            quoted(&name)
        )],
    )
    .await;
    let mut csv = String::from("id,label,taken\n");
    for id in 1..=2_500 {
        csv.push_str(&format!("{id},reading {id},2024-01-02\n"));
    }

    let report = import_csv(
        connection.as_ref(),
        &table(&name),
        csv.as_bytes(),
        &CsvImportOptions::default(),
        within(CALL),
    )
    .await
    .expect("the import");

    let statements = report.rows_affected.len() as u64;
    assert!(statements <= 25, "{statements} statements for 2,500 rows");
    assert_eq!(
        count(connection.as_ref(), &format!("SELECT count() FROM {}", quoted(&name))).await,
        2_500
    );
    let parts = count(
        connection.as_ref(),
        &format!("SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = '{name}' AND active"),
    )
    .await;
    assert!(
        parts <= statements,
        "{parts} parts from {statements} statements: the rows went one part each"
    );
}

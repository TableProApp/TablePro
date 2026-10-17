//! The CSV import against MySQL, through the same plan the app runs.

use tablepro_core::Value;
use tablepro_core::import::CsvImportOptions;
use tablepro_test_fixtures::MysqlFlavour;
use tablepro_test_support::import_csv;

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

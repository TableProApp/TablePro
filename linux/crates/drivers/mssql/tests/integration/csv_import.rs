//! The CSV import against SQL Server, through the same plan the app
//! runs.

use tablepro_core::Value;
use tablepro_core::import::CsvImportOptions;
use tablepro_test_support::import_csv;

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

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_date_array_csv_import_survives_datestyle_change() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TABLE date_array_csv_target (value date[])")
        .await
        .unwrap();
    let mut tx = connection.begin().await.unwrap();
    tx.execute("SET LOCAL DateStyle = 'SQL, DMY'").await.unwrap();
    let expression = "ARRAY['2024-12-31'::date, '0002-12-31 BC'::date, 'infinity'::date, NULL]";
    let result = tx
        .query(&format!("SELECT {expression}::date[] AS value"))
        .await
        .unwrap();
    assert!(matches!(&result.rows[0][0], Value::Text(_)));
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("date-array.csv");
    let csv_options = tablepro_core::export::CsvOptions::default();
    tablepro_core::export::write_result_file(
        &path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Csv,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    tx.execute("SET LOCAL DateStyle = 'ISO, MDY'").await.unwrap();
    tx.execute("INSERT INTO date_array_csv_target VALUES (ARRAY['1999-01-01'::date])")
        .await
        .unwrap();
    let sibling = tx.query("SELECT pg_typeof(value)::text, array_to_json(value)::text, encode(array_send(value), 'hex') FROM date_array_csv_target").await.unwrap();
    let native = tx.query(&format!("SELECT pg_typeof({expression}::date[])::text, array_to_json({expression}::date[])::text, encode(array_send({expression}::date[]), 'hex')")).await.unwrap();
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(&std::fs::read(path).unwrap(), &import_options, None).unwrap();
    let columns = connection.fetch_columns(None, "date_array_csv_target").await.unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("public"),
            table: "date_array_csv_target",
            columns: &columns,
            mapping: &[Some(0)],
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    tx.execute_params(&plan.statement, &plan.rows[0]).await.unwrap();
    let rows = tx.query("SELECT pg_typeof(value)::text, array_to_json(value)::text, encode(array_send(value), 'hex') FROM date_array_csv_target").await.unwrap();
    assert_eq!(rows.rows.len(), 2);
    assert!(rows.rows.contains(&sibling.rows[0]));
    assert!(rows.rows.contains(&native.rows[0]));
    tx.rollback().await.unwrap();
}

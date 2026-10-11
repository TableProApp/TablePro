#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

fn export_csv(result: &tablepro_core::QueryResult, path: &std::path::Path) {
    tablepro_core::export::write_result_file(
        path,
        result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Csv,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_interval_array_csv_import_survives_intervalstyle_change() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TABLE interval_csv_target (value interval[])")
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "interval_csv_target").await.unwrap();
    let mut tx = connection.begin().await.unwrap();
    tx.execute("SET LOCAL IntervalStyle = 'postgres_verbose'")
        .await
        .unwrap();
    let expression = "ARRAY['1 year 2 mons 3 days 04:05:06.123456'::interval, \
        '-1 year +2 mons -3 days -04:05:06.654321'::interval, \
        '0.000001 seconds'::interval, '00:00:00'::interval, NULL]";
    let source = tx.query(&format!("SELECT {expression} AS value")).await.unwrap();
    let native = tx
        .query(&format!(
            "SELECT pg_typeof({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("interval.csv");
    export_csv(&source, &path);
    let sheet = tablepro_core::import::read_csv(&std::fs::read(path).unwrap(), &Default::default(), None).unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("public"),
            table: "interval_csv_target",
            columns: &columns,
            mapping: &[Some(0)],
        },
        &sheet,
        &Default::default(),
    )
    .unwrap();
    tx.execute("SET LOCAL IntervalStyle = 'iso_8601'").await.unwrap();
    tx.execute("INSERT INTO interval_csv_target VALUES (ARRAY['1 day'::interval])")
        .await
        .unwrap();
    let sibling = tx
        .query("SELECT pg_typeof(value)::text, encode(array_send(value), 'hex') FROM interval_csv_target")
        .await
        .unwrap();
    tx.execute_params(&plan.statement, &plan.rows[0]).await.unwrap();
    let rows = tx
        .query("SELECT pg_typeof(value)::text, encode(array_send(value), 'hex') FROM interval_csv_target")
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text("interval[]".into()));
    assert_eq!(rows.rows.len(), 2);
    assert!(rows.rows.contains(&sibling.rows[0]));
    assert!(rows.rows.contains(&native.rows[0]), "rows={:?}", rows.rows);
    tx.rollback().await.unwrap();
}

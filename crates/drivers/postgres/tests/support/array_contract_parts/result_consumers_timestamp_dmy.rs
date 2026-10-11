#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_timestamp_array_file_consumers_preserve_values_across_dmy_datestyle() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TABLE timestamp_array_dmy_csv_target (value timestamp[])")
        .await
        .unwrap();
    let mut transaction = connection.begin().await.unwrap();
    transaction.execute("SET LOCAL DateStyle = 'SQL, DMY'").await.unwrap();
    let expression = "ARRAY['2024-12-31 23:59:59.123456'::timestamp, \
                      '2001-02-03 04:05:06'::timestamp, \
                      '0002-12-31 23:59:59 BC'::timestamp, \
                      '10000-01-01 00:00:00'::timestamp, \
                      'infinity'::timestamp, '-infinity'::timestamp, NULL]";
    let result = transaction
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("timestamp[]", &result);

    let native = transaction
        .query(&format!(
            "SELECT current_setting('DateStyle'), pg_typeof({expression})::text, \
                    {expression}::text, array_to_json({expression})::text, \
                    encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text("SQL, DMY".into()));
    assert_eq!(native.rows[0][1], Value::Text("timestamp without time zone[]".into()));
    assert_ne!(result.rows[0][0], native.rows[0][2]);
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("timestamp[] result must remain exact array text: {:?}", result.rows[0][0]);
    };
    assert!(driver_text.contains("2024-12-31 23:59:59.123456"), "{driver_text}");
    assert!(driver_text.contains("0002-12-31 23:59:59 BC"), "{driver_text}");
    assert!(driver_text.contains("10000-01-01 00:00:00"), "{driver_text}");
    assert!(driver_text.contains("infinity"), "{driver_text}");
    assert!(driver_text.contains("-infinity"), "{driver_text}");

    transaction.execute("SET LOCAL DateStyle = 'ISO, MDY'").await.unwrap();
    let rebound = transaction
        .query_params(
            "SELECT array_to_json($1::text::timestamp[])::text, \
                    encode(array_send($1::text::timestamp[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][3]);
    assert_eq!(rebound.rows[0][1], native.rows[0][4]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let csv_path = directory.path().join("timestamp-array-dmy.csv");
    tablepro_core::export::write_result_file(
        &csv_path,
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
    let mut csv = csv::Reader::from_path(&csv_path).unwrap();
    assert_eq!(csv.headers().unwrap().iter().collect::<Vec<_>>(), ["value"]);
    assert_eq!(&csv.records().next().unwrap().unwrap()[0], driver_text);

    let csv = std::fs::read_to_string(directory.path().join("timestamp-array-dmy.csv")).unwrap();
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();

    let json_path = directory.path().join("timestamp-array-dmy.json");
    tablepro_core::export::write_result_file(
        &json_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Json,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&std::fs::read(json_path).unwrap()).unwrap();
    assert_eq!(json[0]["value"], *driver_text);

    transaction
        .execute(
            "INSERT INTO timestamp_array_dmy_csv_target \
             VALUES (ARRAY['1999-01-01 00:00:00'::timestamp])",
        )
        .await
        .unwrap();
    let csv_sibling = transaction
        .query(
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') FROM timestamp_array_dmy_csv_target",
        )
        .await
        .unwrap();
    let columns = connection
        .fetch_columns(None, "timestamp_array_dmy_csv_target")
        .await
        .unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("public"),
            table: "timestamp_array_dmy_csv_target",
            columns: &columns,
            mapping: &[Some(0)],
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    transaction.execute_params(&plan.statement, &plan.rows[0]).await.unwrap();
    let csv_restored = transaction
        .query(
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') FROM timestamp_array_dmy_csv_target",
        )
        .await
        .unwrap();
    assert_eq!(csv_restored.rows.len(), 2);
    assert!(csv_restored.rows.contains(&csv_sibling.rows[0]));
    assert!(
        csv_restored.rows.contains(&vec![
            native.rows[0][1].clone(),
            native.rows[0][3].clone(),
            native.rows[0][4].clone(),
        ]),
        "CSV restore under changed DateStyle produced {:?}",
        csv_restored.rows
    );

    transaction
        .execute("CREATE TABLE timestamp_array_dmy_target (value timestamp[])")
        .await
        .unwrap();
    transaction
        .execute(
            "INSERT INTO timestamp_array_dmy_target \
             VALUES (ARRAY['1999-01-01 00:00:00'::timestamp])",
        )
        .await
        .unwrap();
    let sibling = transaction
        .query(
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') FROM timestamp_array_dmy_target",
        )
        .await
        .unwrap();
    let sql_path = directory.path().join("timestamp-array-dmy.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "timestamp_array_dmy_target",
            }),
        },
        || false,
        |_| {},
    )
    .unwrap();
    transaction
        .execute(&std::fs::read_to_string(sql_path).unwrap())
        .await
        .unwrap();
    let restored = transaction
        .query(
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') FROM timestamp_array_dmy_target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows.len(), 2);
    assert!(restored.rows.contains(&sibling.rows[0]));
    assert!(
        restored.rows.contains(&vec![
            native.rows[0][1].clone(),
            native.rows[0][3].clone(),
            native.rows[0][4].clone(),
        ]),
        "restored {:?}, expected native type, JSON and wire values",
        restored.rows
    );
    transaction.rollback().await.unwrap();
}

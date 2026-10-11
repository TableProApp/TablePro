#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_timestamptz_array_file_exports_preserve_instants() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY['2024-11-03 01:30:00.123456-04'::timestamptz, \
        '2024-11-03 01:30:00.123456-05'::timestamptz, \
        '0001-01-01 12:34:56+00 BC'::timestamptz, \
        'infinity'::timestamptz, '-infinity'::timestamptz, NULL]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("timestamptz[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, {expression}::text, \
                    array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("timestamp with time zone[]".into()));
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("timestamptz[] result must remain text: {:?}", result.rows[0][0]);
    };
    let Value::Text(native_json) = &oracle.rows[0][2] else {
        panic!("timestamptz[] array_to_json oracle returned {:?}", oracle.rows[0][2]);
    };
    let json_elements = serde_json::from_str::<serde_json::Value>(native_json).unwrap();
    assert_eq!(json_elements.as_array().unwrap().len(), 6);
    assert!(json_elements[0].as_str().unwrap().contains("2024-11-03"));
    assert!(json_elements[1].as_str().unwrap().contains("2024-11-03"));
    assert_ne!(json_elements[0], json_elements[1]);
    assert!(json_elements[2].as_str().unwrap().contains("0001-01-01"));
    assert_eq!(json_elements[3], "infinity");
    assert_eq!(json_elements[4], "-infinity");
    assert!(json_elements[5].is_null());

    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::timestamptz[])::text, \
                    encode(array_send($1::text::timestamptz[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][2]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][3]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let json_path = directory.path().join("timestamptz-array.json");
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
    let json_file: serde_json::Value = serde_json::from_slice(&std::fs::read(json_path).unwrap()).unwrap();
    assert_eq!(json_file[0]["value"], *driver_text);

    let csv_path = directory.path().join("timestamptz-array.csv");
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
    let mut csv = csv::Reader::from_path(csv_path).unwrap();
    assert_eq!(csv.headers().unwrap().iter().collect::<Vec<_>>(), ["value"]);
    assert_eq!(&csv.records().next().unwrap().unwrap()[0], driver_text);

    let xlsx_path = directory.path().join("timestamptz-array.xlsx");
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    if let Some(path) = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT") {
        std::fs::copy(&xlsx_path, path).unwrap();
    }
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet).unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared_strings.contains(driver_text), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");

    connection
        .execute("CREATE TABLE timestamptz_array_filewriter_target (value timestamptz[])")
        .await
        .unwrap();
    let sql_path = directory.path().join("timestamptz-array.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "timestamptz_array_filewriter_target",
            }),
        },
        || false,
        |_| {},
    )
    .unwrap();
    connection
        .execute(&std::fs::read_to_string(sql_path).unwrap())
        .await
        .unwrap();
    let restored = connection
        .query(
            "SELECT value::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') FROM timestamptz_array_filewriter_target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows, vec![oracle.rows[0][1..].to_vec()]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_timestamptz_array_file_exports_preserve_instants_under_non_utc_session() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TABLE timestamptz_array_csv_import_target (value timestamptz[])")
        .await
        .unwrap();
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL TIME ZONE 'America/New_York'")
        .await
        .unwrap();
    let expression = "ARRAY['2024-11-03 01:30:00.123456-04'::timestamptz, \
        '2024-11-03 01:30:00.123456-05'::timestamptz, \
        '0001-01-01 12:34:56+00 BC'::timestamptz, \
        'infinity'::timestamptz, '-infinity'::timestamptz, NULL]";
    let result = transaction
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("timestamptz[]", &result);

    let oracle = transaction
        .query(&format!(
            "SELECT pg_typeof({expression})::text, {expression}::text, \
                    array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("timestamp with time zone[]".into()));
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("timestamptz[] result must remain text: {:?}", result.rows[0][0]);
    };
    assert!(driver_text.contains("+00:00"), "{driver_text}");
    assert_ne!(result.rows[0][0], oracle.rows[0][1]);
    let Value::Text(native_json) = &oracle.rows[0][2] else {
        panic!("timestamptz[] array_to_json returned {:?}", oracle.rows[0][2]);
    };
    let json_elements = serde_json::from_str::<serde_json::Value>(native_json).unwrap();
    assert!(json_elements[0].as_str().unwrap().ends_with("-04:00"));
    assert!(json_elements[1].as_str().unwrap().ends_with("-05:00"));
    assert_ne!(json_elements[0], json_elements[1]);

    let rebound = transaction
        .query_params(
            "SELECT encode(array_send($1::text::timestamptz[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][3]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let json_path = directory.path().join("timestamptz-array-non-utc.json");
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
    let json_file: serde_json::Value = serde_json::from_slice(&std::fs::read(json_path).unwrap()).unwrap();
    assert_eq!(json_file[0]["value"], *driver_text);

    let csv_path = directory.path().join("timestamptz-array-non-utc.csv");
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

    transaction.execute("SET LOCAL TIME ZONE 'UTC'").await.unwrap();
    let expected_utc = transaction
        .query(&format!(
            "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
                    encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    transaction
        .execute(
            "INSERT INTO timestamptz_array_csv_import_target \
             VALUES (ARRAY['1999-01-01 00:00:00+00'::timestamptz])",
        )
        .await
        .unwrap();
    let sibling = transaction
        .query(
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') \
             FROM timestamptz_array_csv_import_target",
        )
        .await
        .unwrap();
    let csv_text = std::fs::read(&csv_path).unwrap();
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(&csv_text, &import_options, None).unwrap();
    let columns = connection
        .fetch_columns(None, "timestamptz_array_csv_import_target")
        .await
        .unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("public"),
            table: "timestamptz_array_csv_import_target",
            columns: &columns,
            mapping: &[Some(0)],
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    transaction
        .execute_params(&plan.statement, &plan.rows[0])
        .await
        .unwrap();
    let csv_restored = transaction
        .query(
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') \
             FROM timestamptz_array_csv_import_target",
        )
        .await
        .unwrap();
    assert_eq!(csv_restored.rows.len(), 2);
    assert!(csv_restored.rows.contains(&sibling.rows[0]));
    assert!(
        csv_restored.rows.contains(&expected_utc.rows[0]),
        "CSV import produced {:?}, expected {:?}",
        csv_restored.rows,
        expected_utc.rows[0]
    );

    let xlsx_path = directory.path().join("timestamptz-array-non-utc.xlsx");
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    if let Some(path) = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT") {
        std::fs::copy(&xlsx_path, path).unwrap();
    }
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet).unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared_strings.contains(driver_text), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");

    transaction
        .execute("CREATE TABLE timestamptz_array_non_utc_target (value timestamptz[])")
        .await
        .unwrap();
    let sql_path = directory.path().join("timestamptz-array-non-utc.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "timestamptz_array_non_utc_target",
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
    transaction
        .execute("SET LOCAL TIME ZONE 'Asia/Kathmandu'")
        .await
        .unwrap();
    let restored = transaction
        .query(
            "SELECT encode(array_send(value), 'hex') FROM timestamptz_array_non_utc_target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows[0][0], oracle.rows[0][3]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_interval_array_file_exports_preserve_values_under_intervalstyle() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TABLE interval_array_filewriter_target (value interval[])")
        .await
        .unwrap();

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL intervalstyle = 'postgres_verbose'")
        .await
        .unwrap();
    let expression = "ARRAY['1 year 2 mons 3 days 04:05:06.123456'::interval, \
        '-1 year +2 mons -3 days -04:05:06.654321'::interval, \
        '0.000001 seconds'::interval, '00:00:00'::interval, NULL]";
    let result = transaction
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("interval[]", &result);

    let oracle = transaction
        .query(&format!(
            "SELECT pg_typeof({expression})::text, {expression}::text, \
                    array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("interval[]".into()));
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("interval[] result must remain text: {:?}", result.rows[0][0]);
    };
    let Value::Text(native_json) = &oracle.rows[0][2] else {
        panic!("interval[] array_to_json oracle returned {:?}", oracle.rows[0][2]);
    };
    let json_elements = serde_json::from_str::<serde_json::Value>(native_json).unwrap();
    assert_eq!(json_elements.as_array().unwrap().len(), 5);
    assert_eq!(json_elements[4], serde_json::Value::Null);
    assert!(json_elements[0].as_str().unwrap().contains("1 year"));
    assert!(json_elements[1].as_str().unwrap().contains("ago"));
    assert_ne!(json_elements[0], json_elements[1]);

    let rebound = transaction
        .query_params(
            "SELECT array_to_json($1::text::interval[])::text, \
                    encode(array_send($1::text::interval[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][2]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][3]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let json_path = directory.path().join("interval-array.json");
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
    let json_file: serde_json::Value = serde_json::from_slice(&std::fs::read(json_path).unwrap()).unwrap();
    assert_eq!(json_file[0]["value"], *driver_text);

    let csv_path = directory.path().join("interval-array.csv");
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
    let mut csv = csv::Reader::from_path(csv_path).unwrap();
    assert_eq!(csv.headers().unwrap().iter().collect::<Vec<_>>(), ["value"]);
    assert_eq!(&csv.records().next().unwrap().unwrap()[0], driver_text);

    let xlsx_path = directory.path().join("interval-array.xlsx");
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    if let Some(path) = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT") {
        std::fs::copy(&xlsx_path, path).unwrap();
    }
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet).unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared_strings.contains(driver_text), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");

    let sql_path = directory.path().join("interval-array.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "interval_array_filewriter_target",
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
            "SELECT value::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') FROM interval_array_filewriter_target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows, vec![oracle.rows[0][1..].to_vec()]);
    transaction.rollback().await.unwrap();
    assert_eq!(
        connection
            .query("SELECT count(*)::bigint FROM interval_array_filewriter_target")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(0)]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_interval_array_csv_and_sql_replay_survive_intervalstyle_change() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL IntervalStyle = 'postgres_verbose'")
        .await
        .unwrap();
    let expression = "ARRAY['1 year 2 mons 3 days 04:05:06.123456'::interval, \
        '-1 year +2 mons -3 days -04:05:06.654321'::interval, \
        '0.000001 seconds'::interval, '00:00:00'::interval, NULL]";
    let result = transaction
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("interval[]", &result);
    let native = transaction
        .query(&format!(
            "SELECT pg_typeof({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text("interval[]".into()));
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("interval[] result must remain exact array text: {:?}", result.rows[0][0]);
    };

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let sql_path = directory.path().join("interval-array-style-transition.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "interval_style_transition_target",
            }),
        },
        || false,
        |_| {},
    )
    .unwrap();
    transaction
        .execute("CREATE TABLE interval_style_transition_target (value interval[])")
        .await
        .unwrap();

    let csv_path = directory.path().join("interval-array-style-transition.csv");
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
    let mut csv = csv::Reader::from_path(csv_path).unwrap();
    let csv_value = csv.records().next().unwrap().unwrap()[0].to_owned();
    assert_eq!(csv_value, *driver_text);

    transaction.execute("SET LOCAL IntervalStyle = 'iso_8601'").await.unwrap();
    let setting = transaction.query("SELECT current_setting('IntervalStyle')").await.unwrap();
    assert_eq!(setting.rows[0][0], Value::Text("iso_8601".into()));
    transaction
        .execute(&std::fs::read_to_string(sql_path).unwrap())
        .await
        .unwrap();
    let rebound = transaction
        .query_params(
            "SELECT encode(array_send($1::text::interval[]), 'hex')",
            std::slice::from_ref(&Value::Text(driver_text.clone())),
        )
        .await
        .unwrap();
    let csv_rebound = transaction
        .query_params(
            "SELECT encode(array_send($1::text::interval[]), 'hex')",
            std::slice::from_ref(&Value::Text(csv_value)),
        )
        .await
        .unwrap();
    let restored = transaction
        .query("SELECT encode(array_send(value), 'hex') FROM interval_style_transition_target")
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][1]);
    assert_eq!(csv_rebound.rows[0][0], native.rows[0][1]);
    assert_eq!(restored.rows[0][0], native.rows[0][1]);
    transaction.rollback().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_unlisted_builtin_arrays_refuse_with_native_oracles() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let cases = [
        (
            "money[]",
            "ARRAY[NULL]::money[]",
            "{NULL}",
            "[null]",
        ),
    ];

    for (expected_type, expression, expected_text, expected_json) in cases {
        let sql = format!(
            "SELECT ({expression}) AS value, pg_typeof(({expression}))::text, \
             ({expression})::text, array_to_json(({expression}))::text"
        );
        let result = connection.query(&sql).await.expect("native array oracle query");
        let value = &result.rows[0][0];
        assert!(
            matches!(value, Value::Undecodable(type_name) if !type_name.is_empty()),
            "{expected_type}: {value:?}"
        );
        assert_eq!(result.rows[0][1], Value::Text(expected_type.into()), "{expected_type}");
        assert_eq!(result.rows[0][2], Value::Text(expected_text.into()), "{expected_type}");
        assert_eq!(result.rows[0][3], Value::Text(expected_json.into()), "{expected_type}");
        assert!(
            tablepro_core::sql_literal::render_sql_literal("postgres", value).is_err(),
            "{expected_type}"
        );
        assert!(
            connection
                .query_params("SELECT $1", std::slice::from_ref(value))
                .await
                .is_err(),
            "{expected_type}"
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_pg_lsn_array_result_bind_keyed_edit_and_csv_are_exact() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "'[0:4]={0/0,0/FFFFFFFF,1/0,FFFFFFFF/FFFFFFFF,NULL}'::pg_lsn[]";
    let source = connection
        .query(&format!(
            "SELECT {expression} AS value, pg_typeof({expression})::text, \
             {expression}::text, array_to_json({expression})::text, \
             encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    let expected = &source.rows[0][0];
    assert_eq!(expected, &Value::Text("[0:4]={\"0/0\",\"0/FFFFFFFF\",\"1/0\",\"FFFFFFFF/FFFFFFFF\",NULL}".into()));
    assert_eq!(source.rows[0][1], Value::Text("pg_lsn[]".into()));
    assert_eq!(source.rows[0][2], Value::Text("[0:4]={0/0,0/FFFFFFFF,1/0,FFFFFFFF/FFFFFFFF,NULL}".into()));
    assert_eq!(source.rows[0][3], Value::Text("[\"0/0\",\"0/FFFFFFFF\",\"1/0\",\"FFFFFFFF/FFFFFFFF\",null]".into()));

    connection
        .execute("CREATE TABLE pg_lsn_array_grid (id integer PRIMARY KEY, value pg_lsn[], sibling text)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO pg_lsn_array_grid VALUES (1, ARRAY['1/1'::pg_lsn], 'target'), (2, ARRAY['2/2'::pg_lsn], 'sibling')")
        .await
        .unwrap();
    connection
        .execute_params(
            "UPDATE pg_lsn_array_grid SET value = $1 WHERE id = $2",
            &[expected.clone(), Value::Int(1)],
        )
        .await
        .expect("assignment context infers pg_lsn[] for the binary array parameter");
    let bound = connection
        .query("SELECT pg_typeof(value)::text, encode(array_send(value), 'hex') FROM pg_lsn_array_grid WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(bound.rows[0][0], Value::Text("pg_lsn[]".into()));
    assert_eq!(bound.rows[0][1], source.rows[0][4]);
    let sibling_before = connection
        .query(
            "SELECT id, pg_typeof(value)::text, value::text, encode(array_send(value), 'hex'), sibling \
             FROM pg_lsn_array_grid WHERE id = 2",
        )
        .await
        .unwrap();
    let mut columns = connection.fetch_columns(None, "pg_lsn_array_grid").await.unwrap();
    columns[0].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "pg_lsn_array_grid",
        &columns,
        &[(1, expected.clone())],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);
    let grid = connection
        .query(
            "SELECT id, pg_typeof(value)::text, value::text, encode(array_send(value), 'hex'), sibling \
             FROM pg_lsn_array_grid ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(grid.rows[0][0], Value::Int(1));
    assert_eq!(grid.rows[0][1], Value::Text("pg_lsn[]".into()));
    assert_eq!(grid.rows[0][2], source.rows[0][2]);
    assert_eq!(grid.rows[0][3], source.rows[0][4]);
    assert_eq!(grid.rows[0][4], Value::Text("target".into()));
    assert_eq!(grid.rows[1], sibling_before.rows[0]);

    let invalid = connection
        .execute_params(
            "UPDATE pg_lsn_array_grid SET value = $1 WHERE id = $2",
            &[Value::Text("{0/1,not-an-lsn}".into()), Value::Int(1)],
        )
        .await;
    assert!(invalid.is_err(), "malformed LSN text must be rejected before the update");
    let after_invalid = connection
        .query("SELECT encode(array_send(value), 'hex') FROM pg_lsn_array_grid WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(after_invalid.rows[0][0], source.rows[0][4]);

    connection.execute("CREATE TABLE pg_lsn_csv_target (value pg_lsn[])").await.unwrap();
    let csv = tablepro_core::export::render_csv(
        &source.columns[..1],
        &[source.rows[0][..1].to_vec()],
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let columns = connection.fetch_columns(None, "pg_lsn_csv_target").await.unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: "pg_lsn_csv_target",
            columns: &columns,
            mapping: &[Some(0)],
        },
        &sheet,
        &options,
    )
    .expect("pg_lsn[] CSV value builds a typed INSERT plan");
    connection.execute_params(&plan.statement, &plan.rows[0]).await.unwrap();
    let restored = connection
        .query("SELECT pg_typeof(value)::text, value::text, encode(array_send(value), 'hex') FROM pg_lsn_csv_target")
        .await
        .unwrap();
    assert_eq!(restored.rows[0][0], source.rows[0][1]);
    assert_eq!(restored.rows[0][1], source.rows[0][2]);
    assert_eq!(restored.rows[0][2], source.rows[0][4]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_macaddr_array_binding_and_keyed_edit_preserve_native_bytes() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "'[0:2]={08:00:2b:01:02:03,NULL,AA:BB:CC:DD:EE:FF}'::macaddr[]";
    let source = connection
        .query(&format!(
            "SELECT {expression} AS value, pg_typeof({expression})::text, \
             {expression}::text, array_to_json({expression})::text, \
             encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    let value = &source.rows[0][0];
    assert_eq!(
        value,
        &Value::Text("[0:2]={\"08:00:2b:01:02:03\",NULL,\"aa:bb:cc:dd:ee:ff\"}".into())
    );
    assert_eq!(source.rows[0][1], Value::Text("macaddr[]".into()));
    assert_eq!(
        source.rows[0][2],
        Value::Text("[0:2]={08:00:2b:01:02:03,NULL,aa:bb:cc:dd:ee:ff}".into())
    );
    assert_eq!(
        source.rows[0][3],
        Value::Text("[\"08:00:2b:01:02:03\",null,\"aa:bb:cc:dd:ee:ff\"]".into())
    );

    connection
        .execute("CREATE TABLE macaddr_array_grid (id integer PRIMARY KEY, value macaddr[], sibling text)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO macaddr_array_grid VALUES (1, ARRAY['00:00:00:00:00:01'::macaddr], 'target'), (2, ARRAY['00:00:00:00:00:02'::macaddr], 'sibling')")
        .await
        .unwrap();
    connection
        .execute_params(
            "UPDATE macaddr_array_grid SET value = $1 WHERE id = $2",
            &[value.clone(), Value::Int(1)],
        )
        .await
        .expect("assignment context infers macaddr[] for a binary array parameter");
    let mut columns = connection.fetch_columns(None, "macaddr_array_grid").await.unwrap();
    columns[0].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "macaddr_array_grid",
        &columns,
        &[(1, value.clone())],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);
    let rows = connection
        .query("SELECT id, value::text, encode(array_send(value), 'hex'), sibling FROM macaddr_array_grid ORDER BY id")
        .await
        .unwrap();
    assert_eq!(rows.rows[0][1], source.rows[0][2]);
    assert_eq!(rows.rows[0][2], source.rows[0][4]);
    assert_eq!(rows.rows[0][3], Value::Text("target".into()));
    assert_eq!(rows.rows[1][3], Value::Text("sibling".into()));

    let malformed = connection
        .execute_params(
            "UPDATE macaddr_array_grid SET value = $1 WHERE id = $2",
            &[Value::Text("{08:00:2b:01:02:0g}".into()), Value::Int(1)],
        )
        .await;
    assert!(malformed.is_err(), "malformed MAC octet must be rejected");
    let after_invalid = connection
        .query("SELECT encode(array_send(value), 'hex') FROM macaddr_array_grid WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(after_invalid.rows[0][0], source.rows[0][4]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_macaddr8_array_binding_and_keyed_edit_preserve_native_bytes() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "'[0:2]={08:00:2b:01:02:03:04:05,NULL,AA:BB:CC:DD:EE:FF:00:11}'::macaddr8[]";
    let source = connection
        .query(&format!(
            "SELECT {expression} AS value, pg_typeof({expression})::text, \
             {expression}::text, array_to_json({expression})::text, \
             encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    let value = &source.rows[0][0];
    assert_eq!(
        value,
        &Value::Text("[0:2]={\"08:00:2b:01:02:03:04:05\",NULL,\"aa:bb:cc:dd:ee:ff:00:11\"}".into())
    );
    assert_eq!(source.rows[0][1], Value::Text("macaddr8[]".into()));
    assert_eq!(
        source.rows[0][2],
        Value::Text("[0:2]={08:00:2b:01:02:03:04:05,NULL,aa:bb:cc:dd:ee:ff:00:11}".into())
    );
    assert_eq!(
        source.rows[0][3],
        Value::Text("[\"08:00:2b:01:02:03:04:05\",null,\"aa:bb:cc:dd:ee:ff:00:11\"]".into())
    );

    connection
        .execute("CREATE TABLE macaddr8_array_grid (id integer PRIMARY KEY, value macaddr8[], sibling text)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO macaddr8_array_grid VALUES (1, ARRAY['00:00:00:00:00:00:00:01'::macaddr8], 'target'), (2, ARRAY['00:00:00:00:00:00:00:02'::macaddr8], 'sibling')")
        .await
        .unwrap();
    connection
        .execute_params(
            "UPDATE macaddr8_array_grid SET value = $1 WHERE id = $2",
            &[value.clone(), Value::Int(1)],
        )
        .await
        .expect("assignment context infers macaddr8[] for a binary array parameter");
    let mut columns = connection.fetch_columns(None, "macaddr8_array_grid").await.unwrap();
    columns[0].primary_key = true;
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        None,
        "macaddr8_array_grid",
        &columns,
        &[(1, value.clone())],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);
    let rows = connection
        .query("SELECT id, value::text, encode(array_send(value), 'hex'), sibling FROM macaddr8_array_grid ORDER BY id")
        .await
        .unwrap();
    assert_eq!(rows.rows[0][1], source.rows[0][2]);
    assert_eq!(rows.rows[0][2], source.rows[0][4]);
    assert_eq!(rows.rows[0][3], Value::Text("target".into()));
    assert_eq!(rows.rows[1][3], Value::Text("sibling".into()));

    let malformed = connection
        .execute_params(
            "UPDATE macaddr8_array_grid SET value = $1 WHERE id = $2",
            &[Value::Text("{08:00:2b:01:02:03:04:0g}".into()), Value::Int(1)],
        )
        .await;
    assert!(malformed.is_err(), "malformed MACADDR8 octet must be rejected");
    let after_invalid = connection
        .query("SELECT encode(array_send(value), 'hex') FROM macaddr8_array_grid WHERE id = 1")
        .await
        .unwrap();
    assert_eq!(after_invalid.rows[0][0], source.rows[0][4]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_builtin_array_oid_census_matches_decode_allowlist() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let catalog = connection
        .query(
            "SELECT oid::bigint, format_type(typarray, NULL) \
             FROM pg_catalog.pg_type \
             WHERE typnamespace = 'pg_catalog'::regnamespace \
               AND typelem = 0 AND typarray <> 0 AND typisdefined \
               AND typtype IN ('b', 'c', 'd', 'e', 'm', 'r') \
             ORDER BY oid",
        )
        .await
        .expect("enumerate built-in array element OIDs");
    let supported_oids = [
        16, 17, 19, 20, 21, 23, 25, 26, 142, 650, 700, 701, 774, 829, 869, 1042, 1043, 1082, 1083, 1114, 1184,
        1186, 1266, 1560, 1562, 1700, 2950, 3220,
    ];
    let mut seen_supported = Vec::new();
    let mut refused = 0;
    let mut refused_names = Vec::new();
    let mut blocked = Vec::new();

    for row in catalog.rows {
        let Value::Int(oid) = row[0] else {
            panic!("unexpected catalog OID: {:?}", row[0])
        };
        let Value::Text(array_type) = &row[1] else {
            panic!("unexpected array type: {:?}", row[1])
        };
        let expression = format!("ARRAY[NULL]::{array_type}");
        let oracle = connection
            .query(&format!(
                "SELECT pg_typeof({expression})::text, {expression}::text, \
                 array_to_json({expression})::text"
            ))
            .await
            .unwrap_or_else(|error| panic!("native {array_type} oracle (element OID {oid}): {error:?}"));
        assert_eq!(oracle.rows[0][0], Value::Text(array_type.clone()), "OID {oid}");
        assert_eq!(oracle.rows[0][1], Value::Text("{NULL}".into()), "OID {oid}");
        assert_eq!(oracle.rows[0][2], Value::Text("[null]".into()), "OID {oid}");

        let direct = connection.query(&format!("SELECT {expression} AS value")).await;
        let result = match direct {
            Ok(result) => result,
            Err(error) => {
                let details = format!("{error:?}");
                let known_metadata_failure = details.contains("typcategory") && details.contains("category code 90");
                let known_no_binary_output = details.contains("no binary output function available");
                let known_multirange_metadata_failure = details.contains("unknown type code 109");
                assert!(
                    known_metadata_failure || known_no_binary_output || known_multirange_metadata_failure,
                    "{array_type} (element OID {oid}) unexpected error: {details}"
                );
                blocked.push((array_type.clone(), details));
                continue;
            }
        };
        let value = &result.rows[0][0];
        if supported_oids.contains(&(oid as u32)) {
            seen_supported.push(oid as u32);
            assert_eq!(value, &Value::Text("{NULL}".into()), "supported {array_type}");
            assert!(tablepro_core::sql_literal::render_sql_literal("postgres", value).is_ok());
        } else {
            refused += 1;
            refused_names.push(array_type.clone());
            assert!(matches!(value, Value::Undecodable(_)), "{array_type}: {value:?}");
            if array_type.contains("multirange") {
                assert!(
                    matches!(value, Value::Undecodable(name) if name.eq_ignore_ascii_case(array_type)),
                    "{array_type} must retain its native type name: {value:?}"
                );
            }
            assert!(tablepro_core::sql_literal::render_sql_literal("postgres", value).is_err());
            assert!(
                connection
                    .query_params("SELECT $1", std::slice::from_ref(value))
                    .await
                    .is_err()
            );
        }
    }

    seen_supported.sort_unstable();
    let catalog_supported_oids: Vec<_> = supported_oids.iter().copied().filter(|oid| *oid != 19).collect();
    assert_eq!(
        seen_supported, catalog_supported_oids,
        "the catalog must cover all allowlisted built-in arrays except name[]"
    );
    let name_array = connection
        .query("SELECT ARRAY[NULL]::name[]")
        .await
        .expect("name[] decoder allowlist contract");
    assert_eq!(name_array.rows[0][0], Value::Text("{NULL}".into()));
    assert!(
        refused >= 7,
        "the catalog census should cover the explicit unlisted-array contract set"
    );
    for array_type in [
        "int4multirange[]",
        "nummultirange[]",
        "tsmultirange[]",
        "tstzmultirange[]",
        "datemultirange[]",
        "int8multirange[]",
    ] {
        assert!(
            refused_names.iter().any(|name| name == array_type),
            "{array_type} must be explicitly refused"
        );
    }
    let blocked_names: Vec<_> = blocked.iter().map(|(name, _)| name.as_str()).collect();
    assert_eq!(
        blocked_names,
        [
            "pg_type[]",
            "pg_proc[]",
            "pg_class[]",
            "aclitem[]",
            "gtsvector[]",
            "pg_attrdef[]",
            "pg_constraint[]",
            "pg_index[]",
            "pg_statistic_ext[]",
            "pg_statistic_ext_data[]",
            "pg_rewrite[]",
            "pg_trigger[]",
            "pg_policy[]",
            "pg_partitioned_table[]",
            "pg_publication_rel[]",
            "pg_stats_ext[]",
        ],
        "every driver-level blocker must be explicit and stable: {blocked:?}"
    );
    assert!(
        blocked
            .iter()
            .filter(|(_, error)| error.contains("category code 90"))
            .all(|(name, _)| { name.ends_with("[]") && !name.contains("multirange") })
    );
    assert!(
        blocked
            .iter()
            .filter(|(_, error)| error.contains("no binary output function available"))
            .all(|(name, _)| { matches!(name.as_str(), "aclitem[]" | "gtsvector[]") })
    );
    for (name, error) in &blocked {
        if matches!(name.as_str(), "aclitem[]" | "gtsvector[]") {
            assert!(error.contains("no binary output function available"), "{name}: {error}");
        } else {
            assert!(
                error.contains("typcategory") && error.contains("category code 90"),
                "{name}: {error}"
            );
        }
    }
}

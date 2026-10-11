#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_text_array_file_exports_preserve_text_and_escape_markup() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression =
        r#"ARRAY['NULL', NULL, '', 'comma,value', E'quote"slash\\', '東京 😀', '</value><injected a="1">&']::text[]"#;
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("text[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, {expression}::text, \
                    array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("text[]".into()));
    assert_eq!(result.rows[0][0], oracle.rows[0][1]);
    let round_trip = connection
        .query_params(
            "SELECT encode(array_send($1::text[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(round_trip.rows[0][0], oracle.rows[0][3]);
    let Value::Text(native_json) = &oracle.rows[0][2] else {
        panic!("native array_to_json returned {:?}", oracle.rows[0][2]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(native_json).unwrap(),
        serde_json::json!([
            "NULL",
            null,
            "",
            "comma,value",
            "quote\"slash\\",
            "東京 😀",
            "</value><injected a=\"1\">&"
        ])
    );

    let directory = tempfile::tempdir().unwrap();
    let options = tablepro_core::export::CsvOptions::default();
    for (extension, format, marker) in [
        (
            "xml",
            tablepro_core::export::ResultFormat::Xml,
            "&lt;/value&gt;&lt;injected",
        ),
        (
            "html",
            tablepro_core::export::ResultFormat::Html,
            "&lt;/value&gt;&lt;injected",
        ),
        (
            "md",
            tablepro_core::export::ResultFormat::Markdown,
            "&lt;/value&gt;&lt;injected",
        ),
    ] {
        let path = directory.path().join(format!("array.{extension}"));
        tablepro_core::export::write_result_file(
            &path,
            &result,
            &tablepro_core::export::ResultExport {
                format,
                csv: &options,
                sql: None,
            },
            || false,
            |_| {},
        )
        .unwrap();
        let output = std::fs::read_to_string(path).unwrap();
        assert!(output.contains(marker), "{extension}: {output}");
        assert!(!output.contains("</value><injected"), "{extension}: {output}");
        assert!(output.contains("NULL"), "{extension}: {output}");
        assert!(output.contains("comma,value"), "{extension}: {output}");
        assert!(output.contains("quote"), "{extension}: {output}");
        assert!(output.contains("slash"), "{extension}: {output}");
        assert!(output.contains("東京 😀"), "{extension}: {output}");
    }

    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("array.xlsx"));
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &options,
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
    assert!(
        shared_strings.contains("\"NULL\",NULL,\"\",\"comma,value\""),
        "{shared_strings}"
    );
    assert!(shared_strings.contains("quote"), "{shared_strings}");
    assert!(shared_strings.contains("東京 😀"), "{shared_strings}");
    assert!(
        shared_strings.contains("&lt;/value&gt;&lt;injected"),
        "{shared_strings}"
    );
    assert!(!sheet.contains("<f>"), "{sheet}");

    connection
        .execute("CREATE TABLE array_filewriter_target (value text[])")
        .await
        .unwrap();
    let path = directory.path().join("array.sql");
    tablepro_core::export::write_result_file(
        &path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "array_filewriter_target",
            }),
        },
        || false,
        |_| {},
    )
    .unwrap();
    connection
        .execute(&std::fs::read_to_string(path).unwrap())
        .await
        .unwrap();
    let restored = connection
        .query(
            "SELECT value::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') FROM array_filewriter_target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows, vec![oracle.rows[0][1..].to_vec()]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_uuid_array_file_exports_preserve_values_for_calc_reimport() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY[\
        '550e8400-e29b-41d4-a716-446655440000'::uuid, \
        '12345678-1234-5678-90ab-1234567890ab'::uuid, NULL]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("uuid[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, {expression}::text, \
             array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("uuid[]".into()));
    assert_eq!(
        oracle.rows[0][2],
        Value::Text(
            r#"["550e8400-e29b-41d4-a716-446655440000","12345678-1234-5678-90ab-1234567890ab",null]"#.into()
        )
    );
    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::uuid[])::text, \
             encode(array_send($1::text::uuid[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][2]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][3]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("uuid[] result must remain text: {:?}", result.rows[0][0]);
    };
    let json_path = directory.path().join("uuid-array.json");
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

    let csv_path = directory.path().join("uuid-array.csv");
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

    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("uuid-array.xlsx"));
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
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(),
        &mut sheet,
    )
    .unwrap();
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
        .execute("CREATE TABLE uuid_array_filewriter_target (value uuid[])")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO uuid_array_filewriter_target VALUES \
             (ARRAY['00000000-0000-0000-0000-000000000001'::uuid])",
        )
        .await
        .unwrap();
    let sibling = connection
        .query(
            "SELECT pg_typeof(value)::text, value::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') \
             FROM uuid_array_filewriter_target",
        )
        .await
        .unwrap();
    let sql_path = directory.path().join("uuid-array.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "uuid_array_filewriter_target",
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
            "SELECT pg_typeof(value)::text, value::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') \
             FROM uuid_array_filewriter_target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows.len(), 2);
    assert!(restored.rows.contains(&sibling.rows[0]));
    assert!(restored.rows.contains(&oracle.rows[0]));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_date_array_file_exports_preserve_boundaries_for_calc_reimport() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY[\
        '0002-12-31 BC'::date, '10000-01-01'::date, \
        'infinity'::date, '-infinity'::date, NULL]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("date[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
             encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("date[]".into()));
    assert_eq!(
        oracle.rows[0][1],
        Value::Text(
            r#"["0002-12-31 BC","10000-01-01","infinity","-infinity",null]"#.into()
        )
    );
    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::date[])::text, \
             encode(array_send($1::text::date[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][1]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][2]);

    let directory = tempfile::tempdir().unwrap();
    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("date-array.xlsx"));
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(),
        &mut sheet,
    )
    .unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("date[] result must remain text: {:?}", result.rows[0][0]);
    };
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared_strings.contains(driver_text), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_date_array_csv_and_sql_replay_preserve_sql_dmy_style() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let mut transaction = connection.begin().await.unwrap();
    transaction.execute("SET LOCAL DateStyle = 'SQL, DMY'").await.unwrap();
    let expression = "ARRAY['2024-12-31'::date, '2001-02-03'::date, \
                      '0002-12-31 BC'::date, 'infinity'::date, NULL]";
    let result = transaction
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("date[]", &result);

    let native = transaction
        .query(&format!(
            "SELECT current_setting('DateStyle'), pg_typeof({expression})::text, \
                    {expression}::text, array_to_json({expression})::text, \
                    encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text("SQL, DMY".into()));
    assert_eq!(native.rows[0][1], Value::Text("date[]".into()));
    assert_ne!(result.rows[0][0], native.rows[0][2]);
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("date[] result must remain exact array text: {:?}", result.rows[0][0]);
    };
    assert_eq!(
        driver_text,
        r#"{"2024-12-31","2001-02-03","0002-12-31 BC","infinity",NULL}"#
    );
    transaction.execute("SET LOCAL DateStyle = 'ISO, MDY'").await.unwrap();

    let rebound = transaction
        .query_params(
            "SELECT array_to_json($1::text::date[])::text, \
                    encode(array_send($1::text::date[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][3]);
    assert_eq!(rebound.rows[0][1], native.rows[0][4]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let csv_path = directory.path().join("date-array-sql-dmy.csv");
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

    transaction
        .execute("CREATE TABLE date_array_sql_dmy_target (value date[])")
        .await
        .unwrap();
    let sql_path = directory.path().join("date-array-sql-dmy.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "date_array_sql_dmy_target",
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
        .query("SELECT encode(array_send(value), 'hex') FROM date_array_sql_dmy_target")
        .await
        .unwrap();
    assert_eq!(restored.rows[0][0], native.rows[0][4]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_timestamp_array_file_exports_preserve_boundaries_for_calc_reimport() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY[\
        '0002-12-31 23:59:59.999999 BC'::timestamp, \
        '10000-01-01 00:00:00'::timestamp, \
        '294276-12-31 23:59:59.999999'::timestamp, \
        'infinity'::timestamp, '-infinity'::timestamp, NULL]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("timestamp[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
             encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(
        oracle.rows[0][0],
        Value::Text("timestamp without time zone[]".into())
    );
    assert_eq!(
        oracle.rows[0][1],
        Value::Text(
            r#"["0002-12-31T23:59:59.999999 BC","10000-01-01T00:00:00","294276-12-31T23:59:59.999999","infinity","-infinity",null]"#.into()
        )
    );
    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::timestamp[])::text, \
             encode(array_send($1::text::timestamp[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][1]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][2]);

    let directory = tempfile::tempdir().unwrap();
    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("timestamp-array.xlsx"));
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(),
        &mut sheet,
    )
    .unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("timestamp[] result must remain text: {:?}", result.rows[0][0]);
    };
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared_strings.contains(driver_text), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_time_array_file_exports_preserve_boundaries_for_calc_reimport() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY[\
        '00:00:00'::time, '12:34:56.123456'::time, \
        '23:59:59.999999'::time, '24:00:00'::time, NULL]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("time[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
             encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(
        oracle.rows[0][0],
        Value::Text("time without time zone[]".into())
    );
    assert_eq!(
        oracle.rows[0][1],
        Value::Text(
            r#"["00:00:00","12:34:56.123456","23:59:59.999999","24:00:00",null]"#.into()
        )
    );
    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::time[])::text, \
             encode(array_send($1::text::time[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][1]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][2]);

    let directory = tempfile::tempdir().unwrap();
    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("time-array.xlsx"));
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(),
        &mut sheet,
    )
    .unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("time[] result must remain text: {:?}", result.rows[0][0]);
    };
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared_strings.contains(driver_text), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_timetz_array_file_exports_preserve_offsets_for_calc_reimport() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TABLE timetz_array_csv_import_target (value timetz[])")
        .await
        .unwrap();
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL TIME ZONE 'America/New_York'")
        .await
        .unwrap();
    let expression = "ARRAY[\
        '00:00:00+15:59'::timetz, '23:59:59.999999-15:59'::timetz, \
        '12:34:56.123456+05:30'::timetz, '12:34:56.123456-05:30'::timetz, NULL]";
    let result = transaction
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("timetz[]", &result);

    let oracle = transaction
        .query(&format!(
            "SELECT current_setting('TimeZone'), pg_typeof({expression})::text, \
             array_to_json({expression})::text, \
             encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("America/New_York".into()));
    assert_eq!(oracle.rows[0][1], Value::Text("time with time zone[]".into()));
    assert_eq!(
        oracle.rows[0][2],
        Value::Text(
            r#"["00:00:00+15:59","23:59:59.999999-15:59","12:34:56.123456+05:30","12:34:56.123456-05:30",null]"#.into()
        )
    );
    transaction
        .execute("SET LOCAL TIME ZONE 'UTC'")
        .await
        .unwrap();
    let rebound = transaction
        .query_params(
            "SELECT array_to_json($1::text::timetz[])::text, \
             encode(array_send($1::text::timetz[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][2]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][3]);

    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("timetz[] result must remain text: {:?}", result.rows[0][0]);
    };
    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let json_path = directory.path().join("timetz-array.json");
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

    let csv_path = directory.path().join("timetz-array.csv");
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

    transaction
        .execute(
            "INSERT INTO timetz_array_csv_import_target \
             VALUES (ARRAY['01:02:03+00'::timetz])",
        )
        .await
        .unwrap();
    let sibling = transaction
        .query(
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex') FROM timetz_array_csv_import_target",
        )
        .await
        .unwrap();
    let csv_text = std::fs::read(csv_path).unwrap();
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(&csv_text, &import_options, None).unwrap();
    let columns = connection
        .fetch_columns(None, "timetz_array_csv_import_target")
        .await
        .unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("public"),
            table: "timetz_array_csv_import_target",
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
    let restored = transaction
        .query(
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex') FROM timetz_array_csv_import_target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows.len(), 2);
    assert!(restored.rows.contains(&sibling.rows[0]));
    assert!(restored.rows.contains(&vec![
        oracle.rows[0][1].clone(),
        oracle.rows[0][2].clone(),
        oracle.rows[0][3].clone(),
    ]));

    transaction
        .execute("CREATE TABLE timetz_array_filewriter_target (value timetz[])")
        .await
        .unwrap();
    transaction
        .execute(
            "INSERT INTO timetz_array_filewriter_target \
             VALUES (ARRAY['01:02:03+00'::timetz])",
        )
        .await
        .unwrap();
    let sibling = transaction
        .query(
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') FROM timetz_array_filewriter_target",
        )
        .await
        .unwrap();
    let sql_path = directory.path().join("timetz-array.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "timetz_array_filewriter_target",
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
                    encode(array_send(value), 'hex') FROM timetz_array_filewriter_target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows.len(), 2);
    assert!(restored.rows.contains(&sibling.rows[0]));
    assert!(restored.rows.contains(&vec![
        oracle.rows[0][1].clone(),
        oracle.rows[0][2].clone(),
        oracle.rows[0][3].clone(),
    ]));

    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("timetz-array.xlsx"));
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
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(),
        &mut sheet,
    )
    .unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("timetz[] result must remain text: {:?}", result.rows[0][0]);
    };
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared_strings.contains(driver_text), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_boolean_array_file_exports_preserve_values_for_calc_reimport() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY[true, false, NULL, true, false]::boolean[]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("bool[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
             encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("boolean[]".into()));
    assert_eq!(
        oracle.rows[0][1],
        Value::Text("[true,false,null,true,false]".into())
    );
    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::boolean[])::text, \
             encode(array_send($1::text::boolean[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][1]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][2]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("boolean[] result must remain text: {:?}", result.rows[0][0]);
    };
    for (format, extension) in [
        (tablepro_core::export::ResultFormat::Json, "json"),
        (tablepro_core::export::ResultFormat::Csv, "csv"),
        (tablepro_core::export::ResultFormat::Xml, "xml"),
        (tablepro_core::export::ResultFormat::Html, "html"),
        (tablepro_core::export::ResultFormat::Markdown, "md"),
    ] {
        let path = directory.path().join(format!("boolean-array.{extension}"));
        tablepro_core::export::write_result_file(
            &path,
            &result,
            &tablepro_core::export::ResultExport {
                format,
                csv: &csv_options,
                sql: None,
            },
            || false,
            |_| {},
        )
        .unwrap();
        let output = std::fs::read_to_string(path).unwrap();
        let validated = match format {
            tablepro_core::export::ResultFormat::Json => {
                let json: serde_json::Value = serde_json::from_str(&output).unwrap();
                assert_eq!(json[0]["value"], *driver_text);
                true
            }
            tablepro_core::export::ResultFormat::Csv => {
                let mut csv = csv::Reader::from_reader(output.as_bytes());
                assert_eq!(csv.headers().unwrap().iter().collect::<Vec<_>>(), ["value"]);
                assert_eq!(&csv.records().next().unwrap().unwrap()[0], driver_text);
                true
            }
            tablepro_core::export::ResultFormat::Xml => {
                let escaped = driver_text.replace('"', "&quot;");
                assert!(output.contains(&format!("<value>{escaped}</value>")), "{output}");
                true
            }
            tablepro_core::export::ResultFormat::Html => {
                let escaped = driver_text.replace('"', "&quot;");
                assert!(output.contains(&format!("<td>{escaped}</td>")), "{output}");
                true
            }
            tablepro_core::export::ResultFormat::Markdown => {
                let escaped = serde_json::Value::String(driver_text.clone())
                    .to_string()
                    .replace('\\', "&#92;");
                assert!(output.contains(&format!("| {escaped} |")), "{output}");
                true
            }
            _ => false,
        };
        assert!(validated, "export loop included an unvalidated format");
    }

    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("boolean-array.xlsx"));
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
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(),
        &mut sheet,
    )
    .unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared_strings.contains(driver_text), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_int8_array_file_exports_preserve_precision_for_calc_reimport() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "'[0:3]={-9223372036854775808,9007199254740993,9223372036854775807,NULL}'::int8[]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("int8[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
             encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("bigint[]".into()));
    assert_eq!(
        oracle.rows[0][1],
        Value::Text("[-9223372036854775808,9007199254740993,9223372036854775807,null]".into())
    );
    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::int8[])::text, \
             encode(array_send($1::text::int8[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][1]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][2]);

    let directory = tempfile::tempdir().unwrap();
    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("int8-array.xlsx"));
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(),
        &mut sheet,
    )
    .unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("int8[] result must remain text: {:?}", result.rows[0][0]);
    };
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared_strings.contains(driver_text), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_integer_arrays_file_exports_preserve_bounds_for_calc_reimport() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let smallint = "'[0:3]={-32768,0,32767,NULL}'::int2[]";
    let integer = "'[2:6]={-2147483648,-16777217,16777217,2147483647,NULL}'::int4[]";
    let result = connection
        .query(&format!("SELECT {smallint} AS smallints, {integer} AS integers"))
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, "INT2[]");
    assert_eq!(result.columns[1].data_type, "INT4[]");
    let smallint_oracle = connection
        .query(&format!(
            "SELECT pg_typeof({smallint})::text, array_to_json({smallint})::text, \
             encode(array_send({smallint}), 'hex')"
        ))
        .await
        .unwrap();
    let integer_oracle = connection
        .query(&format!(
            "SELECT pg_typeof({integer})::text, array_to_json({integer})::text, \
             encode(array_send({integer}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(smallint_oracle.rows[0][0], Value::Text("smallint[]".into()));
    assert_eq!(integer_oracle.rows[0][0], Value::Text("integer[]".into()));
    assert_eq!(smallint_oracle.rows[0][1], Value::Text("[-32768,0,32767,null]".into()));
    assert_eq!(
        integer_oracle.rows[0][1],
        Value::Text("[-2147483648,-16777217,16777217,2147483647,null]".into())
    );
    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::int2[])::text, encode(array_send($1::text::int2[]), 'hex'), \
             array_to_json($2::text::int4[])::text, encode(array_send($2::text::int4[]), 'hex')",
            &[result.rows[0][0].clone(), result.rows[0][1].clone()],
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], smallint_oracle.rows[0][1]);
    assert_eq!(rebound.rows[0][1], smallint_oracle.rows[0][2]);
    assert_eq!(rebound.rows[0][2], integer_oracle.rows[0][1]);
    assert_eq!(rebound.rows[0][3], integer_oracle.rows[0][2]);

    let directory = tempfile::tempdir().unwrap();
    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("integer-arrays.xlsx"));
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut archive = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/worksheets/sheet1.xml").unwrap(),
        &mut sheet,
    )
    .unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut archive.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    let (Value::Text(smallint_text), Value::Text(integer_text)) =
        (&result.rows[0][0], &result.rows[0][1])
    else {
        panic!("integer array results must remain text: {:?}", result.rows[0]);
    };
    for cell in ["A2", "B2"] {
        assert!(sheet.contains(&format!("<c r=\"{cell}\" t=\"s\">")), "{sheet}");
    }
    assert!(shared_strings.contains(smallint_text), "{shared_strings}");
    assert!(shared_strings.contains(integer_text), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");
}

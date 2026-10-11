#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_numeric_array_file_exports_preserve_exact_text() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY[1234567890123456789012345678901234567890::numeric, \
        0.123456789012345678901234567891::numeric, 1.2300::numeric, \
        'NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric, NULL]::numeric[]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("numeric[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, {expression}::text, \
                    array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("numeric[]".into()));
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("numeric[] result must remain text: {:?}", result.rows[0][0]);
    };
    let Value::Text(native_text) = &oracle.rows[0][1] else {
        panic!("numeric[] native text oracle returned {:?}", oracle.rows[0][1]);
    };
    assert_eq!(
        driver_text,
        r#"{"1234567890123456789012345678901234567890","0.123456789012345678901234567891","1.2300","NaN","Infinity","-Infinity",NULL}"#
    );
    assert_eq!(
        native_text,
        "{1234567890123456789012345678901234567890,0.123456789012345678901234567891,1.2300,NaN,Infinity,-Infinity,NULL}"
    );
    let Value::Text(native_json) = &oracle.rows[0][2] else {
        panic!("numeric[] array_to_json oracle returned {:?}", oracle.rows[0][2]);
    };
    let json_elements = serde_json::from_str::<serde_json::Value>(native_json).unwrap();
    assert_eq!(json_elements.as_array().unwrap().len(), 7);
    assert!(json_elements[0].is_number());
    assert!(json_elements[1].is_number());
    assert!(json_elements[2].is_number());
    assert_eq!(json_elements[3], "NaN");
    assert_eq!(json_elements[4], "Infinity");
    assert_eq!(json_elements[5], "-Infinity");
    assert!(json_elements[6].is_null());

    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::numeric[])::text, \
                    encode(array_send($1::text::numeric[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][2]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][3]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let json_path = directory.path().join("numeric-array.json");
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

    let csv_path = directory.path().join("numeric-array.csv");
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

    for (extension, format) in [
        ("xml", tablepro_core::export::ResultFormat::Xml),
        ("html", tablepro_core::export::ResultFormat::Html),
        ("md", tablepro_core::export::ResultFormat::Markdown),
    ] {
        let path = directory.path().join(format!("numeric-array.{extension}"));
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
        let expected = if extension == "md" {
            serde_json::Value::String(driver_text.clone()).to_string().replace('\\', "&#92;")
        } else {
            driver_text
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;")
                .replace('"', "&quot;")
                .replace('\'', "&apos;")
        };
        assert!(output.contains(&expected), "{extension}: {output}");
    }

    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("numeric-array.xlsx"));
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
        .execute("CREATE TABLE numeric_array_filewriter_target (value numeric[])")
        .await
        .unwrap();
    let sql_path = directory.path().join("numeric-array.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "numeric_array_filewriter_target",
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
                    encode(array_send(value), 'hex') FROM numeric_array_filewriter_target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows, vec![oracle.rows[0][1..].to_vec()]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_float8_array_file_exports_preserve_bits() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY[1.0000000000000002::float8, '-0'::float8, \
        '4.9406564584124654e-324'::float8, 'NaN'::float8, 'Infinity'::float8, \
        '-Infinity'::float8, NULL]::float8[]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("float8[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
                    encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("double precision[]".into()));
    let Value::Text(native_json) = &oracle.rows[0][1] else {
        panic!("float8[] array_to_json returned {:?}", oracle.rows[0][1]);
    };
    let elements = serde_json::from_str::<serde_json::Value>(native_json).unwrap();
    let elements = elements.as_array().unwrap();
    assert_eq!(elements.len(), 7);
    assert_eq!(elements[0].as_f64().unwrap().to_bits(), 1.0000000000000002f64.to_bits());
    assert_eq!(elements[2].as_f64().unwrap().to_bits(), 1);
    assert_eq!(elements[3], "NaN");
    assert_eq!(elements[4], "Infinity");
    assert_eq!(elements[5], "-Infinity");
    assert!(elements[6].is_null());

    let element_wire = connection
        .query(&format!(
            "SELECT ordinality, item IS NULL, encode(float8send(item), 'hex') \
             FROM unnest({expression}) WITH ORDINALITY AS element(item, ordinality) ORDER BY ordinality"
        ))
        .await
        .unwrap();
    assert_eq!(element_wire.rows[0][2], Value::Text("3ff0000000000001".into()));
    // array_to_json renders negative zero as 0; float8send is the lossless oracle.
    assert_eq!(element_wire.rows[1][2], Value::Text("8000000000000000".into()));
    assert_eq!(element_wire.rows[2][2], Value::Text("0000000000000001".into()));
    assert_eq!(element_wire.rows[6][1], Value::Bool(true));
    assert_eq!(element_wire.rows[6][2], Value::Null);

    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::float8[])::text, encode(array_send($1::text::float8[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][1]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][2]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("float8[] result must remain text: {:?}", result.rows[0][0]);
    };
    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("float8-array.xlsx"));
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

    let json_path = directory.path().join("float8-array.json");
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

    let csv_path = directory.path().join("float8-array.csv");
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

    for (format, extension, open, close) in [
        (
            tablepro_core::export::ResultFormat::Xml,
            "xml",
            "<value>",
            "</value>",
        ),
        (
            tablepro_core::export::ResultFormat::Html,
            "html",
            "<td>",
            "</td>",
        ),
    ] {
        let path = directory.path().join(format!("float8-array.{extension}"));
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
        let escaped = driver_text.replace('"', "&quot;");
        assert!(output.contains(&format!("{open}{escaped}{close}")), "{output}");
    }

    let markdown_path = directory.path().join("float8-array.md");
    tablepro_core::export::write_result_file(
        &markdown_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Markdown,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let markdown = std::fs::read_to_string(markdown_path).unwrap();
    let markdown_text = serde_json::Value::String(driver_text.clone())
        .to_string()
        .replace('\\', "&#92;");
    assert!(markdown.contains(&format!("| {markdown_text} |")), "{markdown}");

    connection
        .execute("CREATE TABLE float8_array_filewriter_target (value float8[])")
        .await
        .unwrap();
    let sql_path = directory.path().join("float8-array.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "float8_array_filewriter_target",
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
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') FROM float8_array_filewriter_target",
        )
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![vec![
            oracle.rows[0][0].clone(),
            oracle.rows[0][1].clone(),
            oracle.rows[0][2].clone(),
        ]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_float4_array_file_exports_preserve_values_for_calc_reimport() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY[0.1::float4, 1.0000001192092896::float4, '-0'::float4, \
        '1.40129846e-45'::float4, 'NaN'::float4, 'Infinity'::float4, \
        '-Infinity'::float4, NULL]::float4[]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_array_value("float4[]", &result);

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
                    encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("real[]".into()));
    let Value::Text(native_json) = &oracle.rows[0][1] else {
        panic!("float4[] array_to_json returned {:?}", oracle.rows[0][1]);
    };
    let elements = serde_json::from_str::<serde_json::Value>(native_json).unwrap();
    let elements = elements.as_array().unwrap();
    assert_eq!(elements.len(), 8);
    assert_eq!((elements[0].as_f64().unwrap() as f32).to_bits(), 0.1_f32.to_bits());
    assert_eq!(
        (elements[1].as_f64().unwrap() as f32).to_bits(),
        f32::from_bits(0x3f800001).to_bits()
    );
    assert_eq!(
        (elements[3].as_f64().unwrap() as f32).to_bits(),
        f32::from_bits(1).to_bits()
    );
    assert_eq!(elements[4], "NaN");
    assert_eq!(elements[5], "Infinity");
    assert_eq!(elements[6], "-Infinity");
    assert!(elements[7].is_null());

    let element_wire = connection
        .query(&format!(
            "SELECT ordinality, item IS NULL, encode(float4send(item), 'hex') \
             FROM unnest({expression}) WITH ORDINALITY AS element(item, ordinality) \
             ORDER BY ordinality"
        ))
        .await
        .unwrap();
    assert_eq!(element_wire.rows[0][2], Value::Text("3dcccccd".into()));
    assert_eq!(element_wire.rows[1][2], Value::Text("3f800001".into()));
    assert_eq!(element_wire.rows[2][2], Value::Text("80000000".into()));
    assert_eq!(element_wire.rows[3][2], Value::Text("00000001".into()));
    assert_eq!(element_wire.rows[7][1], Value::Bool(true));
    assert_eq!(element_wire.rows[7][2], Value::Null);

    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::float4[])::text, \
                    encode(array_send($1::text::float4[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][1]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][2]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("float4[] result must remain text: {:?}", result.rows[0][0]);
    };
    let csv_path = directory.path().join("float4-array.csv");
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

    connection
        .execute("CREATE TABLE float4_array_filewriter_target (value real[])")
        .await
        .unwrap();
    let sql_path = directory.path().join("float4-array.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "float4_array_filewriter_target",
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
            "SELECT pg_typeof(value)::text, encode(array_send(value), 'hex') \
             FROM float4_array_filewriter_target",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows, vec![vec![oracle.rows[0][0].clone(), oracle.rows[0][2].clone()]]);

    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("float4-array.xlsx"));
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
}

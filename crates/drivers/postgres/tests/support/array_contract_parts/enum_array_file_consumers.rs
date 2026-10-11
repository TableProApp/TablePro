#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_file_exports_preserve_labels() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute(
            "CREATE TYPE value_contract_file_enum AS ENUM \
             ('NULL', '', ' leading', 'trailing ', '東京', 'a,b', 'a\"b', '<tag>&', '=1+1', 'slash\\path', 'sibling')",
        )
        .await
        .unwrap();
    let expression = "ARRAY['NULL'::value_contract_file_enum, \
        ''::value_contract_file_enum, ' leading'::value_contract_file_enum, \
        'trailing '::value_contract_file_enum, '東京'::value_contract_file_enum, \
        'a,b'::value_contract_file_enum, 'a\"b'::value_contract_file_enum, \
        '<tag>&'::value_contract_file_enum, '=1+1'::value_contract_file_enum, \
        'slash\\path'::value_contract_file_enum, NULL]";
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, "value_contract_file_enum[]");
    assert!(matches!(result.rows[0][0], Value::Text(_)));

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, {expression}::text, \
                    array_to_json({expression})::text, encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("value_contract_file_enum[]".into()));
    let Value::Text(driver_text) = &result.rows[0][0] else {
        panic!("enum[] result must remain text: {:?}", result.rows[0][0]);
    };
    let Value::Text(native_json) = &oracle.rows[0][2] else {
        panic!("enum[] array_to_json oracle returned {:?}", oracle.rows[0][2]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(native_json).unwrap(),
        serde_json::json!(["NULL", "", " leading", "trailing ", "東京", "a,b", "a\"b", "<tag>&", "=1+1", "slash\\path", null])
    );
    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::value_contract_file_enum[])::text, \
                    encode(array_send($1::text::value_contract_file_enum[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], oracle.rows[0][2]);
    assert_eq!(rebound.rows[0][1], oracle.rows[0][3]);

    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    let json_path = directory.path().join("enum-array.json");
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

    let csv_path = directory.path().join("enum-array.csv");
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

    for (format, extension, escaped) in [
        (
            tablepro_core::export::ResultFormat::Xml,
            "xml",
            driver_text
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;")
                .replace('"', "&quot;")
                .replace('\'', "&apos;"),
        ),
        (
            tablepro_core::export::ResultFormat::Html,
            "html",
            driver_text
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;")
                .replace('"', "&quot;")
                .replace('\'', "&#39;"),
        ),
    ] {
        let path = directory.path().join(format!("enum-array.{extension}"));
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
        let markup = std::fs::read_to_string(path).unwrap();
        assert!(markup.contains(&escaped), "{extension}: {markup}");
        assert!(markup.contains("NULL"), "{extension}: {markup}");
    }

    let markdown_path = directory.path().join("enum-array.md");
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
    assert!(markdown.contains("&lt;tag&gt;&amp;"), "{markdown}");
    assert!(markdown.contains("&#92;"), "{markdown}");
    assert!(markdown.contains("NULL"), "{markdown}");

    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("enum-array.xlsx"));
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
    let xlsx_text = driver_text
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">"), "{sheet}");
    assert!(shared_strings.contains(&xlsx_text), "{shared_strings}");
    assert!(!sheet.contains("<f>"), "{sheet}");

    connection
        .execute("CREATE TABLE enum_array_filewriter_target (value value_contract_file_enum[])")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO enum_array_filewriter_target \
             VALUES (ARRAY['sibling'::value_contract_file_enum])",
        )
        .await
        .unwrap();
    let sibling = connection
        .query(
            "SELECT value::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') FROM enum_array_filewriter_target",
        )
        .await
        .unwrap();
    assert_eq!(sibling.rows.len(), 1);
    let sql_path = directory.path().join("enum-array.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: None,
                table: "enum_array_filewriter_target",
            }),
        },
        || false,
        |_| {},
    )
    .unwrap();
    let sql_file = std::fs::read_to_string(sql_path).unwrap();
    for (standard_conforming_strings, backslash_quote) in [
        ("on", "safe_encoding"),
        ("on", "off"),
        ("off", "off"),
        ("off", "on"),
    ] {
        let mut transaction = connection.begin().await.unwrap();
        transaction
            .execute(&format!(
                "SET LOCAL standard_conforming_strings = {standard_conforming_strings}"
            ))
            .await
            .unwrap();
        transaction
            .execute(&format!("SET LOCAL backslash_quote = {backslash_quote}"))
            .await
            .unwrap();
        transaction.execute(&sql_file).await.unwrap();
        let restored = transaction
            .query(
                "SELECT value::text, array_to_json(value)::text, \
                        encode(array_send(value), 'hex') FROM enum_array_filewriter_target",
            )
            .await
            .unwrap();
        assert_eq!(
            restored.rows.len(),
            2,
            "enum[] SQL replay with standard_conforming_strings={standard_conforming_strings}, backslash_quote={backslash_quote}"
        );
        assert!(restored.rows.contains(&oracle.rows[0][1..].to_vec()));
        assert!(restored.rows.contains(&sibling.rows[0]));
        transaction.rollback().await.unwrap();
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_multidimensional_lower_bounds_export_as_spreadsheet_text() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE SCHEMA value_contract_enum_array_workbook_shapes")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_array_workbook_shapes.label AS ENUM \
             ('NULL', '', ' leading', 'trailing ', '東京', 'a,b', 'a\"b', '<tag>&', '=1+1', 'slash\\path', 'sibling')",
        )
        .await
        .unwrap();

    let enum_type = "value_contract_enum_array_workbook_shapes.label[]";
    let expression = r#"'[0:1][-4:1]={{"NULL",""," leading","trailing ","東京","a,b"},{"a\"b","<tag>&","=1+1","slash\\path",NULL,"sibling"}}'::value_contract_enum_array_workbook_shapes.label[]"#;
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, enum_type);
    let Value::Text(array_text) = &result.rows[0][0] else {
        panic!("enum[] workbook value must remain text: {:?}", result.rows[0][0]);
    };
    let native = connection
        .query(&format!(
            "SELECT pg_typeof(value)::text, array_dims(value), array_ndims(value), \
                    array_to_json(value)::text, encode(array_send(value), 'hex') \
             FROM (SELECT {expression} AS value) AS source"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text(enum_type.into()));
    assert_eq!(native.rows[0][1], Value::Text("[0:1][-4:1]".into()));
    assert_eq!(native.rows[0][2], Value::Int(2));
    let Value::Text(native_json) = &native.rows[0][3] else {
        panic!("native enum[] JSON oracle is not text: {:?}", native.rows[0][3]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(native_json).unwrap(),
        serde_json::json!([
            ["NULL", "", " leading", "trailing ", "東京", "a,b"],
            ["a\"b", "<tag>&", "=1+1", "slash\\path", null, "sibling"]
        ])
    );

    let rebound = connection
        .query_params(
            &format!(
                "SELECT pg_typeof($1::text::{enum_type})::text, \
                        array_dims($1::text::{enum_type}), array_to_json($1::text::{enum_type})::text, \
                        encode(array_send($1::text::{enum_type}), 'hex')"
            ),
            &[Value::Text(array_text.clone())],
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][0]);
    assert_eq!(rebound.rows[0][1], native.rows[0][1]);
    assert_eq!(rebound.rows[0][2], native.rows[0][3]);
    assert_eq!(rebound.rows[0][3], native.rows[0][4]);

    let directory = tempfile::tempdir().unwrap();
    let xlsx_path = std::env::var_os("BOOKIEE_XLSX_REIMPORT_ARTIFACT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.path().join("enum-array-shapes.xlsx"));
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
    let mut workbook = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut sheet = String::new();
    std::io::Read::read_to_string(&mut workbook.by_name("xl/worksheets/sheet1.xml").unwrap(), &mut sheet)
        .unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut workbook.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    let xml_text = array_text
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    assert!(sheet.contains("<c r=\"A2\" t=\"s\">") && !sheet.contains("<f>"), "{sheet}");
    assert!(shared_strings.contains(&xml_text), "{shared_strings}");

    connection
        .execute(&format!(
            "CREATE TABLE value_contract_enum_array_workbook_shapes.target (value {enum_type})"
        ))
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_enum_array_workbook_shapes.target \
             VALUES (ARRAY['sibling'::value_contract_enum_array_workbook_shapes.label])",
        )
        .await
        .unwrap();
    let sibling_wire = connection
        .query(
            "SELECT encode(array_send(value), 'hex') \
             FROM value_contract_enum_array_workbook_shapes.target",
        )
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let sql_path = directory.path().join("enum-array-shapes.sql");
    tablepro_core::export::write_result_file(
        &sql_path,
        &result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &tablepro_core::export::CsvOptions::default(),
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: Some("value_contract_enum_array_workbook_shapes"),
                table: "target",
            }),
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(&std::fs::read_to_string(sql_path).unwrap())
        .await
        .unwrap();
    let restored = transaction
        .query(
            "SELECT pg_typeof(value)::text, array_dims(value), array_to_json(value)::text, \
                    encode(array_send(value), 'hex') \
             FROM value_contract_enum_array_workbook_shapes.target ORDER BY value::text",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows.len(), 2);
    assert!(restored.rows.iter().all(|row| row[0] == Value::Text(enum_type.into())));
    assert!(restored.rows.iter().any(|row| row[1] == native.rows[0][1] && row[3] == native.rows[0][4]));
    assert!(restored.rows.iter().any(|row| row[1] == Value::Text("[1:1]".into()) && row[3] == sibling_wire));
    transaction.rollback().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_csv_import_preserves_labels_and_siblings() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE SCHEMA value_contract_enum_array_import")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_array_import.label AS ENUM \
             ('NULL', '', '東京', 'a,b', 'a\"b', '<tag>&', 'sibling')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_enum_array_import.target \
             (id integer PRIMARY KEY, labels value_contract_enum_array_import.label[])",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_enum_array_import.target VALUES \
             (1, ARRAY['sibling'::value_contract_enum_array_import.label])",
        )
        .await
        .unwrap();
    let sibling_wire = connection
        .query(
            "SELECT encode(array_send(labels), 'hex') \
             FROM value_contract_enum_array_import.target WHERE id = 1",
        )
        .await
        .unwrap()
        .rows[0][0]
        .clone();

    let source = connection
        .query(
            "SELECT 3 AS id, ARRAY[\
                'NULL'::value_contract_enum_array_import.label, \
                ''::value_contract_enum_array_import.label, \
                '東京'::value_contract_enum_array_import.label, \
                'a,b'::value_contract_enum_array_import.label, \
                'a\"b'::value_contract_enum_array_import.label, \
                '<tag>&'::value_contract_enum_array_import.label, \
                NULL::value_contract_enum_array_import.label\
            ] AS labels",
        )
        .await
        .unwrap();
    let native = connection
        .query(
            "SELECT pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM (SELECT ARRAY[\
                'NULL'::value_contract_enum_array_import.label, \
                ''::value_contract_enum_array_import.label, \
                '東京'::value_contract_enum_array_import.label, \
                'a,b'::value_contract_enum_array_import.label, \
                'a\"b'::value_contract_enum_array_import.label, \
                '<tag>&'::value_contract_enum_array_import.label, \
                NULL::value_contract_enum_array_import.label\
             ] AS labels) AS source",
        )
        .await
        .unwrap();
    assert_eq!(
        native.rows[0][0],
        Value::Text("value_contract_enum_array_import.label[]".into())
    );
    let csv_options = tablepro_core::export::CsvOptions::default();
    let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &csv_options);
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let columns = connection
        .fetch_columns(Some("value_contract_enum_array_import"), "target")
        .await
        .unwrap();
    assert_eq!(columns[1].data_type, "value_contract_enum_array_import.label[]");
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "value_contract_enum_array_import".into(),
            name: "label".into(),
        })
    );
    let mapping = [Some(0), Some(1)];
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("value_contract_enum_array_import"),
            table: "target",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert_eq!(
        plan.statement,
        "INSERT INTO \"value_contract_enum_array_import\".\"target\" \
         (\"id\", \"labels\") VALUES ($1, $2::text::\"value_contract_enum_array_import\".\"label\"[])"
    );
    connection.execute_params(&plan.statement, &plan.rows[0]).await.unwrap();

    let restored = connection
        .query(
            "SELECT id, pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM value_contract_enum_array_import.target ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows.len(), 2);
    assert_eq!(
        restored.rows[0],
        vec![
            Value::Int(1),
            Value::Text("value_contract_enum_array_import.label[]".into()),
            Value::Text("{sibling}".into()),
            Value::Text("[\"sibling\"]".into()),
            sibling_wire,
        ]
    );
    assert_eq!(
        restored.rows[1],
        vec![
            Value::Int(3),
            native.rows[0][0].clone(),
            native.rows[0][1].clone(),
            native.rows[0][2].clone(),
            native.rows[0][3].clone(),
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_csv_import_preserves_nulls_and_shape() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE SCHEMA value_contract_enum_array_shape")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE value_contract_enum_array_shape.label AS ENUM ('NULL', '', '東京', 'sibling')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_enum_array_shape.target \
             (id integer PRIMARY KEY, labels value_contract_enum_array_shape.label[])",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_enum_array_shape.target VALUES \
             (99, ARRAY['sibling'::value_contract_enum_array_shape.label])",
        )
        .await
        .unwrap();
    let sibling_wire = connection
        .query(
            "SELECT encode(array_send(labels), 'hex') \
             FROM value_contract_enum_array_shape.target WHERE id = 99",
        )
        .await
        .unwrap()
        .rows[0][0]
        .clone();

    let source = connection
        .query(
            "SELECT 1 AS id, NULL::value_contract_enum_array_shape.label[] AS labels \
             UNION ALL SELECT 2, ARRAY[]::value_contract_enum_array_shape.label[] \
             UNION ALL SELECT 3, ARRAY[NULL::value_contract_enum_array_shape.label] \
             UNION ALL SELECT 4, '[0:3]={\"NULL\",NULL,\"\",東京}'::value_contract_enum_array_shape.label[] \
             UNION ALL SELECT 5, ARRAY[\
                 ['NULL'::value_contract_enum_array_shape.label, NULL::value_contract_enum_array_shape.label], \
                 [''::value_contract_enum_array_shape.label, '東京'::value_contract_enum_array_shape.label]\
             ]::value_contract_enum_array_shape.label[] \
             ORDER BY id",
        )
        .await
        .unwrap();
    let native = connection
        .query(
            "SELECT id, pg_typeof(labels)::text, array_dims(labels), \
                    array_to_json(labels)::text, encode(array_send(labels), 'hex') \
             FROM (\
                 SELECT 1 AS id, NULL::value_contract_enum_array_shape.label[] AS labels \
                 UNION ALL SELECT 2, ARRAY[]::value_contract_enum_array_shape.label[] \
                 UNION ALL SELECT 3, ARRAY[NULL::value_contract_enum_array_shape.label] \
                 UNION ALL SELECT 4, '[0:3]={\"NULL\",NULL,\"\",東京}'::value_contract_enum_array_shape.label[] \
                 UNION ALL SELECT 5, ARRAY[\
                     ['NULL'::value_contract_enum_array_shape.label, NULL::value_contract_enum_array_shape.label], \
                     [''::value_contract_enum_array_shape.label, '東京'::value_contract_enum_array_shape.label]\
                 ]::value_contract_enum_array_shape.label[]\
             ) AS source ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(source.rows.len(), 5);
    assert_eq!(native.rows.len(), 5);
    assert_eq!(native.rows[0][2], Value::Null);
    assert_eq!(native.rows[1][2], Value::Null);
    assert_eq!(native.rows[0][3], Value::Null);
    assert_eq!(native.rows[1][3], Value::Text("[]".into()));
    assert_ne!(native.rows[0][4], native.rows[1][4]);
    assert_eq!(native.rows[2][3], Value::Text("[null]".into()));
    assert_eq!(native.rows[3][2], Value::Text("[0:3]".into()));
    assert_eq!(native.rows[4][2], Value::Text("[1:2][1:2]".into()));

    let csv_options = tablepro_core::export::CsvOptions::default();
    let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &csv_options);
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let columns = connection
        .fetch_columns(Some("value_contract_enum_array_shape"), "target")
        .await
        .unwrap();
    let mapping = [Some(0), Some(1)];
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("value_contract_enum_array_shape"),
            table: "target",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert_eq!(plan.rows.len(), 5);
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }

    let restored = connection
        .query(
            "SELECT id, pg_typeof(labels)::text, array_dims(labels), \
                    array_to_json(labels)::text, encode(array_send(labels), 'hex') \
             FROM value_contract_enum_array_shape.target ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows.len(), 6);
    assert_eq!(&restored.rows[..5], native.rows.as_slice());
    assert_eq!(restored.rows[5][0], Value::Int(99));
    assert_eq!(restored.rows[5][3], Value::Text("[\"sibling\"]".into()));
    assert_eq!(restored.rows[5][4], sibling_wire);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_csv_import_uses_target_type_under_shadowed_search_path() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA enum_array_shadow_a").await.unwrap();
    connection.execute("CREATE SCHEMA enum_array_shadow_b").await.unwrap();
    connection
        .execute("CREATE TYPE enum_array_shadow_a.label AS ENUM ('ready')")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE enum_array_shadow_b.label AS ENUM ('ready', 'paused')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE enum_array_shadow_b.target \
             (id integer PRIMARY KEY, labels enum_array_shadow_b.label[])",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO enum_array_shadow_b.target VALUES \
             (2, ARRAY['ready'::enum_array_shadow_b.label])",
        )
        .await
        .unwrap();

    let source = connection
        .query("SELECT 1 AS id, ARRAY['paused'::enum_array_shadow_b.label] AS labels")
        .await
        .unwrap();
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let columns = connection
        .fetch_columns(Some("enum_array_shadow_b"), "target")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "enum_array_shadow_b".into(),
            name: "label".into(),
        })
    );
    let mapping = [Some(0), Some(1)];
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("enum_array_shadow_b"),
            table: "target",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert!(plan.statement.contains("$2::text::\"enum_array_shadow_b\".\"label\"[]"));

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO enum_array_shadow_a, public")
        .await
        .unwrap();
    assert_eq!(
        transaction.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text("enum_array_shadow_a".into())]]
    );
    transaction
        .execute_params(&plan.statement, &plan.rows[0])
        .await
        .unwrap();
    let target = transaction
        .query(
            "SELECT id, pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM enum_array_shadow_b.target ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(target.rows.len(), 2);
    assert_eq!(target.rows[0][0], Value::Int(1));
    assert_eq!(target.rows[0][1], Value::Text("enum_array_shadow_b.label[]".into()));
    assert_eq!(target.rows[0][2], Value::Text("{paused}".into()));
    assert_eq!(target.rows[0][3], Value::Text("[\"paused\"]".into()));
    assert_eq!(target.rows[1][0], Value::Int(2));
    assert_eq!(target.rows[1][2], Value::Text("{ready}".into()));
    transaction.commit().await.unwrap();
}

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_range_array_refusal_preserves_target_and_sibling_rows() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection
        .execute("CREATE SCHEMA custom_range_array_contract")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE custom_range_array_contract.int_range AS RANGE (subtype = integer)")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE custom_range_array_contract.rows \
             (id integer PRIMARY KEY, value custom_range_array_contract.int_range[], sibling text NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO custom_range_array_contract.rows VALUES \
             (1, ARRAY['[1,5)'::custom_range_array_contract.int_range, \
                      '(10,20]'::custom_range_array_contract.int_range, \
                      'empty'::custom_range_array_contract.int_range, NULL], 'target'), \
             (2, ARRAY['[30,40)'::custom_range_array_contract.int_range], 'sibling'), \
             (3, ARRAY[]::custom_range_array_contract.int_range[], 'empty array'), \
             (4, NULL, 'SQL NULL array')",
        )
        .await
        .unwrap();

    let source = connection
        .query(
            "SELECT value, pg_typeof(value)::text, value::text, \
             array_to_json(value)::text, encode(array_send(value), 'hex') \
             FROM custom_range_array_contract.rows WHERE id = 1",
        )
        .await
        .unwrap();
    let refusal = source.rows[0][0].clone();
    assert!(
        matches!(&refusal, Value::Undecodable(name) if name.eq_ignore_ascii_case("custom_range_array_contract.int_range[]")),
        "custom range arrays must be visibly undecodable: {refusal:?}"
    );
    assert_eq!(
        source.rows[0][1],
        Value::Text("custom_range_array_contract.int_range[]".into())
    );
    assert_eq!(
        source.rows[0][3],
        Value::Text(r#"["[1,5)","(10,20]","empty",null]"#.into())
    );
    let marker = format!(
        "<undecodable {}>",
        match &refusal {
            Value::Undecodable(type_name) => type_name.as_str(),
            _ => "",
        }
    );
    let json_export = tablepro_core::export::render_json(&source.columns, &source.rows);
    assert!(
        json_export.contains(&marker),
        "JSON export must expose the undecodable type marker: {json_export}"
    );
    assert!(
        tablepro_core::export::render_csv(
            &source.columns,
            &source.rows,
            &tablepro_core::export::CsvOptions::default(),
        )
        .contains(&marker),
        "CSV export must expose the undecodable type marker"
    );
    let export_result = tablepro_core::QueryResult {
        columns: vec![source.columns[0].clone()],
        rows: vec![vec![refusal.clone()]],
        truncated: false,
    };
    let directory = tempfile::tempdir().unwrap();
    let csv_options = tablepro_core::export::CsvOptions::default();
    for (format, expected_marker) in [
        (tablepro_core::export::ResultFormat::Json, marker.clone()),
        (tablepro_core::export::ResultFormat::Csv, marker.clone()),
        (
            tablepro_core::export::ResultFormat::Markdown,
            marker
                .replace('<', "&lt;")
                .replace('>', "&gt;")
                .replace('_', "&#95;")
                .replace('[', "&#91;")
                .replace(']', "&#93;"),
        ),
        (
            tablepro_core::export::ResultFormat::Html,
            marker.replace('<', "&lt;").replace('>', "&gt;"),
        ),
        (
            tablepro_core::export::ResultFormat::Xml,
            marker.replace('<', "&lt;").replace('>', "&gt;"),
        ),
    ] {
        let path = directory.path().join(format!("{format:?}"));
        tablepro_core::export::write_result_file(
            &path,
            &export_result,
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
        assert!(
            output.contains(&expected_marker),
            "{format:?} export must expose the undecodable type marker: {output}"
        );
    }

    let xlsx_path = directory.path().join("range-array.xlsx");
    tablepro_core::export::write_result_file(
        &xlsx_path,
        &export_result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Xlsx,
            csv: &csv_options,
            sql: None,
        },
        || false,
        |_| {},
    )
    .unwrap();
    let mut workbook = zip::ZipArchive::new(std::fs::File::open(xlsx_path).unwrap()).unwrap();
    let mut shared_strings = String::new();
    std::io::Read::read_to_string(
        &mut workbook.by_name("xl/sharedStrings.xml").unwrap(),
        &mut shared_strings,
    )
    .unwrap();
    assert!(
        shared_strings.contains(&marker.replace('<', "&lt;").replace('>', "&gt;")),
        "XLSX export must expose the undecodable type marker: {shared_strings}"
    );

    let sql_path = directory.path().join("range-array.sql");
    std::fs::write(&sql_path, b"keep existing export").unwrap();
    let error = tablepro_core::export::write_result_file(
        &sql_path,
        &export_result,
        &tablepro_core::export::ResultExport {
            format: tablepro_core::export::ResultFormat::Sql,
            csv: &csv_options,
            sql: Some(tablepro_core::export::SqlTarget {
                driver_id: "postgres",
                schema: Some("custom_range_array_contract"),
                table: "rows",
            }),
        },
        || false,
        |_| {},
    )
    .unwrap_err();
    assert!(
        error.to_string().contains("cannot be represented in a SQL statement"),
        "{error}"
    );
    assert_eq!(std::fs::read(sql_path).unwrap(), b"keep existing export");

    let snapshot_sql = "SELECT id, value::text, array_to_json(value)::text, \
                        encode(array_send(value), 'hex'), sibling \
                        FROM custom_range_array_contract.rows ORDER BY id";
    let before = connection.query(snapshot_sql).await.unwrap();
    assert_eq!(before.rows.len(), 4);
    assert_eq!(before.rows[0][2], source.rows[0][3]);
    assert_eq!(before.rows[1][4], Value::Text("sibling".into()));
    let empty_array = connection
        .query(
            "SELECT value, value IS NULL, cardinality(value) \
             FROM custom_range_array_contract.rows WHERE id = 3",
        )
        .await
        .unwrap();
    assert!(matches!(&empty_array.rows[0][0], Value::Undecodable(name) if name.ends_with("[]")));
    assert_eq!(empty_array.rows[0][1], Value::Bool(false));
    assert_eq!(empty_array.rows[0][2], Value::Int(0));
    let null_array = connection
        .query(
            "SELECT value, value IS NULL, cardinality(value) \
             FROM custom_range_array_contract.rows WHERE id = 4",
        )
        .await
        .unwrap();
    assert_eq!(null_array.rows[0][0], Value::Null);
    assert_eq!(null_array.rows[0][1], Value::Bool(true));
    assert_eq!(null_array.rows[0][2], Value::Null);
    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &refusal).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(&refusal))
            .await
            .is_err()
    );
    assert!(
        connection
            .execute_params(
                "UPDATE custom_range_array_contract.rows SET value = $1 WHERE id = 1",
                &[refusal],
            )
            .await
            .is_err()
    );

    let after = connection.query(snapshot_sql).await.unwrap();
    assert_eq!(after.rows, before.rows, "refused binding changed stored values");
    assert_eq!(after.rows[0][1], source.rows[0][2]);
    assert_eq!(after.rows[0][2], source.rows[0][3]);
    assert_eq!(after.rows[0][3], source.rows[0][4]);
    assert_eq!(after.rows[0][4], Value::Text("target".into()));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_range_scalar_refusal_preserves_target_and_sibling_rows() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection
        .execute("CREATE SCHEMA custom_range_scalar_contract")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE custom_range_scalar_contract.int_range AS RANGE (subtype = integer)")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE custom_range_scalar_contract.rows \
             (id integer PRIMARY KEY, value custom_range_scalar_contract.int_range, sibling text NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO custom_range_scalar_contract.rows VALUES \
             (1, '[1,5)'::custom_range_scalar_contract.int_range, 'target'), \
             (2, '(10,20]'::custom_range_scalar_contract.int_range, 'sibling'), \
             (3, 'empty'::custom_range_scalar_contract.int_range, 'empty range'), \
             (4, NULL, 'SQL NULL range')",
        )
        .await
        .unwrap();

    let source = connection
        .query(
            "SELECT value, pg_typeof(value)::text, value::text, to_json(value)::text, \
             encode(range_send(value), 'hex') \
             FROM custom_range_scalar_contract.rows WHERE id = 1",
        )
        .await
        .unwrap();
    let refusal = source.rows[0][0].clone();
    assert!(
        matches!(&refusal, Value::Undecodable(name) if name.eq_ignore_ascii_case("custom_range_scalar_contract.int_range")),
        "custom range scalars must be visibly undecodable: {refusal:?}"
    );
    assert_eq!(
        source.rows[0][1],
        Value::Text("custom_range_scalar_contract.int_range".into())
    );
    assert_eq!(source.rows[0][2], Value::Text("[1,5)".into()));
    assert_eq!(source.rows[0][3], Value::Text(r#""[1,5)""#.into()));
    assert_eq!(
        source.rows[0][4],
        Value::Text("0200000004000000010000000400000005".into())
    );

    let empty = connection
        .query(
            "SELECT value, value IS NULL, isempty(value) \
             FROM custom_range_scalar_contract.rows WHERE id = 3",
        )
        .await
        .unwrap();
    assert!(
        matches!(&empty.rows[0][0], Value::Undecodable(name) if name.eq_ignore_ascii_case("custom_range_scalar_contract.int_range")),
        "empty custom range must remain visibly undecodable: {:?}",
        empty.rows[0][0]
    );
    assert_eq!(empty.rows[0][1], Value::Bool(false));
    assert_eq!(empty.rows[0][2], Value::Bool(true));
    let null = connection
        .query(
            "SELECT value, value IS NULL, isempty(value) \
             FROM custom_range_scalar_contract.rows WHERE id = 4",
        )
        .await
        .unwrap();
    assert_eq!(null.rows[0][0], Value::Null);
    assert_eq!(null.rows[0][1], Value::Bool(true));
    assert_eq!(null.rows[0][2], Value::Null);

    let snapshot_sql = "SELECT id, value::text, to_json(value)::text, \
                        encode(range_send(value), 'hex'), sibling \
                        FROM custom_range_scalar_contract.rows ORDER BY id";
    let before = connection.query(snapshot_sql).await.unwrap();
    assert_eq!(before.rows.len(), 4);
    assert_eq!(before.rows[0][1], source.rows[0][2]);
    assert_eq!(before.rows[0][2], source.rows[0][3]);
    assert_eq!(before.rows[0][3], source.rows[0][4]);
    assert_eq!(before.rows[1][4], Value::Text("sibling".into()));
    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &refusal).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(&refusal))
            .await
            .is_err()
    );
    assert!(
        connection
            .execute_params(
                "UPDATE custom_range_scalar_contract.rows SET value = $1 WHERE id = 1",
                &[refusal],
            )
            .await
            .is_err()
    );

    let after = connection.query(snapshot_sql).await.unwrap();
    assert_eq!(after.rows, before.rows, "refused binding changed stored values");
    assert_eq!(after.rows[0][1], source.rows[0][2]);
    assert_eq!(after.rows[0][2], source.rows[0][3]);
    assert_eq!(after.rows[0][3], source.rows[0][4]);
    assert_eq!(after.rows[0][4], Value::Text("target".into()));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_range_array_refusal_preserves_target_and_sibling_rows() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection.execute("SET TIME ZONE 'UTC'").await.unwrap();
    connection.execute("SET DateStyle TO ISO, YMD").await.unwrap();
    connection
        .execute(
            "CREATE TABLE range_array_refusal (
                id integer PRIMARY KEY,
                int4_values int4range[], int8_values int8range[], num_values numrange[],
                date_values daterange[], ts_values tsrange[], tstz_values tstzrange[],
                sibling text NOT NULL
            )",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO range_array_refusal VALUES
             (1,
                ARRAY[int4range(1, 4), int4range(8, NULL, '(]'), 'empty'::int4range, NULL],
                ARRAY[int8range(1, 4000000000), int8range(9, NULL), 'empty'::int8range, NULL],
                ARRAY[numrange(1.25, 4.5), numrange(9, NULL), 'empty'::numrange, NULL],
                ARRAY[daterange('2024-01-01', '2024-01-03'), daterange('2024-04-01', NULL, '(]'), 'empty'::daterange, NULL],
                ARRAY[tsrange('2024-01-01', '2024-01-02'), tsrange('2024-03-01', NULL), 'empty'::tsrange, NULL],
                ARRAY[tstzrange('2024-01-01 00:00:00+00', '2024-01-02 00:00:00+00'), tstzrange('2024-03-01 00:00:00+00', NULL), 'empty'::tstzrange, NULL],
                'target'),
             (2,
                ARRAY[int4range(20, 25)], ARRAY[int8range(20, 25)],
                ARRAY[numrange(20, 25)], ARRAY[daterange('2024-05-01', '2024-05-03')],
                ARRAY[tsrange('2024-05-01', '2024-05-03')],
                ARRAY[tstzrange('2024-05-01 00:00:00+00', '2024-05-03 00:00:00+00')], 'sibling')",
        )
        .await
        .unwrap();

    let cases = [
        ("int4_values", "int4range[]", r#"["[1,4)","[9,)","empty",null]"#),
        (
            "int8_values",
            "int8range[]",
            r#"["[1,4000000000)","[9,)","empty",null]"#,
        ),
        ("num_values", "numrange[]", r#"["[1.25,4.5)","[9,)","empty",null]"#),
        (
            "date_values",
            "daterange[]",
            r#"["[2024-01-01,2024-01-03)","[2024-04-02,)","empty",null]"#,
        ),
        (
            "ts_values",
            "tsrange[]",
            r#"["[\"2024-01-01 00:00:00\",\"2024-01-02 00:00:00\")","[\"2024-03-01 00:00:00\",)","empty",null]"#,
        ),
        (
            "tstz_values",
            "tstzrange[]",
            r#"["[\"2024-01-01 00:00:00+00\",\"2024-01-02 00:00:00+00\")","[\"2024-03-01 00:00:00+00\",)","empty",null]"#,
        ),
    ];

    for (column, range_type, expected_json) in cases {
        let source = connection
            .query(&format!(
                "SELECT {column}, pg_typeof({column})::text, array_to_json({column})::text \
                 FROM range_array_refusal WHERE id = 1"
            ))
            .await
            .unwrap();
        let refusal = source.rows[0][0].clone();
        assert!(
            matches!(&refusal, Value::Undecodable(name) if name.eq_ignore_ascii_case(range_type)),
            "{range_type} must remain visibly unsupported: {refusal:?}"
        );
        assert_eq!(source.rows[0][1], Value::Text(range_type.into()));
        assert_eq!(source.rows[0][2], Value::Text(expected_json.into()), "{range_type}");

        let snapshot_sql = format!(
            "SELECT id, {column}::text, array_to_json({column})::text, \
             encode(array_send({column}), 'hex'), sibling \
             FROM range_array_refusal ORDER BY id"
        );
        let before = connection.query(&snapshot_sql).await.unwrap();
        assert_eq!(before.rows.len(), 2, "{range_type}");
        assert_eq!(before.rows[0][2], source.rows[0][2], "{range_type}");
        assert_eq!(before.rows[0][4], Value::Text("target".into()));
        assert_eq!(before.rows[1][4], Value::Text("sibling".into()));

        assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &refusal).is_err());
        assert!(
            connection
                .query_params("SELECT $1", std::slice::from_ref(&refusal))
                .await
                .is_err(),
            "{range_type} parameter must be refused"
        );
        assert!(
            connection
                .execute_params(
                    &format!("UPDATE range_array_refusal SET {column} = $1 WHERE id = 1"),
                    std::slice::from_ref(&refusal),
                )
                .await
                .is_err(),
            "{range_type} update must be refused"
        );

        let after = connection.query(&snapshot_sql).await.unwrap();
        assert_eq!(after.rows, before.rows, "{range_type} refusal changed stored values");
    }
}

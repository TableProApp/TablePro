use super::clickhouse::{connect, start_clickhouse};
use tablepro_core::Value;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_clickhouse_enum8_and_enum16_preserve_labels_null_and_csv() {
    let (_container, options) = start_clickhouse().await;
    let connection = connect(options).await;
    connection
        .execute(
            "CREATE TABLE enum_values (
                id UInt8,
                narrow Enum8('NULL' = 1, 'O''Brien' = 2, '東京' = -1, 'minimum' = -128, 'maximum' = 127, 'zero' = 0, '' = 3),
                wide Enum16('low' = -32768, 'high' = 32767, 'zero' = 0, '' = 3),
                optional Nullable(Enum8('NULL' = 1, 'present' = 2, '' = 3))
            ) ENGINE = MergeTree ORDER BY id",
        )
        .await
        .expect("create native enum table");

    let expected = vec![
        vec![
            Value::Int(1),
            Value::Text("NULL".into()),
            Value::Text("low".into()),
            Value::Null,
        ],
        vec![
            Value::Int(2),
            Value::Text("O'Brien".into()),
            Value::Text("high".into()),
            Value::Text("NULL".into()),
        ],
        vec![
            Value::Int(3),
            Value::Text("東京".into()),
            Value::Text("low".into()),
            Value::Text("present".into()),
        ],
        vec![
            Value::Int(4),
            Value::Text("minimum".into()),
            Value::Text("high".into()),
            Value::Null,
        ],
        vec![
            Value::Int(5),
            Value::Text("maximum".into()),
            Value::Text("low".into()),
            Value::Text("present".into()),
        ],
        vec![
            Value::Int(6),
            Value::Text("zero".into()),
            Value::Text("high".into()),
            Value::Null,
        ],
        vec![
            Value::Int(7),
            Value::Text("NULL".into()),
            Value::Text("zero".into()),
            Value::Null,
        ],
        vec![
            Value::Int(8),
            Value::Text(String::new()),
            Value::Text(String::new()),
            Value::Text(String::new()),
        ],
    ];
    for row in &expected {
        connection
            .execute_params("INSERT INTO enum_values VALUES (?, ?, ?, ?)", row)
            .await
            .expect("insert enum labels through parameters");
    }

    let invalid_label = [
        Value::Int(7),
        Value::Text("undeclared".into()),
        Value::Text("low".into()),
        Value::Null,
    ];
    assert!(
        connection
            .execute_params("INSERT INTO enum_values VALUES (?, ?, ?, ?)", &invalid_label)
            .await
            .is_err(),
        "an undeclared Enum8 label must be refused"
    );
    let after_refusal = connection
        .query("SELECT id, narrow, wide, optional FROM enum_values ORDER BY id")
        .await
        .unwrap();
    assert_eq!(after_refusal.rows, expected, "refused enum write leaves rows unchanged");

    let invalid_wide_label = [
        Value::Int(8),
        Value::Text("NULL".into()),
        Value::Text("undeclared".into()),
        Value::Null,
    ];
    assert!(
        connection
            .execute_params("INSERT INTO enum_values VALUES (?, ?, ?, ?)", &invalid_wide_label)
            .await
            .is_err(),
        "an undeclared Enum16 label must be refused"
    );
    let after_wide_refusal = connection
        .query("SELECT id, narrow, wide, optional FROM enum_values ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        after_wide_refusal.rows, expected,
        "refused Enum16 write leaves rows unchanged"
    );

    let columns = connection.fetch_columns(None, "enum_values").await.unwrap();
    assert!(columns[1].data_type.starts_with("Enum8("));
    assert!(columns[2].data_type.starts_with("Enum16("));
    assert!(columns[3].data_type.starts_with("Nullable(Enum8("));
    assert!(columns[3].nullable);

    let result = connection
        .query("SELECT id, narrow, wide, optional FROM enum_values ORDER BY id")
        .await
        .unwrap();
    assert_eq!(result.rows, expected);
    assert!(result.columns[1].data_type.starts_with("Enum8("));
    assert!(result.columns[2].data_type.starts_with("Enum16("));
    assert!(result.columns[3].data_type.starts_with("Nullable(Enum8("));

    let native = connection
        .query(
            "SELECT toTypeName(narrow), toTypeName(wide), toTypeName(optional), \
             CAST(narrow AS String), CAST(wide AS String), \
             CAST(optional AS Nullable(String)), isNull(optional), \
             CAST(narrow AS Int8), CAST(wide AS Int16) \
             FROM enum_values ORDER BY id",
        )
        .await
        .unwrap();
    for (index, row) in native.rows.iter().enumerate() {
        assert!(matches!(&row[0], Value::Text(name) if name.starts_with("Enum8(")));
        assert!(matches!(&row[1], Value::Text(name) if name.starts_with("Enum16(")));
        assert!(matches!(&row[2], Value::Text(name) if name.starts_with("Nullable(Enum8(")));
        for (native_index, value_index) in [(3, 1), (4, 2), (5, 3)] {
            assert_eq!(
                row[native_index], expected[index][value_index],
                "native cast oracle for row {index}"
            );
        }
        assert_eq!(
            row[6],
            Value::Int(if expected[index][3] == Value::Null { 1 } else { 0 })
        );
        assert_eq!(row[7], Value::Int([1, 2, -1, -128, 127, 0, 1, 3][index]));
        assert_eq!(
            row[8],
            Value::Int([-32768, 32767, -32768, 32767, -32768, 32767, 0, 3][index])
        );
    }

    let null_marker = tablepro_core::export::unique_csv_null_marker(&result.rows);
    let csv = tablepro_core::export::render_csv(
        &result.columns,
        &result.rows,
        &tablepro_core::export::CsvOptions {
            null_to_empty: false,
            null_marker: Some(null_marker.clone()),
            ..Default::default()
        },
    );
    let import_options = tablepro_core::import::CsvImportOptions {
        null_marker,
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let mapping: Vec<_> = (0..result.columns.len()).map(Some).collect();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "clickhouse",
            schema: None,
            table: "enum_csv_copy",
            columns: &result.columns,
            mapping: &mapping,
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert_eq!(plan.rows, expected, "CSV import plan keeps enum labels and NULL");
    connection
        .execute(
            "CREATE TABLE enum_csv_copy (
                id UInt8,
                narrow Enum8('NULL' = 1, 'O''Brien' = 2, '東京' = -1, 'minimum' = -128, 'maximum' = 127, 'zero' = 0, '' = 3),
                wide Enum16('low' = -32768, 'high' = 32767, 'zero' = 0, '' = 3),
                optional Nullable(Enum8('NULL' = 1, 'present' = 2, '' = 3))
            ) ENGINE = MergeTree ORDER BY id",
        )
        .await
        .unwrap();
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
    let imported = connection
        .query("SELECT id, narrow, wide, optional FROM enum_csv_copy ORDER BY id")
        .await
        .unwrap();
    assert_eq!(imported.rows, expected, "CSV import preserves native enum values");

    connection
        .execute(
            "CREATE TABLE enum_sql_copy (
                id UInt8,
                narrow Enum8('NULL' = 1, 'O''Brien' = 2, '東京' = -1, 'minimum' = -128, 'maximum' = 127, 'zero' = 0, '' = 3),
                wide Enum16('low' = -32768, 'high' = 32767, 'zero' = 0, '' = 3),
                optional Nullable(Enum8('NULL' = 1, 'present' = 2, '' = 3))
            ) ENGINE = MergeTree ORDER BY id",
        )
        .await
        .unwrap();
    for row in &result.rows {
        let copy_sql =
            tablepro_core::sql_literal::build_insert_literal("clickhouse", None, "enum_sql_copy", &result.columns, row)
                .unwrap();
        connection.execute(&copy_sql).await.unwrap();
    }
    let copied = connection
        .query("SELECT id, narrow, wide, optional FROM enum_sql_copy ORDER BY id")
        .await
        .unwrap();
    assert_eq!(copied.rows, expected, "Copy as SQL preserves enum bounds");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_clickhouse_nullable_enum16_preserves_null_and_labels_across_consumers() {
    let (_container, options) = start_clickhouse().await;
    let connection = connect(options).await;
    let create = "CREATE TABLE nullable_enum16 (
        id UInt8,
        state Nullable(Enum16('NULL' = 1, 'O''Brien' = 2, 'zero' = 0))
    ) ENGINE = MergeTree ORDER BY id";
    connection.execute(create).await.expect("create nullable Enum16 table");

    let expected = vec![
        vec![Value::Int(1), Value::Null],
        vec![Value::Int(2), Value::Text("NULL".into())],
        vec![Value::Int(3), Value::Text("O'Brien".into())],
        vec![Value::Int(4), Value::Text("zero".into())],
    ];
    for row in &expected {
        connection
            .execute_params("INSERT INTO nullable_enum16 VALUES (?, ?)", row)
            .await
            .expect("bind nullable Enum16 value");
    }

    let result = connection
        .query("SELECT id, state FROM nullable_enum16 ORDER BY id")
        .await
        .unwrap();
    assert_eq!(result.rows, expected);
    assert!(result.columns[1].data_type.starts_with("Nullable(Enum16("));
    assert!(result.columns[1].nullable);

    let native = connection
        .query(
            "SELECT toTypeName(state), CAST(state AS Nullable(String)), \
             CAST(state AS Nullable(Int16)), isNull(state) \
             FROM nullable_enum16 ORDER BY id",
        )
        .await
        .unwrap();
    for (index, row) in native.rows.iter().enumerate() {
        assert!(matches!(&row[0], Value::Text(name) if name.starts_with("Nullable(Enum16(")));
        assert_eq!(row[1], expected[index][1]);
        assert_eq!(
            row[2],
            [Value::Null, Value::Int(1), Value::Int(2), Value::Int(0)][index]
        );
        assert_eq!(row[3], Value::Int(i64::from(index == 0)));
    }

    let null_marker = tablepro_core::export::unique_csv_null_marker(&result.rows);
    let csv = tablepro_core::export::render_csv(
        &result.columns,
        &result.rows,
        &tablepro_core::export::CsvOptions {
            null_to_empty: false,
            null_marker: Some(null_marker.clone()),
            ..Default::default()
        },
    );
    let import_options = tablepro_core::import::CsvImportOptions {
        null_marker,
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let mapping = vec![Some(0), Some(1)];
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "clickhouse",
            schema: None,
            table: "nullable_enum16_csv",
            columns: &result.columns,
            mapping: &mapping,
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert_eq!(plan.rows, expected);
    connection
        .execute(&create.replace("nullable_enum16", "nullable_enum16_csv"))
        .await
        .unwrap();
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
    let imported = connection
        .query("SELECT id, state FROM nullable_enum16_csv ORDER BY id")
        .await
        .unwrap();
    assert_eq!(imported.rows, expected);

    connection
        .execute(
            "CREATE TABLE nullable_enum16_copy (
                id UInt8,
                state Nullable(Enum16('NULL' = 1, 'O''Brien' = 2, 'zero' = 0))
            ) ENGINE = MergeTree ORDER BY id",
        )
        .await
        .unwrap();
    for row in &result.rows {
        let sql = tablepro_core::sql_literal::build_insert_literal(
            "clickhouse",
            None,
            "nullable_enum16_copy",
            &result.columns,
            row,
        )
        .unwrap();
        connection.execute(&sql).await.unwrap();
    }
    let copied = connection
        .query("SELECT id, state FROM nullable_enum16_copy ORDER BY id")
        .await
        .unwrap();
    assert_eq!(copied.rows, expected);
}

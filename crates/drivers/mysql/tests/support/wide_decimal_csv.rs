use tablepro_core::{Connection, Value};

pub(super) async fn assert_csv_bound_and_literal_round_trips(connection: &dyn Connection) {
    const WIDE_INTEGER: &str = "12345678901234567890123456789012345678901234567890123456789012345";
    const WIDE_SCALE: &str = "-12345678901234567890123456789012345.123456789012345678901234567890";

    connection
        .execute("CREATE TABLE wide_decimal_source (id INT PRIMARY KEY, whole DECIMAL(65,0) UNSIGNED, scaled DECIMAL(65,30))")
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO wide_decimal_source VALUES (1, {WIDE_INTEGER}, {WIDE_SCALE})"
        ))
        .await
        .unwrap();
    for table in ["wide_decimal_bound", "wide_decimal_literal"] {
        connection
            .execute(&format!("CREATE TABLE {table} LIKE wide_decimal_source"))
            .await
            .unwrap();
    }

    let source = connection
        .query("SELECT id, whole, scaled FROM wide_decimal_source ORDER BY id")
        .await
        .unwrap();
    let expected = vec![vec![
        Value::Int(1),
        Value::Text(WIDE_INTEGER.into()),
        Value::Text(WIDE_SCALE.into()),
    ]];
    assert_eq!(source.rows, expected);

    let json: serde_json::Value =
        serde_json::from_str(&tablepro_core::export::render_json(&source.columns, &source.rows)).unwrap();
    assert_eq!(json[0]["whole"], serde_json::Value::String(WIDE_INTEGER.into()));
    assert_eq!(json[0]["scaled"], serde_json::Value::String(WIDE_SCALE.into()));

    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let target_columns = connection.fetch_columns(None, "wide_decimal_bound").await.unwrap();
    let mapping = (0..target_columns.len()).map(Some).collect::<Vec<_>>();
    let imported =
        tablepro_core::import::row_to_values(&sheet.rows[0], &mapping, &target_columns, &options, 2).unwrap();
    assert_eq!(
        imported, source.rows[0],
        "typed CSV import must retain decimals wider than Rust Decimal"
    );

    connection
        .execute_params("INSERT INTO wide_decimal_bound VALUES (?, ?, ?)", &imported)
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "wide_decimal_literal").await.unwrap();
    let literal =
        tablepro_core::sql_literal::build_insert_literal("mysql", None, "wide_decimal_literal", &columns, &imported)
            .unwrap();
    connection.execute(&literal).await.unwrap();

    for table in ["wide_decimal_bound", "wide_decimal_literal"] {
        let result = connection
            .query(&format!(
                "SELECT COUNT(*) FROM wide_decimal_source s JOIN {table} c ON s.id = c.id \
                 AND HEX(CAST(s.whole AS CHAR)) = HEX(CAST(c.whole AS CHAR)) \
                 AND HEX(CAST(s.scaled AS CHAR)) = HEX(CAST(c.scaled AS CHAR))"
            ))
            .await
            .unwrap();
        assert_eq!(
            result.rows,
            vec![vec![Value::Int(1)]],
            "native MySQL decimal text and scale must survive the {table} round trip"
        );
    }
}

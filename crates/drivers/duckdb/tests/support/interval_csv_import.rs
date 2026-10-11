use tablepro_core::Value;

#[tokio::test]
async fn value_contract_interval_csv_import_preserves_native_components() {
    let connection = crate::native_connection().await;
    let components = [
        "to_months(-1) + to_days(-2) + to_microseconds(-3)",
        "to_months(-1) + to_days(-2) + to_microseconds(3)",
        "to_months(-1) + to_days(2) + to_microseconds(-3)",
        "to_months(-1) + to_days(2) + to_microseconds(3)",
        "to_months(1) + to_days(-2) + to_microseconds(-3)",
        "to_months(1) + to_days(-2) + to_microseconds(3)",
        "to_months(1) + to_days(2) + to_microseconds(-3)",
        "to_months(1) + to_days(2) + to_microseconds(3)",
        "to_months(-2147483648) + to_days(2147483647) + to_microseconds(9223372036854775)",
        "to_months(2147483647) + to_days(-2147483648) + to_microseconds(-9223372036854775)",
        "INTERVAL '0 microseconds'",
        "NULL::INTERVAL",
    ];
    let rows = components
        .iter()
        .enumerate()
        .map(|(index, expression)| format!("({}, {expression})", index + 1))
        .collect::<Vec<_>>()
        .join(", ");
    let source = connection
        .query(&format!("SELECT id, span FROM (VALUES {rows}) AS source(id, span)"))
        .await
        .unwrap();
    assert_eq!(source.rows.len(), components.len());

    connection
        .execute("CREATE TABLE interval_csv_import (id INTEGER PRIMARY KEY, span INTERVAL)")
        .await
        .unwrap();
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let columns = connection.fetch_columns(None, "interval_csv_import").await.unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "duckdb",
            schema: None,
            table: "interval_csv_import",
            columns: &columns,
            mapping: &[Some(0), Some(1)],
        },
        &sheet,
        &options,
    )
    .expect("DuckDB interval CSV must form an exact-text INSERT plan");
    assert_eq!(
        plan.rows, source.rows,
        "CSV import keeps interval text and NULL distinct"
    );
    for row in &plan.rows {
        connection
            .execute_params(&plan.statement, row)
            .await
            .expect("DuckDB converts exact interval text into the target INTERVAL");
    }

    let oracle = "SELECT id, typeof(span), span::VARCHAR, date_part('month', span)::INTEGER, \
                         date_part('day', span)::INTEGER, date_part('microsecond', span)::BIGINT \
                  FROM (VALUES {rows}) AS source(id, span) ORDER BY id";
    let expected = connection.query(&oracle.replace("{rows}", &rows)).await.unwrap();
    let actual = connection
        .query(
            "SELECT id, typeof(span), span::VARCHAR, date_part('month', span)::INTEGER, \
                    date_part('day', span)::INTEGER, date_part('microsecond', span)::BIGINT \
             FROM interval_csv_import ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        actual.rows, expected.rows,
        "CSV import preserves native interval components"
    );
    assert_eq!(
        actual.rows.iter().map(|row| row[0].clone()).collect::<Vec<_>>(),
        (1..=components.len())
            .map(|id| Value::Int(id as i64))
            .collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn value_contract_extended_calendar_csv_round_trips_exactly() {
    let connection = crate::native_connection().await;
    connection
        .execute("CREATE TABLE extended_calendar_source (id INTEGER, day DATE, moment TIMESTAMP)")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO extended_calendar_source VALUES \
            (1, DATE '1000000-02-29', TIMESTAMP '280000-02-29 12:34:56.123456'), \
            (2, DATE '0001-01-01 (BC)', TIMESTAMP '0001-01-01 (BC) 12:34:56')",
        )
        .await
        .unwrap();
    let source = connection
        .query("SELECT * FROM extended_calendar_source ORDER BY id")
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE extended_calendar_import (id INTEGER, day DATE, moment TIMESTAMP)")
        .await
        .unwrap();
    let options = tablepro_core::import::CsvImportOptions::default();
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let columns = connection
        .fetch_columns(None, "extended_calendar_import")
        .await
        .unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "duckdb",
            schema: None,
            table: "extended_calendar_import",
            columns: &columns,
            mapping: &[Some(0), Some(1), Some(2)],
        },
        &sheet,
        &options,
    )
    .expect("DuckDB extended calendar CSV must form an exact-text INSERT plan");
    assert_eq!(plan.rows, source.rows);
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
    let imported = connection
        .query("SELECT id, CAST(day AS VARCHAR), CAST(moment AS VARCHAR) FROM extended_calendar_import ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        imported.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("1000000-02-29".into()),
                Value::Text("280000-02-29 12:34:56.123456".into())
            ],
            vec![
                Value::Int(2),
                Value::Text("0001-01-01 (BC)".into()),
                Value::Text("0001-01-01 (BC) 12:34:56".into())
            ],
        ]
    );
}

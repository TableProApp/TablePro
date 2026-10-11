#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{Connection, OperationControl, Value};
use tokio_util::sync::CancellationToken;

async fn assert_extended_temporal_csv_round_trip(connection: &dyn Connection, kind: &str, text: &str, send: &str) {
    let table = format!("extended_{kind}_csv");
    connection
        .execute(&format!("CREATE TABLE {table} (value {kind})"))
        .await
        .unwrap();
    let source = connection
        .query(&format!("SELECT '{text}'::{kind} AS value"))
        .await
        .unwrap();
    assert_eq!(source.rows[0][0], Value::Text(text.into()));
    let json = tablepro_core::export::render_json(&source.columns, &source.rows);
    let parsed_json: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed_json, serde_json::json!([{"value": text}]));
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let columns = connection.fetch_columns(None, &table).await.unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: &table,
            columns: &columns,
            mapping: &[Some(0)],
        },
        &sheet,
        &options,
    )
    .unwrap();
    assert_eq!(plan.rows, vec![vec![Value::Text(text.into())]]);
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
    let expected = connection
        .query(&format!(
            "SELECT '{text}'::{kind}::text, encode({send}('{text}'::{kind}), 'hex')"
        ))
        .await
        .unwrap();
    let actual = connection
        .query(&format!(
            "SELECT value::text, encode({send}(value), 'hex') FROM {table}"
        ))
        .await
        .unwrap();
    assert_eq!(actual.rows, expected.rows, "{kind} CSV import changed the value");
}

pub async fn assert_date_contract(connection: &dyn Connection) {
    let control = OperationControl::new(CancellationToken::new(), None);
    let mut session = connection.open_session().await.unwrap();
    for zone in ["UTC", "Asia/Kathmandu", "America/New_York"] {
        session
            .query_params_controlled(&format!("SET TIME ZONE '{zone}'"), &[], &control)
            .await
            .unwrap();
        for (kind, input) in [
            ("date", "0001-01-01 BC"),
            ("date", "0002-12-31 BC"),
            ("date", "4713-01-01 BC"),
            ("date", "0001-01-01"),
            ("date", "9999-12-31"),
            ("date", "10000-01-01"),
            ("date", "262000-02-29"),
            ("timestamp", "4713-01-01 00:00:00 BC"),
            ("timestamp", "0001-01-01 12:34:56.123456 BC"),
            ("timestamp", "0002-12-31 23:59:59.999999 BC"),
            ("timestamp", "10000-01-01 00:00:00.000001"),
            ("timestamp", "1999-12-31 23:59:59.999999"),
            ("timestamptz", "0001-01-01 12:34:56.123456+00 BC"),
            ("timestamptz", "10000-01-01 00:00:00.000001+00"),
            ("timestamptz", "2024-11-03 01:30:00-04"),
            ("timestamptz", "2024-11-03 01:30:00-05"),
        ] {
            let sql =
                format!("SELECT '{input}'::{kind} AS value, encode({kind}_send('{input}'::{kind}), 'hex') AS wire");
            let result = session.query_params_controlled(&sql, &[], &control).await.unwrap();
            assert_eq!(
                result.rows,
                connection.query(&sql).await.unwrap().rows,
                "{zone}: {input}"
            );
            assert!(
                matches!(
                    result.rows[0][0],
                    Value::Date(_) | Value::DateTime(_) | Value::TimestampTz(_)
                ),
                "{input}: {:?}",
                result.rows
            );
            assert_eq!(result.columns[0].data_type, kind.to_ascii_uppercase());
            crate::wire_round_trip::assert_wire_round_trip(
                session.as_mut(),
                &control,
                kind,
                &result.columns[0],
                &result.rows[0][0],
                &result.rows[0][1],
            )
            .await;
        }
    }

    let sql = "SELECT '1000000-01-01'::date AS value, '1000000-01-01'::date::text AS server_text, encode(date_send('1000000-01-01'::date), 'hex') AS server_wire";
    let result = session.query_params_controlled(sql, &[], &control).await.unwrap();
    assert_eq!(result.rows, connection.query(sql).await.unwrap().rows);
    assert_eq!(result.rows[0][0], Value::Text("1000000-01-01".into()));
    assert_eq!(result.rows[0][1], Value::Text("1000000-01-01".into()));
    assert!(matches!(&result.rows[0][2], Value::Text(wire) if !wire.is_empty()));
    crate::wire_round_trip::assert_wire_round_trip(
        session.as_mut(),
        &control,
        "DATE",
        &result.columns[0],
        &result.rows[0][0],
        &result.rows[0][2],
    )
    .await;
    assert_extended_temporal_csv_round_trip(connection, "date", "1000000-01-01", "date_send").await;

    let sql = "SELECT DATE '5874897-12-31' AS value, DATE '5874897-12-31'::text AS server_text, encode(date_send(DATE '5874897-12-31'), 'hex') AS server_wire";
    let result = session.query_params_controlled(sql, &[], &control).await.unwrap();
    assert_eq!(result.rows, connection.query(sql).await.unwrap().rows);
    assert_eq!(result.rows[0][0], Value::Text("5874897-12-31".into()));
    assert_eq!(result.rows[0][1], Value::Text("5874897-12-31".into()));
    crate::wire_round_trip::assert_wire_round_trip(
        session.as_mut(),
        &control,
        "DATE",
        &result.columns[0],
        &result.rows[0][0],
        &result.rows[0][2],
    )
    .await;

    let sql = "SELECT TIMESTAMP '294276-12-31 23:59:59.999999' AS value, TIMESTAMP '294276-12-31 23:59:59.999999'::text AS server_text, encode(timestamp_send(TIMESTAMP '294276-12-31 23:59:59.999999'), 'hex') AS server_wire";
    let result = session.query_params_controlled(sql, &[], &control).await.unwrap();
    assert_eq!(result.rows, connection.query(sql).await.unwrap().rows);
    assert_eq!(result.rows[0][0], Value::Text("294276-12-31 23:59:59.999999".into()));
    assert_eq!(result.rows[0][1], Value::Text("294276-12-31 23:59:59.999999".into()));
    assert!(matches!(&result.rows[0][2], Value::Text(wire) if !wire.is_empty()));
    crate::wire_round_trip::assert_wire_round_trip(
        session.as_mut(),
        &control,
        "TIMESTAMP",
        &result.columns[0],
        &result.rows[0][0],
        &result.rows[0][2],
    )
    .await;
    assert_extended_temporal_csv_round_trip(
        connection,
        "timestamp",
        "294276-12-31 23:59:59.999999",
        "timestamp_send",
    )
    .await;

    session
        .query_params_controlled("SET TIME ZONE 'UTC'", &[], &control)
        .await
        .unwrap();
    let sql = "SELECT TIMESTAMPTZ '294276-12-31 23:59:59.999999+00' AS value, TIMESTAMPTZ '294276-12-31 23:59:59.999999+00'::text AS server_text, encode(timestamptz_send(TIMESTAMPTZ '294276-12-31 23:59:59.999999+00'), 'hex') AS server_wire";
    let result = session.query_params_controlled(sql, &[], &control).await.unwrap();
    assert_eq!(result.rows, connection.query(sql).await.unwrap().rows);
    assert_eq!(result.rows[0][0], Value::Text("294276-12-31 23:59:59.999999+00".into()));
    assert_eq!(result.rows[0][0], result.rows[0][1]);
    crate::wire_round_trip::assert_wire_round_trip(
        session.as_mut(),
        &control,
        "TIMESTAMPTZ",
        &result.columns[0],
        &result.rows[0][0],
        &result.rows[0][2],
    )
    .await;
    assert_extended_temporal_csv_round_trip(
        connection,
        "timestamptz",
        "294276-12-31 23:59:59.999999+00",
        "timestamptz_send",
    )
    .await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_bc_dates_survive_default_csv_import() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let options = tablepro_core::import::CsvImportOptions::default();
    for (kind, send_fn, bc, ad, last, beyond) in [
        (
            "date",
            "date_send",
            "0001-12-31 BC",
            "0001-01-01",
            "9999-12-31",
            "10000-01-01",
        ),
        (
            "timestamp",
            "timestamp_send",
            "0001-12-31 23:59:59.999999 BC",
            "0001-01-01 00:00:00.000001",
            "9999-12-31 23:59:59.999999",
            "10000-01-01 00:00:00.000001",
        ),
        (
            "timestamptz",
            "timestamptz_send",
            "0001-12-31 23:59:59.999999+00 BC",
            "0001-01-01 00:00:00.000001+00",
            "9999-12-31 23:59:59.999999+00",
            "10000-01-01 00:00:00.000001+00",
        ),
    ] {
        let source_table = format!("era_csv_source_{kind}");
        let target_table = format!("era_csv_target_{kind}");
        connection
            .execute(&format!(
                "CREATE TABLE {source_table} (id integer PRIMARY KEY, value {kind})"
            ))
            .await
            .unwrap();
        connection
            .execute(&format!(
                "INSERT INTO {source_table} VALUES (1, '{bc}'::{kind}), (2, '{ad}'::{kind}), (3, '{last}'::{kind}), (4, '{beyond}'::{kind}), (5, NULL)"
            ))
            .await
            .unwrap();
        let source = connection
            .query(&format!(
                "SELECT id, value, encode({send_fn}(value), 'hex') AS wire FROM {source_table} ORDER BY id"
            ))
            .await
            .unwrap();
        let csv_columns = &source.columns[..2];
        let csv_rows: Vec<_> = source.rows.iter().map(|row| row[..2].to_vec()).collect();
        let csv =
            tablepro_core::export::render_csv(csv_columns, &csv_rows, &tablepro_core::export::CsvOptions::default());
        let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();

        connection
            .execute(&format!(
                "CREATE TABLE {target_table} (id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, value {kind})"
            ))
            .await
            .unwrap();
        let columns = connection.fetch_columns(None, &target_table).await.unwrap();
        let mapping = [None, Some(1)];
        let plan = tablepro_core::import::build_insert_plan(
            &tablepro_core::import::ImportTarget {
                driver_id: "postgres",
                schema: None,
                table: &target_table,
                columns: &columns,
                mapping: &mapping,
            },
            &sheet,
            &options,
        )
        .unwrap();
        assert!(
            matches!(&plan.rows[0][0], Value::Text(text) if text.ends_with(" BC")),
            "{kind}: {:?}",
            plan.rows
        );
        assert_eq!(plan.rows[4], vec![Value::Null]);
        for row in &plan.rows {
            connection.execute_params(&plan.statement, row).await.unwrap();
        }
        let restored = connection
            .query(&format!(
                "SELECT value::text, encode({send_fn}(value), 'hex') AS wire FROM {target_table} ORDER BY id"
            ))
            .await
            .unwrap();
        assert_eq!(
            restored.rows.iter().map(|row| &row[1]).collect::<Vec<_>>(),
            source.rows.iter().map(|row| &row[2]).collect::<Vec<_>>(),
            "{kind} native bytes changed through CSV"
        );
        assert!(
            matches!(&restored.rows[0][0], Value::Text(text) if text.ends_with(" BC")),
            "{kind}: {:?}",
            restored.rows
        );
    }
}

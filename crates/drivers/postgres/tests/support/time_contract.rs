#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{Connection, OperationControl, Value};
use tokio_util::sync::CancellationToken;

pub async fn assert_time_contract(connection: &dyn Connection) {
    let control = OperationControl::new(CancellationToken::new(), None);
    let mut session = connection.open_session().await.unwrap();
    for zone in ["UTC", "Asia/Kathmandu", "America/New_York"] {
        session
            .query_params_controlled(&format!("SET TIME ZONE '{zone}'"), &[], &control)
            .await
            .unwrap();
        for (kind, input) in [
            ("time", "00:00:00"),
            ("time", "12:34:56.123456"),
            ("time", "23:59:59.999999"),
            ("time", "24:00:00"),
            ("timetz", "00:00:00+00"),
            ("timetz", "12:34:56.123456+05:45"),
            ("timetz", "12:34:56.000001-03:30"),
            ("timetz", "01:02:03+05:45:12"),
            ("timetz", "01:02:03-05:45:12"),
            ("timetz", "24:00:00+15:59:59"),
            ("timetz", "24:00:00-15:59:59"),
        ] {
            let sql =
                format!("SELECT '{input}'::{kind} AS value, encode({kind}_send('{input}'::{kind}), 'hex') AS wire");
            let result = session.query_params_controlled(&sql, &[], &control).await.unwrap();
            assert_eq!(
                result.rows,
                connection.query(&sql).await.unwrap().rows,
                "{zone}: {input}"
            );
            assert_eq!(result.columns[0].data_type, kind.to_ascii_uppercase());
            let value = &result.rows[0][0];
            assert!(
                matches!(value, Value::Time(_) | Value::Text(_)),
                "{zone}: {input}: {value:?}"
            );
            crate::wire_round_trip::assert_wire_round_trip(
                session.as_mut(),
                &control,
                kind,
                &result.columns[0],
                &result.rows[0][0],
                &result.rows[0][1],
            )
            .await;
            let json = tablepro_core::export::row_to_json(&result.columns, &result.rows[0]);
            let text = match value {
                Value::Time(time) => time.to_string(),
                Value::Text(text) => text.clone(),
                other => panic!("unexpected time: {other:?}"),
            };
            assert_eq!(json["value"].as_str(), Some(text.as_str()));
        }
        let nulls = session
            .query_params_controlled("SELECT NULL::time, NULL::timetz", &[], &control)
            .await
            .unwrap();
        assert_eq!(nulls.rows[0], vec![Value::Null, Value::Null]);
    }

    for (kind, input) in [("time", "24:00:00"), ("timetz", "01:02:03+05:45:12")] {
        let table = format!("temporal_text_csv_{kind}");
        connection
            .execute(&format!("CREATE TABLE {table} (value {kind} NOT NULL)"))
            .await
            .unwrap();
        let source = connection
            .query(&format!("SELECT '{input}'::{kind} AS value"))
            .await
            .unwrap();
        assert_eq!(source.rows, vec![vec![Value::Text(input.into())]]);

        let csv = tablepro_core::export::render_csv(
            &source.columns,
            &source.rows,
            &tablepro_core::export::CsvOptions::default(),
        );
        let options = tablepro_core::import::CsvImportOptions::default();
        let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
        let columns = connection.fetch_columns(None, &table).await.unwrap();
        let mapping = [Some(0)];
        let plan = tablepro_core::import::build_insert_plan(
            &tablepro_core::import::ImportTarget {
                driver_id: "postgres",
                schema: None,
                table: &table,
                columns: &columns,
                mapping: &mapping,
            },
            &sheet,
            &options,
        )
        .unwrap_or_else(|error| panic!("typed CSV import of PostgreSQL {kind} {input}: {error}"));
        assert_eq!(plan.rows, vec![vec![Value::Text(input.into())]]);
        connection
            .execute_params(&plan.statement, &plan.rows[0])
            .await
            .unwrap_or_else(|error| panic!("insert PostgreSQL {kind} {input}: {error:?}"));
        let restored = connection
            .query(&format!("SELECT value::text FROM {table}"))
            .await
            .unwrap();
        assert_eq!(restored.rows, vec![vec![Value::Text(input.into())]]);
    }
}

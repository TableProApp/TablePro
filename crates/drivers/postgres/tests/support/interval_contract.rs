#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{Connection, OperationControl, Value};
use tokio_util::sync::CancellationToken;

fn cases() -> Vec<(i32, i32, i64)> {
    let mut cases = vec![(0, 0, 0), (-1, 2, 3), (1, -2, 3), (-1, -2, 3), (1, 2, -3)];
    for months in [i32::MIN, -13, -12, -1, 0, 1, 12, 13, i32::MAX] {
        cases.push((months, 0, 0));
    }
    for days in [i32::MIN, -1, 0, 1, i32::MAX] {
        cases.push((0, days, 0));
    }
    for micros in [
        i64::MIN,
        -86_400_000_001,
        -1_000_001,
        -1,
        1,
        1_000_001,
        86_400_000_001,
        i64::MAX,
    ] {
        cases.push((0, 0, micros));
    }
    let mut seed = 0x1234_5678_u64;
    for _ in 0..32 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        cases.push(((seed >> 32) as i32, seed as i32, seed as i64));
    }
    cases
}

fn source(months: i32, days: i32, micros: i64) -> String {
    let magnitude = micros.unsigned_abs();
    let sign = if micros < 0 { "-" } else { "+" };
    format!(
        "'{months:+} months {days:+} days {sign}{}.{:06} seconds'::interval",
        magnitude / 1_000_000,
        magnitude % 1_000_000
    )
}

pub async fn assert_interval_contract(connection: &dyn Connection) {
    let control = OperationControl::new(CancellationToken::new(), None);
    let mut session = connection.open_session().await.unwrap();
    for style in ["postgres", "sql_standard", "postgres_verbose", "iso_8601"] {
        session
            .query_params_controlled(&format!("SET intervalstyle = '{style}'"), &[], &control)
            .await
            .unwrap();
        for (months, days, micros) in cases() {
            let source = source(months, days, micros);
            let sql = format!("SELECT {source} AS value, encode(interval_send({source}), 'hex') AS wire");
            let result = session.query_params_controlled(&sql, &[], &control).await.unwrap();
            let mut bytes = Vec::new();
            bytes.extend_from_slice(&micros.to_be_bytes());
            bytes.extend_from_slice(&days.to_be_bytes());
            bytes.extend_from_slice(&months.to_be_bytes());
            let wire = Value::Text(bytes.iter().map(|byte| format!("{byte:02x}")).collect());
            assert_eq!(result.rows[0][1], wire, "fixture {style}: {source}");
            let value = &result.rows[0][0];
            assert!(matches!(value, Value::Text(_)), "{style}: {source}: {value:?}");
            assert_eq!(result.columns[0].data_type, "INTERVAL");
            assert_eq!(connection.query(&sql).await.unwrap().rows, result.rows);
            crate::wire_round_trip::assert_wire_round_trip(
                session.as_mut(),
                &control,
                "interval",
                &result.columns[0],
                value,
                &wire,
            )
            .await;
            let json = tablepro_core::export::row_to_json(&result.columns, &result.rows[0]);
            assert_eq!(
                json["value"].as_str(),
                match value {
                    Value::Text(text) => Some(text.as_str()),
                    _ => None,
                }
            );
        }
    }
}

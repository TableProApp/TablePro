#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_builtin_range_scalars_refuse_lossy_writes_and_preserve_rows() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection.execute("SET TIME ZONE 'UTC'").await.unwrap();
    connection
        .execute(
            "CREATE TABLE builtin_range_scalar_contract (
                id integer PRIMARY KEY,
                int4_value int4range, int8_value int8range, num_value numrange,
                date_value daterange, ts_value tsrange, tstz_value tstzrange,
                sibling text NOT NULL
            )",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO builtin_range_scalar_contract VALUES
             (1, int4range(1, 4), int8range(1, 4000000000), numrange(1.25, 4.5),
              daterange('2024-01-01', '2024-01-03'),
              tsrange('2024-01-01 00:00', '2024-01-02 00:00'),
              tstzrange('2024-01-01 00:00+00', '2024-01-02 00:00+00'), 'target'),
             (2, int4range(20, 25), int8range(20, 25), numrange(20, 25),
              daterange('2024-05-01', '2024-05-03'),
              tsrange('2024-05-01', '2024-05-03'),
              tstzrange('2024-05-01+00', '2024-05-03+00'), 'sibling'),
             (3, 'empty', 'empty', 'empty', 'empty', 'empty', 'empty', 'empty'),
             (4, NULL, NULL, NULL, NULL, NULL, NULL, 'SQL NULL')",
        )
        .await
        .unwrap();

    let cases = [
        ("int4_value", "int4range", "[1,4)"),
        ("int8_value", "int8range", "[1,4000000000)"),
        ("num_value", "numrange", "[1.25,4.5)"),
        ("date_value", "daterange", "[2024-01-01,2024-01-03)"),
        (
            "ts_value",
            "tsrange",
            "[\"2024-01-01 00:00:00\",\"2024-01-02 00:00:00\")",
        ),
        (
            "tstz_value",
            "tstzrange",
            "[\"2024-01-01 00:00:00+00\",\"2024-01-02 00:00:00+00\")",
        ),
    ];
    let snapshot_sql = "SELECT id,
        int4_value::text, to_json(int4_value)::text, encode(range_send(int4_value), 'hex'),
        int8_value::text, to_json(int8_value)::text, encode(range_send(int8_value), 'hex'),
        num_value::text, to_json(num_value)::text, encode(range_send(num_value), 'hex'),
        date_value::text, to_json(date_value)::text, encode(range_send(date_value), 'hex'),
        ts_value::text, to_json(ts_value)::text, encode(range_send(ts_value), 'hex'),
        tstz_value::text, to_json(tstz_value)::text, encode(range_send(tstz_value), 'hex'),
        sibling FROM builtin_range_scalar_contract ORDER BY id";
    let native = connection.query(snapshot_sql).await.unwrap();
    assert_eq!(native.rows.len(), 4);
    assert_eq!(native.rows[0][1], Value::Text("[1,4)".into()));
    assert_eq!(native.rows[0][4], Value::Text("[1,4000000000)".into()));
    assert_eq!(native.rows[0][7], Value::Text("[1.25,4.5)".into()));
    assert_eq!(native.rows[0][10], Value::Text("[2024-01-01,2024-01-03)".into()));
    assert_eq!(
        native.rows[0][13],
        Value::Text("[\"2024-01-01 00:00:00\",\"2024-01-02 00:00:00\")".into())
    );
    assert_eq!(
        native.rows[0][16],
        Value::Text("[\"2024-01-01 00:00:00+00\",\"2024-01-02 00:00:00+00\")".into())
    );

    for (index, (column, range_type, native_text)) in cases.into_iter().enumerate() {
        let type_offset = 1 + index * 3;
        assert_eq!(native.rows[0][type_offset], Value::Text(native_text.into()));
        assert_eq!(
            native.rows[0][type_offset + 1],
            Value::Text(serde_json::to_string(native_text).unwrap())
        );
        let Value::Text(wire) = &native.rows[0][type_offset + 2] else {
            panic!("native wire oracle for {range_type} must be hex text");
        };
        assert!(
            !wire.is_empty() && wire.len() % 2 == 0 && wire.bytes().all(|b| b.is_ascii_hexdigit()),
            "invalid native wire snapshot for {range_type}: {wire}"
        );
        let value = connection
            .query(&format!(
                "SELECT {column}, pg_typeof({column})::text FROM builtin_range_scalar_contract WHERE id = 1"
            ))
            .await
            .unwrap();
        let refusal = value.rows[0][0].clone();
        assert!(
            matches!(&refusal, Value::Undecodable(name) if name.eq_ignore_ascii_case(range_type)),
            "{range_type} must be visibly undecodable: {refusal:?}"
        );
        assert_eq!(value.rows[0][1], Value::Text(range_type.into()));
        let empty = connection
            .query(&format!(
                "SELECT {column}, isempty({column}) FROM builtin_range_scalar_contract WHERE id = 3"
            ))
            .await
            .unwrap();
        assert!(matches!(&empty.rows[0][0], Value::Undecodable(name) if name.eq_ignore_ascii_case(range_type)));
        assert_eq!(empty.rows[0][1], Value::Bool(true));
        let null = connection
            .query(&format!(
                "SELECT {column}, {column} IS NULL FROM builtin_range_scalar_contract WHERE id = 4"
            ))
            .await
            .unwrap();
        assert_eq!(null.rows[0][0], Value::Null);
        assert_eq!(null.rows[0][1], Value::Bool(true));

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
                    &format!("UPDATE builtin_range_scalar_contract SET {column} = $1 WHERE id = 1"),
                    std::slice::from_ref(&refusal),
                )
                .await
                .is_err()
        );
        assert_eq!(
            connection.query(snapshot_sql).await.unwrap().rows,
            native.rows,
            "{range_type} refusal changed stored rows"
        );
    }
}

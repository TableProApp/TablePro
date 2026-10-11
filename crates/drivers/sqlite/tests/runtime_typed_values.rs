#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use chrono::{NaiveDate, NaiveDateTime, NaiveTime};
use drivers_sqlite::SqliteDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver, Value};

fn memory_options() -> ConnectOptions {
    ConnectOptions {
        database: ":memory:".into(),
        ..Default::default()
    }
}

#[tokio::test]
async fn declared_boolean_and_temporal_values_keep_their_core_types() {
    let connection = SqliteDriver.connect(memory_options()).await.unwrap();
    connection
        .execute(
            "CREATE TABLE typed_values (\
                 id INTEGER PRIMARY KEY, enabled BOOLEAN, day DATE, clock TIME, \
                 moment DATETIME, legacy_moment TIMESTAMP\
             )",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO typed_values VALUES \
             (1, 1, '2026-10-08', '12:34:56.123456', \
              '2026-10-08 12:34:56.123456', '2026-10-08 12:34:56.123456'), \
             (2, 0, '2026-10-08', '12:34:56.123456', \
              '2026-10-08 12:34:56.123456', '2026-10-08 12:34:56.123456'), \
             (3, NULL, NULL, NULL, NULL, NULL)",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT id, enabled, typeof(enabled), day, typeof(day), \
                    clock, typeof(clock), moment, typeof(moment), \
                    legacy_moment, typeof(legacy_moment) \
             FROM typed_values ORDER BY id",
        )
        .await
        .unwrap();
    let date = NaiveDate::from_ymd_opt(2026, 10, 8).unwrap();
    let time = NaiveTime::from_hms_micro_opt(12, 34, 56, 123_456).unwrap();
    let datetime = NaiveDateTime::new(date, time);
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Bool(true),
                Value::Text("integer".into()),
                Value::Date(date),
                Value::Text("text".into()),
                Value::Time(time),
                Value::Text("text".into()),
                Value::DateTime(datetime),
                Value::Text("text".into()),
                Value::DateTime(datetime),
                Value::Text("text".into()),
            ],
            vec![
                Value::Int(2),
                Value::Bool(false),
                Value::Text("integer".into()),
                Value::Date(date),
                Value::Text("text".into()),
                Value::Time(time),
                Value::Text("text".into()),
                Value::DateTime(datetime),
                Value::Text("text".into()),
                Value::DateTime(datetime),
                Value::Text("text".into()),
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Text("null".into()),
                Value::Null,
                Value::Text("null".into()),
                Value::Null,
                Value::Text("null".into()),
                Value::Null,
                Value::Text("null".into()),
                Value::Null,
                Value::Text("null".into()),
            ],
        ]
    );
}

#[tokio::test]
async fn blob_affinity_values_are_decoded_by_their_runtime_storage_class() {
    let connection = SqliteDriver.connect(memory_options()).await.unwrap();
    connection
        .execute("CREATE TABLE flexible_blob (value BLOB)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible_blob VALUES ('42'), (42), (1.5), (X'00FF'), (NULL)")
        .await
        .unwrap();

    let result = connection
        .query("SELECT value, typeof(value) FROM flexible_blob")
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Text("42".into()), Value::Text("text".into())],
            vec![Value::Int(42), Value::Text("integer".into())],
            vec![Value::Float(1.5), Value::Text("real".into())],
            vec![Value::Bytes(vec![0, 255]), Value::Text("blob".into())],
            vec![Value::Null, Value::Text("null".into())],
        ]
    );
}

#[tokio::test]
async fn json_each_values_keep_their_runtime_storage_classes() {
    let connection = SqliteDriver.connect(memory_options()).await.unwrap();
    let result = connection
        .query(
            r#"SELECT key, value, type, typeof(value), atom, typeof(atom)
               FROM json_each('[1,1.25,"text","",null,true,false,{"x":1},[2]]')
               ORDER BY key"#,
        )
        .await
        .unwrap();

    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(0),
                Value::Int(1),
                Value::Text("integer".into()),
                Value::Text("integer".into()),
                Value::Int(1),
                Value::Text("integer".into()),
            ],
            vec![
                Value::Int(1),
                Value::Float(1.25),
                Value::Text("real".into()),
                Value::Text("real".into()),
                Value::Float(1.25),
                Value::Text("real".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("text".into()),
                Value::Text("text".into()),
                Value::Text("text".into()),
                Value::Text("text".into()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("".into()),
                Value::Text("text".into()),
                Value::Text("text".into()),
                Value::Text("".into()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Int(4),
                Value::Null,
                Value::Text("null".into()),
                Value::Text("null".into()),
                Value::Null,
                Value::Text("null".into()),
            ],
            vec![
                Value::Int(5),
                Value::Int(1),
                Value::Text("true".into()),
                Value::Text("integer".into()),
                Value::Int(1),
                Value::Text("integer".into()),
            ],
            vec![
                Value::Int(6),
                Value::Int(0),
                Value::Text("false".into()),
                Value::Text("integer".into()),
                Value::Int(0),
                Value::Text("integer".into()),
            ],
            vec![
                Value::Int(7),
                Value::Text(r#"{"x":1}"#.into()),
                Value::Text("object".into()),
                Value::Text("text".into()),
                Value::Null,
                Value::Text("null".into()),
            ],
            vec![
                Value::Int(8),
                Value::Text("[2]".into()),
                Value::Text("array".into()),
                Value::Text("text".into()),
                Value::Null,
                Value::Text("null".into()),
            ],
        ]
    );
}

#[tokio::test]
async fn json_operators_keep_json_and_sql_value_storage_classes() {
    let connection = SqliteDriver.connect(memory_options()).await.unwrap();
    let result = connection
        .query(
            r#"WITH source(document) AS (
                   VALUES (json('{"integer":42,"real":1.25,"text":"","numeric_text":"42","null":null,
                                 "boolean":true,"object":{"x":1},"array":[2]}'))
               )
               SELECT document -> '$.integer', typeof(document -> '$.integer'),
                      document ->> '$.integer', typeof(document ->> '$.integer'),
                      document -> '$.real', typeof(document -> '$.real'),
                      document ->> '$.real', typeof(document ->> '$.real'),
                      document -> '$.numeric_text', typeof(document -> '$.numeric_text'),
                      document ->> '$.numeric_text', typeof(document ->> '$.numeric_text'),
                      document -> '$.text', typeof(document -> '$.text'),
                      document ->> '$.text', typeof(document ->> '$.text'),
                      document -> '$.null', typeof(document -> '$.null'),
                      document ->> '$.null', typeof(document ->> '$.null'),
                      document -> '$.boolean', typeof(document -> '$.boolean'),
                      document ->> '$.boolean', typeof(document ->> '$.boolean'),
                      document -> '$.object', typeof(document -> '$.object'),
                      document ->> '$.object', typeof(document ->> '$.object'),
                      document -> '$.array', typeof(document -> '$.array'),
                      document ->> '$.array', typeof(document ->> '$.array')
               FROM source"#,
        )
        .await
        .unwrap();

    assert_eq!(
        result.rows,
        vec![vec![
            Value::Text("42".into()),
            Value::Text("text".into()),
            Value::Int(42),
            Value::Text("integer".into()),
            Value::Text("1.25".into()),
            Value::Text("text".into()),
            Value::Float(1.25),
            Value::Text("real".into()),
            Value::Text("\"42\"".into()),
            Value::Text("text".into()),
            Value::Text("42".into()),
            Value::Text("text".into()),
            Value::Text("\"\"".into()),
            Value::Text("text".into()),
            Value::Text(String::new()),
            Value::Text("text".into()),
            Value::Text("null".into()),
            Value::Text("text".into()),
            Value::Null,
            Value::Text("null".into()),
            Value::Text("true".into()),
            Value::Text("text".into()),
            Value::Int(1),
            Value::Text("integer".into()),
            Value::Text(r#"{"x":1}"#.into()),
            Value::Text("text".into()),
            Value::Text(r#"{"x":1}"#.into()),
            Value::Text("text".into()),
            Value::Text("[2]".into()),
            Value::Text("text".into()),
            Value::Text("[2]".into()),
            Value::Text("text".into()),
        ]]
    );
}

#[tokio::test]
async fn json_each_object_keys_keep_their_text_values_and_storage_classes() {
    let connection = SqliteDriver.connect(memory_options()).await.unwrap();
    let result = connection
        .query(
            r#"SELECT key, value, type, typeof(key), typeof(value), atom, typeof(atom)
               FROM json_each('{"":null,"01":true,"NULL":"","雪":{"x":1}}')
               ORDER BY key"#,
        )
        .await
        .unwrap();

    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Text(String::new()),
                Value::Null,
                Value::Text("null".into()),
                Value::Text("text".into()),
                Value::Text("null".into()),
                Value::Null,
                Value::Text("null".into()),
            ],
            vec![
                Value::Text("01".into()),
                Value::Int(1),
                Value::Text("true".into()),
                Value::Text("text".into()),
                Value::Text("integer".into()),
                Value::Int(1),
                Value::Text("integer".into()),
            ],
            vec![
                Value::Text("NULL".into()),
                Value::Text(String::new()),
                Value::Text("text".into()),
                Value::Text("text".into()),
                Value::Text("text".into()),
                Value::Text(String::new()),
                Value::Text("text".into()),
            ],
            vec![
                Value::Text("雪".into()),
                Value::Text(r#"{"x":1}"#.into()),
                Value::Text("object".into()),
                Value::Text("text".into()),
                Value::Text("text".into()),
                Value::Null,
                Value::Text("null".into()),
            ],
        ]
    );
}

#[tokio::test]
async fn json_object_and_array_results_remain_exact_text() {
    let connection = SqliteDriver.connect(memory_options()).await.unwrap();
    let result = connection
        .query(
            "SELECT json_object('empty', '', 'null', NULL, 'number', 7), \
                    typeof(json_object('empty', '', 'null', NULL, 'number', 7)), \
                    json_array(1, 1.25, '', NULL, json('true'), json('{\"x\":1}')), \
                    typeof(json_array(1, 1.25, '', NULL, json('true'), json('{\"x\":1}'))) ",
        )
        .await
        .unwrap();

    assert_eq!(
        result.rows,
        vec![vec![
            Value::Text(r#"{"empty":"","null":null,"number":7}"#.into()),
            Value::Text("text".into()),
            Value::Text(r#"[1,1.25,"",null,true,{"x":1}]"#.into()),
            Value::Text("text".into()),
        ]]
    );
}

#[tokio::test]
async fn jsonb_results_remain_binary_blobs_with_native_json_content() {
    let connection = SqliteDriver.connect(memory_options()).await.unwrap();
    let result = connection
        .query(
            "SELECT jsonb('{\"empty\":\"\",\"null\":null,\"nested\":[1,true]}'), \
                    typeof(jsonb('{\"empty\":\"\",\"null\":null,\"nested\":[1,true]}')), \
                    json(jsonb('{\"empty\":\"\",\"null\":null,\"nested\":[1,true]}')), \
                    hex(jsonb('{\"empty\":\"\",\"null\":null,\"nested\":[1,true]}'))",
        )
        .await
        .unwrap();

    let [
        Value::Bytes(bytes),
        Value::Text(storage_class),
        Value::Text(json_text),
        Value::Text(native_hex),
    ] = result.rows[0].as_slice()
    else {
        panic!("SQLite JSONB result did not remain a byte value")
    };
    assert!(!bytes.is_empty());
    assert_eq!(
        native_hex,
        &bytes.iter().map(|byte| format!("{byte:02X}")).collect::<String>()
    );
    assert_eq!(storage_class, "blob");
    assert_eq!(json_text, r#"{"empty":"","null":null,"nested":[1,true]}"#);
}

#[tokio::test]
async fn declared_enum_values_follow_sqlite_numeric_affinity_and_keep_runtime_kinds() {
    let connection = SqliteDriver.connect(memory_options()).await.unwrap();
    connection.execute("CREATE TABLE enum_like (value ENUM)").await.unwrap();
    connection
        .execute("INSERT INTO enum_like VALUES ('queued'), ('3.5'), ('7'), (X'00FF'), (NULL)")
        .await
        .unwrap();

    let result = connection
        .query("SELECT value, typeof(value), quote(value) FROM enum_like ORDER BY rowid")
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, "ENUM");
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Text("queued".into()),
                Value::Text("text".into()),
                Value::Text("'queued'".into())
            ],
            vec![Value::Float(3.5), Value::Text("real".into()), Value::Text("3.5".into())],
            vec![Value::Int(7), Value::Text("integer".into()), Value::Text("7".into())],
            vec![
                Value::Bytes(vec![0, 255]),
                Value::Text("blob".into()),
                Value::Text("X'00FF'".into())
            ],
            vec![Value::Null, Value::Text("null".into()), Value::Text("NULL".into())],
        ]
    );
}

#[tokio::test]
async fn invalid_declared_temporal_values_remain_text() {
    let connection = SqliteDriver.connect(memory_options()).await.unwrap();
    connection
        .execute("CREATE TABLE malformed_temporals (day DATE, clock TIME, moment DATETIME, legacy_moment TIMESTAMP)")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO malformed_temporals VALUES \
             ('2026-13-40', '25:61:62', 'not-a-datetime', '2026-13-40 25:61:62')",
        )
        .await
        .unwrap();

    let result = connection
        .query("SELECT day, clock, moment, legacy_moment FROM malformed_temporals")
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Text("2026-13-40".into()),
            Value::Text("25:61:62".into()),
            Value::Text("not-a-datetime".into()),
            Value::Text("2026-13-40 25:61:62".into()),
        ]]
    );
}

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use serde_json::json;
use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_integer_text_and_bytea_match_native_oracles() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let result = connection
        .query(
            "SELECT n, pg_typeof(n)::text, n::text, encode(int8send(n), 'hex'), \
             label, pg_typeof(label)::text, label::text, octet_length(label), \
             encode(convert_to(label, 'UTF8'), 'hex') \
             FROM (VALUES \
             ('-9223372036854775808'::bigint, ''::text), \
             ('-9007199254740993'::bigint, 'NULL'::text), \
             ('9007199254740993'::bigint, 'O''Brien'::text), \
             ('9223372036854775807'::bigint, '東京😀'::text)) AS values(n, label)",
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(i64::MIN),
                Value::Text("bigint".into()),
                Value::Text(i64::MIN.to_string()),
                Value::Text("8000000000000000".into()),
                Value::Text(String::new()),
                Value::Text("text".into()),
                Value::Text(String::new()),
                Value::Int(0),
                Value::Text(String::new()),
            ],
            vec![
                Value::Int(-9_007_199_254_740_993),
                Value::Text("bigint".into()),
                Value::Text("-9007199254740993".into()),
                Value::Text("ffdfffffffffffff".into()),
                Value::Text("NULL".into()),
                Value::Text("text".into()),
                Value::Text("NULL".into()),
                Value::Int(4),
                Value::Text("4e554c4c".into()),
            ],
            vec![
                Value::Int(9_007_199_254_740_993),
                Value::Text("bigint".into()),
                Value::Text("9007199254740993".into()),
                Value::Text("0020000000000001".into()),
                Value::Text("O'Brien".into()),
                Value::Text("text".into()),
                Value::Text("O'Brien".into()),
                Value::Int(7),
                Value::Text("4f27427269656e".into()),
            ],
            vec![
                Value::Int(i64::MAX),
                Value::Text("bigint".into()),
                Value::Text(i64::MAX.to_string()),
                Value::Text("7fffffffffffffff".into()),
                Value::Text("東京😀".into()),
                Value::Text("text".into()),
                Value::Text("東京😀".into()),
                Value::Int(10),
                Value::Text("e69db1e4baacf09f9880".into()),
            ],
        ]
    );

    let bytea = connection
        .query(
            "SELECT payload, encode(payload, 'hex'), octet_length(payload) \
             FROM (VALUES (NULL::bytea), (decode('', 'hex')), (decode('00ff275c', 'hex'))) \
             AS values(payload)",
        )
        .await
        .unwrap();
    assert_eq!(
        bytea.rows,
        vec![
            vec![Value::Null, Value::Null, Value::Null],
            vec![Value::Bytes(Vec::new()), Value::Text(String::new()), Value::Int(0)],
            vec![
                Value::Bytes(vec![0, 255, 39, 92]),
                Value::Text("00ff275c".into()),
                Value::Int(4)
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_json_and_jsonb_match_native_type_oracles() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let result = connection
        .query(
            "SELECT json_value, json_value::text, json_typeof(json_value), \
             jsonb_value, jsonb_typeof(jsonb_value), \
             jsonb_value = '{\"a\":[null,true],\"b\":2}'::jsonb \
             FROM (SELECT '{ \"b\": 2, \"a\": [null, true] }'::json AS json_value, \
             '{ \"b\": 2, \"a\": [null, true] }'::jsonb AS jsonb_value) source",
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows[0],
        vec![
            Value::JsonText("{ \"b\": 2, \"a\": [null, true] }".into()),
            Value::Text("{ \"b\": 2, \"a\": [null, true] }".into()),
            Value::Text("object".into()),
            Value::Json(json!({"a": [null, true], "b": 2})),
            Value::Text("object".into()),
            Value::Bool(true),
        ]
    );
}

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

const EXPRESSIONS: &[&str] = &[
    "'a'::tsvector",
    "'''it''''s'':1A,2B,3C,4D ''b'' ''back\\\\slash'' ''üñí'':3'::tsvector",
    "to_tsvector('simple', 'The quick brown fox jumps over the lazy dog')",
    "''::tsvector",
    "'a:1,2,3,4,5,6,7,8,9,10 b:100 c:16383'::tsvector",
    "int4range(1, 5)",
    "int4range(NULL, 5)",
    "int4range(1, NULL)",
    "int4range(NULL, NULL)",
    "int4range(5, 5)",
    "int4range(1, 5, '(]')",
    "int4range(-2147483648, 2147483647)",
    "int8range(-9223372036854775807, 9223372036854775806, '[]')",
    "int8range(1, 1000000000000)",
    "'(0,0)'::point",
    "'(1.5,-2)'::point",
    "'(0.1,0.30000000000000004)'::point",
    "'(1e21,1e-7)'::point",
    "'(1e15,1e14)'::point",
    "'(123456789.123456789,-0.0001)'::point",
    "'(NaN,Infinity)'::point",
    "'(-Infinity,1e300)'::point",
    "'(1e-300,5e-324)'::point",
];

const SAME_VALUE: &[(&str, &str)] = &[
    ("json", "ARRAY['{\"a\": 1}'::json, 'null'::json, NULL]"),
    (
        "jsonb",
        "ARRAY['{\"b\":   [1, 2, {\"c\": \"x,y\"}]}'::jsonb, '\"üñí\"'::jsonb, NULL]",
    ),
    ("jsonb", "ARRAY['{}'::jsonb, '[]'::jsonb, '1.50'::jsonb, 'true'::jsonb]"),
    ("jsonb", "ARRAY[]::jsonb[]"),
    ("jsonb", "ARRAY[['{\"a\":1}'::jsonb, '2'::jsonb]]"),
    (
        "float8",
        "ARRAY[1e21::float8, 1e-7, 'NaN', '-Infinity', 1.5, 123456789012345678, 1e15, 1e14, 0.0001, 0.00001, 5e-324, -0.0]",
    ),
    (
        "float4",
        "ARRAY[1e6::float4, 1.5e-5, 16777216, 3.4028235e38, 999999, 0.1, 'Infinity', 1e-45]",
    ),
    ("float8", "ARRAY[]::float8[]"),
];

#[tokio::test]
#[ignore = "requires docker"]
async fn decoded_text_matches_what_the_server_prints() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    let mut mismatches = Vec::new();
    for expression in EXPRESSIONS {
        let result = conn
            .query(&format!("SELECT {expression}, ({expression})::text"))
            .await
            .unwrap_or_else(|error| panic!("{expression}: {error:?}"));
        let ours = &result.rows[0][0];
        let server = &result.rows[0][1];
        if ours != server {
            mismatches.push(format!("{expression}\n   ours:   {ours:?}\n   server: {server:?}"));
        }
        assert!(!matches!(ours, Value::Undecodable(_)), "{expression} is undecodable");
    }
    assert!(
        mismatches.is_empty(),
        "{} differ:\n{}",
        mismatches.len(),
        mismatches.join("\n")
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn decoded_arrays_are_the_same_array_when_the_server_reads_them_back() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    for (element, expression) in SAME_VALUE {
        let ours = conn.query(&format!("SELECT {expression}")).await.unwrap().rows[0][0].clone();
        let Value::Text(text) = &ours else {
            panic!("{expression} did not decode: {ours:?}");
        };
        let same = conn
            .query_params(
                &format!("SELECT ($1::text::{element}[])::text IS NOT DISTINCT FROM ({expression})::text"),
                std::slice::from_ref(&ours),
            )
            .await
            .unwrap_or_else(|error| panic!("{expression}\n   decoded as {text}\n   {error:?}"));
        assert_eq!(same.rows[0][0], Value::Bool(true), "{expression}: {text}");
    }
}

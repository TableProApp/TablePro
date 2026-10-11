#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_text_search_array_refusal_preserves_target_and_sibling_rows() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection
        .execute(
            "CREATE TABLE text_search_array_refusal \
             (id integer PRIMARY KEY, vectors tsvector[], queries tsquery[], sibling text NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO text_search_array_refusal VALUES \
             (1, ARRAY[to_tsvector('simple', 'cats dogs'), ''::tsvector, NULL], \
                 ARRAY[to_tsquery('simple', 'cats & dogs'), ''::tsquery, NULL], 'target'), \
             (2, ARRAY[to_tsvector('simple', 'sibling')], \
                 ARRAY[to_tsquery('simple', 'sibling')], 'sibling')",
        )
        .await
        .unwrap();

    let source = connection
        .query(
            "SELECT vectors, queries, pg_typeof(vectors)::text, pg_typeof(queries)::text, \
             vectors::text, queries::text, array_to_json(vectors)::text, \
             array_to_json(queries)::text, encode(array_send(vectors), 'hex'), \
             encode(array_send(queries), 'hex') \
             FROM text_search_array_refusal WHERE id = 1",
        )
        .await
        .unwrap();
    let vector_refusal = source.rows[0][0].clone();
    let query_refusal = source.rows[0][1].clone();
    assert!(
        matches!(&vector_refusal, Value::Undecodable(name) if name.eq_ignore_ascii_case("TSVECTOR[]")),
        "tsvector[] must remain visibly unsupported: {vector_refusal:?}"
    );
    assert!(
        matches!(&query_refusal, Value::Undecodable(name) if name.eq_ignore_ascii_case("TSQUERY[]")),
        "tsquery[] must remain visibly unsupported: {query_refusal:?}"
    );
    assert_eq!(source.rows[0][2], Value::Text("tsvector[]".into()));
    assert_eq!(source.rows[0][3], Value::Text("tsquery[]".into()));
    assert_eq!(
        source.rows[0][6],
        Value::Text(r#"["'cats':1 'dogs':2","",null]"#.into())
    );
    assert_eq!(source.rows[0][7], Value::Text(r#"["'cats' & 'dogs'","",null]"#.into()));

    let before = connection
        .query(
            "SELECT id, vectors::text, queries::text, array_to_json(vectors)::text, \
             array_to_json(queries)::text, encode(array_send(vectors), 'hex'), \
             encode(array_send(queries), 'hex'), sibling \
             FROM text_search_array_refusal ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(before.rows.len(), 2);
    assert_eq!(before.rows[0][1], source.rows[0][4]);
    assert_eq!(before.rows[0][2], source.rows[0][5]);
    assert_eq!(before.rows[0][3], source.rows[0][6]);
    assert_eq!(before.rows[0][4], source.rows[0][7]);
    assert_eq!(before.rows[0][5], source.rows[0][8]);
    assert_eq!(before.rows[0][6], source.rows[0][9]);

    for refusal in [&vector_refusal, &query_refusal] {
        assert!(tablepro_core::sql_literal::render_sql_literal("postgres", refusal).is_err());
        assert!(
            connection
                .query_params("SELECT $1", std::slice::from_ref(refusal))
                .await
                .is_err()
        );
    }
    assert!(
        connection
            .execute_params(
                "UPDATE text_search_array_refusal SET vectors = $1 WHERE id = 1",
                std::slice::from_ref(&vector_refusal),
            )
            .await
            .is_err()
    );
    assert!(
        connection
            .execute_params(
                "UPDATE text_search_array_refusal SET queries = $1 WHERE id = 1",
                std::slice::from_ref(&query_refusal),
            )
            .await
            .is_err()
    );

    let after = connection
        .query(
            "SELECT id, vectors::text, queries::text, array_to_json(vectors)::text, \
             array_to_json(queries)::text, encode(array_send(vectors), 'hex'), \
             encode(array_send(queries), 'hex'), sibling \
             FROM text_search_array_refusal ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(after.rows, before.rows, "refused bindings changed stored values");
    assert_eq!(after.rows[0][7], Value::Text("target".into()));
    assert_eq!(after.rows[1][7], Value::Text("sibling".into()));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_json_array_refusal_preserves_target_and_sibling_rows() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection
        .execute(
            "CREATE TABLE json_array_refusal \
             (id integer PRIMARY KEY, json_values json[], jsonb_values jsonb[], sibling text NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO json_array_refusal VALUES \
             (1, ARRAY['{\"z\":1,\"a\":\"x,y\"}'::json, 'null'::json, NULL], \
                 ARRAY['{\"z\":1,\"a\":\"x,y\"}'::jsonb, 'null'::jsonb, NULL], 'target'), \
             (2, ARRAY['{\"sibling\":true}'::json], \
                 ARRAY['{\"sibling\":true}'::jsonb], 'sibling')",
        )
        .await
        .unwrap();

    let source = connection
        .query(
            "SELECT json_values, jsonb_values, pg_typeof(json_values)::text, \
             pg_typeof(jsonb_values)::text, json_values::text, jsonb_values::text, \
             array_to_json(json_values)::text, array_to_json(jsonb_values)::text, \
             encode(array_send(json_values), 'hex'), encode(array_send(jsonb_values), 'hex') \
             FROM json_array_refusal WHERE id = 1",
        )
        .await
        .unwrap();
    let json_refusal = source.rows[0][0].clone();
    let jsonb_refusal = source.rows[0][1].clone();
    assert!(
        matches!(&json_refusal, Value::Undecodable(name) if name.eq_ignore_ascii_case("JSON[]")),
        "json[] must remain visibly unsupported: {json_refusal:?}"
    );
    assert!(
        matches!(&jsonb_refusal, Value::Undecodable(name) if name.eq_ignore_ascii_case("JSONB[]")),
        "jsonb[] must remain visibly unsupported: {jsonb_refusal:?}"
    );
    assert_eq!(source.rows[0][2], Value::Text("json[]".into()));
    assert_eq!(source.rows[0][3], Value::Text("jsonb[]".into()));
    assert_eq!(
        source.rows[0][4],
        Value::Text(r#"{"{\"z\":1,\"a\":\"x,y\"}","null",NULL}"#.into())
    );
    assert_eq!(
        source.rows[0][5],
        Value::Text(r#"{"{\"a\": \"x,y\", \"z\": 1}","null",NULL}"#.into())
    );
    assert_eq!(
        source.rows[0][6],
        Value::Text(r#"[{"z":1,"a":"x,y"},null,null]"#.into())
    );
    assert_eq!(
        source.rows[0][7],
        Value::Text(r#"[{"a": "x,y", "z": 1},null,null]"#.into())
    );

    let before = connection
        .query(
            "SELECT id, json_values::text, jsonb_values::text, \
             array_to_json(json_values)::text, array_to_json(jsonb_values)::text, \
             encode(array_send(json_values), 'hex'), encode(array_send(jsonb_values), 'hex'), sibling \
             FROM json_array_refusal ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(before.rows.len(), 2);
    assert_eq!(before.rows[0][1], source.rows[0][4]);
    assert_eq!(before.rows[0][2], source.rows[0][5]);
    assert_eq!(before.rows[0][3], source.rows[0][6]);
    assert_eq!(before.rows[0][4], source.rows[0][7]);
    assert_eq!(before.rows[0][5], source.rows[0][8]);
    assert_eq!(before.rows[0][6], source.rows[0][9]);

    for refusal in [&json_refusal, &jsonb_refusal] {
        assert!(tablepro_core::sql_literal::render_sql_literal("postgres", refusal).is_err());
        assert!(
            connection
                .query_params("SELECT $1", std::slice::from_ref(refusal))
                .await
                .is_err()
        );
    }
    for (statement, refusal) in [
        (
            "UPDATE json_array_refusal SET json_values = $1 WHERE id = 1",
            &json_refusal,
        ),
        (
            "UPDATE json_array_refusal SET jsonb_values = $1 WHERE id = 1",
            &jsonb_refusal,
        ),
    ] {
        assert!(
            connection
                .execute_params(statement, std::slice::from_ref(refusal),)
                .await
                .is_err()
        );
    }

    let after = connection
        .query(
            "SELECT id, json_values::text, jsonb_values::text, \
             array_to_json(json_values)::text, array_to_json(jsonb_values)::text, \
             encode(array_send(json_values), 'hex'), encode(array_send(jsonb_values), 'hex'), sibling \
             FROM json_array_refusal ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(after.rows, before.rows, "refused bindings changed stored values");
    assert_eq!(after.rows[0][7], Value::Text("target".into()));
    assert_eq!(after.rows[1][7], Value::Text("sibling".into()));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_empty_json_arrays_refuse_but_sql_null_stays_null() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;

    for native_type in ["json[]", "jsonb[]"] {
        let empty = connection
            .query(&format!(
                "SELECT value, pg_typeof(value)::text, value::text, array_to_json(value)::text \
                 FROM (SELECT ARRAY[]::{native_type} AS value) source"
            ))
            .await
            .unwrap();
        assert!(matches!(
            &empty.rows[0][0],
            Value::Undecodable(name) if name.eq_ignore_ascii_case(native_type)
        ));
        assert_eq!(empty.rows[0][1], Value::Text(native_type.into()));
        assert_eq!(empty.rows[0][2], Value::Text("{}".into()));
        assert_eq!(empty.rows[0][3], Value::Text("[]".into()));
        assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &empty.rows[0][0]).is_err());
        assert!(
            connection
                .query_params("SELECT $1", std::slice::from_ref(&empty.rows[0][0]))
                .await
                .is_err()
        );

        let null = connection
            .query(&format!(
                "SELECT NULL::{native_type}, pg_typeof(NULL::{native_type})::text"
            ))
            .await
            .unwrap();
        assert_eq!(null.rows[0][0], Value::Null);
        assert_eq!(null.rows[0][1], Value::Text(native_type.into()));
    }
}

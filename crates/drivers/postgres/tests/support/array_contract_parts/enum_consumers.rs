#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_json_array_elements_are_explicitly_unsupported() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY['{\"a\": 1}'::jsonb, 'null'::jsonb]";
    let result = connection
        .query(&format!(
            "SELECT {expression} AS value, pg_typeof({expression})::text AS array_type, \
             array_to_json({expression})::text AS json_text, \
             array_to_json({expression})::jsonb = '[{{\"a\": 1}}, null]'::jsonb AS server_match"
        ))
        .await
        .unwrap();

    let value = &result.rows[0][0];
    assert!(matches!(value, Value::Undecodable(_)), "{value:?}");
    assert_eq!(result.rows[0][1], Value::Text("jsonb[]".into()));
    assert_eq!(result.rows[0][2], Value::Text("[{\"a\": 1},null]".into()));
    assert_eq!(result.rows[0][3], Value::Bool(true));
    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", value).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(value))
            .await
            .is_err()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_json_text_array_is_explicitly_unsupported() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let expression = "ARRAY['{\"a\": 1}'::json, 'null'::json]";
    let result = connection
        .query(&format!(
            "SELECT {expression} AS value, pg_typeof({expression})::text AS array_type, \
             array_to_json({expression})::text AS json_text, \
             array_to_json({expression})::jsonb = '[{{\"a\": 1}}, null]'::jsonb AS server_match"
        ))
        .await
        .unwrap();

    let value = &result.rows[0][0];
    assert!(matches!(value, Value::Undecodable(_)), "{value:?}");
    assert_eq!(result.rows[0][1], Value::Text("json[]".into()));
    assert_eq!(result.rows[0][2], Value::Text("[{\"a\": 1},null]".into()));
    assert_eq!(result.rows[0][3], Value::Bool(true));
    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", value).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(value))
            .await
            .is_err()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_projection_preserves_literal_null_and_sql_null() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TYPE value_contract_array_enum AS ENUM ('NULL', '東京', 'o''brien')")
        .await
        .unwrap();
    let expression = "ARRAY['NULL'::value_contract_array_enum, \
        '東京'::value_contract_array_enum, \
        'o''brien'::value_contract_array_enum, NULL]";
    let result = connection
        .query(&format!(
            "SELECT pg_typeof(value)::text AS array_type, value::text AS exact_text, \
             array_to_json(value)::jsonb = \
               '[\"NULL\",\"東京\",\"o''brien\",null]'::jsonb AS server_match \
             FROM (SELECT {expression} AS value) source"
        ))
        .await
        .unwrap();

    assert_eq!(result.rows[0][0], Value::Text("value_contract_array_enum[]".into()));
    assert_eq!(result.rows[0][1], Value::Text(r#"{"NULL",東京,o'brien,NULL}"#.into()));
    assert_eq!(result.rows[0][2], Value::Bool(true));
    let direct_projection = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_eq!(
        direct_projection.rows,
        vec![vec![Value::Text(r#"{"NULL","東京","o'brien",NULL}"#.into())]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_preserves_boundary_whitespace_labels() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute(
            "CREATE TYPE value_contract_whitespace_enum AS ENUM \
             (' leading', 'trailing ', ' both ', 'NULL', '', 'sibling')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_whitespace_target \
             (id integer PRIMARY KEY, labels value_contract_whitespace_enum[])",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_whitespace_target VALUES \
             (99, ARRAY['sibling'::value_contract_whitespace_enum])",
        )
        .await
        .unwrap();
    let sibling_wire = connection
        .query(
            "SELECT encode(array_send(labels), 'hex') \
             FROM value_contract_whitespace_target WHERE id = 99",
        )
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let expression = "ARRAY[' leading'::value_contract_whitespace_enum, \
        'trailing '::value_contract_whitespace_enum, \
        ' both '::value_contract_whitespace_enum, \
        'NULL'::value_contract_whitespace_enum, \
        ''::value_contract_whitespace_enum, NULL]";
    let source = connection
        .query(&format!("SELECT 7 AS id, {expression} AS labels"))
        .await
        .unwrap();
    assert_eq!(source.columns[1].data_type, "value_contract_whitespace_enum[]");
    assert_eq!(
        source.rows[0][1],
        Value::Text(r#"{" leading","trailing "," both ","NULL","",NULL}"#.into())
    );

    let native = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
                    encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text("value_contract_whitespace_enum[]".into()));
    let Value::Text(native_json) = &native.rows[0][1] else {
        panic!("native whitespace enum array JSON returned {:?}", native.rows[0][1]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(native_json).unwrap(),
        serde_json::json!([" leading", "trailing ", " both ", "NULL", "", null])
    );

    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &options, None).unwrap();
    let mapping = [Some(0), Some(1)];
    let imported = tablepro_core::import::row_to_values(&sheet.rows[0], &mapping, &source.columns, &options, 2).unwrap();
    assert_eq!(imported, source.rows[0]);

    let rebound = connection
        .query_params(
            "SELECT pg_typeof($1::text::value_contract_whitespace_enum[])::text, \
                    array_to_json($1::text::value_contract_whitespace_enum[])::text, \
                    encode(array_send($1::text::value_contract_whitespace_enum[]), 'hex')",
            std::slice::from_ref(&imported[1]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][0]);
    assert_eq!(rebound.rows[0][1], native.rows[0][1]);
    assert_eq!(rebound.rows[0][2], native.rows[0][2]);

    let columns = connection
        .fetch_columns(None, "value_contract_whitespace_target")
        .await
        .unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: "value_contract_whitespace_target",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &options,
    )
    .unwrap();
    connection.execute_params(&plan.statement, &plan.rows[0]).await.unwrap();
    let restored = connection
        .query(
            "SELECT id, pg_typeof(labels)::text, labels::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM value_contract_whitespace_target ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(restored.rows.len(), 2);
    assert_eq!(restored.rows[0][0], Value::Int(7));
    assert_eq!(restored.rows[0][1], native.rows[0][0]);
    assert_eq!(restored.rows[0][3], native.rows[0][1]);
    assert_eq!(restored.rows[0][4], native.rows[0][2]);
    assert_eq!(restored.rows[1][0], Value::Int(99));
    assert_eq!(restored.rows[1][4], sibling_wire);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_accepts_maximum_utf8_label_length() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    let maximum_label = "漢".repeat(21);
    assert_eq!(maximum_label.len(), 63);
    connection
        .execute(&format!(
            "CREATE TYPE value_contract_max_enum_label AS ENUM ('{maximum_label}')"
        ))
        .await
        .unwrap();

    let overlong_label = format!("{maximum_label}x");
    assert_eq!(overlong_label.len(), 64);
    let rejected = connection
        .execute(&format!(
            "CREATE TYPE value_contract_overlong_enum_label AS ENUM ('{overlong_label}')"
        ))
        .await;
    assert!(
        matches!(
            rejected,
            Err(tablepro_core::DriverError::Query {
                sqlstate: Some(ref code),
                ..
            }) if code == "42602"
        ),
        "PostgreSQL must reject a 64-byte enum label without truncating it: {rejected:?}"
    );

    let expression = format!(
        "ARRAY['{maximum_label}'::value_contract_max_enum_label]"
    );
    let result = connection
        .query(&format!("SELECT {expression} AS value"))
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, "value_contract_max_enum_label[]");

    let native = connection
        .query(&format!(
            "SELECT pg_typeof({expression})::text, array_to_json({expression})::text, \
                    encode(array_send({expression}), 'hex')"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text("value_contract_max_enum_label[]".into()));
    let Value::Text(array_text) = &result.rows[0][0] else {
        panic!("maximum-label enum array must remain text: {:?}", result.rows[0][0]);
    };
    assert!(array_text.contains(&maximum_label));
    assert_eq!(
        native.rows[0][1],
        Value::Text(serde_json::json!([maximum_label]).to_string())
    );

    let rebound = connection
        .query_params(
            "SELECT pg_typeof($1::text::value_contract_max_enum_label[])::text, \
                    array_to_json($1::text::value_contract_max_enum_label[])::text, \
                    encode(array_send($1::text::value_contract_max_enum_label[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][0]);
    assert_eq!(rebound.rows[0][1], native.rows[0][1]);
    assert_eq!(rebound.rows[0][2], native.rows[0][2]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_three_dimensions_round_trip_native_wire_bytes() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA value_contract_enum_3d").await.unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_3d.label AS ENUM \
             ('NULL', '', 'a,b', 'a\"b', '東京', 'slash\\path', '=1+1')",
        )
        .await
        .unwrap();

    let enum_type = "value_contract_enum_3d.label[]";
    let expression = r#"'[0:1][2:3][-1:0]={{{"NULL",NULL},{"","a,b"}},{{"a\"b","東京"},{"slash\\path","=1+1"}}}'::value_contract_enum_3d.label[]"#;
    let result = connection.query(&format!("SELECT {expression} AS value")).await.unwrap();
    assert_eq!(result.columns[0].data_type, enum_type);
    let Value::Text(array_text) = &result.rows[0][0] else {
        panic!("three-dimensional enum array must remain text: {:?}", result.rows[0][0]);
    };

    let native = connection
        .query(&format!(
            "SELECT pg_typeof(value)::text, array_dims(value), array_ndims(value), \
                    array_to_json(value)::text, encode(array_send(value), 'hex') \
             FROM (SELECT {expression} AS value) AS source"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text(enum_type.into()));
    assert_eq!(native.rows[0][1], Value::Text("[0:1][2:3][-1:0]".into()));
    assert_eq!(native.rows[0][2], Value::Int(3));
    let Value::Text(native_json) = &native.rows[0][3] else {
        panic!("native enum array JSON oracle is not text: {:?}", native.rows[0][3]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(native_json).unwrap(),
        serde_json::json!([
            [["NULL", null], ["", "a,b"]],
            [["a\"b", "東京"], ["slash\\path", "=1+1"]]
        ])
    );

    let rebound = connection
        .query_params(
            &format!(
                "SELECT pg_typeof($1::{enum_type})::text, \
                        array_dims($1::{enum_type}), array_ndims($1::{enum_type}), \
                        array_to_json($1::{enum_type})::text, \
                        encode(array_send($1::{enum_type}), 'hex')"
            ),
            &[Value::Text(array_text.clone())],
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0], native.rows[0]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_six_dimension_limit_round_trips() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA value_contract_enum_6d").await.unwrap();
    connection
        .execute("CREATE TYPE value_contract_enum_6d.label AS ENUM ('ready')")
        .await
        .unwrap();

    let enum_type = "value_contract_enum_6d.label[]";
    let expression = r#"'[0:0][1:1][2:2][3:3][4:4][5:5]={{{{{{ready}}}}}}'::value_contract_enum_6d.label[]"#;
    let result = connection.query(&format!("SELECT {expression} AS value")).await.unwrap();
    assert_eq!(result.columns[0].data_type, enum_type);
    let Value::Text(array_text) = &result.rows[0][0] else {
        panic!("six-dimensional enum array must remain text: {:?}", result.rows[0][0]);
    };

    let native = connection
        .query(&format!(
            "SELECT pg_typeof(value)::text, array_dims(value), array_ndims(value), \
                    array_to_json(value)::text, encode(array_send(value), 'hex') \
             FROM (SELECT {expression} AS value) AS source"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text(enum_type.into()));
    assert_eq!(native.rows[0][1], Value::Text("[0:0][1:1][2:2][3:3][4:4][5:5]".into()));
    assert_eq!(native.rows[0][2], Value::Int(6));
    let Value::Text(native_json) = &native.rows[0][3] else {
        panic!("native enum array JSON oracle is not text: {:?}", native.rows[0][3]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(native_json).unwrap(),
        serde_json::json!([[[[[["ready"]]]]]])
    );

    let rebound = connection
        .query_params(
            &format!(
                "SELECT pg_typeof($1::{enum_type})::text, \
                        array_dims($1::{enum_type}), array_ndims($1::{enum_type}), \
                        array_to_json($1::{enum_type})::text, \
                        encode(array_send($1::{enum_type}), 'hex')"
            ),
            &[Value::Text(array_text.clone())],
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0], native.rows[0]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_range_uses_qualified_type_under_shadowed_search_path() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA value_contract_enum_range_target").await.unwrap();
    connection.execute("CREATE SCHEMA value_contract_enum_range_shadow").await.unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_range_target.ordered_label AS ENUM \
             ('first', 'NULL', '', '東京', 'last')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_range_shadow.ordered_label AS ENUM \
             ('shadow-only', 'NULL')",
        )
        .await
        .unwrap();
    connection
        .execute("SET search_path = value_contract_enum_range_shadow, value_contract_enum_range_target, public")
        .await
        .unwrap();

    let expression = "enum_range(NULL::value_contract_enum_range_target.ordered_label)";
    let result = connection
        .query(&format!(
            "SELECT {expression} AS value, pg_typeof({expression})::text AS array_type"
        ))
        .await
        .unwrap();
    assert_eq!(result.columns[0].data_type, "value_contract_enum_range_target.ordered_label[]");
    let target_type = Value::Text("value_contract_enum_range_target.ordered_label[]".into());
    assert_eq!(result.rows[0][1], target_type);
    let Value::Text(encoded) = &result.rows[0][0] else {
        panic!("enum_range result must remain typed array text: {:?}", result.rows[0][0]);
    };

    let native = connection
        .query(&format!(
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex'), array_dims(value) \
             FROM (SELECT {expression} AS value) AS native"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], target_type);
    let Value::Text(json_text) = &native.rows[0][1] else {
        panic!("enum_range JSON oracle returned {:?}", native.rows[0][1]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(json_text).unwrap(),
        serde_json::json!(["first", "NULL", "", "東京", "last"])
    );
    assert_eq!(native.rows[0][3], Value::Text("[1:5]".into()));

    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::value_contract_enum_range_target.ordered_label[])::text, \
                    encode(array_send($1::text::value_contract_enum_range_target.ordered_label[]), 'hex')",
            std::slice::from_ref(&Value::Text(encoded.clone())),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][1]);
    assert_eq!(rebound.rows[0][1], native.rows[0][2]);

    let shadow_label = Value::Text("{shadow-only}".into());
    let error = connection
        .query_params(
            "SELECT $1::text::value_contract_enum_range_target.ordered_label[]",
            std::slice::from_ref(&shadow_label),
        )
        .await
        .unwrap_err();
    assert!(
        matches!(&error, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected target enum invalid-label SQLSTATE 22P02, got {error:?}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_range_bounds_preserve_inclusive_and_null_boundaries_under_shadowed_search_path() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA value_contract_enum_range_bounds_target").await.unwrap();
    connection.execute("CREATE SCHEMA value_contract_enum_range_bounds_shadow").await.unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_range_bounds_target.label AS ENUM \
             ('first', 'NULL', '', '東京', 'last')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_range_bounds_shadow.label AS ENUM \
             ('shadow-only', 'NULL')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "SET search_path = value_contract_enum_range_bounds_shadow, \
             value_contract_enum_range_bounds_target, public",
        )
        .await
        .unwrap();

    let target_type = "value_contract_enum_range_bounds_target.label";
    let target_array = "value_contract_enum_range_bounds_target.label[]";
    let cases = format!(
        "VALUES \
         (1, 'bounded', 'first'::{target_type}, '東京'::{target_type}), \
         (2, 'null_lower', NULL::{target_type}, ''::{target_type}), \
         (3, 'null_upper', '東京'::{target_type}, NULL::{target_type}), \
         (4, 'both_null', NULL::{target_type}, NULL::{target_type}), \
         (5, 'reversed', 'last'::{target_type}, 'first'::{target_type}), \
         (6, 'equal_label', 'NULL'::{target_type}, 'NULL'::{target_type})"
    );
    let result = connection
        .query(&format!(
            "WITH cases(ord, name, lower_bound, upper_bound) AS ({cases}) \
             SELECT name, enum_range(lower_bound, upper_bound) AS value \
             FROM cases ORDER BY ord"
        ))
        .await
        .unwrap();
    assert_eq!(result.columns[1].data_type, target_array);

    let native = connection
        .query(&format!(
            "WITH cases(ord, name, lower_bound, upper_bound) AS ({cases}), \
             ranges AS (SELECT ord, name, enum_range(lower_bound, upper_bound) AS value FROM cases) \
             SELECT name, pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex'), array_dims(value) \
             FROM ranges ORDER BY ord"
        ))
        .await
        .unwrap();
    let type_value = Value::Text(target_array.into());
    let expected = [
        ("bounded", serde_json::json!(["first", "NULL", "", "東京"]), Some("[1:4]")),
        ("null_lower", serde_json::json!(["first", "NULL", ""]), Some("[1:3]")),
        ("null_upper", serde_json::json!(["東京", "last"]), Some("[1:2]")),
        ("both_null", serde_json::json!(["first", "NULL", "", "東京", "last"]), Some("[1:5]")),
        ("reversed", serde_json::json!([]), None),
        ("equal_label", serde_json::json!(["NULL"]), Some("[1:1]")),
    ];
    for (index, (name, expected_json, expected_dims)) in expected.into_iter().enumerate() {
        assert_eq!(result.rows[index][0], Value::Text(name.into()));
        assert_eq!(result.rows[index][0], native.rows[index][0]);
        assert_eq!(native.rows[index][1], type_value);
        let Value::Text(json_text) = &native.rows[index][2] else {
            panic!("enum_range JSON oracle returned {:?}", native.rows[index][2]);
        };
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(json_text).unwrap(),
            expected_json
        );
        match expected_dims {
            Some(dims) => assert_eq!(native.rows[index][4], Value::Text(dims.into())),
            None => assert_eq!(native.rows[index][4], Value::Null),
        }

        let rebound = connection
            .query_params(
                &format!("SELECT encode(array_send($1::text::{target_array}), 'hex')"),
                std::slice::from_ref(&result.rows[index][1]),
            )
            .await
            .unwrap();
        assert_eq!(rebound.rows[0][0], native.rows[index][3], "{name}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_min_max_keep_target_type_and_order_under_shadowed_search_path() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA value_contract_enum_aggregate_target").await.unwrap();
    connection.execute("CREATE SCHEMA value_contract_enum_aggregate_shadow").await.unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_aggregate_target.state AS ENUM \
             ('early', 'NULL', '', '東京', 'late')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_aggregate_shadow.state AS ENUM \
             ('shadow-only', 'NULL')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_enum_aggregate_target.events \
             (group_id integer, label value_contract_enum_aggregate_target.state)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_enum_aggregate_target.events VALUES \
             (1, 'late'), (1, ''), (1, NULL), (1, 'NULL'), (1, 'early'), \
             (2, '東京'), (2, 'NULL'), (3, NULL), (3, NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "SET search_path = value_contract_enum_aggregate_shadow, \
             value_contract_enum_aggregate_target, public",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT group_id, min(label) AS min_label, max(label) AS max_label \
             FROM value_contract_enum_aggregate_target.events \
             GROUP BY group_id ORDER BY group_id",
        )
        .await
        .unwrap();
    let target_type = "value_contract_enum_aggregate_target.state";
    assert_eq!(result.columns[1].data_type, target_type);
    assert_eq!(result.columns[2].data_type, target_type);
    let native = connection
        .query(
            "SELECT group_id, pg_typeof(min(label))::text, pg_typeof(max(label))::text, \
                    min(label)::text, max(label)::text, \
                    encode(enum_send(min(label)), 'hex'), encode(enum_send(max(label)), 'hex') \
             FROM value_contract_enum_aggregate_target.events \
             GROUP BY group_id ORDER BY group_id",
        )
        .await
        .unwrap();
    let expected = [
        (1, Some("early"), Some("late")),
        (2, Some("NULL"), Some("東京")),
        (3, None, None),
    ];
    for (index, (group_id, min_label, max_label)) in expected.into_iter().enumerate() {
        assert_eq!(result.rows[index][0], Value::Int(group_id));
        assert_eq!(native.rows[index][0], result.rows[index][0]);
        assert_eq!(native.rows[index][1], Value::Text(target_type.into()));
        assert_eq!(native.rows[index][2], Value::Text(target_type.into()));
        for (result_column, native_text_column, native_wire_column, label) in
            [(1, 3, 5, min_label), (2, 4, 6, max_label)]
        {
            match label {
                Some(label) => {
                    assert_eq!(result.rows[index][result_column], Value::Text(label.into()));
                    assert_eq!(native.rows[index][native_text_column], Value::Text(label.into()));
                    let rebound = connection
                        .query_params(
                            &format!(
                                "SELECT encode(enum_send($1::text::{target_type}), 'hex')"
                            ),
                            std::slice::from_ref(&result.rows[index][result_column]),
                        )
                        .await
                        .unwrap();
                    assert_eq!(rebound.rows[0][0], native.rows[index][native_wire_column]);
                }
                None => {
                    assert_eq!(result.rows[index][result_column], Value::Null);
                    assert_eq!(native.rows[index][native_text_column], Value::Null);
                    assert_eq!(native.rows[index][native_wire_column], Value::Null);
                }
            }
        }
    }

    let empty = connection
        .query(
            "SELECT min(label), max(label) \
             FROM value_contract_enum_aggregate_target.events WHERE false",
        )
        .await
        .unwrap();
    assert_eq!(empty.columns[0].data_type, target_type);
    assert_eq!(empty.columns[1].data_type, target_type);
    assert_eq!(empty.rows[0], [Value::Null, Value::Null]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_first_and_last_use_qualified_type_under_shadowed_search_path() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA value_contract_enum_extreme_target").await.unwrap();
    connection.execute("CREATE SCHEMA value_contract_enum_extreme_shadow").await.unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_extreme_target.label AS ENUM \
             ('first', 'NULL', '', '東京', 'last')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_extreme_shadow.label AS ENUM \
             ('shadow-only', 'NULL')",
        )
        .await
        .unwrap();
    connection
        .execute("SET search_path = value_contract_enum_extreme_shadow, value_contract_enum_extreme_target, public")
        .await
        .unwrap();

    let expression = "SELECT enum_first(NULL::value_contract_enum_extreme_target.label) AS first_label, \
                             enum_last(NULL::value_contract_enum_extreme_target.label) AS last_label";
    let result = connection.query(expression).await.unwrap();
    let type_name = "value_contract_enum_extreme_target.label";
    assert_eq!(result.columns[0].data_type, type_name);
    assert_eq!(result.columns[1].data_type, type_name);
    assert_eq!(
        result.rows[0],
        vec![Value::Text("first".into()), Value::Text("last".into())]
    );

    let native = connection
        .query(&format!(
            "SELECT pg_typeof(first_label)::text, pg_typeof(last_label)::text, \
                    encode(enum_send(first_label), 'hex'), encode(enum_send(last_label), 'hex') \
             FROM ({expression}) AS enumerated"
        ))
        .await
        .unwrap();
    assert_eq!(native.rows[0][0], Value::Text(type_name.into()));
    assert_eq!(native.rows[0][1], Value::Text(type_name.into()));

    let rebound = connection
        .query_params(
            "SELECT encode(enum_send($1::text::value_contract_enum_extreme_target.label), 'hex'), \
                    encode(enum_send($2::text::value_contract_enum_extreme_target.label), 'hex')",
            &[result.rows[0][0].clone(), result.rows[0][1].clone()],
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][2]);
    assert_eq!(rebound.rows[0][1], native.rows[0][3]);

    let invalid = connection
        .query_params(
            "SELECT enum_first($1::text::value_contract_enum_extreme_target.label)",
            &[Value::Text("shadow-only".into())],
        )
        .await
        .expect_err("a shadow-only label must not be accepted as the target enum");
    assert!(
        matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_agg_preserves_order_and_nulls() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE TYPE value_contract_array_agg_enum AS ENUM ('NULL', '', '東京', 'a,b', 'o''brien')")
        .await
        .unwrap();

    let source = "VALUES \
        (1, 'NULL'::value_contract_array_agg_enum), \
        (2, ''::value_contract_array_agg_enum), \
        (3, '東京'::value_contract_array_agg_enum), \
        (4, 'a,b'::value_contract_array_agg_enum), \
        (5, 'o''brien'::value_contract_array_agg_enum), \
        (6, NULL::value_contract_array_agg_enum)";
    let aggregate = format!(
        "(SELECT array_agg(label ORDER BY ordinal) FROM ({source}) AS input(ordinal, label))"
    );
    let result = connection.query(&format!("SELECT {aggregate} AS value")).await.unwrap();
    assert_eq!(result.columns[0].data_type, "value_contract_array_agg_enum[]");
    let Value::Text(_) = &result.rows[0][0] else {
        panic!("custom enum array aggregate must remain textual: {:?}", result.rows[0][0]);
    };

    let oracle = connection
        .query(&format!(
            "SELECT pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') \
             FROM (SELECT {aggregate} AS value) AS native"
        ))
        .await
        .unwrap();
    assert_eq!(oracle.rows[0][0], Value::Text("value_contract_array_agg_enum[]".into()));
    let Value::Text(json_text) = &oracle.rows[0][1] else {
        panic!("array_to_json oracle returned {:?}", oracle.rows[0][1]);
    };
    let expected_json = serde_json::json!(["NULL", "", "東京", "a,b", "o'brien", null]);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(json_text).unwrap(),
        expected_json
    );

    let rebound = connection
        .query_params(
            "SELECT array_to_json($1::text::value_contract_array_agg_enum[])::text, \
                    encode(array_send($1::text::value_contract_array_agg_enum[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    let Value::Text(rebound_json) = &rebound.rows[0][0] else {
        panic!("rebound array_to_json returned {:?}", rebound.rows[0][0]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(rebound_json).unwrap(),
        expected_json
    );
    assert_eq!(rebound.rows[0][1], oracle.rows[0][2]);

    let no_rows_aggregate = format!(
        "(SELECT array_agg(label ORDER BY ordinal) FILTER (WHERE false) \
         FROM ({source}) AS input(ordinal, label))"
    );
    let no_rows = connection
        .query(&format!(
            "SELECT {no_rows_aggregate} AS value, pg_typeof({no_rows_aggregate})::text AS array_type"
        ))
        .await
        .unwrap();
    assert_eq!(no_rows.columns[0].data_type, "value_contract_array_agg_enum[]");
    assert_eq!(no_rows.rows[0][0], Value::Null);
    assert_eq!(no_rows.rows[0][1], Value::Text("value_contract_array_agg_enum[]".into()));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_agg_distinct_filter_preserves_native_order_and_nulls() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute(
            "CREATE TYPE value_contract_array_agg_distinct_enum \
             AS ENUM ('NULL', '', '東京', 'a,b', 'o''brien')",
        )
        .await
        .unwrap();

    let aggregate = "array_agg(DISTINCT label ORDER BY label) FILTER (WHERE keep_it)";
    let source = "VALUES \
        (true, 'NULL'::value_contract_array_agg_distinct_enum), \
        (true, 'NULL'::value_contract_array_agg_distinct_enum), \
        (true, ''::value_contract_array_agg_distinct_enum), \
        (true, ''::value_contract_array_agg_distinct_enum), \
        (true, '東京'::value_contract_array_agg_distinct_enum), \
        (true, '東京'::value_contract_array_agg_distinct_enum), \
        (true, 'a,b'::value_contract_array_agg_distinct_enum), \
        (false, 'o''brien'::value_contract_array_agg_distinct_enum), \
        (true, NULL::value_contract_array_agg_distinct_enum), \
        (true, NULL::value_contract_array_agg_distinct_enum)";
    let query = format!(
        "WITH input(keep_it, label) AS ({source}) \
         SELECT {aggregate} AS value FROM input"
    );
    let result = connection.query(&query).await.unwrap();
    assert_eq!(result.columns[0].data_type, "value_contract_array_agg_distinct_enum[]");
    let Value::Text(_) = &result.rows[0][0] else {
        panic!("custom enum aggregate must remain textual: {:?}", result.rows[0][0]);
    };

    let native = connection
        .query(&format!(
            "WITH input(keep_it, label) AS ({source}) \
             SELECT pg_typeof(value)::text, array_to_json(value)::text, \
                    encode(array_send(value), 'hex') \
             FROM (SELECT {aggregate} AS value FROM input) AS aggregate_result"
        ))
        .await
        .unwrap();
    assert_eq!(
        native.rows[0][0],
        Value::Text("value_contract_array_agg_distinct_enum[]".into())
    );
    let Value::Text(json_text) = &native.rows[0][1] else {
        panic!("native enum aggregate JSON oracle returned {:?}", native.rows[0][1]);
    };
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(json_text).unwrap(),
        serde_json::json!(["NULL", "", "東京", "a,b", null])
    );

    let rebound = connection
        .query_params(
            "SELECT pg_typeof($1::text::value_contract_array_agg_distinct_enum[])::text, \
                    array_to_json($1::text::value_contract_array_agg_distinct_enum[])::text, \
                    encode(array_send($1::text::value_contract_array_agg_distinct_enum[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0][0], native.rows[0][0]);
    assert_eq!(rebound.rows[0][1], native.rows[0][1]);
    assert_eq!(rebound.rows[0][2], native.rows[0][2]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_agg_keeps_target_type_under_shadowed_search_path() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection
        .execute("CREATE SCHEMA value_contract_agg_target")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_agg_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_agg_target.status AS ENUM \
             ('NULL', '', 'shared', 'target-only', '東京')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_agg_shadow.status AS ENUM \
             ('shadow-only', 'shared', 'target-only')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_agg_target.rows \
             (ordinal INT PRIMARY KEY, label value_contract_agg_target.status)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_agg_target.rows VALUES \
             (1, 'target-only'), (2, 'NULL'), (3, 'shared'), \
             (4, ''), (5, NULL), (6, '東京')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "SET search_path TO value_contract_agg_shadow, \
             value_contract_agg_target, public",
        )
        .await
        .unwrap();

    let aggregate = "array_agg(DISTINCT label ORDER BY label)";
    let result = connection
        .query(&format!(
            "SELECT {aggregate} AS value \
             FROM value_contract_agg_target.rows"
        ))
        .await
        .unwrap();
    let Value::Text(_) = &result.rows[0][0] else {
        panic!("custom enum aggregate must remain textual: {:?}", result.rows[0][0]);
    };

    let native = connection
        .query(&format!(
            "SELECT pg_typeof(value)::text, \
                    pg_typeof(value)::oid = \
                        'value_contract_agg_target.status[]'::regtype::oid, \
                    array_to_json(value)::text, encode(array_send(value), 'hex') \
             FROM (SELECT {aggregate} AS value \
                   FROM value_contract_agg_target.rows) AS aggregate_result"
        ))
        .await
        .unwrap();
    assert_eq!(
        native.rows[0][0],
        Value::Text("value_contract_agg_target.status[]".into())
    );
    assert_eq!(native.rows[0][1], Value::Bool(true));
    assert_eq!(
        native.rows[0][2],
        Value::Text(r#"["NULL","","shared","target-only","東京",null]"#.into())
    );

    let rebound = connection
        .query_params(
            "SELECT pg_typeof($1::text::value_contract_agg_target.status[])::text, \
                    pg_typeof($1::text::value_contract_agg_target.status[])::oid = \
                        'value_contract_agg_target.status[]'::regtype::oid, \
                    array_to_json($1::text::value_contract_agg_target.status[])::text, \
                    encode(array_send($1::text::value_contract_agg_target.status[]), 'hex')",
            std::slice::from_ref(&result.rows[0][0]),
        )
        .await
        .unwrap();
    assert_eq!(rebound.rows[0], native.rows[0]);

    let shadow_only_label = Value::Text("{shadow-only}".into());
    assert!(
        connection
            .query_params(
                "SELECT $1::text::value_contract_agg_target.status[]",
                std::slice::from_ref(&shadow_only_label),
            )
            .await
            .is_err()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_array_grid_edit_preserves_labels_and_siblings() {
    let (_container, options) = crate::start_pg().await;
    let connection = crate::connect(options).await;
    connection.execute("CREATE SCHEMA enum_array_grid").await.unwrap();
    connection
        .execute("CREATE TYPE enum_array_grid.label AS ENUM ('NULL', '', '東京', 'a,b', 'sibling', 'ready')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE enum_array_grid.items \
             (id integer PRIMARY KEY, labels enum_array_grid.label[])",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO enum_array_grid.items VALUES \
             (1, ARRAY['sibling'::enum_array_grid.label]), \
             (2, ARRAY['ready'::enum_array_grid.label])",
        )
        .await
        .unwrap();
    let sibling_wire = connection
        .query("SELECT encode(array_send(labels), 'hex') FROM enum_array_grid.items WHERE id = 1")
        .await
        .unwrap()
        .rows[0][0]
        .clone();

    let mut columns = connection
        .fetch_columns(Some("enum_array_grid"), "items")
        .await
        .unwrap();
    let id_index = columns.iter().position(|column| column.name == "id").unwrap();
    let labels_index = columns.iter().position(|column| column.name == "labels").unwrap();
    assert_eq!(
        columns[labels_index].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "enum_array_grid".into(),
            name: "label".into(),
        })
    );
    columns[id_index].primary_key = true;
    let original = connection
        .query("SELECT labels::text FROM enum_array_grid.items WHERE id = 2")
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    let edited = r#"{"NULL","",東京,"a,b",NULL}"#;
    let update = tablepro_core::sql_dialect::build_optimistic_keyed_update(
        "postgres",
        Some("enum_array_grid"),
        "items",
        &columns,
        &[(labels_index, original, Value::Text(edited.into()))],
        &[Value::Int(2)],
    )
    .unwrap();
    assert!(update.0.contains("$1::text::\"enum_array_grid\".\"label\"[]"));
    assert!(update
        .0
        .contains("labels\" IS NOT DISTINCT FROM $3::text::\"enum_array_grid\".\"label\"[]"));
    assert_eq!(connection.execute_in_transaction(&[update]).await.unwrap(), vec![1]);

    let native = connection
        .query(
            "SELECT pg_typeof(labels)::text, labels::text, array_dims(labels), \
                    array_to_json(labels)::text, encode(array_send(labels), 'hex') \
             FROM (SELECT ARRAY[\
                 'NULL'::enum_array_grid.label, ''::enum_array_grid.label, \
                 '東京'::enum_array_grid.label, 'a,b'::enum_array_grid.label, \
                 NULL::enum_array_grid.label\
             ] AS labels) AS source",
        )
        .await
        .unwrap();
    let saved = connection
        .query(
            "SELECT pg_typeof(labels)::text, labels::text, array_dims(labels), \
                    array_to_json(labels)::text, encode(array_send(labels), 'hex') \
             FROM enum_array_grid.items WHERE id = 2",
        )
        .await
        .unwrap();
    assert_eq!(saved.rows, native.rows);

    let invalid = tablepro_core::sql_dialect::build_optimistic_keyed_update(
        "postgres",
        Some("enum_array_grid"),
        "items",
        &columns,
        &[(
            labels_index,
            Value::Text(edited.into()),
            Value::Text("{not-a-label}".into()),
        )],
        &[Value::Int(2)],
    )
    .unwrap();
    assert!(connection.execute_in_transaction(&[invalid]).await.is_err());
    let unchanged = connection
        .query(
            "SELECT pg_typeof(labels)::text, labels::text, array_dims(labels), \
                    array_to_json(labels)::text, encode(array_send(labels), 'hex') \
             FROM enum_array_grid.items WHERE id = 2",
        )
        .await
        .unwrap();
    assert_eq!(unchanged.rows, native.rows);

    let null_update = tablepro_core::sql_dialect::build_optimistic_keyed_update(
        "postgres",
        Some("enum_array_grid"),
        "items",
        &columns,
        &[(labels_index, Value::Text(edited.into()), Value::Null)],
        &[Value::Int(2)],
    )
    .unwrap();
    assert!(null_update.0.contains("$1::text::\"enum_array_grid\".\"label\"[]"));
    connection.execute_in_transaction(&[null_update]).await.unwrap();
    let saved_null = connection
        .query(
            "SELECT labels IS NULL, pg_typeof(labels)::text, array_to_json(labels)::text, \
                    encode(array_send(labels), 'hex') \
             FROM enum_array_grid.items WHERE id = 2",
        )
        .await
        .unwrap();
    assert_eq!(
        saved_null.rows,
        vec![vec![
            Value::Bool(true),
            Value::Text("enum_array_grid.label[]".into()),
            Value::Null,
            Value::Null,
        ]]
    );

    let empty_update = tablepro_core::sql_dialect::build_optimistic_keyed_update(
        "postgres",
        Some("enum_array_grid"),
        "items",
        &columns,
        &[(labels_index, Value::Null, Value::Text("{}".into()))],
        &[Value::Int(2)],
    )
    .unwrap();
    connection.execute_in_transaction(&[empty_update]).await.unwrap();
    let saved_empty = connection
        .query(
            "SELECT labels IS NULL, pg_typeof(labels)::text, labels::text, array_dims(labels), \
                    array_to_json(labels)::text, encode(array_send(labels), 'hex') \
             FROM enum_array_grid.items WHERE id = 2",
        )
        .await
        .unwrap();
    assert_eq!(saved_empty.rows[0][0], Value::Bool(false));
    assert_eq!(saved_empty.rows[0][1], Value::Text("enum_array_grid.label[]".into()));
    assert_eq!(saved_empty.rows[0][2], Value::Text("{}".into()));
    assert_eq!(saved_empty.rows[0][3], Value::Null);
    assert_eq!(saved_empty.rows[0][4], Value::Text("[]".into()));
    assert_ne!(saved_empty.rows[0][5], Value::Null);
    assert_eq!(
        connection
            .query("SELECT encode(array_send(labels), 'hex') FROM enum_array_grid.items WHERE id = 1")
            .await
            .unwrap()
            .rows[0][0],
        sibling_wire
    );
}

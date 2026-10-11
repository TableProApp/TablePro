use std::str::FromStr;

use uuid::Uuid;

use tablepro_core::Value;

use super::{array_contract, connect, date_contract, interval_contract, start_pg, time_contract, vector_contract};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_intervals_preserve_independent_fields_in_every_style() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    interval_contract::assert_interval_contract(connection.as_ref()).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_temporal_infinities_remain_distinct_from_null() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    for kind in ["date", "timestamp", "timestamptz"] {
        let table = format!("temporal_infinity_csv_{kind}");
        connection
            .execute(&format!("CREATE TABLE {table} (value {kind} NOT NULL)"))
            .await
            .unwrap();
        let columns = connection.fetch_columns(None, &table).await.unwrap();
        let options = tablepro_core::import::CsvImportOptions::default();
        let mapping = [Some(0)];
        let mut expected_csv_imports = Vec::new();
        for input in ["infinity", "-infinity"] {
            let result = connection
                .query(&format!("SELECT '{input}'::{kind} AS value"))
                .await
                .unwrap();
            assert_eq!(result.rows, vec![vec![Value::Text(input.into())]]);
            let value = &result.rows[0][0];
            let literal = tablepro_core::sql_literal::render_sql_literal("postgres", value).unwrap();
            let restored = connection.query(&format!("SELECT {literal}::{kind}")).await.unwrap();
            assert_eq!(restored.rows, result.rows);
            let bound = connection
                .query_params(&format!("SELECT $1::text::{kind}"), std::slice::from_ref(value))
                .await
                .unwrap();
            assert_eq!(bound.rows, result.rows);
            assert_eq!(
                tablepro_core::export::row_to_json(&result.columns, &result.rows[0])["value"],
                input
            );
            let csv = tablepro_core::export::render_csv(
                &result.columns,
                &result.rows,
                &tablepro_core::export::CsvOptions::default(),
            );
            let sheet = tablepro_core::import::read_csv(
                csv.as_bytes(),
                &tablepro_core::import::CsvImportOptions::default(),
                None,
            )
            .unwrap();
            let expected_csv_cell = if input.starts_with(['+', '-']) {
                format!("'{input}")
            } else {
                input.to_owned()
            };
            assert_eq!(
                sheet.rows[0][0], expected_csv_cell,
                "default CSV formula safety marker for PostgreSQL {kind} {input}"
            );

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
            expected_csv_imports.push(vec![Value::Text(input.into())]);
            let restored = connection
                .query(&format!("SELECT value::text FROM {table} ORDER BY value::text"))
                .await
                .unwrap();
            let mut expected = expected_csv_imports.clone();
            expected.sort_by(|left, right| match (&left[0], &right[0]) {
                (Value::Text(left), Value::Text(right)) => left.cmp(right),
                _ => std::cmp::Ordering::Equal,
            });
            assert_eq!(restored.rows, expected, "native {kind} CSV re-import");
        }
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_wide_numeric_csv_round_trips_through_native_insert_plan() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let wide = "1234567890123456789012345678901234567890";
    connection
        .execute(
            "CREATE TABLE numeric_csv_source (id integer PRIMARY KEY, amount numeric(65, 0), marker text NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO numeric_csv_source VALUES (1, 12, 'narrow'), (2, {wide}, 'wide'), (3, NULL, 'null')"
        ))
        .await
        .unwrap();
    let source = connection
        .query("SELECT amount, marker FROM numeric_csv_source ORDER BY id")
        .await
        .unwrap();
    let csv = tablepro_core::export::render_csv(
        &source.columns,
        &source.rows,
        &tablepro_core::export::CsvOptions::default(),
    );
    let sheet = tablepro_core::import::read_csv(
        csv.as_bytes(),
        &tablepro_core::import::CsvImportOptions::default(),
        None,
    )
    .unwrap();

    connection
        .execute(
            "CREATE TABLE numeric_csv_target (id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, amount numeric(65, 0), marker text NOT NULL)",
        )
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "numeric_csv_target").await.unwrap();
    let mapping = [None, Some(0), Some(1)];
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: "numeric_csv_target",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &tablepro_core::import::CsvImportOptions::default(),
    )
    .unwrap();
    assert!(plan.statement.contains("$1::text::pg_catalog.numeric"));
    assert_eq!(
        plan.rows,
        vec![
            vec![Value::Text("12".into()), Value::Text("narrow".into())],
            vec![Value::Text(wide.into()), Value::Text("wide".into())],
            vec![Value::Null, Value::Text("null".into())],
        ]
    );
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }

    let restored = connection
        .query("SELECT amount::text, marker FROM numeric_csv_target ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        restored.rows,
        vec![
            vec![Value::Text("12".into()), Value::Text("narrow".into())],
            vec![Value::Text(wide.into()), Value::Text("wide".into())],
            vec![Value::Null, Value::Text("null".into())],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_postgres_money_is_refused_with_exact_server_oracle() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let result = connection
        .query(
            "SELECT amount, pg_typeof(amount)::text AS native_type, \
             amount::numeric::text AS exact_value, \
             amount::numeric = 12345.67::numeric AS server_match \
             FROM (SELECT 12345.67::numeric::money AS amount) source",
        )
        .await
        .unwrap();

    assert!(matches!(result.rows[0][0], Value::Undecodable(_)));
    assert_eq!(result.rows[0][1], Value::Text("money".into()));
    assert_eq!(result.rows[0][2], Value::Text("12345.67".into()));
    assert_eq!(result.rows[0][3], Value::Bool(true));
    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &result.rows[0][0]).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(&result.rows[0][0]))
            .await
            .is_err()
    );

    let null = connection.query("SELECT NULL::money").await.unwrap();
    assert_eq!(null.rows, vec![vec![Value::Null]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_geometric_types_keep_native_oracles_when_projection_is_refused() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let cases = [
        ("point", "'(1,2)'::point"),
        ("line", "'{1,2,3}'::line"),
        ("lseg", "'[(1,2),(3,4)]'::lseg"),
        ("box", "'(3,4),(1,2)'::box"),
        ("path", "'((1,2),(3,4))'::path"),
        ("polygon", "'((1,2),(3,4),(5,6))'::polygon"),
        ("circle", "'<(1,2),3>'::circle"),
    ];

    for (native_type, expression) in cases {
        let oracle = connection
            .query(&format!("SELECT pg_typeof({expression})::text, ({expression})::text"))
            .await
            .unwrap();
        assert_eq!(oracle.rows[0][0], Value::Text(native_type.into()));
        let exact_native_text = oracle.rows[0][1].clone();

        let projected = connection
            .query(&format!("SELECT {expression} AS value"))
            .await
            .unwrap_or_else(|error| {
                panic!("{native_type} should reach the value decoder: {error:?}; native text: {exact_native_text:?}")
            });
        assert_eq!(projected.rows.len(), 1);
        assert!(
            matches!(&projected.rows[0][0], Value::Undecodable(name) if name.eq_ignore_ascii_case(native_type)),
            "{native_type} projection must be explicit, not lossy: {:?}; native text: {exact_native_text:?}",
            projected.rows[0][0]
        );
        assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &projected.rows[0][0]).is_err());
        assert!(
            connection
                .query_params("SELECT $1", std::slice::from_ref(&projected.rows[0][0]))
                .await
                .is_err()
        );

        let null = connection
            .query(&format!("SELECT NULL::{native_type} AS value"))
            .await
            .unwrap();
        assert_eq!(null.rows, vec![vec![Value::Null]], "{native_type}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_citext_preserves_label_and_case_insensitive_comparison() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection.execute("CREATE EXTENSION citext").await.unwrap();
    let original = "MixedCase@example.test";
    let result = connection
        .query(&format!(
            "SELECT value, value::text AS exact_text, \
             value = 'mixedcase@example.test'::citext AS case_insensitive_match \
             FROM (SELECT '{original}'::citext AS value) source"
        ))
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Text(original.into()),
            Value::Text(original.into()),
            Value::Bool(true),
        ]]
    );

    let value = Value::Text(original.into());
    let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &value).unwrap();
    let literal_result = connection
        .query(&format!("SELECT {literal}::citext::text"))
        .await
        .unwrap();
    assert_eq!(literal_result.rows, vec![vec![Value::Text(original.into())]]);

    let bound_result = connection
        .query_params("SELECT $1::citext::text", &[value])
        .await
        .unwrap();
    assert_eq!(bound_result.rows, vec![vec![Value::Text(original.into())]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_varbit_preserves_leading_zero_bits_across_consumers() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let bits = "0010110101110001".repeat(5);
    let result = connection
        .query(&format!(
            "SELECT value, pg_typeof(value)::text AS native_type, value::text AS exact_text, \
             bit_length(value) AS bit_count, value = B'{bits}'::varbit AS server_match \
             FROM (SELECT B'{bits}'::varbit AS value) source"
        ))
        .await
        .unwrap();
    assert_eq!(
        result.rows[0],
        vec![
            Value::Text(bits.clone()),
            Value::Text("bit varying".into()),
            Value::Text(bits.clone()),
            Value::Int(80),
            Value::Bool(true),
        ]
    );

    let value = Value::Text(bits.clone());
    let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &value).unwrap();
    let literal_result = connection
        .query(&format!("SELECT {literal}::varbit::text"))
        .await
        .unwrap();
    assert_eq!(literal_result.rows, vec![vec![Value::Text(bits.clone())]]);
    let bound_result = connection
        .query_params("SELECT $1::text::varbit::text", &[value])
        .await
        .unwrap();
    assert_eq!(bound_result.rows, vec![vec![Value::Text(bits)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_macaddr_preserves_exact_text_across_consumers() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let result = connection
        .query(
            "SELECT value, pg_typeof(value)::text AS native_type, value::text AS exact_text, \
             encode(macaddr_send(value), 'hex') AS wire_hex \
             FROM (SELECT '08:00:2b:01:02:03'::macaddr AS value) source",
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows[0],
        vec![
            Value::Text("08:00:2b:01:02:03".into()),
            Value::Text("macaddr".into()),
            Value::Text("08:00:2b:01:02:03".into()),
            Value::Text("08002b010203".into()),
        ]
    );

    let value = Value::Text("08:00:2b:01:02:03".into());
    let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &value).unwrap();
    let literal_result = connection
        .query(&format!("SELECT {literal}::macaddr::text"))
        .await
        .unwrap();
    assert_eq!(literal_result.rows, vec![vec![Value::Text("08:00:2b:01:02:03".into())]]);
    let bound_result = connection
        .query_params("SELECT $1::text::macaddr::text", &[value])
        .await
        .unwrap();
    assert_eq!(bound_result.rows, vec![vec![Value::Text("08:00:2b:01:02:03".into())]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_macaddr8_preserves_eui64_text_across_consumers() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let result = connection
        .query(
            "SELECT value, pg_typeof(value)::text AS native_type, value::text AS exact_text, \
             encode(macaddr8_send(value), 'hex') AS wire_hex \
             FROM (SELECT '08:00:2b:ff:fe:01:02:03'::macaddr8 AS value) source",
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows[0],
        vec![
            Value::Text("08:00:2b:ff:fe:01:02:03".into()),
            Value::Text("macaddr8".into()),
            Value::Text("08:00:2b:ff:fe:01:02:03".into()),
            Value::Text("08002bfffe010203".into()),
        ]
    );

    let value = Value::Text("08:00:2b:ff:fe:01:02:03".into());
    let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &value).unwrap();
    let literal_result = connection
        .query(&format!("SELECT {literal}::macaddr8::text"))
        .await
        .unwrap();
    assert_eq!(
        literal_result.rows,
        vec![vec![Value::Text("08:00:2b:ff:fe:01:02:03".into())]]
    );
    let bound_result = connection
        .query_params("SELECT $1::text::macaddr8::text", &[value])
        .await
        .unwrap();
    assert_eq!(
        bound_result.rows,
        vec![vec![Value::Text("08:00:2b:ff:fe:01:02:03".into())]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_inet_and_cidr_preserve_ipv6_prefix_semantics() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    for (kind, source, expected, host, network) in [
        (
            "inet",
            "2001:db8::1/64",
            "2001:db8::1/64",
            "2001:db8::1",
            "2001:db8::/64",
        ),
        ("cidr", "2001:db8::/64", "2001:db8::/64", "2001:db8::", "2001:db8::/64"),
    ] {
        let result = connection
            .query(&format!(
                "SELECT value, pg_typeof(value)::text AS native_type, value::text AS exact_text, \
                 host(value::inet) AS host_address, network(value::inet)::text AS network_text, \
                 masklen(value::inet) AS prefix_length \
                 FROM (SELECT '{source}'::{kind} AS value) source"
            ))
            .await
            .unwrap();
        assert_eq!(
            result.rows,
            vec![vec![
                Value::Text(expected.into()),
                Value::Text(kind.into()),
                Value::Text(expected.into()),
                Value::Text(host.into()),
                Value::Text(network.into()),
                Value::Int(64),
            ]]
        );

        let value = Value::Text(expected.into());
        let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &value).unwrap();
        let literal_result = connection
            .query(&format!("SELECT {literal}::{kind}::text"))
            .await
            .unwrap();
        assert_eq!(literal_result.rows, vec![vec![Value::Text(expected.into())]]);
        let bound_result = connection
            .query_params(&format!("SELECT $1::text::{kind}::text"), &[value])
            .await
            .unwrap();
        assert_eq!(bound_result.rows, vec![vec![Value::Text(expected.into())]]);
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_pg_lsn_maximum_preserves_text_and_wire_identity() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let result = connection
        .query(
            "SELECT value, pg_typeof(value)::text AS native_type, value::text AS exact_text, \
             encode(pg_lsn_send(value), 'hex') AS wire_hex, \
             value = 'FFFFFFFF/FFFFFFFF'::pg_lsn AS server_match \
             FROM (SELECT 'FFFFFFFF/FFFFFFFF'::pg_lsn AS value) source",
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows[0],
        vec![
            Value::Text("FFFFFFFF/FFFFFFFF".into()),
            Value::Text("pg_lsn".into()),
            Value::Text("FFFFFFFF/FFFFFFFF".into()),
            Value::Text("ffffffffffffffff".into()),
            Value::Bool(true),
        ]
    );

    let value = Value::Text("FFFFFFFF/FFFFFFFF".into());
    let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &value).unwrap();
    let literal_result = connection
        .query(&format!("SELECT {literal}::pg_lsn::text"))
        .await
        .unwrap();
    assert_eq!(literal_result.rows, vec![vec![Value::Text("FFFFFFFF/FFFFFFFF".into())]]);
    let bound_result = connection
        .query_params("SELECT $1::text::pg_lsn::text", &[value])
        .await
        .unwrap();
    assert_eq!(bound_result.rows, vec![vec![Value::Text("FFFFFFFF/FFFFFFFF".into())]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_uuid_domain_preserves_uuid_across_consumers() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE DOMAIN value_contract_uuid_domain AS uuid")
        .await
        .unwrap();
    let expected = Uuid::from_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
    let expected_text = expected.to_string();

    let result = connection
        .query(&format!(
            "SELECT value, value::uuid::text AS uuid_text, pg_typeof(value)::text AS domain_type \
             FROM (SELECT '{expected_text}'::value_contract_uuid_domain AS value) source"
        ))
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Uuid(expected),
            Value::Text(expected_text.clone()),
            Value::Text("value_contract_uuid_domain".into()),
        ]]
    );

    let value = Value::Uuid(expected);
    let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &value).unwrap();
    let literal_result = connection
        .query(&format!("SELECT {literal}::value_contract_uuid_domain::uuid::text"))
        .await
        .unwrap();
    assert_eq!(literal_result.rows, vec![vec![Value::Text(expected_text.clone())]]);

    let bound_result = connection
        .query_params("SELECT $1::value_contract_uuid_domain::uuid::text", &[value])
        .await
        .unwrap();
    assert_eq!(bound_result.rows, vec![vec![Value::Text(expected_text)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_jsonb_domain_keeps_json_null_distinct_from_sql_null() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE DOMAIN value_contract_jsonb_domain AS jsonb")
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT 'null'::value_contract_jsonb_domain AS json_value, \
             NULL::value_contract_jsonb_domain AS sql_null, \
             pg_typeof('null'::value_contract_jsonb_domain)::text AS domain_type, \
             jsonb_typeof('null'::value_contract_jsonb_domain::jsonb) AS json_kind, \
             ('null'::value_contract_jsonb_domain) IS NULL AS json_is_sql_null, \
             (NULL::value_contract_jsonb_domain) IS NULL AS sql_is_null",
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows[0],
        vec![
            Value::Json(serde_json::Value::Null),
            Value::Null,
            Value::Text("value_contract_jsonb_domain".into()),
            Value::Text("null".into()),
            Value::Bool(false),
            Value::Bool(true),
        ]
    );

    let json_null = Value::Json(serde_json::Value::Null);
    let literal = tablepro_core::sql_literal::render_sql_literal("postgres", &json_null).unwrap();
    let literal_result = connection
        .query(&format!("SELECT {literal}::value_contract_jsonb_domain::jsonb"))
        .await
        .unwrap();
    assert_eq!(literal_result.rows, vec![vec![Value::Json(serde_json::Value::Null)]]);

    let bound_json = connection
        .query_params(
            "SELECT $1::value_contract_jsonb_domain::jsonb",
            std::slice::from_ref(&json_null),
        )
        .await
        .unwrap();
    assert_eq!(bound_json.rows, vec![vec![Value::Json(serde_json::Value::Null)]]);
    let bound_sql_null = connection
        .query_params("SELECT $1::value_contract_jsonb_domain", &[Value::Null])
        .await
        .unwrap();
    assert_eq!(bound_sql_null.rows, vec![vec![Value::Null]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_int4range_is_explicitly_unsupported() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let result = connection
        .query(
            "SELECT value, pg_typeof(value)::text AS native_type, value::text AS exact_text, \
             lower(value) AS lower_bound, upper(value) AS upper_bound, \
             lower_inc(value) AS lower_inclusive, upper_inc(value) AS upper_inclusive \
             FROM (SELECT int4range(1, 5, '[)') AS value) source",
        )
        .await
        .unwrap();
    let row = &result.rows[0];
    assert!(matches!(row[0], Value::Undecodable(_)), "{:?}", row[0]);
    assert_eq!(row[1], Value::Text("int4range".into()));
    assert_eq!(row[2], Value::Text("[1,5)".into()));
    assert_eq!(row[3], Value::Int(1));
    assert_eq!(row[4], Value::Int(5));
    assert_eq!(row[5], Value::Bool(true));
    assert_eq!(row[6], Value::Bool(false));
    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &row[0]).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(&row[0]))
            .await
            .is_err()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_int4multirange_is_explicitly_undecodable() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let result = connection
        .query(
            "SELECT pg_typeof(value)::text AS native_type, value::text AS exact_text, \
             range_merge(value)::text AS hull, \
             (SELECT count(*) FROM unnest(value) AS component) AS component_count \
             FROM (SELECT '{[1,3),[5,8)}'::int4multirange AS value) source",
        )
        .await
        .unwrap();
    let row = &result.rows[0];
    assert_eq!(row[0], Value::Text("int4multirange".into()));
    assert_eq!(row[1], Value::Text("{[1,3),[5,8)}".into()));
    assert_eq!(row[2], Value::Text("[1,8)".into()));
    assert_eq!(row[3], Value::Int(2));

    let direct_projection = connection
        .query("SELECT '{[1,3),[5,8)}'::int4multirange")
        .await
        .expect("multirange metadata should resolve to the value decoder");
    let value = &direct_projection.rows[0][0];
    assert!(
        matches!(value, Value::Undecodable(name) if name.eq_ignore_ascii_case("int4multirange")),
        "{value:?}"
    );
    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", value).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(value))
            .await
            .is_err()
    );

    let null = connection.query("SELECT NULL::int4multirange").await.unwrap();
    assert_eq!(null.rows, vec![vec![Value::Null]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_remaining_builtin_multiranges_are_undecodable_with_native_oracles() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let cases = [
        (
            "'{[1,3),[5,8)}'::int8multirange",
            "int8multirange",
            "{[1,3),[5,8)}",
            "[1,8)",
        ),
        (
            "'{[1.25,3.5),[5,8)}'::nummultirange",
            "nummultirange",
            "{[1.25,3.5),[5,8)}",
            "[1.25,8)",
        ),
        (
            "'{[2024-01-01,2024-02-01),[2024-03-01,2024-04-01)}'::datemultirange",
            "datemultirange",
            "{[2024-01-01,2024-02-01),[2024-03-01,2024-04-01)}",
            "[2024-01-01,2024-04-01)",
        ),
        (
            "'{[\"2024-01-01 00:00:00\",\"2024-02-01 00:00:00\"),[\"2024-03-01 00:00:00\",\"2024-04-01 00:00:00\")}'::tsmultirange",
            "tsmultirange",
            "{[\"2024-01-01 00:00:00\",\"2024-02-01 00:00:00\"),[\"2024-03-01 00:00:00\",\"2024-04-01 00:00:00\")}",
            "[\"2024-01-01 00:00:00\",\"2024-04-01 00:00:00\")",
        ),
        (
            "'{[\"2024-01-01 00:00:00+00\",\"2024-02-01 00:00:00+00\"),[\"2024-03-01 00:00:00+00\",\"2024-04-01 00:00:00+00\")}'::tstzmultirange",
            "tstzmultirange",
            "{[\"2024-01-01 00:00:00+00\",\"2024-02-01 00:00:00+00\"),[\"2024-03-01 00:00:00+00\",\"2024-04-01 00:00:00+00\")}",
            "[\"2024-01-01 00:00:00+00\",\"2024-04-01 00:00:00+00\")",
        ),
    ];

    for (expression, expected_type, expected_text, expected_hull) in cases {
        let oracle = connection
            .query(&format!(
                "SELECT pg_typeof(value)::text, value::text, range_merge(value)::text, \
                 (SELECT count(*) FROM unnest(value) AS component)::bigint \
                 FROM (SELECT {expression} AS value) source"
            ))
            .await
            .unwrap_or_else(|error| panic!("native multirange oracle for {expected_type}: {error:?}"));
        assert_eq!(
            oracle.rows[0],
            vec![
                Value::Text(expected_type.into()),
                Value::Text(expected_text.into()),
                Value::Text(expected_hull.into()),
                Value::Int(2),
            ],
            "independent PostgreSQL oracle for {expected_type}"
        );

        let projection = connection
            .query(&format!("SELECT {expression}"))
            .await
            .unwrap_or_else(|error| panic!("{expected_type} must reach the value decoder: {error:?}"));
        let value = &projection.rows[0][0];
        assert!(
            matches!(value, Value::Undecodable(name) if name.eq_ignore_ascii_case(expected_type)),
            "{expected_type} must remain explicit and lossless: {value:?}"
        );
        assert!(tablepro_core::sql_literal::render_sql_literal("postgres", value).is_err());
        assert!(
            connection
                .query_params("SELECT $1", std::slice::from_ref(value))
                .await
                .is_err()
        );

        let null = connection
            .query(&format!("SELECT NULL::{expected_type}"))
            .await
            .unwrap_or_else(|error| panic!("SQL NULL oracle for {expected_type}: {error:?}"));
        assert_eq!(null.rows, vec![vec![Value::Null]], "{expected_type}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_tstzrange_is_explicitly_unsupported() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection.execute("SET TIME ZONE 'UTC'").await.unwrap();
    let result = connection
        .query(
            "SELECT value, pg_typeof(value)::text AS native_type, value::text AS exact_text, \
             lower(value)::text AS lower_text, upper(value)::text AS upper_text, \
             lower_inc(value) AS lower_inclusive, upper_inc(value) AS upper_inclusive \
             FROM (SELECT tstzrange(\
               '2024-01-02 03:04:05.123456+02', \
               '2024-01-02 04:05:06.654321+02', '[)') AS value) source",
        )
        .await
        .unwrap();
    let row = &result.rows[0];
    assert!(matches!(row[0], Value::Undecodable(_)), "{:?}", row[0]);
    assert_eq!(row[1], Value::Text("tstzrange".into()));
    assert_eq!(
        row[2],
        Value::Text("[\"2024-01-02 01:04:05.123456+00\",\"2024-01-02 02:05:06.654321+00\")".into())
    );
    assert_eq!(row[3], Value::Text("2024-01-02 01:04:05.123456+00".into()));
    assert_eq!(row[4], Value::Text("2024-01-02 02:05:06.654321+00".into()));
    assert_eq!(row[5], Value::Bool(true));
    assert_eq!(row[6], Value::Bool(false));
    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &row[0]).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(&row[0]))
            .await
            .is_err()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_builtin_range_families_are_refused_without_losing_native_text() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let cases = [
        (
            "daterange(DATE '2024-01-01', DATE '2024-02-01', '[)')",
            "daterange",
            "[2024-01-01,2024-02-01)",
            "2024-01-01",
            "2024-02-01",
            true,
            false,
        ),
        (
            "numrange(1.25::numeric, 9.75::numeric, '[]')",
            "numrange",
            "[1.25,9.75]",
            "1.25",
            "9.75",
            true,
            true,
        ),
        (
            "tsrange(TIMESTAMP '2024-01-02 03:04:05.123456', TIMESTAMP '2024-01-02 04:05:06.654321', '()')",
            "tsrange",
            "(\"2024-01-02 03:04:05.123456\",\"2024-01-02 04:05:06.654321\")",
            "2024-01-02 03:04:05.123456",
            "2024-01-02 04:05:06.654321",
            false,
            false,
        ),
        ("int8range(1, 5, '(]')", "int8range", "[2,6)", "2", "6", true, false),
    ];

    for (expression, native_type, exact_text, lower, upper, lower_inclusive, upper_inclusive) in cases {
        let result = connection
            .query(&format!(
                "SELECT value, pg_typeof(value)::text AS native_type, value::text AS exact_text, \
                 lower(value)::text AS lower_text, upper(value)::text AS upper_text, \
                 lower_inc(value) AS lower_inclusive, upper_inc(value) AS upper_inclusive \
                 FROM (SELECT {expression} AS value) source"
            ))
            .await
            .unwrap();
        let row = &result.rows[0];
        assert!(matches!(row[0], Value::Undecodable(_)), "{native_type}: {:?}", row[0]);
        assert_eq!(row[1], Value::Text(native_type.into()), "{native_type}");
        assert_eq!(row[2], Value::Text(exact_text.into()), "{native_type}");
        assert_eq!(row[3], Value::Text(lower.into()), "{native_type}");
        assert_eq!(row[4], Value::Text(upper.into()), "{native_type}");
        assert_eq!(row[5], Value::Bool(lower_inclusive), "{native_type}");
        assert_eq!(row[6], Value::Bool(upper_inclusive), "{native_type}");
        assert!(
            tablepro_core::sql_literal::render_sql_literal("postgres", &row[0]).is_err(),
            "{native_type} must not produce a lossy SQL literal"
        );
        assert!(
            connection
                .query_params("SELECT $1", std::slice::from_ref(&row[0]))
                .await
                .is_err(),
            "{native_type} must not be rebound as a lossy parameter"
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_composite_result_is_explicitly_unsupported() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE TYPE value_contract_pair AS (id bigint, label text)")
        .await
        .unwrap();
    let result = connection
        .query(
            "SELECT pair, pg_typeof(pair)::text AS native_type, row_to_json(pair)::text AS json_text, \
             (pair).id AS id_oracle, (pair).label AS label_oracle \
             FROM (SELECT ROW(9007199254740993, '東京')::value_contract_pair AS pair) source",
        )
        .await
        .unwrap();
    let row = &result.rows[0];
    assert!(matches!(row[0], Value::Undecodable(_)), "{:?}", row[0]);
    assert_eq!(row[1], Value::Text("value_contract_pair".into()));
    assert_eq!(
        row[2],
        Value::Text("{\"id\":9007199254740993,\"label\":\"東京\"}".into())
    );
    assert_eq!(row[3], Value::Int(9_007_199_254_740_993));
    assert_eq!(row[4], Value::Text("東京".into()));
    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &row[0]).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(&row[0]))
            .await
            .is_err()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_dates_preserve_eras_large_years_and_instants() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    date_contract::assert_date_contract(connection.as_ref()).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_times_preserve_midnight_fraction_and_offset() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    time_contract::assert_time_contract(connection.as_ref()).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_arrays_preserve_elements_dimensions_and_exports() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    array_contract::assert_array_contract(connection.as_ref()).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_vectors_keep_space_separated_elements_through_exports() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    vector_contract::assert_vector_contract(connection.as_ref()).await;
}

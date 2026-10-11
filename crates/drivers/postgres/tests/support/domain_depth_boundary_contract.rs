#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{FilterOp, FilterRule, FilterSet, FilterValue, Value};

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_deep_enum_domain_refuses_incompatible_typed_assignments() {
    let (_container, options) = start_pg().await;
    let setup = connect(options.clone()).await;
    let schema = "value_contract_enum_integer_depth";
    setup.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    setup
        .execute(&format!("CREATE TYPE {schema}.state AS ENUM ('ready', 'paused')"))
        .await
        .unwrap();
    let mut base = "state".to_owned();
    for level in 1..=64 {
        let domain = format!("state_domain_{level}");
        setup
            .execute(&format!("CREATE DOMAIN {schema}.{domain} AS {schema}.{base}"))
            .await
            .unwrap();
        base = domain;
    }
    setup
        .execute(&format!(
            "CREATE TABLE {schema}.rows (id integer PRIMARY KEY, state {schema}.{base})"
        ))
        .await
        .unwrap();
    setup
        .execute(&format!("INSERT INTO {schema}.rows VALUES (1, 'ready')"))
        .await
        .unwrap();
    drop(setup);

    let connection = connect(options).await;
    assert_incompatible_enum_assignments_refused(connection.as_ref(), schema).await;
}

async fn assert_incompatible_enum_assignments_refused(connection: &dyn tablepro_core::Connection, schema: &str) {
    let date = chrono::NaiveDate::from_ymd_opt(2000, 1, 2).unwrap();
    let time = chrono::NaiveTime::from_hms_opt(12, 34, 56).unwrap();
    let timestamp = chrono::NaiveDateTime::new(date, time);
    let timestamp_tz = chrono::DateTime::parse_from_rfc3339("2000-01-02T12:34:56+00:00")
        .unwrap()
        .to_utc();
    let cases = [
        (Value::Bool(true), "TRUE"),
        (Value::Int(1), "1"),
        (Value::Float(1.5), "1.5::double precision"),
        (Value::Bytes(vec![1]), "decode('01', 'hex')"),
        (Value::Decimal("1.25".parse().unwrap()), "1.25::numeric"),
        (Value::Date(date), "DATE '2000-01-02'"),
        (Value::Time(time), "TIME '12:34:56'"),
        (Value::DateTime(timestamp), "TIMESTAMP '2000-01-02 12:34:56'"),
        (
            Value::TimestampTz(timestamp_tz),
            "TIMESTAMPTZ '2000-01-02 12:34:56+00:00'",
        ),
        (
            Value::Uuid(uuid::Uuid::nil()),
            "'00000000-0000-0000-0000-000000000000'::uuid",
        ),
        (Value::Json(serde_json::json!({})), "'{}'::jsonb"),
    ];
    let sqlstate = |error: tablepro_core::DriverError| match error {
        tablepro_core::DriverError::Query {
            sqlstate: Some(sqlstate),
            ..
        } => sqlstate,
        other => panic!("expected a native query refusal, got {other:?}"),
    };
    for (value, literal) in cases {
        let native = connection
            .execute(&format!("UPDATE {schema}.rows SET state = {literal} WHERE id = 1"))
            .await
            .unwrap_err();
        let parameterized = connection
            .execute_params(&format!("UPDATE {schema}.rows SET state = $1 WHERE id = 1"), &[value])
            .await
            .unwrap_err();
        let native_state = sqlstate(native);
        let parameterized_state = sqlstate(parameterized);
        assert_eq!(native_state, "42804", "literal {literal}");
        assert_eq!(parameterized_state, native_state, "literal {literal}");
    }
    assert_eq!(
        connection
            .query(&format!("SELECT state::text FROM {schema}.rows WHERE id = 1"))
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Text("ready".into())]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_257_levels_preserve_schema_aware_values() {
    let (_container, options) = start_pg().await;
    let setup = connect(options.clone()).await;
    let schema = "value_contract_257_domains";
    let shadow = "value_contract_257_shadow";
    setup.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    setup
        .execute(&format!("CREATE TYPE {schema}.status AS ENUM ('ready', 'paused')"))
        .await
        .unwrap();
    let mut base = "status".to_owned();
    for level in 1..=257 {
        let domain = format!("status_domain_{level}");
        setup
            .execute(&format!("CREATE DOMAIN {schema}.{domain} AS {schema}.{base}"))
            .await
            .unwrap();
        base = domain;
    }
    setup
        .execute(&format!(
            "CREATE TABLE {schema}.rows (id integer PRIMARY KEY, status {schema}.{base})"
        ))
        .await
        .unwrap();
    setup
        .execute(&format!("INSERT INTO {schema}.rows VALUES (1, 'ready'), (2, NULL)"))
        .await
        .unwrap();
    setup.execute(&format!("CREATE SCHEMA {shadow}")).await.unwrap();
    setup
        .execute(&format!("CREATE TYPE {shadow}.status AS ENUM ('shadow')"))
        .await
        .unwrap();
    setup
        .execute(&format!("ALTER ROLE postgres SET search_path TO {shadow}"))
        .await
        .unwrap();
    drop(setup);

    let connection = connect(options).await;
    assert_eq!(
        connection.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text(shadow.into())]]
    );
    let columns = connection.fetch_columns(Some(schema), "rows").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: "status".into()
        })
    );
    assert_eq!(
        columns[1].domain_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: "status_domain_257".into(),
        })
    );

    let (update, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, Value::Text("paused".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(
        update.contains(&format!("\"{schema}\".\"status_domain_257\"")),
        "{update}"
    );
    connection.execute_params(&update, &params).await.unwrap();

    let raw = connection
        .execute_params(
            &format!("UPDATE {schema}.rows SET status = $1 WHERE id = 1"),
            &[Value::Text("ready".into())],
        )
        .await
        .expect_err("deep raw enum inference remains an explicit refusal");
    assert!(
        matches!(&raw, tablepro_core::DriverError::Unsupported(message) if message.contains("resolvable depth")),
        "{raw:?}"
    );

    let filters = FilterSet {
        rules: vec![FilterRule {
            column: "status".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("paused".into())),
        }],
        ..Default::default()
    };
    let (where_sql, filter_params) = tablepro_core::build_filter_where("postgres", &columns, &filters)
        .unwrap()
        .unwrap();
    let filtered = connection
        .query_params(
            &format!(
                "SELECT id, status::text, pg_typeof(status)::text \
                 FROM {schema}.rows WHERE {where_sql} ORDER BY id"
            ),
            &filter_params,
        )
        .await
        .unwrap();
    assert_eq!(
        filtered.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("paused".into()),
            Value::Text(format!("{schema}.status_domain_257")),
        ]]
    );

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(&format!("SET LOCAL search_path TO {shadow}, public"))
        .await
        .unwrap();
    let (transaction_update, transaction_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, Value::Text("ready".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    transaction
        .execute_params(&transaction_update, &transaction_params)
        .await
        .unwrap();
    let stored = transaction
        .query(&format!(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM {schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("ready".into()),
                Value::Text(format!("{schema}.status_domain_257")),
            ],
            vec![
                Value::Int(2),
                Value::Null,
                Value::Text(format!("{schema}.status_domain_257")),
            ],
        ]
    );
    transaction.rollback().await.unwrap();
    let after_rollback = connection
        .query(&format!(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM {schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(
        after_rollback.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("paused".into()),
                Value::Text(format!("{schema}.status_domain_257")),
            ],
            vec![
                Value::Int(2),
                Value::Null,
                Value::Text(format!("{schema}.status_domain_257")),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_259_levels_preserve_schema_aware_values() {
    let (_container, options) = start_pg().await;
    let setup = connect(options.clone()).await;
    let schema = "value_contract_259_domains";
    let shadow = "value_contract_259_shadow";
    setup.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    setup
        .execute(&format!("CREATE TYPE {schema}.status AS ENUM ('ready', 'paused')"))
        .await
        .unwrap();

    let mut base = "status".to_owned();
    for level in 1..=259 {
        let domain = format!("status_domain_{level}");
        setup
            .execute(&format!("CREATE DOMAIN {schema}.{domain} AS {schema}.{base}"))
            .await
            .unwrap();
        base = domain;
    }
    setup
        .execute(&format!(
            "CREATE TABLE {schema}.rows (id integer PRIMARY KEY, status {schema}.{base})"
        ))
        .await
        .unwrap();
    setup
        .execute(&format!("INSERT INTO {schema}.rows VALUES (1, 'ready'), (2, NULL)"))
        .await
        .unwrap();
    setup.execute(&format!("CREATE SCHEMA {shadow}")).await.unwrap();
    setup
        .execute(&format!("CREATE TYPE {shadow}.status AS ENUM ('shadow')"))
        .await
        .unwrap();
    setup
        .execute(&format!("ALTER ROLE postgres SET search_path TO {shadow}"))
        .await
        .unwrap();
    drop(setup);

    let connection = connect(options).await;
    assert_eq!(
        connection.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text(shadow.into())]]
    );
    let columns = connection.fetch_columns(Some(schema), "rows").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: "status".into(),
        })
    );
    assert_eq!(
        columns[1].domain_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: "status_domain_259".into(),
        })
    );

    let (update, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, Value::Text("paused".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(
        update.contains(&format!("\"{schema}\".\"status_domain_259\"")),
        "{update}"
    );
    connection.execute_params(&update, &params).await.unwrap();

    let filters = FilterSet {
        rules: vec![FilterRule {
            column: "status".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("paused".into())),
        }],
        ..Default::default()
    };
    let (where_sql, filter_params) = tablepro_core::build_filter_where("postgres", &columns, &filters)
        .unwrap()
        .unwrap();
    let rows = connection
        .query_params(
            &format!(
                "SELECT id, status::text, pg_typeof(status)::text \
                 FROM {schema}.rows WHERE {where_sql} ORDER BY id"
            ),
            &filter_params,
        )
        .await
        .unwrap();
    assert_eq!(
        rows.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("paused".into()),
            Value::Text(format!("{schema}.status_domain_259")),
        ]]
    );
    assert_eq!(
        connection
            .query(&format!(
                "SELECT id, status IS NULL, pg_typeof(status)::text \
                 FROM {schema}.rows ORDER BY id"
            ))
            .await
            .unwrap()
            .rows,
        vec![
            vec![
                Value::Int(1),
                Value::Bool(false),
                Value::Text(format!("{schema}.status_domain_259")),
            ],
            vec![
                Value::Int(2),
                Value::Bool(true),
                Value::Text(format!("{schema}.status_domain_259")),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_inferred_enum_array_parameter_respects_domain_depth_boundary() {
    let (_container, options) = start_pg().await;
    let setup = connect(options.clone()).await;
    let schema = "value_contract_enum_array_depth";
    setup.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    setup
        .execute(&format!("CREATE TYPE {schema}.state AS ENUM ('ready', 'paused')"))
        .await
        .unwrap();

    let mut base = "state".to_owned();
    for level in 1..=64 {
        let domain = format!("state_domain_{level}");
        setup
            .execute(&format!("CREATE DOMAIN {schema}.{domain} AS {schema}.{base}"))
            .await
            .unwrap();
        base = domain;
    }
    setup
        .execute(&format!(
            "CREATE TABLE {schema}.rows (\
             id integer PRIMARY KEY, status_62 {schema}.state_domain_62, \
             status_63 {schema}.state_domain_63, status_64 {schema}.state_domain_64)"
        ))
        .await
        .unwrap();
    setup
        .execute(&format!(
            "INSERT INTO {schema}.rows VALUES \
             (1, 'ready', 'ready', 'paused'), (2, 'paused', 'paused', 'ready'), \
             (3, NULL, NULL, NULL)"
        ))
        .await
        .unwrap();
    drop(setup);

    let connection = connect(options).await;
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(&format!("SET LOCAL search_path TO {schema}_shadow, public"))
        .await
        .unwrap();

    transaction.execute("SAVEPOINT native_domain_equality").await.unwrap();
    let native_equality = transaction
        .query(&format!(
            "SELECT status_63 = ANY('{{\"ready\"}}'::{schema}.state_domain_63[]) \
             FROM {schema}.rows WHERE id = 1"
        ))
        .await
        .expect_err("PostgreSQL cannot resolve equality for this deep domain chain");
    assert!(
        matches!(&native_equality, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42883"),
        "expected native missing-operator SQLSTATE 42883, got {native_equality:?}"
    );
    transaction
        .execute("ROLLBACK TO SAVEPOINT native_domain_equality")
        .await
        .unwrap();

    for depth in [62, 63] {
        let status_column = format!("status_{depth}");
        let type_name = format!("{schema}.state_domain_{depth}");
        let array_type = format!("{type_name}[]");
        for (parameter, native_text) in [
            (Value::Text(r#"{"ready","paused"}"#.into()), r#"'{"ready","paused"}'"#),
            (Value::Text(r#"{"ready",NULL}"#.into()), r#"'{"ready",NULL}'"#),
            (Value::Text("{}".into()), "'{}'"),
            (Value::Null, "NULL"),
        ] {
            let native_array = format!("{native_text}::{array_type}");
            let oracle = transaction
                .query(&format!(
                    "SELECT id, ARRAY[{status_column}] <@ {native_array} \
                     FROM {schema}.rows ORDER BY id"
                ))
                .await
                .unwrap();
            let wire = transaction
                .query(&format!("SELECT encode(array_send({native_array}), 'hex')"))
                .await
                .unwrap()
                .rows[0][0]
                .clone();
            let result = transaction
                .query_params(
                    &format!(
                        "SELECT id, ARRAY[{status_column}] <@ $1, pg_typeof($1)::text, \
                         pg_typeof({status_column})::text, encode(array_send($1), 'hex') \
                         FROM {schema}.rows ORDER BY id"
                    ),
                    std::slice::from_ref(&parameter),
                )
                .await
                .unwrap();
            let expected = oracle
                .rows
                .into_iter()
                .map(|row| {
                    vec![
                        row[0].clone(),
                        row[1].clone(),
                        Value::Text(array_type.clone()),
                        Value::Text(type_name.clone()),
                        wire.clone(),
                    ]
                })
                .collect::<Vec<_>>();
            assert_eq!(result.rows, expected, "depth {depth} with {parameter:?}");
        }
    }

    for parameter in [Value::Text(r#"{"ready"}"#.into()), Value::Null] {
        let error = transaction
            .query_params(
                &format!("SELECT ARRAY[status_64] <@ $1 FROM {schema}.rows WHERE id = 1"),
                std::slice::from_ref(&parameter),
            )
            .await
            .expect_err("inferred enum-array parameters at depth 64 must be explicitly refused");
        assert!(
            matches!(&error, tablepro_core::DriverError::Unsupported(message) if message.contains("resolvable depth")),
            "expected the enum-domain depth refusal at depth 64, got {error:?}"
        );
    }

    transaction.rollback().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_deep_enum_scalar_contexts_match_native_inference_at_depth_boundary() {
    let (_container, options) = start_pg().await;
    let setup = connect(options.clone()).await;
    let schema = "value_contract_enum_scalar_depth";
    create_enum_scalar_depth_fixture(setup.as_ref(), schema).await;
    drop(setup);

    let connection = connect(options).await;
    let mut transaction = connection.begin().await.unwrap();
    transaction.execute("SET LOCAL search_path TO public").await.unwrap();
    assert_scalar_contexts_match_native_inference(&mut *transaction, schema, 63).await;
    assert_scalar_contexts_match_native_inference(&mut *transaction, schema, 64).await;
    assert_deep_enum_between_parameters(&mut *transaction, schema, 63).await;
    assert_deep_enum_between_parameters(&mut *transaction, schema, 64).await;
    transaction.rollback().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_deep_enum_scalar_contexts_resolve_under_shadowed_search_path() {
    let (_container, options) = start_pg().await;
    let setup = connect(options.clone()).await;
    let schema = "value_contract_enum_scalar_shadow_depth";
    create_enum_scalar_depth_fixture(setup.as_ref(), schema).await;
    drop(setup);

    let connection = connect(options).await;
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(&format!("SET LOCAL search_path TO {schema}_shadow, public"))
        .await
        .unwrap();
    assert_scalar_contexts_match_native_inference(&mut *transaction, schema, 63).await;
    assert_scalar_contexts_match_native_inference(&mut *transaction, schema, 64).await;
    assert_deep_enum_between_parameters(&mut *transaction, schema, 63).await;
    assert_deep_enum_between_parameters(&mut *transaction, schema, 64).await;
    transaction.rollback().await.unwrap();
}

async fn create_enum_scalar_depth_fixture(connection: &dyn tablepro_core::Connection, schema: &str) {
    connection.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {schema}.state AS ENUM ('ready', 'paused', 'NULL', '')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!("CREATE SCHEMA {schema}_shadow"))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {schema}_shadow.state AS ENUM ('ready', 'paused', 'NULL', '', 'shadow-only')"
        ))
        .await
        .unwrap();
    let mut base = "state".to_owned();
    for level in 1..=64 {
        let domain = format!("state_domain_{level}");
        connection
            .execute(&format!("CREATE DOMAIN {schema}.{domain} AS {schema}.{base}"))
            .await
            .unwrap();
        base = domain;
    }
    connection
        .execute(&format!(
            "CREATE TABLE {schema}.rows (id integer PRIMARY KEY, \
             status_63 {schema}.state_domain_63, status_64 {schema}.state_domain_64)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {schema}.rows VALUES \
             (1, 'ready', 'paused'), (2, NULL, NULL), (3, 'paused', 'ready')"
        ))
        .await
        .unwrap();
}

async fn assert_scalar_contexts_match_native_inference(
    session: &mut dyn tablepro_core::Transaction,
    schema: &str,
    depth: usize,
) {
    for (expression, native_expression) in scalar_contexts(depth) {
        for (parameter, native_parameter) in [
            (Value::Text("paused".into()), "'paused'"),
            (Value::Text("NULL".into()), "'NULL'"),
            (Value::Text(String::new()), "''"),
            (Value::Null, "NULL"),
        ] {
            let native_expression = native_expression.replace("$ARG", native_parameter);
            let native = session
                .query(&format!(
                    "SELECT id, {native_expression}::text, \
                     pg_typeof({native_expression})::text, pg_typeof(status_{depth})::text \
                     FROM {schema}.rows ORDER BY id"
                ))
                .await
                .unwrap();
            let inferred = session
                .query_params(
                    &format!(
                        "SELECT id, {expression}::text, pg_typeof($1)::text, \
                         pg_typeof({expression})::text, pg_typeof(status_{depth})::text \
                         FROM {schema}.rows ORDER BY id"
                    ),
                    std::slice::from_ref(&parameter),
                )
                .await
                .unwrap();
            let expected = native
                .rows
                .into_iter()
                .map(|row| {
                    vec![
                        row[0].clone(),
                        row[1].clone(),
                        Value::Text(format!("{schema}.state")),
                        row[2].clone(),
                        row[3].clone(),
                    ]
                })
                .collect::<Vec<_>>();
            assert_eq!(inferred.rows, expected, "depth {depth}: {expression}, {parameter:?}");
        }
    }
}

async fn assert_deep_enum_between_parameters(session: &mut dyn tablepro_core::Transaction, schema: &str, depth: usize) {
    for parameters in [
        [Value::Text("ready".into()), Value::Text("paused".into())],
        [Value::Text("NULL".into()), Value::Text(String::new())],
        [Value::Null, Value::Text("paused".into())],
    ] {
        session.execute("SAVEPOINT between_contract").await.unwrap();
        let native = session
            .query(&format!(
                "SELECT status_{depth} BETWEEN 'ready' AND 'paused' FROM {schema}.rows"
            ))
            .await
            .expect_err("PostgreSQL does not resolve BETWEEN over a domain-over-enum");
        session.execute("ROLLBACK TO SAVEPOINT between_contract").await.unwrap();
        let inferred = session
            .query_params(
                &format!("SELECT status_{depth} BETWEEN $1 AND $2 FROM {schema}.rows"),
                &parameters,
            )
            .await
            .expect_err("parameterized BETWEEN must not invent domain comparison support");
        session.execute("ROLLBACK TO SAVEPOINT between_contract").await.unwrap();
        session.execute("RELEASE SAVEPOINT between_contract").await.unwrap();
        assert!(
            matches!(&native, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42883"),
            "depth {depth}: {native:?}"
        );
        assert!(
            matches!(&inferred, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42883"),
            "depth {depth}: {inferred:?}"
        );
        assert_eq!(session.query("SELECT 1").await.unwrap().rows, vec![vec![Value::Int(1)]]);
    }
}

fn scalar_contexts(depth: usize) -> [(String, String); 8] {
    let column = format!("status_{depth}");
    [
        (format!("COALESCE($1, {column})"), format!("COALESCE($ARG, {column})")),
        (format!("COALESCE({column}, $1)"), format!("COALESCE({column}, $ARG)")),
        (
            format!("CASE WHEN id = 1 THEN $1 ELSE {column} END"),
            format!("CASE WHEN id = 1 THEN $ARG ELSE {column} END"),
        ),
        (
            format!("CASE WHEN id = 1 THEN {column} ELSE $1 END"),
            format!("CASE WHEN id = 1 THEN {column} ELSE $ARG END"),
        ),
        (format!("GREATEST($1, {column})"), format!("GREATEST($ARG, {column})")),
        (format!("GREATEST({column}, $1)"), format!("GREATEST({column}, $ARG)")),
        (format!("LEAST($1, {column})"), format!("LEAST($ARG, {column})")),
        (format!("LEAST({column}, $1)"), format!("LEAST({column}, $ARG)")),
    ]
}

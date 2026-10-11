#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{DriverError, OperationControl, QueryResult, Session, Value};
use tokio_util::sync::CancellationToken;

use crate::{connect, start_pg};

async fn session_query(
    session: &mut dyn Session,
    sql: &str,
    params: &[Value],
    control: &OperationControl,
) -> QueryResult {
    session.query_params_controlled(sql, params, control).await.unwrap()
}

async fn create_shadowed_enum_fixture(connection: &dyn tablepro_core::Connection) {
    connection.execute("CREATE SCHEMA enum_session_target").await.unwrap();
    connection.execute("CREATE SCHEMA enum_session_shadow").await.unwrap();
    connection
        .execute("CREATE TYPE enum_session_target.state AS ENUM ('ready', 'paused')")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE enum_session_shadow.state AS ENUM ('shadow-only')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE enum_session_target.rows \
             (id INT PRIMARY KEY, state enum_session_target.state)",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO enum_session_target.rows VALUES (1, 'ready'), (2, 'ready'), (3, 'ready')")
        .await
        .unwrap();
}

async fn assert_session_enum_path(session: &mut dyn Session, control: &OperationControl) {
    session_query(session, "SET search_path = enum_session_shadow, public", &[], control).await;
    assert_eq!(
        session_query(
            session,
            "SELECT current_schema()::text, current_setting('search_path')::text, \
             current_schemas(false)::text",
            &[],
            control,
        )
        .await
        .rows,
        vec![vec![
            Value::Text("enum_session_shadow".into()),
            Value::Text("enum_session_shadow, public".into()),
            Value::Text("{enum_session_shadow,public}".into()),
        ]]
    );
}

async fn assert_session_enum_parameter_oracles(session: &mut dyn Session, control: &OperationControl) {
    let native = session_query(
        session,
        "UPDATE enum_session_target.rows SET state = 'paused'::enum_session_target.state \
         WHERE id = 2 RETURNING state::text, pg_typeof(state)::text",
        &[],
        control,
    )
    .await;
    let bound = session_query(
        session,
        "UPDATE enum_session_target.rows SET state = $1 \
         WHERE id = 1 RETURNING state::text, pg_typeof(state)::text",
        &[Value::Text("paused".into())],
        control,
    )
    .await;
    assert_eq!(bound.rows, native.rows);

    let native_null = session_query(
        session,
        "UPDATE enum_session_target.rows SET state = NULL::enum_session_target.state \
         WHERE id = 2 RETURNING state::text, pg_typeof(state)::text",
        &[],
        control,
    )
    .await;
    let bound_null = session_query(
        session,
        "UPDATE enum_session_target.rows SET state = $1 \
         WHERE id = 1 RETURNING state::text, pg_typeof(state)::text",
        &[Value::Null],
        control,
    )
    .await;
    assert_eq!(bound_null.rows, native_null.rows);
    assert_eq!(
        session_query(
            session,
            "SELECT id, state::text, pg_typeof(state)::text \
             FROM enum_session_target.rows ORDER BY id",
            &[],
            control,
        )
        .await
        .rows,
        vec![
            vec![
                Value::Int(1),
                Value::Null,
                Value::Text("enum_session_target.state".into())
            ],
            vec![
                Value::Int(2),
                Value::Null,
                Value::Text("enum_session_target.state".into())
            ],
            vec![
                Value::Int(3),
                Value::Text("ready".into()),
                Value::Text("enum_session_target.state".into())
            ],
        ]
    );
}

async fn assert_shadow_only_enum_label_is_refused(session: &mut dyn Session, control: &OperationControl) {
    let error = session
        .query_params_controlled(
            "UPDATE enum_session_target.rows SET state = $1 WHERE id = 3",
            &[Value::Text("shadow-only".into())],
            control,
        )
        .await
        .unwrap_err();
    assert!(
        matches!(&error, DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected target enum to reject the shadow-only label with 22P02, got {error:?}"
    );
    assert_eq!(
        session_query(
            session,
            "SELECT state::text, pg_typeof(state)::text \
             FROM enum_session_target.rows WHERE id = 3",
            &[],
            control,
        )
        .await
        .rows,
        vec![vec![
            Value::Text("ready".into()),
            Value::Text("enum_session_target.state".into()),
        ]]
    );
}

async fn assert_session_enum_expression_parameters(session: &mut dyn Session, control: &OperationControl) {
    let enum_type = "enum_session_target.state";
    for (parameter, coalesced, appended) in [
        (
            Value::Text("paused".into()),
            Value::Text("paused".into()),
            r#"["ready","paused"]"#,
        ),
        (Value::Null, Value::Text("ready".into()), r#"["ready",null]"#),
    ] {
        assert_eq!(
            session_query(
                session,
                "SELECT COALESCE($1, state)::text, pg_typeof($1)::text, \
                 pg_typeof(COALESCE($1, state))::text \
                 FROM enum_session_target.rows WHERE id = 3",
                std::slice::from_ref(&parameter),
                control,
            )
            .await
            .rows,
            vec![vec![
                coalesced,
                Value::Text(enum_type.into()),
                Value::Text(enum_type.into()),
            ]]
        );
        assert_eq!(
            session_query(
                session,
                "SELECT array_to_json(array_append(ARRAY[state], $1))::text, \
                 pg_typeof($1)::text, pg_typeof(array_append(ARRAY[state], $1))::text \
                 FROM enum_session_target.rows WHERE id = 3",
                std::slice::from_ref(&parameter),
                control,
            )
            .await
            .rows,
            vec![vec![
                Value::Text(appended.into()),
                Value::Text(enum_type.into()),
                Value::Text(format!("{enum_type}[]")),
            ]]
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_parameter_resolves_without_target_schema_in_session_path() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    create_shadowed_enum_fixture(connection.as_ref()).await;
    let mut session = connection.open_session().await.unwrap();
    let control = OperationControl::new(CancellationToken::new(), None);
    assert_session_enum_path(&mut *session, &control).await;
    assert_session_enum_parameter_oracles(&mut *session, &control).await;
    assert_session_enum_expression_parameters(&mut *session, &control).await;
    assert_shadow_only_enum_label_is_refused(&mut *session, &control).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_parameters_in_coalesce_array_append_and_nullif() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection
        .execute("CREATE SCHEMA value_contract_enum_parameter_context")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_enum_parameter_context.state \
             AS ENUM ('ready', 'paused', 'NULL', '')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_enum_parameter_context.rows \
             (id INT PRIMARY KEY, state value_contract_enum_parameter_context.state)",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO value_contract_enum_parameter_context.rows VALUES (1, 'ready'), (2, NULL)")
        .await
        .unwrap();

    let enum_type = "value_contract_enum_parameter_context.state";
    for (parameter, expected_coalesced, expected_array, expected_fallback) in [
        (
            Value::Text("NULL".into()),
            "NULL",
            r#"["ready","NULL"]"#,
            Value::Text("NULL".into()),
        ),
        (Value::Null, "ready", "[\"ready\",null]", Value::Null),
    ] {
        let coalesced = connection
            .query_params(
                "SELECT COALESCE($1, state)::text, pg_typeof(COALESCE($1, state))::text \
                 FROM value_contract_enum_parameter_context.rows WHERE id = 1",
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(
            coalesced.rows,
            vec![vec![
                Value::Text(expected_coalesced.into()),
                Value::Text(enum_type.into()),
            ]]
        );

        let fallback = connection
            .query_params(
                "SELECT COALESCE(state, $1)::text, pg_typeof(COALESCE(state, $1))::text \
                 FROM value_contract_enum_parameter_context.rows WHERE id = 2",
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(
            fallback.rows,
            vec![vec![expected_fallback, Value::Text(enum_type.into())]]
        );

        let appended = connection
            .query_params(
                "SELECT array_to_json(array_append(ARRAY[state], $1))::text, \
                        pg_typeof(array_append(ARRAY[state], $1))::text \
                 FROM value_contract_enum_parameter_context.rows WHERE id = 1",
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(
            appended.rows,
            vec![vec![
                Value::Text(expected_array.into()),
                Value::Text(format!("{enum_type}[]")),
            ]]
        );
    }

    for (parameter, native_parameter) in [
        (Value::Text("NULL".into()), "'NULL'"),
        (Value::Text(String::new()), "''"),
        (Value::Null, "NULL"),
    ] {
        let native = connection
            .query(&format!(
                "SELECT id, \
                 CASE WHEN id = 1 THEN {native_parameter}::{enum_type} ELSE state END::text, \
                 pg_typeof(CASE WHEN id = 1 THEN {native_parameter}::{enum_type} ELSE state END)::text, \
                 CASE WHEN id = 1 THEN state ELSE {native_parameter}::{enum_type} END::text, \
                 pg_typeof(CASE WHEN id = 1 THEN state ELSE {native_parameter}::{enum_type} END)::text \
                 FROM value_contract_enum_parameter_context.rows ORDER BY id"
            ))
            .await
            .unwrap();
        let inferred = connection
            .query_params(
                "SELECT id, \
                 CASE WHEN id = 1 THEN $1 ELSE state END::text, pg_typeof($1)::text, \
                 pg_typeof(CASE WHEN id = 1 THEN $1 ELSE state END)::text, \
                 CASE WHEN id = 1 THEN state ELSE $1 END::text, \
                 pg_typeof(CASE WHEN id = 1 THEN state ELSE $1 END)::text \
                 FROM value_contract_enum_parameter_context.rows ORDER BY id",
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
                    Value::Text(enum_type.into()),
                    row[2].clone(),
                    row[3].clone(),
                    row[4].clone(),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(inferred.rows, expected, "CASE enum parameter {parameter:?}");

        for (native_expression, inferred_expression) in [
            (
                format!("GREATEST({native_parameter}::{enum_type}, state)"),
                "GREATEST($1, state)",
            ),
            (
                format!("GREATEST(state, {native_parameter}::{enum_type})"),
                "GREATEST(state, $1)",
            ),
            (
                format!("LEAST({native_parameter}::{enum_type}, state)"),
                "LEAST($1, state)",
            ),
            (
                format!("LEAST(state, {native_parameter}::{enum_type})"),
                "LEAST(state, $1)",
            ),
        ] {
            let native = connection
                .query(&format!(
                    "SELECT id, {native_expression}::text, \
                     pg_typeof({native_expression})::text \
                     FROM value_contract_enum_parameter_context.rows ORDER BY id"
                ))
                .await
                .unwrap();
            let inferred = connection
                .query_params(
                    &format!(
                        "SELECT id, {inferred_expression}::text, pg_typeof($1)::text, \
                         pg_typeof({inferred_expression})::text \
                         FROM value_contract_enum_parameter_context.rows ORDER BY id"
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
                        Value::Text(enum_type.into()),
                        row[2].clone(),
                    ]
                })
                .collect::<Vec<_>>();
            assert_eq!(inferred.rows, expected, "{inferred_expression} with {parameter:?}");
        }
    }

    for (parameter, expected_ready) in [
        (Value::Text("ready".into()), Value::Null),
        (Value::Text("paused".into()), Value::Text("ready".into())),
        (Value::Null, Value::Text("ready".into())),
    ] {
        let compared = connection
            .query_params(
                "SELECT id, NULLIF(state, $1)::text, \
                        pg_typeof(NULLIF(state, $1))::text, pg_typeof($1)::text \
                 FROM value_contract_enum_parameter_context.rows ORDER BY id",
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(
            compared.rows,
            vec![
                vec![
                    Value::Int(1),
                    expected_ready,
                    Value::Text(enum_type.into()),
                    Value::Text(enum_type.into()),
                ],
                vec![
                    Value::Int(2),
                    Value::Null,
                    Value::Text(enum_type.into()),
                    Value::Text(enum_type.into()),
                ],
            ],
            "NULLIF parameter {parameter:?}"
        );
    }

    for sql in [
        "SELECT COALESCE($1, state) FROM value_contract_enum_parameter_context.rows WHERE id = 1",
        "SELECT NULLIF(state, $1) FROM value_contract_enum_parameter_context.rows WHERE id = 1",
        "SELECT array_append(ARRAY[state], $1) FROM value_contract_enum_parameter_context.rows WHERE id = 1",
        "SELECT CASE WHEN id = 1 THEN $1 ELSE state END FROM value_contract_enum_parameter_context.rows",
        "SELECT CASE WHEN id = 1 THEN state ELSE $1 END FROM value_contract_enum_parameter_context.rows",
        "SELECT GREATEST($1, state) FROM value_contract_enum_parameter_context.rows",
        "SELECT GREATEST(state, $1) FROM value_contract_enum_parameter_context.rows",
        "SELECT LEAST($1, state) FROM value_contract_enum_parameter_context.rows",
        "SELECT LEAST(state, $1) FROM value_contract_enum_parameter_context.rows",
    ] {
        let error = connection
            .query_params(sql, &[Value::Text("not-a-label".into())])
            .await
            .expect_err("invalid enum text must reach PostgreSQL's enum input validation");
        assert!(
            matches!(&error, DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
            "expected native invalid-enum SQLSTATE 22P02, got {error:?}"
        );
    }

    for parameter in [Value::Int(7), Value::Bool(true)] {
        for sql in [
            "SELECT id FROM value_contract_enum_parameter_context.rows \
             WHERE state IS NOT DISTINCT FROM $1",
            "UPDATE value_contract_enum_parameter_context.rows SET state = $1 WHERE id = 1",
        ] {
            let error = connection
                .query_params(sql, std::slice::from_ref(&parameter))
                .await
                .expect_err("non-text values must not be coerced into a custom enum");
            assert!(
                matches!(&error, DriverError::Query { sqlstate: Some(code), .. } if code == "42883" || code == "42804"),
                "expected PostgreSQL's native type-mismatch refusal for {parameter:?}: {error:?}"
            );
        }
    }

    let unchanged = connection
        .query(
            "SELECT id, state::text, pg_typeof(state)::text \
             FROM value_contract_enum_parameter_context.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        unchanged.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("ready".into()),
                Value::Text(enum_type.into())
            ],
            vec![Value::Int(2), Value::Null, Value::Text(enum_type.into())],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_parameters_resolve_target_under_shadowed_search_path() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let enum_schema = "value_contract_enum_shadowed_context";
    let shadow_schema = "value_contract_enum_shadowed_context_shadow";
    let enum_type = format!("{enum_schema}.state");
    connection
        .execute(&format!("CREATE SCHEMA {enum_schema}"))
        .await
        .unwrap();
    connection
        .execute(&format!("CREATE SCHEMA {shadow_schema}"))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {enum_type} AS ENUM ('ready', 'paused', 'NULL', '')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {shadow_schema}.state AS ENUM ('ready', 'shadow-only')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE {enum_schema}.rows \
             (id INT PRIMARY KEY, state {enum_type})"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {enum_schema}.rows VALUES \
             (1, 'ready'), (2, 'paused'), (3, 'NULL'), (4, ''), (5, NULL)"
        ))
        .await
        .unwrap();

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(&format!("SET LOCAL search_path TO {enum_schema}, public"))
        .await
        .unwrap();
    let warmed = transaction
        .query(&format!(
            "SELECT state::text, pg_typeof(state)::oid = '{enum_type}'::regtype::oid \
             FROM {enum_schema}.rows WHERE id = 1"
        ))
        .await
        .unwrap();
    assert_eq!(warmed.rows, vec![vec![Value::Text("ready".into()), Value::Bool(true)]]);
    transaction
        .execute(&format!(
            "SET LOCAL search_path TO {shadow_schema}, {enum_schema}, public"
        ))
        .await
        .unwrap();

    let expressions = [
        ("COALESCE({p}::{t}, state)", "COALESCE($1, state)"),
        ("COALESCE(state, {p}::{t})", "COALESCE(state, $1)"),
        ("NULLIF({p}::{t}, state)", "NULLIF($1, state)"),
        ("NULLIF(state, {p}::{t})", "NULLIF(state, $1)"),
        ("GREATEST({p}::{t}, state)", "GREATEST($1, state)"),
        ("GREATEST(state, {p}::{t})", "GREATEST(state, $1)"),
        ("LEAST({p}::{t}, state)", "LEAST($1, state)"),
        ("LEAST(state, {p}::{t})", "LEAST(state, $1)"),
    ];
    let parameters = [
        (Value::Text("paused".into()), "'paused'"),
        (Value::Text("NULL".into()), "'NULL'"),
        (Value::Text(String::new()), "''"),
        (Value::Null, "NULL"),
    ];

    for (parameter, native_parameter) in &parameters {
        for (native_template, inferred_expression) in expressions {
            let native_expression = native_template
                .replace("{p}", native_parameter)
                .replace("{t}", &enum_type);
            let native = transaction
                .query(&format!(
                    "SELECT id, {native_expression}::text, \
                     pg_typeof({native_parameter}::{enum_type})::text, \
                     pg_typeof({native_expression})::text, pg_typeof(state)::text \
                     FROM {enum_schema}.rows ORDER BY id"
                ))
                .await
                .unwrap();
            let inferred = transaction
                .query_params(
                    &format!(
                        "SELECT id, {inferred_expression}::text, pg_typeof($1)::text, \
                         pg_typeof({inferred_expression})::text, pg_typeof(state)::text \
                         FROM {enum_schema}.rows ORDER BY id"
                    ),
                    std::slice::from_ref(parameter),
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
                        row[2].clone(),
                        row[3].clone(),
                        row[4].clone(),
                    ]
                })
                .collect::<Vec<_>>();
            assert_eq!(
                inferred.rows, expected,
                "{inferred_expression} with parameter {parameter:?}"
            );
        }
    }

    for (_, inferred_expression) in expressions {
        transaction
            .execute("SAVEPOINT invalid_shadowed_enum_parameter")
            .await
            .unwrap();
        let invalid = transaction
            .query_params(
                &format!("SELECT {inferred_expression} FROM {enum_schema}.rows ORDER BY id"),
                &[Value::Text("shadow-only".into())],
            )
            .await
            .expect_err("inferred enum parameters must resolve against the column's schema");
        assert!(
            matches!(&invalid, DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
            "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT invalid_shadowed_enum_parameter")
            .await
            .unwrap();
    }

    let unchanged = transaction
        .query(&format!(
            "SELECT id, state::text, pg_typeof(state)::text \
             FROM {enum_schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(
        unchanged.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("ready".into()),
                Value::Text(enum_type.clone())
            ],
            vec![
                Value::Int(2),
                Value::Text("paused".into()),
                Value::Text(enum_type.clone())
            ],
            vec![
                Value::Int(3),
                Value::Text("NULL".into()),
                Value::Text(enum_type.clone())
            ],
            vec![
                Value::Int(4),
                Value::Text(String::new()),
                Value::Text(enum_type.clone())
            ],
            vec![Value::Int(5), Value::Null, Value::Text(enum_type)],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_parameters_in_union_and_values_keep_native_type() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let enum_type = "value_contract_enum_set_operation.state";
    connection
        .execute("CREATE SCHEMA value_contract_enum_set_operation")
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {enum_type} AS ENUM ('ready', 'paused', 'NULL', '')"
        ))
        .await
        .unwrap();

    let contexts = [
        (
            "SELECT 1 AS ordinal, {parameter} AS label \
             UNION ALL SELECT 2, 'ready'::{enum_type} ORDER BY ordinal",
            "SELECT 1 AS ordinal, $1 AS label \
             UNION ALL SELECT 2, 'ready'::{enum_type} ORDER BY ordinal",
        ),
        (
            "SELECT 1 AS ordinal, 'ready'::{enum_type} AS label \
             UNION ALL SELECT 2, {parameter} ORDER BY ordinal",
            "SELECT 1 AS ordinal, 'ready'::{enum_type} AS label \
             UNION ALL SELECT 2, $1 ORDER BY ordinal",
        ),
        (
            "SELECT ordinal, label FROM (VALUES (1, {parameter}), \
             (2, 'ready'::{enum_type})) AS candidates(ordinal, label) ORDER BY ordinal",
            "SELECT ordinal, label FROM (VALUES (1, $1), \
             (2, 'ready'::{enum_type})) AS candidates(ordinal, label) ORDER BY ordinal",
        ),
        (
            "SELECT ordinal, label FROM (VALUES (1, 'ready'::{enum_type}), \
             (2, {parameter})) AS candidates(ordinal, label) ORDER BY ordinal",
            "SELECT ordinal, label FROM (VALUES (1, 'ready'::{enum_type}), \
             (2, $1)) AS candidates(ordinal, label) ORDER BY ordinal",
        ),
    ];

    for parameter in [
        Value::Text("paused".into()),
        Value::Text("NULL".into()),
        Value::Text(String::new()),
        Value::Null,
    ] {
        let native_parameter = match &parameter {
            Value::Text(value) => format!("'{}'", value.replace('\'', "''")),
            Value::Null => "NULL".into(),
            other => panic!("unexpected enum parameter: {other:?}"),
        };

        for (native_template, inferred_template) in contexts {
            let native_sql = native_template
                .replace("{parameter}", &format!("{native_parameter}::{enum_type}"))
                .replace("{enum_type}", enum_type);
            let inferred_sql = inferred_template.replace("{enum_type}", enum_type);
            let native = connection
                .query(&format!(
                    "SELECT ordinal, label::text, pg_typeof(label)::text, \
                 encode(enum_send(label), 'hex') FROM ({native_sql}) AS result"
                ))
                .await
                .unwrap();
            let inferred = connection
                .query_params(
                    &format!(
                        "SELECT ordinal, label::text, pg_typeof(label)::text, \
                 encode(enum_send(label), 'hex') FROM ({inferred_sql}) AS result"
                    ),
                    std::slice::from_ref(&parameter),
                )
                .await
                .unwrap();
            assert_eq!(
                inferred.rows, native.rows,
                "SQL: {inferred_sql}, parameter: {parameter:?}"
            );
            assert!(
                inferred
                    .rows
                    .iter()
                    .all(|row| row.get(2) == Some(&Value::Text(enum_type.into()))),
                "inferred enum type changed: {:?}",
                inferred.rows
            );
        }
    }

    for (_, inferred_template) in contexts {
        let inferred_sql = inferred_template.replace("{enum_type}", enum_type);
        let invalid = connection
            .query_params(&inferred_sql, &[Value::Text("not-a-label".into())])
            .await
            .expect_err("invalid inferred enum labels must be rejected by PostgreSQL");
        assert!(
            matches!(&invalid, DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
            "expected native invalid-enum SQLSTATE 22P02 for {inferred_sql}, got {invalid:?}"
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_set_operations_keep_target_type_under_shadowed_search_path() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let target_schema = "value_contract_enum_set_target";
    let shadow_schema = "value_contract_enum_set_shadow";
    let target_type = format!("{target_schema}.state");

    for schema in [target_schema, shadow_schema] {
        connection.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    }
    connection
        .execute(&format!(
            "CREATE TYPE {target_type} AS ENUM ('ready', 'paused', 'NULL', '')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {shadow_schema}.state AS ENUM ('ready', 'shadow-only')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE {target_schema}.rows (id INT PRIMARY KEY, state {target_type})"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!("INSERT INTO {target_schema}.rows VALUES (1, 'ready')"))
        .await
        .unwrap();

    let contexts = [
        "SELECT 1 AS ordinal, $1 AS label \
         UNION ALL SELECT 2, state FROM {target_schema}.rows WHERE id = 1 ORDER BY ordinal",
        "SELECT 1 AS ordinal, state AS label FROM {target_schema}.rows WHERE id = 1 \
         UNION ALL SELECT 2, $1 ORDER BY ordinal",
        "SELECT ordinal, label FROM (VALUES (1, $1), \
         (2, (SELECT state FROM {target_schema}.rows WHERE id = 1))) \
         AS candidates(ordinal, label) ORDER BY ordinal",
        "SELECT ordinal, label FROM (VALUES \
         (1, (SELECT state FROM {target_schema}.rows WHERE id = 1)), (2, $1)) \
         AS candidates(ordinal, label) ORDER BY ordinal",
    ];
    let queries = contexts.map(|sql| sql.replace("{target_schema}", target_schema));
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(&format!("SET LOCAL search_path TO {target_schema}, public"))
        .await
        .unwrap();
    let warmed = transaction
        .query(&format!(
            "SELECT pg_typeof(state)::oid = '{target_type}'::regtype::oid \
             FROM {target_schema}.rows WHERE id = 1"
        ))
        .await
        .unwrap();
    assert_eq!(warmed.rows, vec![vec![Value::Bool(true)]]);

    for sql in &queries {
        transaction
            .query_params(sql, &[Value::Text("paused".into())])
            .await
            .unwrap();
    }
    transaction
        .execute(&format!(
            "SET LOCAL search_path TO {shadow_schema}, {target_schema}, public"
        ))
        .await
        .unwrap();

    for parameter in [
        Value::Text("paused".into()),
        Value::Text("NULL".into()),
        Value::Text(String::new()),
        Value::Null,
    ] {
        for sql in &queries {
            let native_parameter = match &parameter {
                Value::Text(value) => format!("'{}'", value.replace('\'', "''")),
                Value::Null => "NULL".into(),
                other => panic!("unexpected enum parameter: {other:?}"),
            };
            let native_sql = sql.replace("$1", &format!("{native_parameter}::{target_type}"));
            let native = transaction
                .query(&format!(
                    "SELECT ordinal, label::text, \
                     pg_typeof(label)::oid = '{target_type}'::regtype::oid, \
                     encode(enum_send(label), 'hex') FROM ({native_sql}) AS result"
                ))
                .await
                .unwrap();
            let inferred = transaction
                .query_params(
                    &format!(
                        "SELECT ordinal, label::text, \
                         pg_typeof(label)::oid = '{target_type}'::regtype::oid, \
                         encode(enum_send(label), 'hex') FROM ({sql}) AS result"
                    ),
                    std::slice::from_ref(&parameter),
                )
                .await
                .unwrap();
            assert_eq!(inferred.rows, native.rows, "SQL: {sql}, parameter: {parameter:?}");
            assert!(
                inferred.rows.iter().all(|row| row.get(2) == Some(&Value::Bool(true))),
                "result resolved to a shadow enum: {:?}",
                inferred.rows
            );
        }
    }

    for sql in &queries {
        transaction
            .execute("SAVEPOINT invalid_shadow_enum_set_operation")
            .await
            .unwrap();
        let invalid = transaction
            .query_params(sql, &[Value::Text("shadow-only".into())])
            .await
            .expect_err("target-column inference must reject the shadow-only label");
        assert!(
            matches!(&invalid, DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
            "expected target enum SQLSTATE 22P02 for {sql}, got {invalid:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT invalid_shadow_enum_set_operation")
            .await
            .unwrap();
    }
}

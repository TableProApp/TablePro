#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_array_functions_infer_parameter_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_functions")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_array_functions.state \
             AS ENUM ('ready', 'paused')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_array_functions.state_domain \
             AS value_contract_domain_array_functions.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_array_functions.rows \
             (id INT PRIMARY KEY, status value_contract_domain_array_functions.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_array_functions.rows VALUES \
             (1, 'ready'), (2, 'paused'), (3, NULL)",
        )
        .await
        .unwrap();

    for (expression, text_values, null_values) in [
        (
            "array_append(ARRAY[status], $1)",
            [
                r#"["ready","paused"]"#,
                r#"["paused","paused"]"#,
                r#"[null,"paused"]"#,
            ],
            [r#"["ready",null]"#, r#"["paused",null]"#, "[null,null]"],
        ),
        (
            "array_prepend($1, ARRAY[status])",
            [
                r#"["paused","ready"]"#,
                r#"["paused","paused"]"#,
                r#"["paused",null]"#,
            ],
            [r#"[null,"ready"]"#, r#"[null,"paused"]"#, "[null,null]"],
        ),
    ] {
        for (parameter, expected) in [
            (
                Value::Text("paused".into()),
                text_values.map(str::to_owned),
            ),
            (Value::Null, null_values.map(str::to_owned)),
        ] {
            let result = connection
                .query_params(
                    &format!(
                        "SELECT id, array_to_json({expression})::text, \
                         pg_typeof($1)::text, pg_typeof(ARRAY[status])::text, \
                         pg_typeof({expression})::text, pg_typeof(status)::text \
                         FROM value_contract_domain_array_functions.rows ORDER BY id"
                    ),
                    std::slice::from_ref(&parameter),
                )
                .await
                .unwrap();
            assert_eq!(
                result.rows,
                expected
                    .into_iter()
                    .enumerate()
                    .map(|(index, values)| vec![
                        Value::Int(index as i64 + 1),
                        Value::Text(values),
                        Value::Text("value_contract_domain_array_functions.state".into()),
                        Value::Text("value_contract_domain_array_functions.state_domain[]".into()),
                        Value::Text("value_contract_domain_array_functions.state[]".into()),
                        Value::Text("value_contract_domain_array_functions.state_domain".into()),
                    ])
                    .collect::<Vec<_>>(),
                "{expression} with parameter {parameter:?}"
            );
        }
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_array_append_prepend_keep_target_under_shadowed_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_shadowed_array_functions")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_shadowed_array_functions_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_shadowed_array_functions.state \
             AS ENUM ('ready', 'NULL', 'paused')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_shadowed_array_functions_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_shadowed_array_functions.state_domain \
             AS value_contract_shadowed_array_functions.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_shadowed_array_functions.rows \
             (id INT PRIMARY KEY, status value_contract_shadowed_array_functions.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_shadowed_array_functions.rows \
             VALUES (1, 'ready'), (2, 'NULL'), (3, NULL)",
        )
        .await
        .unwrap();

    let schema = "value_contract_shadowed_array_functions";
    let enum_type = format!("{schema}.state");
    let result_array = format!("{schema}.state[]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(
            "SET LOCAL search_path TO value_contract_shadowed_array_functions_shadow, public",
        )
        .await
        .unwrap();

    for (expression, native_function) in [
        (
            "array_append(ARRAY[status], $1)",
            "array_append(ARRAY[status], {value})",
        ),
        (
            "array_prepend($1, ARRAY[status])",
            "array_prepend({value}, ARRAY[status])",
        ),
    ] {
        for (parameter, native_value) in [
            (
                Value::Text("paused".into()),
                format!("'paused'::{enum_type}"),
            ),
            (Value::Text("NULL".into()), format!("'NULL'::{enum_type}")),
            (Value::Null, format!("NULL::{enum_type}")),
        ] {
            let native = transaction
                .query(&format!(
                    "SELECT id, array_to_json({})::text, \
                     pg_typeof({})::text, encode(array_send({}), 'hex') \
                     FROM {schema}.rows ORDER BY id",
                    native_function.replace("{value}", &native_value),
                    native_function.replace("{value}", &native_value),
                    native_function.replace("{value}", &native_value),
                ))
                .await
                .unwrap();
            let result = transaction
                .query_params(
                    &format!(
                        "SELECT id, array_to_json({expression})::text, \
                         pg_typeof($1)::text, pg_typeof({expression})::text, \
                         encode(array_send({expression}), 'hex') \
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
                        Value::Text(enum_type.clone()),
                        Value::Text(result_array.clone()),
                        row[3].clone(),
                    ]
                })
                .collect::<Vec<_>>();
            assert_eq!(result.rows, expected, "{expression} with {parameter:?}");
        }

        transaction.execute("SAVEPOINT invalid_array_function_parameter").await.unwrap();
        let invalid = transaction
            .query_params(
                &format!(
                    "SELECT {expression} FROM {schema}.rows WHERE id = 1"
                ),
                &[Value::Text("shadow-only".into())],
            )
            .await
            .expect_err("a label found only in the shadow enum must be rejected by the target enum");
        assert!(
            matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
            "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT invalid_array_function_parameter")
            .await
            .unwrap();
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_enum_array_remove_infers_scalar_parameter_type() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_remove")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_array_remove.state \
             AS ENUM ('ready', 'paused')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_array_remove.state_domain \
             AS value_contract_domain_array_remove.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_array_remove.rows \
             (id INT PRIMARY KEY, status value_contract_domain_array_remove.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_array_remove.rows VALUES \
             (1, 'ready'), (2, 'paused'), (3, NULL)",
        )
        .await
        .unwrap();

    let array = "ARRAY[status::value_contract_domain_array_remove.state]";
    for (parameter, native_value) in [
        (
            Value::Text("paused".into()),
            "'paused'::value_contract_domain_array_remove.state",
        ),
        (Value::Null, "NULL::value_contract_domain_array_remove.state"),
    ] {
        let native = connection
            .query(&format!(
                "SELECT id, array_to_json(array_remove({array}, {native_value}))::text \
                 FROM value_contract_domain_array_remove.rows ORDER BY id"
            ))
            .await
            .unwrap();
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, array_to_json(array_remove({array}, $1))::text, \
                     pg_typeof($1)::text, pg_typeof(array_remove({array}, $1))::text \
                     FROM value_contract_domain_array_remove.rows ORDER BY id"
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
                    Value::Text("value_contract_domain_array_remove.state".into()),
                    Value::Text("value_contract_domain_array_remove.state[]".into()),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(result.rows, expected, "array_remove with {parameter:?}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_enum_array_position_infers_scalar_parameter_and_matches_null() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_position")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_array_position.state \
             AS ENUM ('ready', 'paused')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_array_position.state_domain \
             AS value_contract_domain_array_position.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_array_position.rows \
             (id INT PRIMARY KEY, status value_contract_domain_array_position.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_array_position.rows VALUES \
             (1, 'ready'), (2, 'paused'), (3, NULL)",
        )
        .await
        .unwrap();

    let array = "ARRAY[status::value_contract_domain_array_position.state]";
    for (parameter, native_value) in [
        (
            Value::Text("paused".into()),
            "'paused'::value_contract_domain_array_position.state",
        ),
        (
            Value::Null,
            "NULL::value_contract_domain_array_position.state",
        ),
    ] {
        let native = connection
            .query(&format!(
                "SELECT id, array_position({array}, {native_value}) \
                 FROM value_contract_domain_array_position.rows ORDER BY id"
            ))
            .await
            .unwrap();
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, array_position({array}, $1), pg_typeof($1)::text, \
                     pg_typeof(array_position({array}, $1))::text \
                     FROM value_contract_domain_array_position.rows ORDER BY id"
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
                    Value::Text("value_contract_domain_array_position.state".into()),
                    Value::Text("integer".into()),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(result.rows, expected, "array_position with {parameter:?}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_enum_array_replace_infers_both_scalar_parameters() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_replace")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_array_replace.state \
             AS ENUM ('ready', 'paused')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_array_replace.state_domain \
             AS value_contract_domain_array_replace.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_array_replace.rows \
             (id INT PRIMARY KEY, status value_contract_domain_array_replace.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_array_replace.rows VALUES \
             (1, 'ready'), (2, 'paused'), (3, NULL)",
        )
        .await
        .unwrap();

    let array = "ARRAY[status::value_contract_domain_array_replace.state]";
    for (search, replacement, native_search, native_replacement) in [
        (
            Value::Text("ready".into()),
            Value::Text("paused".into()),
            "'ready'",
            "'paused'",
        ),
        (
            Value::Null,
            Value::Text("ready".into()),
            "NULL",
            "'ready'",
        ),
        (
            Value::Text("paused".into()),
            Value::Null,
            "'paused'",
            "NULL",
        ),
        (Value::Null, Value::Null, "NULL", "NULL"),
    ] {
        let native = connection
            .query(&format!(
                "SELECT id, array_to_json(array_replace({array}, \
                 {native_search}::value_contract_domain_array_replace.state, \
                 {native_replacement}::value_contract_domain_array_replace.state))::text \
                 FROM value_contract_domain_array_replace.rows ORDER BY id"
            ))
            .await
            .unwrap();
        let result = connection
            .query_params(
                &format!(
                    "SELECT id, array_to_json(array_replace({array}, $1, $2))::text, \
                     pg_typeof($1)::text, pg_typeof($2)::text, \
                     pg_typeof(array_replace({array}, $1, $2))::text \
                     FROM value_contract_domain_array_replace.rows ORDER BY id"
                ),
                &[search.clone(), replacement.clone()],
            )
            .await
            .unwrap();
        let enum_type = Value::Text("value_contract_domain_array_replace.state".into());
        let array_type = Value::Text("value_contract_domain_array_replace.state[]".into());
        let expected = native
            .rows
            .into_iter()
            .map(|row| {
                vec![
                    row[0].clone(),
                    row[1].clone(),
                    enum_type.clone(),
                    enum_type.clone(),
                    array_type.clone(),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(
            result.rows,
            expected,
            "array_replace with {search:?} to {replacement:?}"
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_enum_array_replace_keeps_both_parameters_under_shadowed_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_shadowed_array_replace")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_shadowed_array_replace_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_shadowed_array_replace.state \
             AS ENUM ('ready', 'paused', 'NULL')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_shadowed_array_replace_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_shadowed_array_replace.state_domain \
             AS value_contract_shadowed_array_replace.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_shadowed_array_replace.rows \
             (id INT PRIMARY KEY, status value_contract_shadowed_array_replace.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_shadowed_array_replace.rows \
             VALUES (1, 'ready'), (2, 'paused'), (3, 'NULL'), (4, NULL)",
        )
        .await
        .unwrap();

    let schema = "value_contract_shadowed_array_replace";
    let enum_type = format!("{schema}.state");
    let result_array = format!("{schema}.state[]");
    let array = format!("ARRAY[status::{enum_type}, status::{enum_type}]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(
            "SET LOCAL search_path TO value_contract_shadowed_array_replace_shadow, public",
        )
        .await
        .unwrap();

    for (search, replacement, native_search, native_replacement) in [
        (
            Value::Text("ready".into()),
            Value::Text("paused".into()),
            format!("'ready'::{enum_type}"),
            format!("'paused'::{enum_type}"),
        ),
        (
            Value::Text("NULL".into()),
            Value::Text("ready".into()),
            format!("'NULL'::{enum_type}"),
            format!("'ready'::{enum_type}"),
        ),
        (
            Value::Null,
            Value::Text("paused".into()),
            format!("NULL::{enum_type}"),
            format!("'paused'::{enum_type}"),
        ),
        (
            Value::Text("paused".into()),
            Value::Null,
            format!("'paused'::{enum_type}"),
            format!("NULL::{enum_type}"),
        ),
        (
            Value::Null,
            Value::Null,
            format!("NULL::{enum_type}"),
            format!("NULL::{enum_type}"),
        ),
    ] {
        let native_expression = format!(
            "array_replace({array}, {native_search}, {native_replacement})"
        );
        let native = transaction
            .query(&format!(
                "SELECT id, array_to_json({native_expression})::text, \
                 encode(array_send({native_expression}), 'hex') \
                 FROM {schema}.rows ORDER BY id"
            ))
            .await
            .unwrap();
        let result = transaction
            .query_params(
                &format!(
                    "SELECT id, array_to_json(array_replace({array}, $1, $2))::text, \
                     pg_typeof($1)::text, pg_typeof($2)::text, \
                     pg_typeof(array_replace({array}, $1, $2))::text, \
                     encode(array_send(array_replace({array}, $1, $2)), 'hex') \
                     FROM {schema}.rows ORDER BY id"
                ),
                &[search.clone(), replacement.clone()],
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
                    Value::Text(enum_type.clone()),
                    Value::Text(enum_type.clone()),
                    Value::Text(result_array.clone()),
                    row[2].clone(),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(
            result.rows, expected,
            "array_replace with {search:?} to {replacement:?}"
        );
    }

    for invalid_position in ["$1", "$2"] {
        transaction.execute("SAVEPOINT invalid_replace_parameter").await.unwrap();
        let parameters = if invalid_position == "$1" {
            [Value::Text("shadow-only".into()), Value::Text("ready".into())]
        } else {
            [Value::Text("ready".into()), Value::Text("shadow-only".into())]
        };
        let invalid = transaction
            .query_params(
                &format!(
                    "SELECT array_replace({array}, $1, $2) FROM {schema}.rows WHERE id = 1"
                ),
                &parameters,
            )
            .await
            .expect_err("a label present only in the shadow enum must be rejected");
        assert!(
            matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
            "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT invalid_replace_parameter")
            .await
            .unwrap();
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_enum_array_functions_infer_first_array_parameter_under_shadowed_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_shadowed_array_input")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_shadowed_array_input_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_shadowed_array_input.state \
             AS ENUM ('ready', 'paused', 'NULL')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_shadowed_array_input_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_shadowed_array_input.state_domain \
             AS value_contract_shadowed_array_input.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_shadowed_array_input.rows \
             (id INT PRIMARY KEY, status value_contract_shadowed_array_input.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_shadowed_array_input.rows \
             VALUES (1, 'ready'), (2, 'NULL'), (3, 'paused'), (4, NULL)",
        )
        .await
        .unwrap();

    let schema = "value_contract_shadowed_array_input";
    let enum_type = format!("{schema}.state");
    let array_type = format!("{schema}.state[]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(
            "SET LOCAL search_path TO value_contract_shadowed_array_input_shadow, public",
        )
        .await
        .unwrap();

    for (parameter, native_array) in [
        (
            Value::Text(r#"{"ready","NULL","paused"}"#.into()),
            format!(r#"'{{"ready","NULL","paused"}}'::{array_type}"#),
        ),
        (
            Value::Text(r#"{"ready",NULL,"paused"}"#.into()),
            format!(r#"'{{"ready",NULL,"paused"}}'::{array_type}"#),
        ),
        (
            Value::Text(r#"[0:3]={"ready","NULL","paused",NULL}"#.into()),
            format!(r#"'[0:3]={{"ready","NULL","paused",NULL}}'::{array_type}"#),
        ),
        (Value::Text("{}".into()), format!("'{{}}'::{array_type}")),
        (Value::Null, format!("NULL::{array_type}")),
    ] {
        let trim_count = match &parameter {
            Value::Text(text) if text == "{}" => 0,
            _ => 1,
        };
        let native_position = transaction
            .query(&format!(
                "SELECT id, array_position({native_array}, status::{enum_type}), \
                 encode(array_send({native_array}), 'hex') \
                 FROM {schema}.rows ORDER BY id"
            ))
            .await
            .unwrap();
        let position = transaction
            .query_params(
                &format!(
                    "SELECT id, array_position($1, status::{enum_type}), \
                     pg_typeof($1)::text, encode(array_send($1), 'hex') \
                     FROM {schema}.rows ORDER BY id"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        let expected_position = native_position
            .rows
            .into_iter()
            .map(|row| {
                vec![
                    row[0].clone(),
                    row[1].clone(),
                    Value::Text(array_type.clone()),
                    row[2].clone(),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(position.rows, expected_position, "array_position {parameter:?}");

        let native_remove = transaction
            .query(&format!(
                "SELECT id, array_to_json(array_remove({native_array}, status::{enum_type}))::text, \
                 encode(array_send(array_remove({native_array}, status::{enum_type})), 'hex') \
                 FROM {schema}.rows ORDER BY id"
            ))
            .await
            .unwrap();
        let remove = transaction
            .query_params(
                &format!(
                    "SELECT id, array_to_json(array_remove($1, status::{enum_type}))::text, \
                     pg_typeof($1)::text, \
                     pg_typeof(array_remove($1, status::{enum_type}))::text, \
                     encode(array_send(array_remove($1, status::{enum_type})), 'hex') \
                     FROM {schema}.rows ORDER BY id"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        let expected_remove = native_remove
            .rows
            .into_iter()
            .map(|row| {
                vec![
                    row[0].clone(),
                    row[1].clone(),
                    Value::Text(array_type.clone()),
                    Value::Text(array_type.clone()),
                    row[2].clone(),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(remove.rows, expected_remove, "array_remove {parameter:?}");

        let native_trim = transaction
            .query(&format!(
                "SELECT id, array_to_json(trim_array({native_array}, {trim_count}))::text, \
                 pg_typeof(trim_array({native_array}, {trim_count}))::text, \
                 encode(array_send(trim_array({native_array}, {trim_count})), 'hex'), \
                 encode(array_send({native_array}), 'hex') \
                 FROM {schema}.rows ORDER BY id"
            ))
            .await
            .unwrap();
        transaction.execute("SAVEPOINT untyped_trim_array").await.unwrap();
        let trim_untyped = transaction
            .query_params(
                &format!(
                    "SELECT trim_array($1, {trim_count}) FROM {schema}.rows LIMIT 1"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .expect_err("trim_array alone cannot resolve its polymorphic input");
        assert!(
            matches!(&trim_untyped, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42804"),
            "expected unresolved polymorphic-type SQLSTATE 42804, got {trim_untyped:?}"
        );
        transaction.execute("ROLLBACK TO SAVEPOINT untyped_trim_array").await.unwrap();
        let trim = transaction
            .query_params(
                &format!(
                    "SELECT id, array_to_json(trim_array($1::{array_type}, {trim_count}))::text, \
                     pg_typeof($1::{array_type})::text, \
                     pg_typeof(trim_array($1::{array_type}, {trim_count}))::text, \
                     encode(array_send(trim_array($1::{array_type}, {trim_count})), 'hex'), \
                     encode(array_send($1::{array_type}), 'hex') \
                     FROM {schema}.rows ORDER BY id"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        let expected_trim = native_trim
            .rows
            .into_iter()
            .map(|row| {
                vec![
                    row[0].clone(),
                    row[1].clone(),
                    Value::Text(array_type.clone()),
                    row[2].clone(),
                    row[3].clone(),
                    row[4].clone(),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(trim.rows, expected_trim, "cast trim_array with {parameter:?}");

        for (expression, native_expression) in [
            (
                "array_append($1, status::value_contract_shadowed_array_input.state)",
                format!("array_append({native_array}, status::{enum_type})"),
            ),
            (
                "array_prepend(status::value_contract_shadowed_array_input.state, $1)",
                format!("array_prepend(status::{enum_type}, {native_array})"),
            ),
        ] {
            let native = transaction
                .query(&format!(
                    "SELECT id, array_to_json({native_expression})::text, \
                     pg_typeof({native_expression})::text, \
                     encode(array_send({native_expression}), 'hex'), \
                     encode(array_send({native_array}), 'hex') \
                     FROM {schema}.rows ORDER BY id"
                ))
                .await
                .unwrap();
            let result = transaction
                .query_params(
                    &format!(
                        "SELECT id, array_to_json({expression})::text, \
                         pg_typeof($1)::text, pg_typeof({expression})::text, \
                         encode(array_send({expression}), 'hex'), \
                         encode(array_send($1), 'hex') \
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
                        Value::Text(array_type.clone()),
                        Value::Text(array_type.clone()),
                        row[3].clone(),
                        row[4].clone(),
                    ]
                })
                .collect::<Vec<_>>();
            assert_eq!(result.rows, expected, "{expression} with {parameter:?}");
        }
    }

    for expression in [
        "array_position($1, status::value_contract_shadowed_array_input.state)",
        "array_remove($1, status::value_contract_shadowed_array_input.state)",
        "array_append($1, status::value_contract_shadowed_array_input.state)",
        "array_prepend(status::value_contract_shadowed_array_input.state, $1)",
    ] {
        transaction.execute("SAVEPOINT invalid_array_input").await.unwrap();
        let invalid = transaction
            .query_params(
                &format!(
                    "SELECT {expression} FROM {schema}.rows WHERE id = 1"
                ),
                &[Value::Text(r#"{"shadow-only"}"#.into())],
            )
            .await
            .expect_err("array labels present only in the shadow enum must be rejected");
        assert!(
            matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
            "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
        );
        transaction.execute("ROLLBACK TO SAVEPOINT invalid_array_input").await.unwrap();
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_any_all_infer_array_parameter_type_under_shadowed_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_any_array")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_domain_any_array_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_any_array.state \
             AS ENUM ('ready', 'paused', 'NULL', '', 'comma,label', 'quote\"label', 'backslash\\label')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_any_array_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_any_array.state_domain \
             AS value_contract_domain_any_array.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_any_array.rows \
             (id INT PRIMARY KEY, status value_contract_domain_any_array.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_any_array.rows VALUES \
             (1, 'ready'), (2, 'paused'), (3, 'NULL'), (4, ''), (5, NULL), \
             (6, 'comma,label'), (7, 'quote\"label'), (8, 'backslash\\label')",
        )
        .await
        .unwrap();

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO value_contract_domain_any_array_shadow, public")
        .await
        .unwrap();

    let domain_type = "value_contract_domain_any_array.state_domain";
    let enum_array_type = "value_contract_domain_any_array.state[]";
    for (parameter, native_array, expected) in [
        (
            Value::Text(r#"{"ready","paused"}"#.into()),
            r#"'{"ready","paused"}'::value_contract_domain_any_array.state[]"#,
            [
                Value::Bool(true),
                Value::Bool(true),
                Value::Bool(false),
                Value::Bool(false),
                Value::Null,
                Value::Bool(false),
                Value::Bool(false),
                Value::Bool(false),
            ],
        ),
        (
            Value::Text(r#"{"NULL",""}"#.into()),
            r#"'{"NULL",""}'::value_contract_domain_any_array.state[]"#,
            [
                Value::Bool(false),
                Value::Bool(false),
                Value::Bool(true),
                Value::Bool(true),
                Value::Null,
                Value::Bool(false),
                Value::Bool(false),
                Value::Bool(false),
            ],
        ),
        (
            Value::Text(r#"{"comma,label","quote\"label","backslash\\label"}"#.into()),
            r#"'{"comma,label","quote\"label","backslash\\label"}'::value_contract_domain_any_array.state[]"#,
            [
                Value::Bool(false),
                Value::Bool(false),
                Value::Bool(false),
                Value::Bool(false),
                Value::Null,
                Value::Bool(true),
                Value::Bool(true),
                Value::Bool(true),
            ],
        ),
        (
            Value::Text(r#"[0:1][3:4]={{"ready","NULL"},{"",NULL}}"#.into()),
            r#"'[0:1][3:4]={{"ready","NULL"},{"",NULL}}'::value_contract_domain_any_array.state[]"#,
            [
                Value::Bool(true),
                Value::Null,
                Value::Bool(true),
                Value::Bool(true),
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
            ],
        ),
        (
            Value::Text("{}".into()),
            "'{}'::value_contract_domain_any_array.state[]",
            [
                Value::Bool(false),
                Value::Bool(false),
                Value::Bool(false),
                Value::Bool(false),
                Value::Bool(false),
                Value::Bool(false),
                Value::Bool(false),
                Value::Bool(false),
            ],
        ),
        (
            Value::Null,
            "NULL::value_contract_domain_any_array.state[]",
            [
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
                Value::Null,
            ],
        ),
    ] {
        let native_wire = transaction
            .query(&format!(
                "SELECT encode(array_send({native_array}), 'hex')"
            ))
            .await
            .unwrap()
            .rows[0][0]
            .clone();
        let result = transaction
            .query_params(
                "SELECT id, status::value_contract_domain_any_array.state = ANY($1), \
                 pg_typeof($1)::text, pg_typeof(status)::text, encode(array_send($1), 'hex') \
                 FROM value_contract_domain_any_array.rows ORDER BY id",
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(
            result.rows,
            expected
                .into_iter()
                .enumerate()
                .map(|(index, value)| vec![
                    Value::Int(index as i64 + 1),
                    value,
                    Value::Text(enum_array_type.into()),
                    Value::Text(domain_type.into()),
                    native_wire.clone(),
                ])
                .collect::<Vec<_>>(),
            "ANY with parameter {parameter:?}"
        );

        let native_all = transaction
            .query(&format!(
                "SELECT id, status::value_contract_domain_any_array.state = ALL({native_array}) \
                 FROM value_contract_domain_any_array.rows ORDER BY id"
            ))
            .await
            .unwrap();
        let all = transaction
            .query_params(
                "SELECT id, status::value_contract_domain_any_array.state = ALL($1), \
                 pg_typeof($1)::text, pg_typeof(status)::text, encode(array_send($1), 'hex') \
                 FROM value_contract_domain_any_array.rows ORDER BY id",
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(
            all.rows,
            native_all
                .rows
                .iter()
                .map(|row| vec![
                    row[0].clone(),
                    row[1].clone(),
                    Value::Text(enum_array_type.into()),
                    Value::Text(domain_type.into()),
                    native_wire.clone(),
                ])
                .collect::<Vec<_>>(),
            "ALL with parameter {parameter:?}"
        );
    }

    let invalid = transaction
        .query_params(
            "SELECT status::value_contract_domain_any_array.state = ANY($1) \
             FROM value_contract_domain_any_array.rows WHERE id = 1",
            &[Value::Text(r#"{"shadow-only"}"#.into())],
        )
        .await
        .expect_err("invalid array enum labels must be refused by PostgreSQL");
    assert!(
        matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected native invalid-enum SQLSTATE 22P02, got {invalid:?}"
    );

    let invalid_bounds = connection
        .query_params(
            "SELECT status::value_contract_domain_any_array.state = ANY($1) \
             FROM value_contract_domain_any_array.rows WHERE id = 1",
            &[Value::Text(r#"[0:1]={ready}"#.into())],
        )
        .await
        .expect_err("array bounds inconsistent with the values must be refused before dispatch");
    assert!(
        matches!(&invalid_bounds, tablepro_core::DriverError::Unsupported(message) if message.contains("bounds")),
        "expected an explicit unsupported result for inconsistent bounds, got {invalid_bounds:?}"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_enum_array_unnest_requires_qualified_cast_under_shadowed_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_shadowed_unnest")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_shadowed_unnest_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_shadowed_unnest.state \
             AS ENUM ('ready', 'NULL', '', '東京', 'comma,label')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_shadowed_unnest_shadow.state \
             AS ENUM ('ready', 'shadow-only')",
        )
        .await
        .unwrap();

    let schema = "value_contract_shadowed_unnest";
    let array_type = format!("{schema}.state[]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO value_contract_shadowed_unnest_shadow, public")
        .await
        .unwrap();

    for (parameter, native_array) in [
        (
            Value::Text(r#"[0:1][2:3]={{"NULL",NULL},{"東京","comma,label"}}"#.into()),
            format!(r#"'[0:1][2:3]={{{{"NULL",NULL}},{{"東京","comma,label"}}}}'::{array_type}"#),
        ),
        (Value::Text("{}".into()), format!("'{{}}'::{array_type}")),
        (Value::Null, format!("NULL::{array_type}")),
    ] {
        transaction
            .execute("SAVEPOINT untyped_unnest_parameter")
            .await
            .unwrap();
        let untyped = transaction
            .query_params(
                "SELECT item FROM unnest($1) AS element(item)",
                std::slice::from_ref(&parameter),
            )
            .await
            .expect_err("unnest has no typed argument from which to infer an enum array");
        assert!(
            matches!(&untyped, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "42725"),
            "expected PostgreSQL ambiguous-function SQLSTATE 42725, got {untyped:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT untyped_unnest_parameter")
            .await
            .unwrap();

        let native_items = transaction
            .query(&format!(
                "SELECT ordinality::bigint, item::text, item IS NULL \
                 FROM unnest({native_array}) WITH ORDINALITY AS element(item, ordinality) \
                 ORDER BY ordinality"
            ))
            .await
            .unwrap();
        let items = transaction
            .query_params(
                &format!(
                    "SELECT ordinality::bigint, item::text, item IS NULL \
                     FROM unnest($1::{array_type}) WITH ORDINALITY AS element(item, ordinality) \
                     ORDER BY ordinality"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(items.rows, native_items.rows, "unnest values for {parameter:?}");

        let native_type_and_bytes = transaction
            .query(&format!(
                "SELECT {native_array} IS NULL, pg_typeof({native_array})::text, \
                 encode(array_send({native_array}), 'hex')"
            ))
            .await
            .unwrap();
        let type_and_bytes = transaction
            .query_params(
                &format!(
                    "SELECT $1::{array_type} IS NULL, pg_typeof($1::{array_type})::text, \
                     encode(array_send($1::{array_type}), 'hex')"
                ),
                std::slice::from_ref(&parameter),
            )
            .await
            .unwrap();
        assert_eq!(type_and_bytes.rows, native_type_and_bytes.rows, "array metadata and bytes for {parameter:?}");
    }

    transaction
        .execute("SAVEPOINT shadow_only_unnest_label")
        .await
        .unwrap();
    let invalid = transaction
        .query_params(
            &format!("SELECT item FROM unnest($1::{array_type}) AS element(item)"),
            &[Value::Text(r#"{"shadow-only"}"#.into())],
        )
        .await
        .expect_err("a label defined only by the shadow enum must be rejected");
    assert!(
        matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
    );
    transaction.execute("ROLLBACK TO SAVEPOINT shadow_only_unnest_label").await.unwrap();
    transaction.rollback().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_over_enum_array_operators_infer_parameter_type_in_both_positions() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_operators")
        .await
        .unwrap();
    connection
        .execute("CREATE SCHEMA value_contract_domain_array_operator_shadow")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_array_operator_shadow.state \
             AS ENUM ('shadow-only')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TYPE value_contract_domain_array_operators.state AS ENUM \
             ('ready', 'paused', 'NULL', '', 'comma,label', 'quote\"label', 'backslash\\label')",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE DOMAIN value_contract_domain_array_operators.state_domain \
             AS value_contract_domain_array_operators.state",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE value_contract_domain_array_operators.rows \
             (id INT PRIMARY KEY, status value_contract_domain_array_operators.state_domain)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO value_contract_domain_array_operators.rows VALUES \
             (1, 'ready'), (2, 'paused'), (3, 'NULL'), (4, ''), (5, NULL), \
             (6, 'comma,label'), (7, 'quote\"label'), (8, 'backslash\\label')",
        )
        .await
        .unwrap();

    let schema = "value_contract_domain_array_operators";
    let domain_type = format!("{schema}.state_domain");
    let array_type = format!("{schema}.state[]");
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO value_contract_domain_array_operator_shadow, public")
        .await
        .unwrap();
    let cases = [
        (
            Value::Text(r#"{"ready","paused"}"#.into()),
            r#"'{"ready","paused"}'::value_contract_domain_array_operators.state[]"#,
        ),
        (
            Value::Text(r#"{"NULL",""}"#.into()),
            r#"'{"NULL",""}'::value_contract_domain_array_operators.state[]"#,
        ),
        (
            Value::Text(r#"{"comma,label","quote\"label","backslash\\label"}"#.into()),
            r#"'{"comma,label","quote\"label","backslash\\label"}'::value_contract_domain_array_operators.state[]"#,
        ),
        (
            Value::Text("{}".into()),
            "'{}'::value_contract_domain_array_operators.state[]",
        ),
        (
            Value::Null,
            "NULL::value_contract_domain_array_operators.state[]",
        ),
    ];

    for expression in [
        "ARRAY[status::value_contract_domain_array_operators.state] <@ $1",
        "$1 @> ARRAY[status::value_contract_domain_array_operators.state]",
        "ARRAY[status::value_contract_domain_array_operators.state] && $1",
        "$1 && ARRAY[status::value_contract_domain_array_operators.state]",
    ] {
        for (parameter, native_array) in cases.iter() {
            let native_expression = expression.replace("$1", native_array);
            let oracle = transaction
                .query(&format!(
                    "SELECT id, {native_expression} FROM \
                     value_contract_domain_array_operators.rows ORDER BY id"
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
                        "SELECT id, {expression}, pg_typeof($1)::text, \
                         pg_typeof(status)::text, encode(array_send($1), 'hex') \
                         FROM value_contract_domain_array_operators.rows ORDER BY id"
                    ),
                    std::slice::from_ref(parameter),
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
                        Value::Text(domain_type.clone()),
                        wire.clone(),
                    ]
                })
                .collect::<Vec<_>>();
            assert_eq!(result.rows, expected, "{expression} with {parameter:?}");
        }
    }

    for expression in [
        "ARRAY[status::value_contract_domain_array_operators.state] <@ $1",
        "$1 @> ARRAY[status::value_contract_domain_array_operators.state]",
    ] {
        transaction.execute("SAVEPOINT invalid_enum_parameter").await.unwrap();
        let invalid = transaction
            .query_params(
                &format!(
                    "SELECT {expression} FROM \
                     value_contract_domain_array_operators.rows WHERE id = 1"
                ),
                &[Value::Text(r#"{"missing-label"}"#.into())],
            )
            .await
            .expect_err("invalid array enum labels must retain PostgreSQL's native error");
        assert!(
            matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
            "expected native invalid-enum SQLSTATE 22P02, got {invalid:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT invalid_enum_parameter")
            .await
            .unwrap();
    }
}

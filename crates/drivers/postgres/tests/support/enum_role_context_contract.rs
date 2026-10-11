#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_parameter_stays_with_target_type_after_role_and_local_search_path() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection.execute("CREATE SCHEMA enum_role_target").await.unwrap();
    connection.execute("CREATE SCHEMA enum_role_shadow").await.unwrap();
    connection
        .execute("CREATE TYPE enum_role_target.state AS ENUM ('target-only', 'common')")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE enum_role_shadow.state AS ENUM ('shadow-only', 'common')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE enum_role_target.rows \
             (id INT PRIMARY KEY, state enum_role_target.state, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE enum_role_shadow.rows \
             (id INT PRIMARY KEY, state enum_role_shadow.state, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO enum_role_target.rows VALUES \
             (1, 'target-only', 'target sibling'), (2, 'common', 'common sibling'), (3, NULL, 'null sibling')",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO enum_role_shadow.rows VALUES (1, 'shadow-only', 'shadow sibling')")
        .await
        .unwrap();
    connection
        .execute("CREATE ROLE enum_role_contract NOLOGIN")
        .await
        .unwrap();
    connection
        .execute("GRANT USAGE ON SCHEMA enum_role_target, enum_role_shadow TO enum_role_contract")
        .await
        .unwrap();
    connection
        .execute("GRANT USAGE ON TYPE enum_role_target.state, enum_role_shadow.state TO enum_role_contract")
        .await
        .unwrap();
    connection
        .execute("GRANT SELECT, UPDATE ON enum_role_target.rows TO enum_role_contract")
        .await
        .unwrap();

    // These settings and the bound queries must use one backend; connection calls use the pool.
    let mut session = connection.open_session().await.unwrap();
    let control = crate::no_timeout();
    session
        .query_params_controlled("SET ROLE enum_role_contract", &[], &control)
        .await
        .unwrap();
    let original_search_path = match session
        .query_params_controlled("SHOW search_path", &[], &control)
        .await
        .unwrap()
        .rows[0][0]
        .clone()
    {
        Value::Text(path) => path,
        other => panic!("search_path is not text: {other:?}"),
    };
    session
        .query_params_controlled(
            "SET search_path TO enum_role_shadow, enum_role_target, public",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        session
            .query_params_controlled(
                "SELECT current_user::text, current_setting('search_path')::text",
                &[],
                &control,
            )
            .await
            .unwrap()
            .rows,
        vec![vec![
            Value::Text("enum_role_contract".into()),
            Value::Text("enum_role_shadow, enum_role_target, public".into()),
        ]]
    );

    let target_type = "enum_role_target.state";
    let target_value = session
        .query_params_controlled(
            "SELECT id, state::text, pg_typeof(state)::text \
             FROM enum_role_target.rows WHERE state IS NOT DISTINCT FROM $1 ORDER BY id",
            &[Value::Text("target-only".into())],
            &control,
        )
        .await
        .unwrap();
    let native_target_value = connection
        .query(
            "SELECT id, state::text, pg_typeof(state)::text \
             FROM enum_role_target.rows \
             WHERE state IS NOT DISTINCT FROM 'target-only'::enum_role_target.state ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(target_value.rows, native_target_value.rows);
    assert_eq!(
        target_value.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("target-only".into()),
            Value::Text(target_type.into()),
        ]]
    );

    let update = session
        .query_params_controlled(
            "UPDATE enum_role_target.rows SET state = $1 WHERE id = 1 \
             RETURNING id, state::text, pg_typeof(state)::text, sibling",
            &[Value::Text("target-only".into())],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        update.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("target-only".into()),
            Value::Text(target_type.into()),
            Value::Text("target sibling".into()),
        ]]
    );
    let null_update = session
        .query_params_controlled(
            "UPDATE enum_role_target.rows SET state = $1 WHERE id = 3 \
             RETURNING id, state::text, pg_typeof(state)::text, sibling",
            &[Value::Null],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        null_update.rows,
        vec![vec![
            Value::Int(3),
            Value::Null,
            Value::Text(target_type.into()),
            Value::Text("null sibling".into()),
        ]]
    );

    let invalid_shadow_label = session
        .query_params_controlled(
            "UPDATE enum_role_target.rows SET state = $1 WHERE id = 1",
            &[Value::Text("shadow-only".into())],
            &control,
        )
        .await
        .expect_err("a label from the shadow enum must not be accepted for the target column");
    let native_invalid_label = connection
        .query("SELECT 'shadow-only'::enum_role_target.state")
        .await
        .expect_err("the native target enum must reject the shadow-only label");
    let error_code = |error: &tablepro_core::DriverError| match error {
        tablepro_core::DriverError::Query { sqlstate, .. } => sqlstate.clone(),
        _ => None,
    };
    assert!(
        error_code(&invalid_shadow_label).as_deref() == Some("22P02"),
        "the target enum must reject the shadow-only label with 22P02: {invalid_shadow_label:?}"
    );
    assert_eq!(error_code(&invalid_shadow_label), error_code(&native_invalid_label));

    session.query_params_controlled("BEGIN", &[], &control).await.unwrap();
    session
        .query_params_controlled("SET LOCAL search_path TO enum_role_shadow, public", &[], &control)
        .await
        .unwrap();
    assert_eq!(
        session
            .query_params_controlled(
                "SELECT current_user::text, current_setting('search_path')::text",
                &[],
                &control,
            )
            .await
            .unwrap()
            .rows,
        vec![vec![
            Value::Text("enum_role_contract".into()),
            Value::Text("enum_role_shadow, public".into()),
        ]]
    );
    let local_update = session
        .query_params_controlled(
            "UPDATE enum_role_target.rows SET state = $1 WHERE id = 2 \
             RETURNING id, state::text, pg_typeof(state)::text, sibling",
            &[Value::Text("target-only".into())],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        local_update.rows,
        vec![vec![
            Value::Int(2),
            Value::Text("target-only".into()),
            Value::Text(target_type.into()),
            Value::Text("common sibling".into()),
        ]]
    );
    let local_filter = session
        .query_params_controlled(
            "SELECT id FROM enum_role_target.rows \
             WHERE state IS NOT DISTINCT FROM $1 ORDER BY id",
            &[Value::Text("target-only".into())],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(local_filter.rows, vec![vec![Value::Int(1)], vec![Value::Int(2)]]);

    session
        .query_params_controlled("SAVEPOINT before_local_invalid_label", &[], &control)
        .await
        .unwrap();
    let local_invalid = session
        .query_params_controlled(
            "UPDATE enum_role_target.rows SET state = $1 WHERE id = 2",
            &[Value::Text("shadow-only".into())],
            &control,
        )
        .await
        .expect_err("a local shadow path must not accept the shadow-only label");
    assert_eq!(error_code(&local_invalid).as_deref(), Some("22P02"));
    assert_eq!(error_code(&local_invalid), error_code(&native_invalid_label));
    session
        .query_params_controlled("ROLLBACK TO SAVEPOINT before_local_invalid_label", &[], &control)
        .await
        .unwrap();
    session.query_params_controlled("COMMIT", &[], &control).await.unwrap();
    assert_eq!(
        session
            .query_params_controlled("SHOW search_path", &[], &control)
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Text("enum_role_shadow, enum_role_target, public".into())]]
    );

    session
        .query_params_controlled("SET search_path TO enum_role_shadow, public", &[], &control)
        .await
        .unwrap();
    assert_eq!(
        session
            .query_params_controlled(
                "SELECT current_user::text, current_setting('search_path')::text",
                &[],
                &control,
            )
            .await
            .unwrap()
            .rows,
        vec![vec![
            Value::Text("enum_role_contract".into()),
            Value::Text("enum_role_shadow, public".into()),
        ]]
    );

    let hidden_schema_update = session
        .query_params_controlled(
            "UPDATE enum_role_target.rows SET state = $1 WHERE id = 2 \
             RETURNING id, state::text, pg_typeof(state)::text, sibling",
            &[Value::Text("target-only".into())],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        hidden_schema_update.rows,
        vec![vec![
            Value::Int(2),
            Value::Text("target-only".into()),
            Value::Text(target_type.into()),
            Value::Text("common sibling".into()),
        ]]
    );
    let hidden_schema_query = session
        .query_params_controlled(
            "SELECT id, state::text, pg_typeof(state)::text \
             FROM enum_role_target.rows \
             WHERE state IS NOT DISTINCT FROM $1 ORDER BY id",
            &[Value::Text("target-only".into())],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        hidden_schema_query.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("target-only".into()),
                Value::Text(target_type.into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("target-only".into()),
                Value::Text(target_type.into()),
            ],
        ]
    );
    session
        .query_params_controlled(
            "SELECT set_config('search_path', $1, false)",
            &[Value::Text(original_search_path.clone())],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        session
            .query_params_controlled("SHOW search_path", &[], &control)
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Text(original_search_path)]]
    );

    let target_rows = session
        .query_params_controlled(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_role_target.rows ORDER BY id",
            &[],
            &control,
        )
        .await
        .unwrap();
    session
        .query_params_controlled("RESET ROLE", &[], &control)
        .await
        .unwrap();
    session.close().await.unwrap();
    let native_target_rows = connection
        .query(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_role_target.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(target_rows.rows, native_target_rows.rows);
    assert_eq!(
        target_rows.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("target-only".into()),
                Value::Text(target_type.into()),
                Value::Text("target sibling".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("target-only".into()),
                Value::Text(target_type.into()),
                Value::Text("common sibling".into()),
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Text(target_type.into()),
                Value::Text("null sibling".into()),
            ],
        ]
    );
    let shadow_rows = connection
        .query(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_role_shadow.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        shadow_rows.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("shadow-only".into()),
            Value::Text("enum_role_shadow.state".into()),
            Value::Text("shadow sibling".into()),
        ]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_quoted_enum_keyed_edit_survives_role_and_shadowed_local_search_path() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let target_schema = "Enum Role Target";
    let type_name = "State \"Kind";
    let target_schema_sql = "\"Enum Role Target\"";
    let shadow_schema_sql = "\"Enum Role Shadow\"";
    let type_sql = "\"State \"\"Kind\"";
    let target_type_sql = format!("{target_schema_sql}.{type_sql}");
    connection
        .execute(&format!("CREATE SCHEMA {target_schema_sql}"))
        .await
        .unwrap();
    connection
        .execute(&format!("CREATE SCHEMA {shadow_schema_sql}"))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {target_type_sql} AS ENUM ('target-only', 'common')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {shadow_schema_sql}.{type_sql} AS ENUM ('shadow-only', 'common')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE {target_schema_sql}.rows \
             (id INT PRIMARY KEY, state {target_type_sql}, sibling TEXT NOT NULL)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {target_schema_sql}.rows VALUES \
             (1, 'common', 'target sibling'), (2, NULL, 'untouched sibling')"
        ))
        .await
        .unwrap();
    connection
        .execute("CREATE ROLE enum_role_quoted_contract NOLOGIN")
        .await
        .unwrap();
    connection
        .execute(&format!(
            "GRANT USAGE ON SCHEMA {target_schema_sql}, {shadow_schema_sql} \
             TO enum_role_quoted_contract"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "GRANT USAGE ON TYPE {target_type_sql}, {shadow_schema_sql}.{type_sql} \
             TO enum_role_quoted_contract"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "GRANT SELECT, UPDATE ON {target_schema_sql}.rows TO enum_role_quoted_contract"
        ))
        .await
        .unwrap();

    let columns = connection.fetch_columns(Some(target_schema), "rows").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: target_schema.into(),
            name: type_name.into(),
        })
    );
    let edit = tablepro_core::sql_dialect::build_optimistic_keyed_update(
        "postgres",
        Some(target_schema),
        "rows",
        &columns,
        &[(1, Value::Text("common".into()), Value::Text("target-only".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(edit.0.contains(&format!("::text::{target_type_sql}")), "{}", edit.0);
    assert!(
        edit.0
            .contains(&format!("state\" IS NOT DISTINCT FROM $3::text::{target_type_sql}")),
        "{}",
        edit.0
    );

    let mut session = connection.open_session().await.unwrap();
    let control = crate::no_timeout();
    session
        .query_params_controlled("SET ROLE enum_role_quoted_contract", &[], &control)
        .await
        .unwrap();
    session.query_params_controlled("BEGIN", &[], &control).await.unwrap();
    session
        .query_params_controlled(
            &format!("SET LOCAL search_path TO {shadow_schema_sql}, public"),
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        session
            .query_params_controlled(
                "SELECT current_user = 'enum_role_quoted_contract', \
                        NOT ('Enum Role Target' = ANY(current_schemas(false))), \
                        'Enum Role Shadow' = ANY(current_schemas(false))",
                &[],
                &control,
            )
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Bool(true), Value::Bool(true), Value::Bool(true)]]
    );

    let updated = session
        .query_params_controlled(
            &format!("{} RETURNING id, state::text, pg_typeof(state)::text, sibling", edit.0),
            &edit.1,
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        updated.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("target-only".into()),
            Value::Text(target_type_sql.clone()),
            Value::Text("target sibling".into()),
        ]]
    );

    session
        .query_params_controlled("SAVEPOINT reject_shadow_label", &[], &control)
        .await
        .unwrap();
    let invalid_edit = tablepro_core::sql_dialect::build_optimistic_keyed_update(
        "postgres",
        Some(target_schema),
        "rows",
        &columns,
        &[(1, Value::Text("target-only".into()), Value::Text("shadow-only".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    let invalid = session
        .query_params_controlled(&format!("{} RETURNING id", invalid_edit.0), &invalid_edit.1, &control)
        .await
        .expect_err("a label declared only by the shadow enum must be refused");
    let native_invalid = connection
        .query(&format!("SELECT 'shadow-only'::{target_type_sql}"))
        .await
        .expect_err("the native target enum must refuse the shadow-only label");
    let error_code = |error: &tablepro_core::DriverError| match error {
        tablepro_core::DriverError::Query { sqlstate, .. } => sqlstate.clone(),
        _ => None,
    };
    assert!(
        error_code(&invalid).as_deref() == Some("22P02"),
        "expected native invalid-enum-label SQLSTATE 22P02, got {invalid:?}"
    );
    assert_eq!(error_code(&invalid), error_code(&native_invalid));
    session
        .query_params_controlled("ROLLBACK TO SAVEPOINT reject_shadow_label", &[], &control)
        .await
        .unwrap();
    session.query_params_controlled("COMMIT", &[], &control).await.unwrap();
    session
        .query_params_controlled("RESET ROLE", &[], &control)
        .await
        .unwrap();
    session.close().await.unwrap();

    let native = connection
        .query(&format!(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM {target_schema_sql}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(
        native.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("target-only".into()),
                Value::Text(target_type_sql.clone()),
                Value::Text("target sibling".into()),
            ],
            vec![
                Value::Int(2),
                Value::Null,
                Value::Text(target_type_sql.clone()),
                Value::Text("untouched sibling".into()),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_parameter_stays_with_target_type_after_role_login() {
    let (_container, options) = start_pg().await;
    let admin = connect(options.clone()).await;
    admin.execute("CREATE SCHEMA enum_role_login_target").await.unwrap();
    admin.execute("CREATE SCHEMA enum_role_login_shadow").await.unwrap();
    admin
        .execute("CREATE TYPE enum_role_login_target.state AS ENUM ('target-only', 'common')")
        .await
        .unwrap();
    admin
        .execute("CREATE TYPE enum_role_login_shadow.state AS ENUM ('shadow-only', 'common')")
        .await
        .unwrap();
    admin
        .execute(
            "CREATE TABLE enum_role_login_target.rows \
             (id INT PRIMARY KEY, state enum_role_login_target.state, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    admin
        .execute("INSERT INTO enum_role_login_target.rows VALUES (1, 'target-only', 'keep'), (2, NULL, 'null')")
        .await
        .unwrap();
    admin
        .execute("CREATE ROLE enum_role_login_contract LOGIN PASSWORD 'enum-role-login-test'")
        .await
        .unwrap();
    admin
        .execute(
            "ALTER ROLE enum_role_login_contract SET search_path \
             TO enum_role_login_shadow, public",
        )
        .await
        .unwrap();
    admin
        .execute("GRANT USAGE ON SCHEMA enum_role_login_target, enum_role_login_shadow TO enum_role_login_contract")
        .await
        .unwrap();
    admin
        .execute("GRANT USAGE ON TYPE enum_role_login_target.state, enum_role_login_shadow.state TO enum_role_login_contract")
        .await
        .unwrap();
    admin
        .execute("GRANT SELECT ON enum_role_login_target.rows TO enum_role_login_contract")
        .await
        .unwrap();

    let login = connect(tablepro_core::ConnectOptions {
        username: "enum_role_login_contract".into(),
        password: secrecy::SecretString::new("enum-role-login-test".to_string().into()),
        ..options
    })
    .await;
    let mut session = login.open_session().await.unwrap();
    let control = crate::no_timeout();
    let identity = session
        .query_params_controlled(
            "SELECT current_user::text, current_setting('search_path')::text",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        identity.rows,
        vec![vec![
            Value::Text("enum_role_login_contract".into()),
            Value::Text("enum_role_login_shadow, public".into()),
        ]]
    );

    let bound = session
        .query_params_controlled(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_role_login_target.rows \
             WHERE state IS NOT DISTINCT FROM $1 ORDER BY id",
            &[Value::Text("target-only".into())],
            &control,
        )
        .await
        .unwrap();
    let native = admin
        .query(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_role_login_target.rows \
             WHERE state IS NOT DISTINCT FROM 'target-only'::enum_role_login_target.state ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(bound.rows, native.rows);
    assert_eq!(
        bound.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("target-only".into()),
            Value::Text("enum_role_login_target.state".into()),
            Value::Text("keep".into()),
        ]]
    );

    let null = session
        .query_params_controlled(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_role_login_target.rows \
             WHERE state IS NOT DISTINCT FROM $1 ORDER BY id",
            &[Value::Null],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        null.rows,
        vec![vec![
            Value::Int(2),
            Value::Null,
            Value::Text("enum_role_login_target.state".into()),
            Value::Text("null".into()),
        ]]
    );

    let invalid = session
        .query_params_controlled(
            "SELECT id FROM enum_role_login_target.rows WHERE state = $1",
            &[Value::Text("shadow-only".into())],
            &control,
        )
        .await
        .expect_err("the login role's shadow enum label must not match the target enum");
    let native_invalid = admin
        .query("SELECT 'shadow-only'::enum_role_login_target.state")
        .await
        .expect_err("native target enum cast must reject shadow-only label");
    let error_code = |error: &tablepro_core::DriverError| match error {
        tablepro_core::DriverError::Query { sqlstate, .. } => sqlstate.clone(),
        _ => None,
    };
    assert_eq!(error_code(&invalid).as_deref(), Some("22P02"));
    assert_eq!(error_code(&invalid), error_code(&native_invalid));

    session.close().await.unwrap();
    login.close().await.unwrap();
    let rows = admin
        .query(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_role_login_target.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(rows.rows.len(), 2);
    assert_eq!(rows.rows[0][3], Value::Text("keep".into()));
    assert_eq!(rows.rows[1][1], Value::Null);
}

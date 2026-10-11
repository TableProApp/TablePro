#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{DriverError, Value};

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_enum_values_remain_queryable_without_type_usage() {
    let (_container, options) = start_pg().await;
    let admin = connect(options).await;
    admin.execute("CREATE SCHEMA enum_without_type_usage").await.unwrap();
    admin
        .execute("CREATE TYPE enum_without_type_usage.state AS ENUM ('target-only', 'common')")
        .await
        .unwrap();
    admin
        .execute(
            "CREATE TABLE enum_without_type_usage.rows \
             (id INT PRIMARY KEY, state enum_without_type_usage.state, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    admin
        .execute(
            "INSERT INTO enum_without_type_usage.rows VALUES \
             (1, 'common', 'keep'), (2, NULL, 'null sibling')",
        )
        .await
        .unwrap();
    admin
        .execute("REVOKE USAGE ON TYPE enum_without_type_usage.state FROM PUBLIC")
        .await
        .unwrap();
    admin
        .execute("CREATE ROLE enum_without_type_usage_contract NOLOGIN")
        .await
        .unwrap();
    admin
        .execute("GRANT USAGE ON SCHEMA enum_without_type_usage TO enum_without_type_usage_contract")
        .await
        .unwrap();
    admin
        .execute(
            "GRANT SELECT, UPDATE ON enum_without_type_usage.rows \
             TO enum_without_type_usage_contract",
        )
        .await
        .unwrap();

    let mut session = admin.open_session().await.unwrap();
    let control = crate::no_timeout();
    session
        .query_params_controlled("SET ROLE enum_without_type_usage_contract", &[], &control)
        .await
        .unwrap();
    let privilege = session
        .query_params_controlled(
            "SELECT current_user::text, \
                    has_type_privilege(current_user, \
                      'enum_without_type_usage.state'::regtype, 'USAGE')",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        privilege.rows,
        vec![vec![
            Value::Text("enum_without_type_usage_contract".into()),
            Value::Bool(false)
        ]]
    );

    let bound = session
        .query_params_controlled(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_without_type_usage.rows \
             WHERE state IS NOT DISTINCT FROM $1 ORDER BY id",
            &[Value::Text("common".into())],
            &control,
        )
        .await
        .unwrap();
    let native = admin
        .query(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_without_type_usage.rows \
             WHERE state IS NOT DISTINCT FROM 'common'::enum_without_type_usage.state \
             ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(bound.rows, native.rows);

    let null_bound = session
        .query_params_controlled(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_without_type_usage.rows \
             WHERE state IS NOT DISTINCT FROM $1 ORDER BY id",
            &[Value::Null],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        null_bound.rows,
        vec![vec![
            Value::Int(2),
            Value::Null,
            Value::Text("enum_without_type_usage.state".into()),
            Value::Text("null sibling".into()),
        ]]
    );

    let update = session
        .query_params_controlled(
            "UPDATE enum_without_type_usage.rows SET state = $1 WHERE id = 2 \
             RETURNING id, state::text, pg_typeof(state)::text, sibling",
            &[Value::Text("target-only".into())],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        update.rows,
        vec![vec![
            Value::Int(2),
            Value::Text("target-only".into()),
            Value::Text("enum_without_type_usage.state".into()),
            Value::Text("null sibling".into()),
        ]]
    );

    let invalid = session
        .query_params_controlled(
            "UPDATE enum_without_type_usage.rows SET state = $1 WHERE id = 1",
            &[Value::Text("not-a-label".into())],
            &control,
        )
        .await
        .expect_err("an invalid enum label must retain PostgreSQL's refusal");
    let native_invalid = admin
        .query("SELECT 'not-a-label'::enum_without_type_usage.state")
        .await
        .expect_err("PostgreSQL must reject an invalid enum label natively");
    let sqlstate = |error: &DriverError| match error {
        DriverError::Query { sqlstate, .. } => sqlstate.clone(),
        _ => None,
    };
    assert_eq!(sqlstate(&invalid).as_deref(), Some("22P02"));
    assert_eq!(sqlstate(&invalid), sqlstate(&native_invalid));

    session.close().await.unwrap();
    let rows = admin
        .query(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_without_type_usage.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        rows.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("common".into()),
                Value::Text("enum_without_type_usage.state".into()),
                Value::Text("keep".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("target-only".into()),
                Value::Text("enum_without_type_usage.state".into()),
                Value::Text("null sibling".into()),
            ],
        ]
    );
}

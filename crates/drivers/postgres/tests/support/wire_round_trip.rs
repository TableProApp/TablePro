#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{ColumnInfo, OperationControl, Session, Value};

pub async fn assert_wire_round_trip(
    session: &mut dyn Session,
    control: &OperationControl,
    kind: &str,
    column: &ColumnInfo,
    value: &Value,
    expected: &Value,
) {
    let send = if kind.ends_with("[]") {
        "array_send".to_string()
    } else {
        format!("{kind}_send")
    };
    let literal = tablepro_core::sql_literal::render_sql_literal("postgres", value).unwrap();
    let sql = format!("SELECT encode({send}({literal}::{kind}), 'hex')");
    assert_eq!(
        &first_cell(session, control, &sql, &[]).await,
        expected,
        "{kind}: literal {literal}"
    );
    let cast = if matches!(value, Value::Text(_) | Value::Null) {
        "::text"
    } else {
        ""
    };
    let sql = format!("SELECT encode({send}($1{cast}::{kind}), 'hex')");
    let bound = first_cell(session, control, &sql, std::slice::from_ref(value)).await;
    assert_eq!(&bound, expected, "{kind}: bound {literal}");
    for sql in [
        "DROP TABLE IF EXISTS wire_export_target".to_string(),
        format!("CREATE TEMP TABLE wire_export_target (value {kind})"),
    ] {
        session.query_params_controlled(&sql, &[], control).await.unwrap();
    }
    let insert = tablepro_core::sql_literal::build_insert_literal(
        "postgres",
        None,
        "wire_export_target",
        std::slice::from_ref(column),
        std::slice::from_ref(value),
    )
    .unwrap();
    session.query_params_controlled(&insert, &[], control).await.unwrap();
    let sql = format!("SELECT encode({send}(value), 'hex') FROM wire_export_target");
    assert_eq!(
        &first_cell(session, control, &sql, &[]).await,
        expected,
        "{kind}: INSERT {literal}"
    );
}

async fn first_cell(session: &mut dyn Session, control: &OperationControl, sql: &str, params: &[Value]) -> Value {
    let result = session
        .query_params_controlled(sql, params, control)
        .await
        .unwrap_or_else(|error| panic!("{sql}: {error}"));
    result.rows[0][0].clone()
}

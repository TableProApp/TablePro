#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn list_databases_returns_connectable_user_databases_only() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE DATABASE alpha_db").await.unwrap();

    let names = conn.list_databases().await.unwrap();

    assert_eq!(
        names,
        vec!["alpha_db".to_string(), "postgres".to_string(), "test".to_string()]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_failed_statement_reports_the_character_position_of_the_error() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;

    let error = conn.query("SELECT 'é', * FROM missing_table").await.unwrap_err();

    let tablepro_core::DriverError::Query { sqlstate, position, .. } = error else {
        panic!("expected a query error, got {error:?}")
    };
    assert_eq!(sqlstate.as_deref(), Some("42P01"));
    assert_eq!(position, Some(20));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn session_string_settings_follow_standard_conforming_strings() {
    use tablepro_core::sql_syntax::SqlGrammar;
    use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};
    use tablepro_core::{OperationControl, Value};
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
    let standard = Some(LexicalSettings::default_for(SqlGrammar::PostgreSql));
    assert_eq!(
        connection.lexical_settings_controlled(&control).await.unwrap(),
        standard
    );
    let mut session = connection.open_session().await.expect("open session");
    assert_eq!(session.lexical_settings_controlled(&control).await.unwrap(), standard);

    session
        .query_params_controlled("SET standard_conforming_strings = off", &[], &control)
        .await
        .unwrap();
    let settings = session.lexical_settings_controlled(&control).await.unwrap().unwrap();
    assert!(settings.backslash_escapes);
    let script = r"SELECT 'it\'s' AS quoted; SELECT 2 AS second";
    let plan = ScriptPlan::build(script, SqlGrammar::PostgreSql, settings);
    assert!(plan.diagnostics().is_empty(), "{:?}", plan.diagnostics());
    let mut rows = Vec::new();
    for statement in plan.statements() {
        let sql = statement.text(script).trim();
        rows.push(session.query_params_controlled(sql, &[], &control).await.unwrap().rows);
    }
    assert_eq!(
        rows,
        [vec![vec![Value::Text("it's".into())]], vec![vec![Value::Int(2)]]]
    );
    assert_eq!(
        connection.lexical_settings_controlled(&control).await.unwrap(),
        standard,
        "the pool keeps the server default"
    );

    session.query_params_controlled("BEGIN", &[], &control).await.unwrap();
    assert!(
        session
            .query_params_controlled("SELECT 1 / 0", &[], &control)
            .await
            .is_err()
    );
    assert_eq!(
        session.lexical_settings_controlled(&control).await.unwrap(),
        Some(settings),
        "an aborted transaction still reports the setting"
    );
    session
        .query_params_controlled("ROLLBACK", &[], &control)
        .await
        .unwrap();
    session
        .query_params_controlled("RESET standard_conforming_strings", &[], &control)
        .await
        .unwrap();
    assert_eq!(session.lexical_settings_controlled(&control).await.unwrap(), standard);
    session.close().await.unwrap();
}

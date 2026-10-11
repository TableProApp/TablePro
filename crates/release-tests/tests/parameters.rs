#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_core::sql_lex::split_statements;
use tablepro_core::{Value, extract_named_parameters};
use tablepro_release_tests::Fixture;

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn named_parameters_bind_values_through_the_driver() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    let parsed = extract_named_parameters("SELECT amount FROM release_items WHERE name = :name", "postgres");
    assert_eq!(parsed.sql, "SELECT amount FROM release_items WHERE name = $1");

    let result = connection
        .query_params(&parsed.sql, &[Value::Text("beta".into())])
        .await
        .expect("parameterized select");

    assert_eq!(result.rows.len(), 1);
    assert_eq!(result.rows[0].first(), Some(&Value::Int(20)));
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_sql_payload_in_a_parameter_stays_data() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    let parsed = extract_named_parameters("SELECT amount FROM release_items WHERE name = :name", "postgres");

    let result = connection
        .query_params(&parsed.sql, &[Value::Text("' OR 1=1 --".into())])
        .await
        .expect("parameterized select with a sql payload");

    assert!(result.rows.is_empty(), "the payload must not match any row");

    let intact = connection
        .query("SELECT count(*) FROM release_items")
        .await
        .expect("table still readable");
    assert_eq!(intact.rows[0].first(), Some(&Value::Int(3)));
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn repeated_parameters_bind_the_same_value_at_every_position() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    let parsed = extract_named_parameters(
        "SELECT count(*) FROM release_items WHERE amount >= :bound AND amount <= :bound",
        "postgres",
    );
    assert_eq!(parsed.bindings, vec!["bound", "bound"]);

    let result = connection
        .query_params(&parsed.sql, &[Value::Int(20), Value::Int(20)])
        .await
        .expect("parameterized count");

    assert_eq!(result.rows[0].first(), Some(&Value::Int(1)));
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_dollar_quoted_function_body_executes_as_one_statement() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    let script = "CREATE OR REPLACE FUNCTION release_split_probe(bound int) RETURNS int AS $body$\n\
                  DECLARE total int;\n\
                  BEGIN\n\
                    SELECT count(*) INTO total FROM release_items WHERE amount >= bound;\n\
                    RETURN total;\n\
                  END;\n\
                  $body$ LANGUAGE plpgsql;\n\
                  SELECT release_split_probe(20)";

    let statements = split_statements(script, "postgres");
    assert_eq!(
        statements.len(),
        2,
        "the function body must not split at its internal semicolons"
    );

    for statement in &statements[..1] {
        connection.execute(statement).await.expect("create the function");
    }

    let result = connection
        .query(&statements[1])
        .await
        .expect("call the function the split produced");
    assert_eq!(result.rows[0].first(), Some(&Value::Int(2)));

    connection
        .execute("DROP FUNCTION release_split_probe(int)")
        .await
        .expect("drop the probe function");
}

/// PostgreSQL treats a backslash as an ordinary character inside a
/// standard string literal, so escaping one would corrupt the value.
/// This is the other half of the MySQL case: the same payload has to
/// round-trip unchanged through a rendered INSERT on both engines.
#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_copied_insert_round_trips_a_value_holding_a_backslash_and_a_quote() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    connection
        .execute("CREATE TABLE copy_probe (id int PRIMARY KEY, note text)")
        .await
        .expect("create the probe table");

    let payload = "x\\' OR 1=1 -- ";
    connection
        .execute_params(
            "INSERT INTO copy_probe (id, note) VALUES ($1, $2)",
            &[Value::Int(1), Value::Text(payload.into())],
        )
        .await
        .expect("store the payload as data");

    let columns = connection.fetch_columns(None, "copy_probe").await.expect("columns");
    let loaded = connection
        .query("SELECT id, note FROM copy_probe WHERE id = 1")
        .await
        .expect("read the row back");
    let row: Vec<Value> = loaded.rows[0]
        .iter()
        .cloned()
        .map(|value| match value {
            Value::Int(id) => Value::Int(id + 1),
            other => other,
        })
        .collect();

    let sql = tablepro_core::sql_literal::build_insert_literal("postgres", None, "copy_probe", &columns, &row)
        .expect("render the insert");
    connection.execute(&sql).await.expect("the copied insert must execute");

    let after = connection
        .query("SELECT note FROM copy_probe WHERE id = 2")
        .await
        .expect("read the copied row");
    assert_eq!(
        after.rows,
        vec![vec![Value::Text(payload.into())]],
        "postgres must keep the backslash exactly as stored"
    );

    connection
        .execute("DROP TABLE copy_probe")
        .await
        .expect("drop the probe table");
}

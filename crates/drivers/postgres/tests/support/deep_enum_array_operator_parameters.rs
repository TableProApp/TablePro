use tablepro_core::{Connection, Transaction, Value};

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_deep_enum_array_contains_and_overlap_parameter_boundary() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    for levels in [63, 64] {
        let (schema, array_type) = create_domain_array(&*connection, levels).await;
        assert_operator_parameter_boundary(&*connection, &schema, &array_type, levels).await;
    }
}

async fn create_domain_array(connection: &dyn Connection, levels: usize) -> (String, String) {
    let schema = format!("deep_enum_array_operator_{levels}");
    connection.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    connection
        .execute(&format!("CREATE SCHEMA {schema}_shadow"))
        .await
        .unwrap();
    connection
        .execute(&format!("CREATE TYPE {schema}_shadow.state AS ENUM ('shadow')"))
        .await
        .unwrap();
    connection
        .execute(&format!("CREATE TYPE {schema}.state AS ENUM ('ready', 'paused')"))
        .await
        .unwrap();
    let array_type = create_domain_chain(connection, &schema, levels).await;
    create_array_table(connection, &schema, &array_type).await;
    (schema, array_type)
}

async fn create_domain_chain(connection: &dyn Connection, schema: &str, levels: usize) -> String {
    let mut previous = format!("{schema}.state");
    for level in 1..=levels {
        let name = format!("{schema}.state_domain_{level}");
        connection
            .execute(&format!("CREATE DOMAIN {name} AS {previous}"))
            .await
            .unwrap();
        previous = name;
    }
    format!("{previous}[]")
}

async fn create_array_table(connection: &dyn Connection, schema: &str, array_type: &str) {
    let scalar_type = array_type.strip_suffix("[]").unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE {schema}.items (id INT PRIMARY KEY, labels {array_type})"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {schema}.items VALUES \
             (1, ARRAY['ready'::{scalar_type}, NULL::{scalar_type}])"
        ))
        .await
        .unwrap();
}

async fn assert_operator_parameter_boundary(
    connection: &dyn Connection,
    schema: &str,
    array_type: &str,
    levels: usize,
) {
    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute(&format!("SET LOCAL search_path TO {schema}_shadow, public"))
        .await
        .unwrap();
    for (parameter, literal) in [
        (Value::Text("{ready}".into()), "'{ready}'"),
        (Value::Text("{}".into()), "'{}'"),
        (Value::Null, "NULL"),
    ] {
        compare_operator_parameter(&mut transaction, schema, array_type, levels, parameter, literal).await;
    }
    transaction.rollback().await.unwrap();
}

async fn compare_operator_parameter(
    transaction: &mut Box<dyn Transaction>,
    schema: &str,
    array_type: &str,
    levels: usize,
    parameter: Value,
    literal: &str,
) {
    let query = format!(
        "SELECT labels @> $1, labels && $2, pg_typeof($1)::text, pg_typeof($2)::text, \
         encode(array_send($1), 'hex'), encode(array_send($2), 'hex') \
         FROM {schema}.items"
    );
    if levels == 63 {
        let expected = transaction
            .query(&format!(
                "SELECT labels @> {literal}::{array_type}, labels && {literal}::{array_type}, \
                 pg_typeof({literal}::{array_type})::text, \
                 pg_typeof({literal}::{array_type})::text, \
                 encode(array_send({literal}::{array_type}), 'hex'), \
                 encode(array_send({literal}::{array_type}), 'hex') FROM {schema}.items"
            ))
            .await
            .unwrap();
        let actual = transaction
            .query_params(&query, &[parameter.clone(), parameter])
            .await
            .unwrap();
        assert_eq!(actual.rows, expected.rows, "63-level operator parameter {literal}");
    } else {
        let error = transaction
            .query_params(&query, &[parameter.clone(), parameter])
            .await
            .expect_err("64-level enum-array operator parameter must refuse");
        assert!(
            matches!(&error, tablepro_core::DriverError::Unsupported(message)
                if message.contains("resolvable depth")),
            "64-level operator parameter {literal}: {error:?}"
        );
    }
}

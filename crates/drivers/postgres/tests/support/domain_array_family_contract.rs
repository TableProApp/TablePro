#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_arrays_over_text_numeric_and_timestamptz_use_base_types() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let schema = "domain_array_family";
    connection.execute(&format!("CREATE SCHEMA {schema}")).await.unwrap();
    for statement in [
        format!("CREATE DOMAIN {schema}.label AS text"),
        format!("CREATE DOMAIN {schema}.amount AS numeric CHECK (VALUE >= 0)"),
        format!("CREATE DOMAIN {schema}.instant AS timestamptz"),
    ] {
        connection.execute(&statement).await.unwrap();
    }

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL TIME ZONE 'Asia/Kathmandu'")
        .await
        .unwrap();
    let result = transaction
        .query(&format!(
            "SELECT ARRAY['NULL'::{schema}.label, ''::{schema}.label, \
                    'a,b'::{schema}.label, NULL::{schema}.label], \
                    ARRAY['12345678901234567890.123400'::{schema}.amount, \
                          '1.2300'::{schema}.amount, NULL::{schema}.amount], \
                    ARRAY['2024-11-03 01:30:00.123456-04'::{schema}.instant, \
                          '2024-11-03 01:30:00.123456-05'::{schema}.instant, \
                          'infinity'::{schema}.instant, NULL::{schema}.instant]"
        ))
        .await
        .unwrap();
    assert_eq!(
        result
            .columns
            .iter()
            .map(|column| column.data_type.as_str())
            .collect::<Vec<_>>(),
        [
            "domain_array_family.label[]",
            "domain_array_family.amount[]",
            "domain_array_family.instant[]",
        ]
    );
    let native = transaction
        .query(&format!(
            "SELECT \
                pg_typeof(ARRAY['NULL'::{schema}.label, ''::{schema}.label, \
                    'a,b'::{schema}.label, NULL::{schema}.label])::text, \
                array_to_json(ARRAY['NULL'::{schema}.label, ''::{schema}.label, \
                    'a,b'::{schema}.label, NULL::{schema}.label])::text, \
                encode(array_send(ARRAY['NULL'::{schema}.label, ''::{schema}.label, \
                    'a,b'::{schema}.label, NULL::{schema}.label]), 'hex'), \
                pg_typeof(ARRAY['12345678901234567890.123400'::{schema}.amount, \
                    '1.2300'::{schema}.amount, NULL::{schema}.amount])::text, \
                array_to_json(ARRAY['12345678901234567890.123400'::{schema}.amount, \
                    '1.2300'::{schema}.amount, NULL::{schema}.amount])::text, \
                encode(array_send(ARRAY['12345678901234567890.123400'::{schema}.amount, \
                    '1.2300'::{schema}.amount, NULL::{schema}.amount]), 'hex'), \
                pg_typeof(ARRAY['2024-11-03 01:30:00.123456-04'::{schema}.instant, \
                    '2024-11-03 01:30:00.123456-05'::{schema}.instant, \
                    'infinity'::{schema}.instant, NULL::{schema}.instant])::text, \
                array_to_json(ARRAY['2024-11-03 01:30:00.123456-04'::{schema}.instant, \
                    '2024-11-03 01:30:00.123456-05'::{schema}.instant, \
                    'infinity'::{schema}.instant, NULL::{schema}.instant])::text, \
                encode(array_send(ARRAY['2024-11-03 01:30:00.123456-04'::{schema}.instant, \
                    '2024-11-03 01:30:00.123456-05'::{schema}.instant, \
                    'infinity'::{schema}.instant, NULL::{schema}.instant]), 'hex')"
        ))
        .await
        .unwrap();

    for (column, offset, domain) in [(0, 0, "label"), (1, 3, "amount"), (2, 6, "instant")] {
        assert_eq!(native.rows[0][offset], Value::Text(format!("{schema}.{domain}[]")));
        let bound = transaction
            .query_params(
                &format!(
                    "SELECT array_to_json($1::text::{schema}.{domain}[])::text, \
                            encode(array_send($1::text::{schema}.{domain}[]), 'hex')"
                ),
                std::slice::from_ref(&result.rows[0][column]),
            )
            .await
            .unwrap();
        assert_eq!(bound.rows[0][0], native.rows[0][offset + 1], "{domain}");
        assert_eq!(bound.rows[0][1], native.rows[0][offset + 2], "{domain}");
    }
    transaction.rollback().await.unwrap();
}

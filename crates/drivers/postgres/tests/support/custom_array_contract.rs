#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_composite_array_refusal_preserves_rows() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection.execute("CREATE SCHEMA custom_array_contract").await.unwrap();
    connection
        .execute(
            "CREATE TYPE custom_array_contract.entry AS \
             (label text, quantity integer)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE custom_array_contract.rows \
             (id integer PRIMARY KEY, value custom_array_contract.entry[], sibling text NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO custom_array_contract.rows VALUES \
             (1, ARRAY[ROW('a,b', 1)::custom_array_contract.entry, NULL], 'target'), \
             (2, ARRAY[ROW('sibling', 2)::custom_array_contract.entry], 'sibling')",
        )
        .await
        .unwrap();

    let result = connection
        .query(
            "SELECT value, pg_typeof(value)::text, value::text, \
             array_to_json(value)::text, encode(array_send(value), 'hex') \
             FROM custom_array_contract.rows WHERE id = 1",
        )
        .await
        .unwrap();
    let refusal = result.rows[0][0].clone();
    assert!(
        matches!(&refusal, Value::Undecodable(name) if name.contains("[]")),
        "custom composite arrays must be visibly undecodable: {refusal:?}"
    );
    assert_eq!(result.rows[0][1], Value::Text("custom_array_contract.entry[]".into()));
    assert_eq!(
        result.rows[0][3],
        Value::Text(r#"[{"label":"a,b","quantity":1},null]"#.into())
    );
    let before = connection
        .query(
            "SELECT id, value::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex'), sibling \
             FROM custom_array_contract.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &refusal).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(&refusal))
            .await
            .is_err()
    );
    assert!(
        connection
            .execute_params(
                "UPDATE custom_array_contract.rows SET value = $1 WHERE id = 1",
                &[refusal],
            )
            .await
            .is_err()
    );

    let after = connection
        .query(
            "SELECT id, value::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex'), sibling \
             FROM custom_array_contract.rows ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(after.rows, before.rows, "refused binding changed stored values");
    assert_eq!(after.rows[0][1], result.rows[0][2]);
    assert_eq!(after.rows[0][2], result.rows[0][3]);
    assert_eq!(after.rows[0][3], result.rows[0][4]);
    assert_eq!(after.rows[0][4], Value::Text("target".into()));
    assert_eq!(after.rows[1][4], Value::Text("sibling".into()));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_money_array_refusal_preserves_target_and_sibling_rows() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection
        .execute(
            "CREATE TABLE money_array_refusal \
             (id integer PRIMARY KEY, value money[], sibling text NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO money_array_refusal VALUES \
             (1, ARRAY['12.34'::money, NULL, '-56.78'::money], 'target'), \
             (2, ARRAY['9.99'::money], 'sibling')",
        )
        .await
        .unwrap();

    let source = connection
        .query(
            "SELECT value, pg_typeof(value)::text, value::text, \
             array_to_json(value)::text, encode(array_send(value), 'hex') \
             FROM money_array_refusal WHERE id = 1",
        )
        .await
        .unwrap();
    assert_eq!(source.rows[0][1], Value::Text("money[]".into()));
    assert!(
        matches!(&source.rows[0][0], Value::Undecodable(name) if !name.is_empty()),
        "money[] must remain explicitly unsupported: {:?}",
        source.rows[0][0]
    );
    assert_ne!(source.rows[0][2], Value::Text("{NULL}".into()));
    let refusal = source.rows[0][0].clone();
    let before = connection
        .query(
            "SELECT id, value::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex'), sibling \
             FROM money_array_refusal ORDER BY id",
        )
        .await
        .unwrap();

    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &refusal).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(&refusal))
            .await
            .is_err()
    );
    assert!(
        connection
            .execute_params("UPDATE money_array_refusal SET value = $1 WHERE id = 1", &[refusal],)
            .await
            .is_err()
    );
    let after = connection
        .query(
            "SELECT id, value::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex'), sibling \
             FROM money_array_refusal ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(after.rows, before.rows, "refused binding changed stored values");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_point_array_refusal_preserves_target_and_sibling_rows() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    connection
        .execute("CREATE TABLE point_array_refusal (id integer PRIMARY KEY, value point[], sibling text NOT NULL)")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO point_array_refusal VALUES \
             (1, ARRAY[point '(1,2)', NULL, point '(-3.5,4)'], 'target'), \
             (2, ARRAY[point '(9,9)'], 'sibling')",
        )
        .await
        .unwrap();

    let source = connection
        .query(
            "SELECT value, pg_typeof(value)::text, value::text, \
             array_to_json(value)::text, encode(array_send(value), 'hex') \
             FROM point_array_refusal WHERE id = 1",
        )
        .await
        .unwrap();
    assert_eq!(source.rows[0][1], Value::Text("point[]".into()));
    assert!(matches!(&source.rows[0][0], Value::Undecodable(name) if !name.is_empty()));
    assert_ne!(source.rows[0][2], Value::Text("{}".into()));
    let refusal = source.rows[0][0].clone();
    let before = connection
        .query(
            "SELECT id, value::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex'), sibling \
             FROM point_array_refusal ORDER BY id",
        )
        .await
        .unwrap();
    assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &refusal).is_err());
    assert!(
        connection
            .query_params("SELECT $1", std::slice::from_ref(&refusal))
            .await
            .is_err()
    );
    assert!(
        connection
            .execute_params("UPDATE point_array_refusal SET value = $1 WHERE id = 1", &[refusal],)
            .await
            .is_err()
    );

    let after = connection
        .query(
            "SELECT id, value::text, array_to_json(value)::text, \
             encode(array_send(value), 'hex'), sibling \
             FROM point_array_refusal ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(after.rows, before.rows, "refused binding changed stored values");
    assert_eq!(after.rows[0][1], source.rows[0][2]);
    assert_eq!(after.rows[0][2], source.rows[0][3]);
    assert_eq!(after.rows[0][3], source.rows[0][4]);
    assert_eq!(after.rows[0][4], Value::Text("target".into()));
    assert_eq!(after.rows[1][4], Value::Text("sibling".into()));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_geometric_array_refusals_preserve_target_and_sibling_rows() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;
    let cases = [
        ("point", "point '(1,2)'", "point '(-3.5,4)'"),
        ("line", "'{1,2,3}'::line", "'{-2,0,1}'::line"),
        ("lseg", "'[(1,2),(3,4)]'::lseg", "'[(-2,0),(1,5)]'::lseg"),
        ("box", "'(3,4),(1,2)'::box", "'(0,5),(-2,1)'::box"),
        ("path", "'((1,2),(3,4))'::path", "'((-2,0),(1,5))'::path"),
        (
            "polygon",
            "'((1,2),(3,4),(5,6))'::polygon",
            "'((-2,0),(1,5),(3,1))'::polygon",
        ),
        ("circle", "'<(1,2),3>'::circle", "'<(-2,0),1.5>'::circle"),
    ];

    for (native_type, first, second) in cases {
        let table = format!("geometry_array_refusal_{native_type}");
        connection
            .execute(&format!(
                "CREATE TABLE {table} \
                 (id integer PRIMARY KEY, value {native_type}[], sibling text NOT NULL)"
            ))
            .await
            .unwrap();
        connection
            .execute(&format!(
                "INSERT INTO {table} VALUES \
                 (1, ARRAY[{first}, NULL, {second}]::{native_type}[], 'target'), \
                 (2, ARRAY[{second}]::{native_type}[], 'sibling')"
            ))
            .await
            .unwrap();

        let source = connection
            .query(&format!(
                "SELECT value, pg_typeof(value)::text, value::text, \
                 array_to_json(value)::text, encode(array_send(value), 'hex') \
                 FROM {table} WHERE id = 1"
            ))
            .await
            .unwrap();
        assert_eq!(
            source.rows[0][1],
            Value::Text(format!("{native_type}[]")),
            "native geometry array type changed"
        );
        let refusal = source.rows[0][0].clone();
        assert!(
            matches!(&refusal, Value::Undecodable(name) if name.eq_ignore_ascii_case(&format!("{native_type}[]"))),
            "{native_type}[] must remain visibly undecodable: {refusal:?}"
        );
        assert_ne!(source.rows[0][2], Value::Text("{}".into()));
        let before = connection
            .query(&format!(
                "SELECT id, value::text, array_to_json(value)::text, \
                 encode(array_send(value), 'hex'), sibling \
                 FROM {table} ORDER BY id"
            ))
            .await
            .unwrap();

        assert!(tablepro_core::sql_literal::render_sql_literal("postgres", &refusal).is_err());
        assert!(
            connection
                .query_params("SELECT $1", std::slice::from_ref(&refusal))
                .await
                .is_err()
        );
        assert!(
            connection
                .execute_params(&format!("UPDATE {table} SET value = $1 WHERE id = 1"), &[refusal])
                .await
                .is_err()
        );

        let after = connection
            .query(&format!(
                "SELECT id, value::text, array_to_json(value)::text, \
                 encode(array_send(value), 'hex'), sibling \
                 FROM {table} ORDER BY id"
            ))
            .await
            .unwrap();
        assert_eq!(after.rows, before.rows, "{native_type}[] refusal changed stored values");
        assert_eq!(after.rows[0][1], source.rows[0][2]);
        assert_eq!(after.rows[0][2], source.rows[0][3]);
        assert_eq!(after.rows[0][3], source.rows[0][4]);
        assert_eq!(after.rows[0][4], Value::Text("target".into()));
        assert_eq!(after.rows[1][4], Value::Text("sibling".into()));
    }
}

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{Connection, Value};

pub async fn assert_vector_contract(conn: &dyn Connection) {
    for table in ["vector_source", "vector_bound", "vector_exported"] {
        conn.execute(&format!(
            "CREATE TABLE {table} (id int PRIMARY KEY, a int2vector, b oidvector)"
        ))
        .await
        .unwrap();
    }
    conn.execute(
        "INSERT INTO vector_source VALUES (1, '1 2', '23 25'), (2, '', ''), (3, '-32768 32767', '0 4294967295')",
    )
    .await
    .unwrap();
    let result = conn
        .query("SELECT id, a, b FROM vector_source ORDER BY id")
        .await
        .unwrap();
    let text = |value: &str| Value::Text(value.into());
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(1), text("1 2"), text("23 25")],
            vec![Value::Int(2), text(""), text("")],
            vec![Value::Int(3), text("-32768 32767"), text("0 4294967295")],
        ]
    );
    let columns = conn.fetch_columns(None, "vector_exported").await.unwrap();
    for row in &result.rows {
        conn.execute_params(
            "INSERT INTO vector_bound VALUES ($1, $2::int2vector, $3::oidvector)",
            row,
        )
        .await
        .unwrap();
        let insert =
            tablepro_core::sql_literal::build_insert_literal("postgres", None, "vector_exported", &columns, row)
                .unwrap();
        conn.execute(&insert).await.unwrap();
    }
    for copy in ["vector_bound", "vector_exported"] {
        let matching = conn
            .query(&format!(
                "SELECT count(*) FROM vector_source s JOIN {copy} c ON s.id = c.id \
                 AND s.a::text = c.a::text AND s.b::text = c.b::text"
            ))
            .await
            .unwrap();
        assert_eq!(matching.rows, vec![vec![Value::Int(3)]], "{copy}");
    }
}

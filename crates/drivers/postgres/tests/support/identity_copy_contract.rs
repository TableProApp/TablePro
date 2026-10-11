use crate::{connect, start_pg};
use tablepro_core::Value;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_postgres_copy_insert_regenerates_identity_values() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;

    for (table, generation) in [
        ("identity_always_copy", "ALWAYS"),
        ("identity_default_copy", "BY DEFAULT"),
    ] {
        connection
            .execute(&format!(
                "CREATE TABLE {table} (\
                    id bigint GENERATED {generation} AS IDENTITY PRIMARY KEY, \
                    note text NOT NULL, \
                    doubled bigint GENERATED ALWAYS AS (id * 2) STORED)"
            ))
            .await
            .unwrap();
        connection
            .execute(&format!("INSERT INTO {table} (note) VALUES ('source')"))
            .await
            .unwrap();

        let columns = connection.fetch_columns(None, table).await.unwrap();
        assert!(columns[0].is_auto_increment, "{table} identity metadata");
        assert!(columns[2].is_generated, "{table} computed-column metadata");
        let row = connection
            .query(&format!("SELECT id, note, doubled FROM {table}"))
            .await
            .unwrap()
            .rows
            .remove(0);
        let insert = tablepro_core::sql_literal::build_insert_literal("postgres", None, table, &columns, &row).unwrap();
        assert_eq!(insert, format!("INSERT INTO \"{table}\" (\"note\") VALUES ('source');"));
        connection.execute(&insert).await.unwrap();

        assert_eq!(
            connection
                .query(&format!("SELECT id, note, doubled FROM {table} ORDER BY id"))
                .await
                .unwrap()
                .rows,
            vec![
                vec![Value::Int(1), Value::Text("source".into()), Value::Int(2)],
                vec![Value::Int(2), Value::Text("source".into()), Value::Int(4)],
            ]
        );
    }

    connection
        .execute("CREATE TABLE identity_only_copy (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO identity_only_copy DEFAULT VALUES")
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "identity_only_copy").await.unwrap();
    let row = connection
        .query("SELECT id FROM identity_only_copy")
        .await
        .unwrap()
        .rows
        .remove(0);
    let insert =
        tablepro_core::sql_literal::build_insert_literal("postgres", None, "identity_only_copy", &columns, &row)
            .unwrap();
    assert_eq!(insert, "INSERT INTO \"identity_only_copy\" DEFAULT VALUES;");
    connection.execute(&insert).await.unwrap();
    assert_eq!(
        connection
            .query("SELECT id FROM identity_only_copy ORDER BY id")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)], vec![Value::Int(2)]]
    );
}

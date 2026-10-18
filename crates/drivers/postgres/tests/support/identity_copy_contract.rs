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

#[tokio::test]
#[ignore = "requires docker"]
async fn sequence_sync_preserves_ahead_sequences_and_negative_increments() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;

    connection
        .execute("CREATE TABLE sequence_ahead (id bigserial PRIMARY KEY)")
        .await
        .unwrap();
    connection
        .execute("SELECT setval(pg_get_serial_sequence('sequence_ahead', 'id'), 40, true)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO sequence_ahead (id) VALUES (5)")
        .await
        .unwrap();
    connection
        .synchronize_auto_increment_sequences(None, "sequence_ahead", &["id".into()])
        .await
        .unwrap();
    connection
        .execute("INSERT INTO sequence_ahead DEFAULT VALUES")
        .await
        .unwrap();
    assert_eq!(
        connection
            .query("SELECT id FROM sequence_ahead ORDER BY id")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(5)], vec![Value::Int(41)]]
    );

    connection
        .execute(
            "CREATE TABLE sequence_decreasing (
                id bigint GENERATED ALWAYS AS IDENTITY (START WITH 0 INCREMENT BY -1 MAXVALUE 0) PRIMARY KEY
            )",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO sequence_decreasing (id) OVERRIDING SYSTEM VALUE VALUES (0)")
        .await
        .unwrap();
    connection
        .synchronize_auto_increment_sequences(None, "sequence_decreasing", &["id".into()])
        .await
        .unwrap();
    connection
        .execute("INSERT INTO sequence_decreasing DEFAULT VALUES")
        .await
        .unwrap();
    assert_eq!(
        connection
            .query("SELECT id FROM sequence_decreasing ORDER BY id DESC")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(0)], vec![Value::Int(-1)]]
    );

    connection.execute("CREATE SCHEMA \"sequence schema\"").await.unwrap();
    connection
        .execute(
            "CREATE TABLE \"sequence schema\".\"a.table\" (
                \"id value\" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY
            )",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO \"sequence schema\".\"a.table\" (\"id value\")
             OVERRIDING SYSTEM VALUE VALUES (1)",
        )
        .await
        .unwrap();
    connection
        .synchronize_auto_increment_sequences(Some("sequence schema"), "a.table", &["id value".into()])
        .await
        .unwrap();
    connection
        .execute("INSERT INTO \"sequence schema\".\"a.table\" DEFAULT VALUES")
        .await
        .unwrap();
    assert_eq!(
        connection
            .query("SELECT \"id value\" FROM \"sequence schema\".\"a.table\" ORDER BY \"id value\"")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)], vec![Value::Int(2)]]
    );

    connection.execute("CREATE SEQUENCE unowned_sequence").await.unwrap();
    connection
        .execute(
            "CREATE TABLE unowned_sequence_table (
                id bigint DEFAULT nextval('unowned_sequence')
            )",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO unowned_sequence_table (id) VALUES (1)")
        .await
        .unwrap();
    assert!(matches!(
        connection
            .synchronize_auto_increment_sequences(None, "unowned_sequence_table", &["id".into()])
            .await,
        Err(tablepro_core::DriverError::Unsupported(_))
    ));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn explicit_import_values_advance_identity_and_serial_sequences() {
    let (_container, options) = start_pg().await;
    let connection = connect(options).await;

    for (table, declaration, insert) in [
        (
            "import_identity_always",
            "bigint GENERATED ALWAYS AS IDENTITY",
            "INSERT INTO import_identity_always (id) OVERRIDING SYSTEM VALUE VALUES (1)",
        ),
        (
            "import_serial",
            "bigserial",
            "INSERT INTO import_serial (id) VALUES (1)",
        ),
    ] {
        connection
            .execute(&format!("CREATE TABLE {table} (id {declaration} PRIMARY KEY)"))
            .await
            .unwrap();
        connection.execute(insert).await.unwrap();
        connection
            .synchronize_auto_increment_sequences(None, table, &["id".into()])
            .await
            .unwrap();
        let generated = connection.execute(&format!("INSERT INTO {table} DEFAULT VALUES")).await;
        assert!(
            generated.is_ok(),
            "the next generated value must not collide in {table}"
        );
        assert_eq!(
            connection
                .query(&format!("SELECT id FROM {table} ORDER BY id"))
                .await
                .unwrap()
                .rows,
            vec![vec![Value::Int(1)], vec![Value::Int(2)]]
        );
    }
}

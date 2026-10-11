use super::{connect, start_mysql};
use tablepro_core::Value;

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_sql_copy_export_preserves_auto_increment_ids_and_next_value() {
    let (_container, options) = start_mysql().await;
    let conn = connect(options).await;
    conn.execute(
        "CREATE TABLE identity_source (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, note VARCHAR(64) NOT NULL)",
    )
    .await
    .unwrap();
    conn.execute("INSERT INTO identity_source (id, note) VALUES (7, 'copy'), (13, 'copy again')")
        .await
        .unwrap();
    conn.execute("CREATE TABLE identity_copy LIKE identity_source")
        .await
        .unwrap();

    let result = conn
        .query("SELECT id, note FROM identity_source ORDER BY id")
        .await
        .unwrap();
    let csv = tablepro_core::export::CsvOptions::default();
    let export = tablepro_core::export::ResultExport {
        format: tablepro_core::export::ResultFormat::Sql,
        csv: &csv,
        sql: Some(tablepro_core::export::SqlTarget {
            driver_id: "mysql",
            schema: None,
            table: "identity_copy",
        }),
    };
    let file = tempfile::NamedTempFile::new().unwrap();
    tablepro_core::export::write_result_file(file.path(), &result, &export, || false, |_| {}).unwrap();

    for statement in std::fs::read_to_string(file.path()).unwrap().lines() {
        conn.execute(statement).await.unwrap();
    }
    assert_eq!(
        conn.query("SELECT id, note FROM identity_copy ORDER BY id")
            .await
            .unwrap()
            .rows,
        vec![
            vec![Value::Int(7), Value::Text("copy".into())],
            vec![Value::Int(13), Value::Text("copy again".into())],
        ]
    );
    conn.execute("INSERT INTO identity_copy (note) VALUES ('next')")
        .await
        .unwrap();
    assert_eq!(
        conn.query("SELECT id FROM identity_copy WHERE note = 'next'")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(14)]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_copy_as_insert_preserves_auto_increment_id_and_next_value() {
    let (_container, options) = start_mysql().await;
    let conn = connect(options).await;
    conn.execute(
        "CREATE TABLE identity_source (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, note VARCHAR(64) NOT NULL)",
    )
    .await
    .unwrap();
    conn.execute("INSERT INTO identity_source (id, note) VALUES (7, 'copied')")
        .await
        .unwrap();
    conn.execute("CREATE TABLE identity_copy LIKE identity_source")
        .await
        .unwrap();

    let columns = conn.fetch_columns(None, "identity_source").await.unwrap();
    assert!(columns[0].is_auto_increment, "identity metadata must be exact");
    let row = conn
        .query("SELECT id, note FROM identity_source")
        .await
        .unwrap()
        .rows
        .remove(0);
    let sql = tablepro_core::sql_literal::build_insert_literal("mysql", None, "identity_copy", &columns, &row).unwrap();
    assert_eq!(sql, "INSERT INTO `identity_copy` (`id`, `note`) VALUES (7, 'copied');");
    conn.execute(&sql).await.unwrap();

    assert_eq!(
        conn.query("SELECT id, note FROM identity_copy").await.unwrap().rows,
        vec![vec![Value::Int(7), Value::Text("copied".into())]]
    );
    conn.execute("INSERT INTO identity_copy (note) VALUES ('next')")
        .await
        .unwrap();
    assert_eq!(
        conn.query("SELECT id FROM identity_copy WHERE note = 'next'")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(8)]]
    );
}

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{connect, start_mysql};

#[tokio::test]
#[ignore = "requires docker"]
async fn list_databases_returns_user_databases_and_hides_system_schemas() {
    let (_c, opts) = start_mysql().await;
    let conn = connect(opts).await;
    conn.execute("CREATE DATABASE alpha_db").await.unwrap();

    let names = conn.list_databases().await.unwrap();

    assert!(names.contains(&"alpha_db".to_string()), "{names:?}");
    for hidden in ["information_schema", "mysql", "performance_schema", "sys"] {
        assert!(!names.contains(&hidden.to_string()), "{hidden} leaked: {names:?}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn renaming_a_table_in_another_database_keeps_it_there() {
    let (_c, opts) = start_mysql().await;
    let default_database = opts.database.clone();
    let conn = connect(opts).await;
    let other = format!("rename_{}", uuid::Uuid::new_v4().simple());
    conn.execute(&format!("CREATE DATABASE `{other}`")).await.unwrap();
    conn.execute(&format!("CREATE TABLE `{other}`.`old_name` (id int PRIMARY KEY)"))
        .await
        .unwrap();

    let rename = tablepro_core::sql_ddl::build_rename_table("mysql", Some(&other), "old_name", "new_name").unwrap();
    conn.execute(&rename).await.unwrap();

    let moved = conn
        .query(&format!(
            "SELECT CAST(table_schema AS CHAR) FROM information_schema.tables WHERE table_name = 'new_name' AND table_schema IN ('{other}', '{default_database}')"
        ))
        .await
        .unwrap();
    assert_eq!(moved.rows, vec![vec![tablepro_core::Value::Text(other.clone())]]);
    conn.execute(&format!("DROP DATABASE `{other}`")).await.unwrap();
}

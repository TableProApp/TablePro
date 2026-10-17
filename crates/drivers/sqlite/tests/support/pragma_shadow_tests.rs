async fn assert_metadata_survives_shadowing(connection: &SqliteConnection) {
    let columns = connection.fetch_columns(None, "parent.with space").await.unwrap();
    assert_eq!(columns.iter().map(|column| column.name.as_str()).collect::<Vec<_>>(), ["a", "b", "value"]);

    let indexes = connection.fetch_indexes(None, "parent.with space").await.unwrap();
    assert!(indexes.iter().any(|index| index.primary && index.columns == ["b", "a"]), "{indexes:?}");
    let child_indexes = connection.fetch_indexes(None, "child").await.unwrap();
    assert!(child_indexes.iter().any(|index| index.name == "child parent idx"), "{child_indexes:?}");

    let foreign_keys = connection.fetch_foreign_keys(None, "child").await.unwrap();
    assert_eq!(foreign_keys.len(), 1, "{foreign_keys:?}");
    assert_eq!(foreign_keys[0].ref_table, "parent.with space");
    assert_eq!(foreign_keys[0].columns, ["pb", "pa"]);
    assert_eq!(foreign_keys[0].ref_columns, ["b", "a"]);

    let result = connection.query("SELECT value FROM aux.\"typed rows\"").await.unwrap();
    assert_eq!(result.columns[0].data_type, "TEXT");
}

#[tokio::test]
async fn user_objects_cannot_shadow_sqlite_metadata_pragmas() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(SqliteConnectOptions::from_str("sqlite::memory:").unwrap())
        .await
        .unwrap();
    let connection = SqliteConnection { pool, session_options: None };
    for sql in [
        "CREATE TABLE \"parent.with space\" (a INTEGER, b TEXT, value TEXT, PRIMARY KEY (b, a))",
        "CREATE TABLE child (id INTEGER PRIMARY KEY, pa INTEGER, pb TEXT, FOREIGN KEY (pb, pa) REFERENCES \"parent.with space\")",
        "CREATE INDEX \"child parent idx\" ON child(pa)",
        "ATTACH DATABASE ':memory:' AS aux",
        "CREATE TABLE aux.\"typed rows\" (value TEXT)",
        "INSERT INTO aux.\"typed rows\" VALUES (NULL)",
        "CREATE TEMP TABLE pragma_table_info (name TEXT)",
        "CREATE TEMP TABLE pragma_table_xinfo (name TEXT)",
        "CREATE TEMP TABLE pragma_index_list (name TEXT)",
        "CREATE TEMP TABLE pragma_index_info (name TEXT)",
        "CREATE TEMP TABLE pragma_foreign_key_list (name TEXT)",
        "CREATE TEMP TABLE pragma_database_list (name TEXT)",
        "INSERT INTO temp.pragma_database_list VALUES ('ghost')",
    ] {
        sqlx::query(sql).execute(&connection.pool).await.unwrap();
    }
    assert_metadata_survives_shadowing(&connection).await;

    for sql in [
        "DROP TABLE temp.pragma_table_info",
        "DROP TABLE temp.pragma_table_xinfo",
        "DROP TABLE temp.pragma_index_list",
        "DROP TABLE temp.pragma_index_info",
        "DROP TABLE temp.pragma_foreign_key_list",
        "DROP TABLE temp.pragma_database_list",
        "CREATE TABLE pragma_table_info (name TEXT)",
        "CREATE TABLE pragma_table_xinfo (name TEXT)",
        "CREATE TABLE pragma_index_list (name TEXT)",
        "CREATE TABLE pragma_index_info (name TEXT)",
        "CREATE TABLE pragma_foreign_key_list (name TEXT)",
        "CREATE TABLE pragma_database_list (name TEXT)",
        "INSERT INTO pragma_database_list VALUES ('ghost')",
    ] {
        sqlx::query(sql).execute(&connection.pool).await.unwrap();
    }
    assert_metadata_survives_shadowing(&connection).await;
}

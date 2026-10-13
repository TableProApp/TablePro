use super::{connect, start_mysql};

#[tokio::test]
#[ignore = "requires docker"]
async fn composite_indexes_and_foreign_keys_report_every_column_in_order() {
    let (_container, options) = start_mysql().await;
    let connection = connect(options).await;
    connection
        .execute("CREATE TABLE parent (a INT, b INT, PRIMARY KEY (a, b))")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE child (id INT PRIMARY KEY, x INT, y INT, \
             UNIQUE KEY child_xy (y, x), KEY child_x (x), \
             CONSTRAINT child_parent FOREIGN KEY (x, y) REFERENCES parent (a, b) \
             ON DELETE CASCADE ON UPDATE NO ACTION)",
        )
        .await
        .unwrap();

    let mut indexes = connection.fetch_indexes(None, "child").await.unwrap();
    indexes.sort_by(|left, right| left.name.cmp(&right.name));
    let summary: Vec<_> = indexes
        .iter()
        .map(|index| (index.name.as_str(), index.columns.clone(), index.unique, index.primary))
        .collect();
    assert!(summary.contains(&("PRIMARY", vec!["id".to_string()], true, true)));
    assert!(summary.contains(&("child_xy", vec!["y".to_string(), "x".to_string()], true, false)));
    assert!(summary.contains(&("child_x", vec!["x".to_string()], false, false)));

    let keys = connection.fetch_foreign_keys(None, "child").await.unwrap();
    assert_eq!(keys.len(), 1);
    assert_eq!(keys[0].name, "child_parent");
    assert_eq!(keys[0].columns, ["x", "y"]);
    assert_eq!(keys[0].ref_table, "parent");
    assert_eq!(keys[0].ref_columns, ["a", "b"]);
    assert_eq!(keys[0].on_delete.as_deref(), Some("CASCADE"));
    assert_eq!(keys[0].on_update, None);
}

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{connect, start_mysql};

#[tokio::test]
#[ignore = "requires docker"]
async fn use_on_a_pooled_connection_does_not_change_what_later_catalog_reads_see() {
    let (_c, opts) = start_mysql().await;
    let connection = connect(opts.clone()).await;
    connection.execute("CREATE TABLE home_table (id INT)").await.unwrap();
    connection.execute("CREATE DATABASE other_db").await.unwrap();
    connection
        .execute("CREATE TABLE other_db.away_table (id INT)")
        .await
        .unwrap();

    connection
        .query_controlled(
            "USE other_db",
            &tablepro_core::OperationControl::with_timeout(std::time::Duration::from_secs(5)),
        )
        .await
        .unwrap();

    for _ in 0..8 {
        let names: Vec<String> = connection
            .list_tables()
            .await
            .unwrap()
            .into_iter()
            .map(|table| table.name)
            .collect();
        assert_eq!(names, vec!["home_table".to_string()]);
    }
}

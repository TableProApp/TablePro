#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn select_star_sees_a_column_added_after_the_statement_was_first_prepared() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE sp (id int PRIMARY KEY, a int)")
        .await
        .unwrap();
    for _ in 0..8 {
        assert_eq!(conn.query("SELECT * FROM sp").await.unwrap().columns.len(), 2);
    }
    conn.execute("ALTER TABLE sp ADD COLUMN b int").await.unwrap();
    for attempt in 0..8 {
        let result = conn.query("SELECT * FROM sp").await;
        let columns = result
            .unwrap_or_else(|error| panic!("attempt {attempt} after ALTER TABLE: {error:?}"))
            .columns
            .len();
        assert_eq!(columns, 3, "attempt {attempt}");
    }
}

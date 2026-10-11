#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn enum_labels_come_back_in_declared_order_for_the_named_type_only() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE SCHEMA other").await.unwrap();
    conn.execute("CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy', 'it''s fine', '')")
        .await
        .unwrap();
    conn.execute("CREATE TYPE other.mood AS ENUM ('elsewhere')")
        .await
        .unwrap();

    let labels = conn.fetch_enum_labels("public", "mood").await.unwrap();
    assert_eq!(labels, ["sad", "ok", "happy", "it's fine", ""]);
    assert_eq!(conn.fetch_enum_labels("other", "mood").await.unwrap(), ["elsewhere"]);
    assert!(conn.fetch_enum_labels("public", "missing").await.unwrap().is_empty());
}

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn xml_and_oid_scalars_decode_as_text() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    let result = conn.query("SELECT '<a/>'::xml AS x, 5::oid AS o").await.unwrap();
    assert_eq!(result.rows[0][0], Value::Text("<a/>".into()));
    assert_eq!(result.rows[0][1], Value::Text("5".into()));
}

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn a_float4_reads_back_with_its_short_decimal_form() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    let result = conn.query("SELECT 0.1::float4 AS a, 1.5::float4 AS b").await.unwrap();
    assert_eq!(result.rows[0][0], Value::Float(0.1));
    assert_eq!(result.rows[0][1], Value::Float(1.5));
}

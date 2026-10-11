use super::{connect, start_mariadb, start_mysql};
use tablepro_core::{Connection, OperationControl, Value};

#[tokio::test]
#[ignore = "requires docker"]
async fn a_value_the_driver_cannot_decode_is_reported_rather_than_shown_as_null() {
    let (_container, options) = start_mysql().await;
    assert_non_utf8_enum_set_results(connect(options).await.as_ref()).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_non_utf8_enum_and_set_results_preserve_bytes() {
    let (_container, options) = start_mariadb().await;
    assert_non_utf8_enum_set_results(connect(options).await.as_ref()).await;
}

async fn assert_non_utf8_enum_set_results(connection: &dyn Connection) {
    connection
        .execute(
            "CREATE TABLE non_utf8_labels (enum_value ENUM('ünï') CHARACTER SET utf8mb4, \
             set_value SET('ünï') CHARACTER SET utf8mb4)",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO non_utf8_labels VALUES ('ünï', 'ünï')")
        .await
        .unwrap();
    let mut session = connection.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    session
        .query_params_controlled("SET character_set_results = latin1", &[], &control)
        .await
        .unwrap();
    let native = session
        .query_params_controlled(
            "SELECT CAST(enum_value + 0 AS CHAR), HEX(enum_value), \
             CAST(set_value + 0 AS CHAR), HEX(set_value) FROM non_utf8_labels",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        native.rows,
        vec![vec![
            Value::Text("1".into()),
            Value::Text("C3BC6EC3AF".into()),
            Value::Text("1".into()),
            Value::Text("C3BC6EC3AF".into()),
        ]],
        "native ENUM ordinal, SET mask, and stored UTF-8 label bytes"
    );
    let result = session
        .query_params_controlled(
            "SELECT 'ünï' AS latin, CAST(NULL AS SIGNED) AS absent, enum_value, set_value \
             FROM non_utf8_labels",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![vec![
            Value::Undecodable("VARCHAR".into()),
            Value::Null,
            Value::Bytes(vec![0xfc, b'n', 0xef]),
            Value::Bytes(vec![0xfc, b'n', 0xef]),
        ]],
        "a value that failed to decode must not be indistinguishable from a stored NULL"
    );
}

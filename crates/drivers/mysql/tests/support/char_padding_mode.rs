#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{ConnectOptions, OperationControl, QueryResult, Session, Value};

use crate::{connect, start_mariadb, start_mysql};

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_char_padding_mode_preserves_char_and_varchar_results() {
    let (_container, options) = start_mysql().await;
    assert_char_padding_contract(options, "MySQL").await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_char_padding_mode_preserves_char_and_varchar_results() {
    let (_container, options) = start_mariadb().await;
    assert_char_padding_contract(options, "MariaDB").await;
}

async fn assert_char_padding_contract(options: ConnectOptions, engine: &str) {
    let connection = connect(options).await;
    connection
        .execute(
            "CREATE TABLE char_padding_values (
                id INT PRIMARY KEY,
                fixed CHAR(4) CHARACTER SET utf8mb4,
                variable VARCHAR(4) CHARACTER SET utf8mb4
            )",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO char_padding_values VALUES
                (1, 'x', 'x '), (2, '', ''), (3, NULL, NULL)",
        )
        .await
        .unwrap();
    let mut session = connection.open_session().await.unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    assert_trimmed_char_values(session.as_mut(), &control, engine).await;

    session
        .query_params_controlled("SET SESSION sql_mode = 'PAD_CHAR_TO_FULL_LENGTH'", &[], &control)
        .await
        .unwrap();
    let mode = session
        .query_params_controlled("SELECT @@SESSION.sql_mode", &[], &control)
        .await
        .unwrap();
    assert_eq!(
        mode.rows,
        vec![vec![Value::Text("PAD_CHAR_TO_FULL_LENGTH".into())]],
        "{engine}"
    );

    assert_padded_char_values(session.as_mut(), &control, engine).await;
    session.close().await.unwrap();
    connection.close().await.unwrap();
}

async fn assert_trimmed_char_values(session: &mut dyn Session, control: &OperationControl, engine: &str) {
    let ordinary = query_char_values(session, control).await;
    assert_eq!(ordinary.columns[0].data_type, "CHAR", "{engine}");
    assert_eq!(ordinary.columns[1].data_type, "VARCHAR", "{engine}");
    assert_eq!(ordinary.rows[0][0], Value::Text("x".into()), "{engine}");
    assert_eq!(ordinary.rows[0][1], Value::Text("x ".into()), "{engine}");
    assert_eq!(
        ordinary.rows[0][2],
        Value::Text("78".into()),
        "{engine}: trimmed CHAR hex"
    );
    assert_eq!(ordinary.rows[0][3], Value::Text("7820".into()), "{engine}: VARCHAR hex");
}

async fn assert_padded_char_values(session: &mut dyn Session, control: &OperationControl, engine: &str) {
    let padded = query_char_values(session, control).await;
    assert_eq!(padded.rows[0][0], Value::Text("x   ".into()), "{engine}: CHAR padding");
    assert_eq!(
        padded.rows[0][1],
        Value::Text("x ".into()),
        "{engine}: VARCHAR unchanged"
    );
    assert_eq!(
        padded.rows[0][2],
        Value::Text("78202020".into()),
        "{engine}: padded CHAR hex"
    );
    assert_eq!(padded.rows[0][3], Value::Text("7820".into()), "{engine}: VARCHAR hex");
    assert_eq!(
        padded.rows[1][0],
        Value::Text("    ".into()),
        "{engine}: empty CHAR padding"
    );
    assert_eq!(padded.rows[1][1], Value::Text("".into()), "{engine}: empty VARCHAR");
    assert_eq!(padded.rows[2][0], Value::Null, "{engine}: CHAR NULL");
    assert_eq!(padded.rows[2][1], Value::Null, "{engine}: VARCHAR NULL");
}

async fn query_char_values(session: &mut dyn Session, control: &OperationControl) -> QueryResult {
    session
        .query_params_controlled(
            "SELECT fixed, variable, HEX(fixed), HEX(variable), id \
             FROM char_padding_values ORDER BY id",
            &[],
            control,
        )
        .await
        .unwrap()
}

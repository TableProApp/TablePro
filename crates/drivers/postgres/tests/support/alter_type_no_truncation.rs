#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::sql_ddl::{DraftColumn, build_alter_column};
use tablepro_core::{Connection, Value};

use crate::{connect, start_pg};

async fn change_type(conn: &dyn Connection, table: &str, to: &str) -> Result<(), String> {
    let columns = conn.fetch_columns(None, table).await.unwrap();
    let mut draft = DraftColumn::from_info(columns.iter().find(|c| c.name == "v").unwrap().clone());
    draft.data_type = to.into();
    for statement in build_alter_column("postgres", None, table, &draft).unwrap() {
        conn.execute(&statement)
            .await
            .map_err(|error| format!("{statement}: {error:?}"))?;
    }
    Ok(())
}

async fn value(conn: &dyn Connection, table: &str) -> Value {
    conn.query(&format!("SELECT v FROM {table}")).await.unwrap().rows[0][0].clone()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn narrowing_a_column_is_refused_instead_of_truncating_the_data() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE narrow_text (v varchar(255))").await.unwrap();
    conn.execute("INSERT INTO narrow_text VALUES ('abcdefghijkl')")
        .await
        .unwrap();
    conn.execute("CREATE TABLE narrow_number (v integer)").await.unwrap();
    conn.execute("INSERT INTO narrow_number VALUES (12345)").await.unwrap();
    conn.execute("CREATE TABLE narrow_bits (v bit varying(10))")
        .await
        .unwrap();
    conn.execute("INSERT INTO narrow_bits VALUES (B'1111100000')")
        .await
        .unwrap();

    for (table, to) in [
        ("narrow_text", "character varying(10)"),
        ("narrow_number", "character varying(3)"),
        ("narrow_bits", "bit varying(5)"),
    ] {
        let outcome = change_type(conn.as_ref(), table, to).await;
        let error = outcome.expect_err(&format!("{table}: narrowing must be refused"));
        assert!(
            error.contains("too long") || error.contains("22001"),
            "{table}: {error}"
        );
    }
    assert_eq!(
        value(conn.as_ref(), "narrow_text").await,
        Value::Text("abcdefghijkl".into())
    );
    assert_eq!(value(conn.as_ref(), "narrow_number").await, Value::Int(12345));
    assert_eq!(
        value(conn.as_ref(), "narrow_bits").await,
        Value::Text("1111100000".into())
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn widening_and_conversions_that_need_a_cast_still_work() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE widen (v varchar(5))").await.unwrap();
    conn.execute("INSERT INTO widen VALUES ('abc')").await.unwrap();
    conn.execute("CREATE TABLE convert (v text)").await.unwrap();
    conn.execute("INSERT INTO convert VALUES ('42')").await.unwrap();
    conn.execute("CREATE TABLE to_text (v integer)").await.unwrap();
    conn.execute("INSERT INTO to_text VALUES (7)").await.unwrap();

    change_type(conn.as_ref(), "widen", "character varying(50)")
        .await
        .unwrap();
    change_type(conn.as_ref(), "convert", "integer").await.unwrap();
    change_type(conn.as_ref(), "to_text", "text").await.unwrap();

    assert_eq!(value(conn.as_ref(), "widen").await, Value::Text("abc".into()));
    assert_eq!(value(conn.as_ref(), "convert").await, Value::Int(42));
    assert_eq!(value(conn.as_ref(), "to_text").await, Value::Text("7".into()));
}

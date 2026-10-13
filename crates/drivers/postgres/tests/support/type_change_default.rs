#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::sql_ddl::{DraftColumn, build_alter_column};

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn changing_a_column_type_keeps_its_default() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE retyped (id int PRIMARY KEY, c varchar(5) DEFAULT '7')")
        .await
        .unwrap();
    let columns = conn.fetch_columns(None, "retyped").await.unwrap();
    let mut draft = DraftColumn::from_info(columns[1].clone());
    draft.data_type = "integer".into();
    for statement in build_alter_column("postgres", None, "retyped", &draft).unwrap() {
        let outcome = conn.execute(&statement).await;
        assert!(outcome.is_ok(), "{statement}: {outcome:?}");
    }
    let altered = conn.fetch_columns(None, "retyped").await.unwrap();
    assert_eq!(altered[1].data_type, "integer");
    let default = altered[1].default_value.clone().unwrap_or_default();
    assert!(default.contains('7'), "{default}");
}

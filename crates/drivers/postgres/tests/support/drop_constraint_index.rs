#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::sql_ddl::{StructureOp, materialize_ops};

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn dropping_the_index_of_a_unique_constraint_drops_the_constraint() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE uniq (id int PRIMARY KEY, email text, CONSTRAINT uniq_email UNIQUE (email))")
        .await
        .unwrap();
    conn.execute("CREATE INDEX uniq_plain ON uniq (id)").await.unwrap();
    let indexes = conn.fetch_indexes(None, "uniq").await.unwrap();
    let owned = indexes.iter().find(|index| index.name == "uniq_email").unwrap();
    assert_eq!(owned.constraint.as_deref(), Some("uniq_email"));
    let plain = indexes.iter().find(|index| index.name == "uniq_plain").unwrap();
    assert_eq!(plain.constraint, None);

    let ops: Vec<StructureOp> = [owned, plain]
        .into_iter()
        .map(|index| StructureOp::DropIndex {
            schema: None,
            table: "uniq".into(),
            index_name: index.name.clone(),
            constraint: index.constraint.clone(),
        })
        .collect();
    for statement in materialize_ops(&ops, "postgres").unwrap() {
        let outcome = conn.execute(&statement).await;
        assert!(outcome.is_ok(), "{statement}: {outcome:?}");
    }
    let left = conn.fetch_indexes(None, "uniq").await.unwrap();
    assert_eq!(left.iter().map(|i| i.name.as_str()).collect::<Vec<_>>(), ["uniq_pkey"]);
}

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

#[tokio::test]
#[ignore = "requires docker"]
async fn replacing_an_index_and_a_foreign_key_under_the_same_name_changes_the_table() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE swap_parent (id int PRIMARY KEY)")
        .await
        .unwrap();
    conn.execute("CREATE TABLE swap (id int PRIMARY KEY, a int, b int)")
        .await
        .unwrap();
    conn.execute("CREATE INDEX swap_idx ON swap (a)").await.unwrap();
    conn.execute("ALTER TABLE swap ADD CONSTRAINT swap_fk FOREIGN KEY (a) REFERENCES swap_parent (id)")
        .await
        .unwrap();
    let original_indexes = conn.fetch_indexes(None, "swap").await.unwrap();
    let original_keys = conn.fetch_foreign_keys(None, "swap").await.unwrap();

    let mut indexes = original_indexes.clone();
    let replaced = indexes.iter_mut().find(|index| index.name == "swap_idx").unwrap();
    replaced.columns = vec!["a".into(), "b".into()];
    replaced.unique = true;
    let mut keys = original_keys.clone();
    keys[0].on_delete = Some("CASCADE".into());

    let ops = tablepro_core::sql_ddl::diff_to_ops(
        None,
        "swap",
        "swap",
        &[],
        &[],
        &original_indexes,
        &indexes,
        &original_keys,
        &keys,
    );
    assert_eq!(ops.len(), 4, "{ops:?}");
    for statement in materialize_ops(&ops, "postgres").unwrap() {
        let outcome = conn.execute(&statement).await;
        assert!(outcome.is_ok(), "{statement}: {outcome:?}");
    }

    let after = conn.fetch_indexes(None, "swap").await.unwrap();
    let index = after.iter().find(|index| index.name == "swap_idx").unwrap();
    assert_eq!(index.columns, ["a", "b"]);
    assert!(index.unique);
    let key = &conn.fetch_foreign_keys(None, "swap").await.unwrap()[0];
    assert_eq!(key.on_delete.as_deref(), Some("CASCADE"));
}

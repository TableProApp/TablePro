#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn foreign_keys_pair_composite_columns_and_report_the_referential_actions() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE SCHEMA other").await.unwrap();
    conn.execute("CREATE TABLE other.parent (a int, b int, PRIMARY KEY (a, b))")
        .await
        .unwrap();
    conn.execute("CREATE TABLE local_parent (id int PRIMARY KEY)")
        .await
        .unwrap();
    conn.execute(
        "CREATE TABLE child (id int PRIMARY KEY, x int, y int, p int, q int, r int, \
         CONSTRAINT a_composite FOREIGN KEY (y, x) REFERENCES other.parent (a, b) \
             ON DELETE CASCADE ON UPDATE SET NULL, \
         CONSTRAINT b_restrict FOREIGN KEY (p) REFERENCES local_parent (id) \
             ON DELETE RESTRICT ON UPDATE SET DEFAULT, \
         CONSTRAINT c_plain FOREIGN KEY (q) REFERENCES local_parent (id))",
    )
    .await
    .unwrap();

    for schema in [None, Some("public")] {
        let keys = conn.fetch_foreign_keys(schema, "child").await.unwrap();
        let names: Vec<_> = keys.iter().map(|key| key.name.as_str()).collect();
        assert_eq!(names, ["a_composite", "b_restrict", "c_plain"], "{schema:?}");

        assert_eq!(keys[0].columns, ["y", "x"]);
        assert_eq!(
            keys[0].ref_columns,
            ["a", "b"],
            "each column pairs with its own referenced column"
        );
        assert_eq!(keys[0].ref_table, "parent");
        assert_eq!(keys[0].ref_schema.as_deref(), Some("other"));
        assert_eq!(keys[0].on_delete.as_deref(), Some("CASCADE"));
        assert_eq!(keys[0].on_update.as_deref(), Some("SET NULL"));

        assert_eq!(keys[1].columns, ["p"]);
        assert_eq!(keys[1].ref_schema.as_deref(), Some("public"));
        assert_eq!(keys[1].on_delete.as_deref(), Some("RESTRICT"));
        assert_eq!(keys[1].on_update.as_deref(), Some("SET DEFAULT"));

        assert_eq!(keys[2].on_delete, None, "NO ACTION is the default and is not reported");
        assert_eq!(keys[2].on_update, None);
    }

    let none = conn.fetch_foreign_keys(Some("other"), "child").await.unwrap();
    assert!(none.is_empty(), "the table lives in public, not in the other schema");
    assert!(conn.fetch_foreign_keys(None, "local_parent").await.unwrap().is_empty());
}

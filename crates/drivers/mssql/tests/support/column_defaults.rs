#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use super::{connect, start_mssql};
use tablepro_core::Value;
use tablepro_core::sql_ddl::{DraftColumn, diff_to_ops, materialize_ops};

#[tokio::test]
#[ignore = "requires docker"]
async fn a_column_with_a_default_changes_type_and_drops() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE def_drop (id int NOT NULL PRIMARY KEY, n smallint NULL DEFAULT 7, gone int DEFAULT 1)")
        .await
        .unwrap();
    let original = conn.fetch_columns(None, "def_drop").await.unwrap();
    let mut current: Vec<_> = original
        .iter()
        .filter(|c| c.name != "gone")
        .cloned()
        .map(DraftColumn::from_info)
        .collect();
    let n = current.iter_mut().find(|c| c.name == "n").unwrap();
    n.data_type = "int".into();

    let ops = diff_to_ops(None, "def_drop", "def_drop", &original, &current, &[], &[], &[], &[]);
    for sql in materialize_ops(&ops, "mssql").unwrap() {
        conn.execute(&sql)
            .await
            .unwrap_or_else(|error| panic!("{sql}: {error}"));
    }

    let after = conn.fetch_columns(None, "def_drop").await.unwrap();
    assert!(after.iter().all(|c| c.name != "gone"), "{after:?}");
    let n = after.iter().find(|c| c.name == "n").unwrap();
    assert_eq!(n.data_type, "int");
    assert_eq!(n.default_value.as_deref(), Some("7"));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn alter_column_default_round_trips() {
    let (_c, opts) = start_mssql().await;
    let conn = connect(opts).await;

    conn.execute("CREATE TABLE def_demo (id int NOT NULL, status nvarchar(20) NULL)")
        .await
        .unwrap();

    let mut column = tablepro_core::sql_ddl::DraftColumn {
        original: Some(
            conn.fetch_columns(None, "def_demo")
                .await
                .unwrap()
                .into_iter()
                .find(|c| c.name == "status")
                .unwrap(),
        ),
        name: "status".into(),
        data_type: "nvarchar(20)".into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: Some("'pending'".into()),
        comment: None,
        collation: None,
    };
    for sql in tablepro_core::sql_ddl::build_alter_column("mssql", None, "def_demo", &column).unwrap() {
        conn.execute(&sql).await.unwrap();
    }
    let status = |cols: Vec<tablepro_core::ColumnInfo>| cols.into_iter().find(|c| c.name == "status").unwrap();
    let after_add = status(conn.fetch_columns(None, "def_demo").await.unwrap());
    assert_eq!(after_add.default_value.as_deref(), Some("'pending'"));

    conn.execute("INSERT INTO def_demo (id) VALUES (1)").await.unwrap();
    let rows = conn.query("SELECT status FROM def_demo").await.unwrap();
    assert_eq!(rows.rows[0][0], Value::Text("pending".into()));

    column.original = Some(after_add);
    column.default_value = None;
    for sql in tablepro_core::sql_ddl::build_alter_column("mssql", None, "def_demo", &column).unwrap() {
        conn.execute(&sql).await.unwrap();
    }
    assert!(
        status(conn.fetch_columns(None, "def_demo").await.unwrap())
            .default_value
            .is_none()
    );
}

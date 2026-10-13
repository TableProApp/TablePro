//! Structure changes the PostgreSQL dialect plans, run against a real
//! server.

use tablepro_core::Connection;
use tablepro_core::ddl::{CollationName, DraftType, TableDefinition, TableDraft, diff_table};
use tablepro_core::meta::TableRef;

use crate::support::{CALL, connect, setup, start, within};

fn kept() -> TableRef {
    TableRef::new(Some("public".to_owned()), "kept")
}

async fn read(connection: &dyn Connection) -> TableDefinition {
    connection
        .fetch_table_definition(&kept(), within(CALL))
        .await
        .expect("the definition")
}

/// SET DATA TYPE gives the column the new type's default collation
/// unless the statement names one, so a type change on a text column
/// has to name the one it had.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn type_change_keeps_c_collation() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id int PRIMARY KEY, code varchar(10) COLLATE \"C\", tags text[] COLLATE \"C\", \
           amount varchar(10) COLLATE \"C\")",
        ],
    )
    .await;
    let before = read(connection.as_ref()).await;
    let mut draft = TableDraft::from_definition(&before);
    for column in &mut draft.columns {
        let retyped = match column.name.as_str() {
            "code" => "varchar(40)",
            "tags" => "varchar(20)[]",
            "amount" => "integer",
            _ => continue,
        };
        column.column_type = DraftType::Typed(retyped.to_owned());
    }
    let dialect = connection.dialect();
    let plan = dialect
        .ddl()
        .expect("PostgreSQL plans its DDL")
        .plan_alter_table(&before, &diff_table(&before, &draft))
        .expect("the change plans");

    connection
        .write_batch(&plan.into_write_batch(kept()), within(CALL))
        .await
        .expect("the change runs");
    let after = read(connection.as_ref()).await;

    assert_eq!(before.columns.len(), after.columns.len());
    for old in &before.columns {
        let mut expected = old.attributes.clone();
        // An integer holds no text, so it has no collation to keep.
        if old.name() == "amount" {
            expected.collation = None;
        }
        let new = after.column(old.name()).expect("the column");
        assert_eq!(new.attributes, expected, "{}", old.name());
    }
    let c = Some(CollationName::new(Some("pg_catalog".to_owned()), "C"));
    let column = |name: &str| after.column(name).expect("the column");
    assert_eq!(column("code").attributes.collation, c);
    assert_eq!(column("code").info.column_type.name, "character varying(40)");
    assert_eq!(column("tags").attributes.collation, c);
    assert_eq!(column("tags").info.column_type.name, "character varying(20)[]");
    assert_eq!(column("amount").attributes.collation, None);
    assert_eq!(column("amount").info.column_type.name, "integer");
    connection.close().await.expect("a close");
}

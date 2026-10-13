//! Structure changes the SQL Server dialect plans, run against a real
//! server.

use tablepro_core::Connection;
use tablepro_core::ddl::{DraftType, TableDefinition, TableDraft, diff_table};

use crate::support::{CALL, connect, dbo, setup, start, within};

async fn read(connection: &dyn Connection) -> TableDefinition {
    connection
        .fetch_table_definition(&dbo("kept"), within(CALL))
        .await
        .expect("the definition")
}

/// ALTER COLUMN gives the column the database's collation and drops
/// SPARSE unless the statement restates them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn nullability_change_keeps_column_collation() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.kept (id int PRIMARY KEY, code varchar(20) COLLATE Latin1_General_BIN NULL, \
           name nvarchar(40) COLLATE Latin1_General_100_CS_AS NOT NULL, weight int SPARSE NULL)",
        ],
    )
    .await;
    let before = read(connection.as_ref()).await;
    let mut draft = TableDraft::from_definition(&before);
    for column in &mut draft.columns {
        match column.name.as_str() {
            "code" => column.nullable = false,
            "name" => column.column_type = DraftType::Typed("nvarchar(80)".to_owned()),
            "weight" => column.column_type = DraftType::Typed("bigint".to_owned()),
            _ => {}
        }
    }
    let dialect = connection.dialect();
    let plan = dialect
        .ddl()
        .expect("SQL Server plans its DDL")
        .plan_alter_table(&before, &diff_table(&before, &draft))
        .expect("the change plans");

    connection
        .write_batch(&plan.into_write_batch(dbo("kept")), within(CALL))
        .await
        .expect("the change runs");
    let after = read(connection.as_ref()).await;

    let column = |name: &str| after.column(name).expect("the column");
    let collation = |name: &str| {
        column(name)
            .attributes
            .collation
            .as_ref()
            .map(|collation| collation.name.clone())
    };
    assert!(!column("code").info.nullable);
    assert_eq!(collation("code").as_deref(), Some("Latin1_General_BIN"));
    assert!(!column("name").info.nullable);
    assert_eq!(collation("name").as_deref(), Some("Latin1_General_100_CS_AS"));
    assert_eq!(column("name").info.column_type.name, "nvarchar(80)");
    assert!(column("weight").attributes.sparse);
    assert_eq!(column("weight").info.column_type.name, "bigint");
}

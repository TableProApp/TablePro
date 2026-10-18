//! Structure changes the ClickHouse dialect plans, run against a real
//! server.

use tablepro_core::Connection;
use tablepro_core::ddl::{TableDefinition, TableDraft, diff_table};

use crate::support::{CALL, connect, scalar, setup, start, table, text, within};

async fn read(connection: &dyn Connection) -> TableDefinition {
    connection
        .fetch_table_definition(&table("kept"), within(CALL))
        .await
        .expect("the definition")
}

/// ClickHouse runs each rename on its own and refuses one into a name
/// still in use, so a swap goes through a temporary name.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn swap_column_names_applies() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE tablepro.kept (id UInt64, a String, b Int32) ENGINE = MergeTree ORDER BY id",
            "INSERT INTO tablepro.kept VALUES (1, 'x', 2)",
        ],
    )
    .await;
    let before = read(connection.as_ref()).await;
    let mut draft = TableDraft::from_definition(&before);
    for column in &mut draft.columns {
        column.name = match column.name.as_str() {
            "a" => "b",
            "b" => "a",
            other => other,
        }
        .to_owned();
    }
    let dialect = connection.dialect();
    let plan = dialect
        .ddl()
        .expect("ClickHouse plans its DDL")
        .plan_alter_table(&before, &diff_table(&before, &draft))
        .expect("the change plans");

    connection
        .write_batch(&plan.into_write_batch(table("kept")), within(CALL))
        .await
        .expect("the change runs");
    let after = read(connection.as_ref()).await;

    let names: Vec<&str> = after.columns.iter().map(|column| column.name()).collect();
    assert_eq!(names, ["id", "b", "a"]);
    let type_of = |name: &str| after.column(name).map(|column| column.info.column_type.name.clone());
    assert_eq!(type_of("b").as_deref(), Some("String"));
    assert_eq!(type_of("a").as_deref(), Some("Int32"));
    assert_eq!(
        text(
            &scalar(
                connection.as_ref(),
                "SELECT concat(b, '|', toString(a)) FROM tablepro.kept"
            )
            .await
        ),
        "x|2"
    );
    connection.close().await.expect("a close");
}

//! Structure changes the ClickHouse dialect plans, run against a real
//! server.

use tablepro_core::ddl::{
    DatabaseDraft, DropDatabaseOptions, TableDefinition, TableDraft, TruncateTableOptions, diff_table,
    plan_create_database, plan_drop_database, plan_truncate_table,
};
use tablepro_core::{Connection, TableRef};

use crate::support::{CALL, DATABASE, connect, count, quoted, scalar, setup, start, table, text, unique, within};

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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn truncate_empties_the_table_and_keeps_it() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("emptied");
    let qualified = format!("{DATABASE}.{}", quoted(&name));
    setup(
        connection.as_ref(),
        &[
            &format!("CREATE TABLE {qualified} (id UInt64) ENGINE = MergeTree ORDER BY id"),
            &format!("INSERT INTO {qualified} VALUES (1), (2)"),
        ],
    )
    .await;
    let dialect = connection.dialect();
    let plan = plan_truncate_table(dialect.as_ref(), &table(&name), &TruncateTableOptions::default()).expect("a plan");

    connection
        .write_batch(&plan.into_write_batch(table(&name)), within(CALL))
        .await
        .expect("the truncate runs");

    let kept = format!("SELECT count() FROM system.tables WHERE database = '{DATABASE}' AND name = '{name}'");
    assert_eq!(count(connection.as_ref(), &format!("SELECT count() FROM {qualified}")).await, 0);
    assert_eq!(count(connection.as_ref(), &kept).await, 1);
    connection.close().await.expect("a close");
}

/// A database plan runs through the save path with a batch that names
/// the database and no table, as the app sends it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_database_is_created_and_dropped_through_a_save() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("made");
    let dialect = connection.dialect();
    let target = TableRef::new(Some(name.clone()), "");
    let created = plan_create_database(dialect.as_ref(), &DatabaseDraft::named(name.clone())).expect("a plan");
    let dropped = plan_drop_database(dialect.as_ref(), &name, &DropDatabaseOptions::default()).expect("a plan");
    let listed = format!("SELECT count() FROM system.databases WHERE name = '{name}'");

    connection
        .write_batch(&created.into_write_batch(target.clone()), within(CALL))
        .await
        .expect("the database is created");
    let schemas = connection.list_schemas(within(CALL)).await.expect("the schemas");
    connection
        .write_batch(&dropped.into_write_batch(target), within(CALL))
        .await
        .expect("the database is dropped");

    let made = schemas.iter().find(|schema| schema.name == name).expect("the new database");
    assert!(!made.is_default && !made.is_system, "{made:?}");
    assert_eq!(count(connection.as_ref(), &listed).await, 0);
    connection.close().await.expect("a close");
}

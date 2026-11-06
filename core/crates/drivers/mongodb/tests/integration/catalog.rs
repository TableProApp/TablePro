//! Emptying a collection and creating and dropping a database through
//! the plans the sidebar runs with `write_batch`. Each names a database
//! other than the connection's own, which has to be the one it changes.

use tablepro_core::ddl::{
    DatabaseDraft, DropDatabaseOptions, TruncateTableOptions, plan_create_database, plan_drop_database,
    plan_truncate_table,
};
use tablepro_core::meta::{ObjectScope, SchemaInfo, TableRef};
use tablepro_core::{Connection, RunEnd, Value};

use crate::support::{CALL, connect, editor, rows, run, start, unique, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn deleting_every_document_keeps_the_collection_and_its_indexes() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let (database, collection) = (unique("emptied"), unique("orders"));
    let (filled, _) = run(
        session.as_ref(),
        &format!(
            "db.getSiblingDB('{database}').getCollection('{collection}').insertMany([{{_id: 1, label: 'a'}}, \
             {{_id: 2, label: 'b'}}, {{_id: 3, label: 'c'}}])\n\
             db.getSiblingDB('{database}').getCollection('{collection}').createIndex({{label: 1}})"
        ),
    )
    .await;
    assert_eq!(filled.end, RunEnd::Completed);
    let table = TableRef::new(Some(database.clone()), collection.clone());
    let plan =
        plan_truncate_table(connection.dialect().as_ref(), &table, &TruncateTableOptions::default()).expect("a plan");

    let report = connection
        .write_batch(&plan.into_write_batch(table.clone()), within(CALL))
        .await
        .expect("the delete");

    assert_eq!(report.rows_affected, [Some(3)]);
    let (counted, events) = run(
        session.as_ref(),
        &format!("db.getSiblingDB('{database}').getCollection('{collection}').countDocuments({{}})"),
    )
    .await;
    assert_eq!(counted.end, RunEnd::Completed);
    assert_eq!(rows(&events), [vec![Value::Int(0)]]);
    let indexes = connection
        .fetch_indexes(&table, within(CALL))
        .await
        .expect("the indexes");
    assert!(indexes.iter().any(|index| index.name == "label_1"), "{indexes:?}");
    let objects = connection
        .list_objects(&ObjectScope::Schema(database.clone()), within(CALL))
        .await
        .expect("the database's collections");
    assert!(objects.iter().any(|object| object.name == collection), "{objects:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_new_database_is_listed_with_its_first_collection() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let (database, collection) = (unique("created"), unique("first"));
    let mut draft = DatabaseDraft::named(database.clone());
    draft.first_collection = Some(collection.clone());
    let plan = plan_create_database(connection.dialect().as_ref(), &draft).expect("a plan");

    connection
        .write_batch(
            &plan.into_write_batch(TableRef::new(Some(database.clone()), "")),
            within(CALL),
        )
        .await
        .expect("the create");

    assert!(lists(connection.as_ref(), &database).await, "{database} is not listed");
    let objects = connection
        .list_objects(&ObjectScope::Schema(database.clone()), within(CALL))
        .await
        .expect("the new database's collections");
    assert!(objects.iter().any(|object| object.name == collection), "{objects:?}");
    let own = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL))
        .await
        .expect("the connection's own collections");
    assert!(
        own.iter().all(|object| object.name != collection),
        "the collection was made in the connection's database: {own:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_dropped_database_is_no_longer_listed() {
    let fixture = start().await;
    let connection = connect(&fixture).await;
    let session = editor(connection.as_ref()).await;
    let (database, kept) = (unique("dropped"), unique("kept"));
    let (filled, _) = run(
        session.as_ref(),
        &format!(
            "db.getSiblingDB('{database}').getCollection('items').insertOne({{_id: 1}})\n\
             db.getCollection('{kept}').insertOne({{_id: 1}})"
        ),
    )
    .await;
    assert_eq!(filled.end, RunEnd::Completed);
    assert!(lists(connection.as_ref(), &database).await, "{database} is not listed");
    let plan = plan_drop_database(
        connection.dialect().as_ref(),
        &database,
        &DropDatabaseOptions::default(),
    )
    .expect("a plan");

    connection
        .write_batch(
            &plan.into_write_batch(TableRef::new(Some(database.clone()), "")),
            within(CALL),
        )
        .await
        .expect("the drop");

    assert!(
        !lists(connection.as_ref(), &database).await,
        "{database} is still listed"
    );
    let own = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL))
        .await
        .expect("the connection's own collections");
    assert!(
        own.iter().any(|object| object.name == kept),
        "the connection's own database was dropped: {own:?}"
    );
}

async fn lists(connection: &dyn Connection, database: &str) -> bool {
    let databases: Vec<SchemaInfo> = connection.list_databases(within(CALL)).await.expect("the databases");
    databases.iter().any(|listed| listed.name == database)
}

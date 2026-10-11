use drivers_mongodb::MongodbDriver;
use mongodb::bson::{Document, doc, oid::ObjectId};
use tablepro_core::{DatabaseDriver, Value};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_stale_grid_delete_preserves_concurrent_document_change() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client.database("appdb").collection::<Document>("stale_grid_deletes");
    let unchanged_id = ObjectId::new();
    let row_id = ObjectId::new();
    let sibling_row_id = ObjectId::new();
    let null_row_id = ObjectId::new();
    let null_array_row_id = ObjectId::new();
    collection
        .insert_many([
            doc! { "_id": unchanged_id, "payload": "unchanged", "sibling": "stable" },
            doc! { "_id": row_id, "payload": "before", "sibling": "stable" },
            doc! { "_id": sibling_row_id, "payload": "same", "sibling": "before" },
            doc! { "_id": null_row_id, "payload": mongodb::bson::Bson::Null, "sibling": "null-row" },
            doc! { "_id": null_array_row_id, "payload": mongodb::bson::Bson::Null, "sibling": "null-array-row" },
        ])
        .await
        .expect("seed MongoDB rows");

    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let before = connection
        .query("db.stale_grid_deletes.find({})")
        .await
        .expect("read row before delete");
    let key_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let find_row = |id: ObjectId| {
        before
            .rows
            .iter()
            .find(|row| row[key_index] == Value::Json(mongodb::bson::Bson::ObjectId(id).into_canonical_extjson()))
            .expect("find row by complete native key")
            .clone()
    };
    let unchanged = find_row(unchanged_id);
    let row = find_row(row_id);
    let sibling_row = find_row(sibling_row_id);
    let null_row = find_row(null_row_id);
    let null_array_row = find_row(null_array_row_id);
    collection
        .update_one(doc! { "_id": row_id }, doc! { "$set": { "payload": "concurrent" } })
        .await
        .expect("make concurrent edit after grid read");
    collection
        .update_one(
            doc! { "_id": sibling_row_id },
            doc! { "$set": { "sibling": "concurrent sibling" } },
        )
        .await
        .expect("change an untouched sibling field after the grid read");
    collection
        .update_one(doc! { "_id": null_row_id }, doc! { "$unset": { "payload": "" } })
        .await
        .expect("remove an explicit-NULL field after the grid read");
    collection
        .update_one(
            doc! { "_id": null_array_row_id },
            doc! { "$set": { "payload": [mongodb::bson::Bson::Null] } },
        )
        .await
        .expect("change explicit NULL to an array containing NULL after the grid read");

    let build_delete = |row: &[Value]| {
        tablepro_core::sql_dialect::build_mongodb_keyed_delete(
            Some("appdb"),
            "stale_grid_deletes",
            &before.columns,
            row,
            &[row[key_index].clone()],
        )
        .expect("build delete from full grid snapshot")
    };
    let statements = [
        unchanged.as_slice(),
        row.as_slice(),
        sibling_row.as_slice(),
        null_row.as_slice(),
        null_array_row.as_slice(),
    ]
    .map(build_delete);
    let affected = connection
        .execute_in_transaction(&statements)
        .await
        .expect("stale deletes must report conflicts");
    assert_eq!(
        affected,
        [1, 0, 0, 0, 0],
        "unchanged delete succeeds and stale snapshots conflict"
    );

    assert!(
        collection
            .find_one(doc! { "_id": unchanged_id })
            .await
            .expect("read unchanged row")
            .is_none(),
        "unchanged row should be deleted"
    );

    let persisted = collection
        .find_one(doc! { "_id": row_id })
        .await
        .expect("read native persisted document")
        .expect("stale delete must leave row present");
    assert_eq!(persisted.get_str("payload").unwrap(), "concurrent");
    assert_eq!(persisted.get_str("sibling").unwrap(), "stable");
    let persisted_sibling = collection
        .find_one(doc! { "_id": sibling_row_id })
        .await
        .expect("read native persisted sibling-change document")
        .expect("row with a concurrent sibling change must survive");
    assert_eq!(persisted_sibling.get_str("payload").unwrap(), "same");
    assert_eq!(persisted_sibling.get_str("sibling").unwrap(), "concurrent sibling");
    let persisted_null = collection
        .find_one(doc! { "_id": null_row_id })
        .await
        .expect("read native persisted missing-field document")
        .expect("row changed to a missing field must survive");
    assert!(!persisted_null.contains_key("payload"));
    let persisted_null_array = collection
        .find_one(doc! { "_id": null_array_row_id })
        .await
        .expect("read native persisted array document")
        .expect("row changed to an array must survive");
    assert_eq!(
        persisted_null_array.get_array("payload").unwrap(),
        &[mongodb::bson::Bson::Null]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_stale_grid_delete_preserves_field_added_after_materialization() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client
        .database("appdb")
        .collection::<Document>("new_field_stale_delete");
    let row_id = ObjectId::new();
    collection
        .insert_one(doc! { "_id": row_id, "payload": "keep", "sibling": "stable" })
        .await
        .expect("seed MongoDB row");

    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let before = connection
        .query("db.new_field_stale_delete.find({})")
        .await
        .expect("materialize row before delete");
    let key_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let row = before.rows.first().expect("one materialized row");
    assert!(
        before
            .columns
            .iter()
            .all(|column| column.name != "added_after_grid_read")
    );

    collection
        .update_one(
            doc! { "_id": row_id },
            doc! { "$set": { "added_after_grid_read": "preserve me" } },
        )
        .await
        .expect("add a field outside the materialized grid columns");
    let (sql, params) = tablepro_core::sql_dialect::build_mongodb_keyed_delete(
        Some("appdb"),
        "new_field_stale_delete",
        &before.columns,
        row,
        &[row[key_index].clone()],
    )
    .expect("build guarded delete from the materialized snapshot");
    let deleted = connection.execute_params(&sql, &params).await.unwrap();
    assert_eq!(deleted.rows_affected, 0, "a new field makes the snapshot stale");

    let persisted = collection
        .find_one(doc! { "_id": row_id })
        .await
        .expect("read native persisted document")
        .expect("stale delete must leave row present");
    assert_eq!(persisted.get_str("payload").unwrap(), "keep");
    assert_eq!(persisted.get_str("sibling").unwrap(), "stable");
    assert_eq!(persisted.get_str("added_after_grid_read").unwrap(), "preserve me");
}

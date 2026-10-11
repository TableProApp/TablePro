use drivers_mongodb::MongodbDriver;
use mongodb::bson::{Document, doc, oid::ObjectId};
use tablepro_core::{DatabaseDriver, Value};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mongodb_grid_value_comparison_does_not_detect_aba() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client.database("appdb").collection::<Document>("aba_grid");
    let edit_id = ObjectId::new();
    let delete_id = ObjectId::new();
    collection
        .insert_many([
            doc! { "_id": edit_id, "payload": "before", "sibling": "keep edit sibling" },
            doc! { "_id": delete_id, "payload": "before", "sibling": "delete sibling" },
        ])
        .await
        .expect("seed edit and delete rows");

    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let before = connection.query("db.aba_grid.find({})").await.expect("read rows");
    let key_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let payload_index = before
        .columns
        .iter()
        .position(|column| column.name == "payload")
        .unwrap();
    let row_for = |id: ObjectId| {
        before
            .rows
            .iter()
            .find(|row| row[key_index] == Value::Json(mongodb::bson::Bson::ObjectId(id).into_canonical_extjson()))
            .expect("find row by complete native key")
            .clone()
    };
    let edit_row = row_for(edit_id);
    let delete_row = row_for(delete_id);

    for id in [edit_id, delete_id] {
        collection
            .update_one(doc! { "_id": id }, doc! { "$set": { "payload": "away" } })
            .await
            .expect("change the value after the grid read");
        collection
            .update_one(doc! { "_id": id }, doc! { "$set": { "payload": "before" } })
            .await
            .expect("restore the original value before the grid write");
    }

    let (update, update_params) = tablepro_core::sql_dialect::build_mongodb_keyed_update(
        Some("appdb"),
        "aba_grid",
        &before.columns,
        &[(
            payload_index,
            edit_row[payload_index].clone(),
            Value::Text("user edit".into()),
        )],
        &[edit_row[key_index].clone()],
    )
    .expect("build keyed edit from the materialized row");
    assert_eq!(
        connection
            .execute_in_transaction(&[(update, update_params)])
            .await
            .unwrap(),
        [1],
        "value comparison accepts the row after it returns to the materialized value"
    );

    let (delete, delete_params) = tablepro_core::sql_dialect::build_mongodb_keyed_delete(
        Some("appdb"),
        "aba_grid",
        &before.columns,
        &delete_row,
        &[delete_row[key_index].clone()],
    )
    .expect("build keyed delete from the materialized row");
    assert_eq!(
        connection
            .execute_in_transaction(&[(delete, delete_params)])
            .await
            .unwrap(),
        [1],
        "full-document comparison cannot distinguish an ABA change"
    );

    let persisted_edit = collection.find_one(doc! { "_id": edit_id }).await.unwrap().unwrap();
    assert_eq!(persisted_edit.get_str("payload").unwrap(), "user edit");
    assert_eq!(persisted_edit.get_str("sibling").unwrap(), "keep edit sibling");
    assert!(collection.find_one(doc! { "_id": delete_id }).await.unwrap().is_none());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_stale_grid_edit_does_not_overwrite_concurrent_document_change() {
    let (_container, host, port) = super::start_mongo().await;
    let client = mongodb::Client::with_uri_str(format!("mongodb://{host}:{port}/appdb"))
        .await
        .expect("connect native fixture client");
    let collection = client.database("appdb").collection::<Document>("stale_grid_edits");
    let row_id = ObjectId::new();
    collection
        .insert_one(doc! { "_id": row_id, "payload": "before", "sibling": "stable" })
        .await
        .expect("seed MongoDB row");
    let null_row_id = ObjectId::new();
    collection
        .insert_one(doc! { "_id": null_row_id, "payload": mongodb::bson::Bson::Null, "sibling": "null-row" })
        .await
        .expect("seed explicit BSON NULL row");
    let null_array_row_id = ObjectId::new();
    collection
        .insert_one(
            doc! { "_id": null_array_row_id, "payload": mongodb::bson::Bson::Null, "sibling": "null-array-row" },
        )
        .await
        .expect("seed explicit BSON NULL row for array-change case");

    let connection = MongodbDriver
        .connect(super::opts(&host, port, "appdb"))
        .await
        .expect("connect driver");
    let before = connection
        .query("db.stale_grid_edits.find({})")
        .await
        .expect("read rows before edits");
    let key_index = before.columns.iter().position(|column| column.name == "_id").unwrap();
    let payload_index = before
        .columns
        .iter()
        .position(|column| column.name == "payload")
        .unwrap();
    let row = before
        .rows
        .iter()
        .find(|row| row[key_index] == Value::Json(mongodb::bson::Bson::ObjectId(row_id).into_canonical_extjson()))
        .expect("find the target row by its complete native key");
    assert_eq!(
        row[payload_index],
        Value::Json(serde_json::Value::String("before".into()))
    );
    let null_row = before
        .rows
        .iter()
        .find(|row| row[key_index] == Value::Json(mongodb::bson::Bson::ObjectId(null_row_id).into_canonical_extjson()))
        .expect("find the explicit-NULL row by its complete native key");
    assert_eq!(null_row[payload_index], Value::Json(serde_json::Value::Null));
    let null_array_row = before
        .rows
        .iter()
        .find(|row| {
            row[key_index] == Value::Json(mongodb::bson::Bson::ObjectId(null_array_row_id).into_canonical_extjson())
        })
        .expect("find the explicit-NULL row for the array-change case by its complete native key");
    assert_eq!(null_array_row[payload_index], Value::Json(serde_json::Value::Null));

    collection
        .update_one(doc! { "_id": row_id }, doc! { "$set": { "payload": "concurrent" } })
        .await
        .expect("make a concurrent edit after the grid read");
    collection
        .update_one(doc! { "_id": null_row_id }, doc! { "$unset": { "payload": "" } })
        .await
        .expect("remove the explicit-NULL field after the grid read");
    collection
        .update_one(
            doc! { "_id": null_array_row_id },
            doc! { "$set": { "payload": [mongodb::bson::Bson::Null] } },
        )
        .await
        .expect("change the explicit-NULL field to an array containing NULL after the grid read");

    let (statement, params) = tablepro_core::sql_dialect::build_mongodb_keyed_update(
        Some("appdb"),
        "stale_grid_edits",
        &before.columns,
        &[(
            payload_index,
            row[payload_index].clone(),
            Value::Text("user edit".into()),
        )],
        &[row[key_index].clone()],
    )
    .expect("build keyed update from the stale grid result");
    let (null_statement, null_params) = tablepro_core::sql_dialect::build_mongodb_keyed_update(
        Some("appdb"),
        "stale_grid_edits",
        &before.columns,
        &[(
            payload_index,
            null_row[payload_index].clone(),
            Value::Text("user edit".into()),
        )],
        &[null_row[key_index].clone()],
    )
    .expect("build keyed update from the stale explicit-NULL result");
    let (null_array_statement, null_array_params) = tablepro_core::sql_dialect::build_mongodb_keyed_update(
        Some("appdb"),
        "stale_grid_edits",
        &before.columns,
        &[(
            payload_index,
            null_array_row[payload_index].clone(),
            Value::Text("user edit".into()),
        )],
        &[null_array_row[key_index].clone()],
    )
    .expect("build keyed update from the stale explicit-NULL array result");
    let affected = connection
        .execute_in_transaction(&[
            (statement, params),
            (null_statement, null_params),
            (null_array_statement, null_array_params),
        ])
        .await
        .expect("attempt guarded stale edits");
    assert_eq!(affected, [0, 0, 0], "concurrent field changes must report conflicts");

    let persisted = collection
        .find_one(doc! { "_id": row_id })
        .await
        .expect("read native persisted document")
        .expect("row remains present");
    assert_eq!(persisted.get_str("payload").unwrap(), "concurrent");
    assert_eq!(persisted.get_str("sibling").unwrap(), "stable");
    let persisted_null = collection
        .find_one(doc! { "_id": null_row_id })
        .await
        .expect("read native persisted explicit-NULL document")
        .expect("NULL row remains present");
    assert!(
        !persisted_null.contains_key("payload"),
        "the concurrent field removal must survive"
    );
    let persisted_null_array = collection
        .find_one(doc! { "_id": null_array_row_id })
        .await
        .expect("read native persisted explicit-NULL array document")
        .expect("NULL array row remains present");
    assert_eq!(
        persisted_null_array.get_array("payload").unwrap(),
        &[mongodb::bson::Bson::Null],
        "the concurrent array value must survive"
    );
}

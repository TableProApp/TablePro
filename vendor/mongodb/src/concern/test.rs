use std::time::Duration;

use crate::{
    bson::{doc, Bson, Document},
    error::ErrorKind,
    options::{Acknowledgment, ReadConcern, WriteConcern},
    test::{server_version_lt, transactions_supported, EventClient},
    Client,
    Collection,
};

#[test]
fn write_concern_is_acknowledged() {
    let w_1 = WriteConcern::builder()
        .w(Acknowledgment::Nodes(1))
        .journal(false)
        .build();
    assert!(w_1.is_acknowledged());

    let w_majority = WriteConcern::builder()
        .w(Acknowledgment::Majority)
        .journal(false)
        .build();
    assert!(w_majority.is_acknowledged());

    let w_0 = WriteConcern::builder()
        .w(Acknowledgment::Nodes(0))
        .journal(false)
        .build();
    assert!(!w_0.is_acknowledged());

    let w_0 = WriteConcern::builder().w(Acknowledgment::Nodes(0)).build();
    assert!(!w_0.is_acknowledged());

    let empty = WriteConcern::builder().build();
    assert!(empty.is_acknowledged());

    let empty = WriteConcern::builder().journal(false).build();
    assert!(empty.is_acknowledged());

    let empty = WriteConcern::builder().journal(true).build();
    assert!(empty.is_acknowledged());
}

#[test]
fn write_concern_deserialize() {
    let w_1 = doc! { "w": 1 };
    let wc: WriteConcern = crate::bson_compat::deserialize_from_bson(Bson::Document(w_1)).unwrap();
    assert_eq!(
        wc,
        WriteConcern {
            w: Acknowledgment::Nodes(1).into(),
            w_timeout: None,
            journal: None
        }
    );

    let w_majority = doc! { "w": "majority" };
    let wc: WriteConcern =
        crate::bson_compat::deserialize_from_bson(Bson::Document(w_majority)).unwrap();
    assert_eq!(
        wc,
        WriteConcern {
            w: Acknowledgment::Majority.into(),
            w_timeout: None,
            journal: None
        }
    );

    let w_timeout = doc! { "w": "majority", "wtimeout": 100 };
    let wc: WriteConcern =
        crate::bson_compat::deserialize_from_bson(Bson::Document(w_timeout)).unwrap();
    assert_eq!(
        wc,
        WriteConcern {
            w: Acknowledgment::Majority.into(),
            w_timeout: Duration::from_millis(100).into(),
            journal: None
        }
    );

    let journal = doc! { "w": "majority", "j": true };
    let wc: WriteConcern =
        crate::bson_compat::deserialize_from_bson(Bson::Document(journal)).unwrap();
    assert_eq!(
        wc,
        WriteConcern {
            w: Acknowledgment::Majority.into(),
            w_timeout: None,
            journal: true.into()
        }
    );
}

#[tokio::test]
#[function_name::named]
async fn inconsistent_write_concern_rejected() {
    let client = Client::for_test().await;
    let db = client.database(function_name!());

    let coll = db.collection(function_name!());
    let wc = WriteConcern {
        w: Acknowledgment::Nodes(0).into(),
        journal: true.into(),
        w_timeout: None,
    };
    let error = coll
        .insert_one(doc! {})
        .write_concern(wc)
        .await
        .expect_err("insert should fail");
    assert!(matches!(*error.kind, ErrorKind::InvalidArgument { .. }));
}

#[tokio::test]
#[function_name::named]
async fn unacknowledged_write_concern_rejected() {
    let client = Client::for_test().await;
    let db = client.database(function_name!());
    let coll = db.collection(function_name!());
    let wc = WriteConcern {
        w: Acknowledgment::Nodes(0).into(),
        journal: false.into(),
        w_timeout: None,
    };
    let error = coll
        .insert_one(doc! {})
        .write_concern(wc)
        .await
        .expect_err("insert should fail");
    assert!(matches!(*error.kind, ErrorKind::InvalidArgument { .. }));
}

#[tokio::test]
#[function_name::named]
async fn snapshot_read_concern() {
    let client = Client::for_test().monitor_events().await;

    let coll = client
        .database(function_name!())
        .collection::<Document>(function_name!());

    if transactions_supported().await {
        let mut session = client.start_session().await.unwrap();
        session
            .start_transaction()
            .read_concern(ReadConcern::snapshot())
            .await
            .unwrap();
        let result = coll.find_one(doc! {}).session(&mut session).await;
        assert!(result.is_ok());
        assert_event_contains_read_concern(&client).await;
    }

    if server_version_lt(4, 9).await {
        let error = coll
            .find_one(doc! {})
            .read_concern(ReadConcern::snapshot())
            .await
            .expect_err("non-transaction find one with snapshot read concern should fail");
        // ensure that an error from the server is returned
        assert!(matches!(*error.kind, ErrorKind::Command(_)));
        assert_event_contains_read_concern(&client).await;
    }
}

async fn assert_event_contains_read_concern(client: &EventClient) {
    let event = client
        .events
        .get_command_started_events(&["find"])
        .into_iter()
        .next()
        .unwrap();
    assert_eq!(
        event
            .command
            .get_document("readConcern")
            .unwrap()
            .get_str("level")
            .unwrap(),
        "snapshot"
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_insert_one() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();
    coll.insert_one(doc! { "foo": "bar" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.insert_one(doc! { "foo": "bar" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "insert"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_insert_many() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();
    coll.insert_many(&[doc! { "foo": "bar" }])
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.insert_many(&[doc! { "foo": "bar" }])
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "insert"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_update_one() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();
    coll.insert_one(doc! { "foo": "bar" }).await.unwrap();
    coll.update_one(doc! { "foo": "bar" }, doc! { "$set": { "foo": "baz" } })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.update_one(doc! { "foo": "baz" }, doc! { "$set": { "foo": "quux" } })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "update"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_update_many() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();
    coll.insert_many(&[doc! { "foo": "bar" }, doc! { "foo": "bar" }])
        .await
        .unwrap();
    coll.update_many(doc! { "foo": "bar" }, doc! { "$set": { "foo": "baz" } })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.update_many(doc! { "foo": "baz" }, doc! { "$set": { "foo": "quux" } })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "update"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_replace_one() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();
    coll.insert_one(doc! { "foo": "bar" }).await.unwrap();
    coll.replace_one(doc! { "foo": "bar" }, doc! { "baz": "fun" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.replace_one(doc! { "foo": "bar" }, doc! { "baz": "fun" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "update"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_delete_one() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();
    coll.insert_many(&[doc! { "foo": "bar" }, doc! { "foo": "bar" }])
        .await
        .unwrap();
    coll.delete_one(doc! { "foo": "bar" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.delete_one(doc! { "foo": "bar" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "delete"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_delete_many() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();
    coll.insert_many(&[doc! { "foo": "bar" }, doc! { "foo": "bar" }])
        .await
        .unwrap();
    coll.delete_many(doc! { "foo": "bar" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.insert_many(&[doc! { "foo": "bar" }, doc! { "foo": "bar" }])
        .await
        .unwrap();
    coll.delete_many(doc! { "foo": "bar" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "delete"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_find_one_and_delete() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();
    coll.insert_many(&[doc! { "foo": "bar" }, doc! { "foo": "bar" }])
        .await
        .unwrap();
    coll.find_one_and_delete(doc! { "foo": "bar" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.find_one_and_delete(doc! { "foo": "bar" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "findAndModify"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_find_one_and_replace() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();
    coll.insert_many(&[doc! { "foo": "bar" }, doc! { "foo": "bar" }])
        .await
        .unwrap();
    coll.find_one_and_replace(doc! { "foo": "bar" }, doc! { "baz": "fun" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.find_one_and_replace(doc! { "foo": "bar" }, doc! { "baz": "fun" })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "findAndModify"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_find_one_and_update() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();
    coll.insert_many(&[doc! { "foo": "bar" }, doc! { "foo": "bar" }])
        .await
        .unwrap();
    coll.find_one_and_update(doc! { "foo": "bar" }, doc! { "$set": { "foo": "fun" } })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.find_one_and_update(doc! { "foo": "bar" }, doc! { "$set": { "foo": "fun" } })
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "findAndModify"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_aggregate() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();
    coll.insert_one(doc! { "foo": "bar" }).await.unwrap();
    coll.aggregate(vec![
        doc! { "$match": { "foo": "bar" } },
        doc! { "$addFields": { "foo": "baz" } },
        doc! { "$out": format!("{}-out", function_name!()) },
    ])
    .write_concern(
        WriteConcern::builder()
            .w(Acknowledgment::Nodes(1))
            .journal(true)
            .build(),
    )
    .await
    .unwrap();
    coll.aggregate(vec![
        doc! { "$match": { "foo": "bar" } },
        doc! { "$addFields": { "foo": "baz" } },
        doc! { "$out": format!("{}-out", function_name!()) },
    ])
    .write_concern(
        WriteConcern::builder()
            .w(Acknowledgment::Nodes(1))
            .journal(false)
            .build(),
    )
    .await
    .unwrap();

    assert_eq!(
        command_write_concerns(&client, "aggregate"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_drop() {
    let client = Client::for_test().monitor_events().await;
    let coll: Collection<Document> = client.database("test").collection(function_name!());

    coll.drop().await.unwrap();

    let mut events = client.events.clone();
    events.clear_cached_events();
    coll.insert_one(doc! { "foo": "bar" }).await.unwrap();
    coll.drop()
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.insert_one(doc! { "foo": "bar" }).await.unwrap();
    coll.drop()
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "drop"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

#[tokio::test]
#[function_name::named]
async fn command_contains_write_concern_create_collection() {
    let client = Client::for_test().monitor_events().await;
    let db = client.database("test");
    let coll: Collection<Document> = db.collection(function_name!());

    coll.drop().await.unwrap();
    db.create_collection(function_name!())
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(true)
                .build(),
        )
        .await
        .unwrap();
    coll.drop().await.unwrap();
    db.create_collection(function_name!())
        .write_concern(
            WriteConcern::builder()
                .w(Acknowledgment::Nodes(1))
                .journal(false)
                .build(),
        )
        .await
        .unwrap();

    assert_eq!(
        command_write_concerns(&client, "create"),
        vec![
            doc! {
                "w": 1,
                "j": true,
            },
            doc! {
                "w": 1,
                "j": false,
            },
        ]
    );
}

fn command_write_concerns(client: &EventClient, key: &str) -> Vec<Document> {
    client
        .events
        .get_command_started_events(&[key])
        .into_iter()
        .map(|d| d.command.get_document("writeConcern").unwrap().clone())
        .collect()
}

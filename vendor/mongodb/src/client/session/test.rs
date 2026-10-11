mod causal_consistency;

use std::{future::Future, sync::Arc, time::Duration};

use crate::bson::Document;
use futures::stream::StreamExt;

use crate::{
    bson::{doc, Bson},
    coll::options::CountOptions,
    error::Result,
    event::sdam::SdamEvent,
    options::{FindOptions, ReadConcern, ReadPreference, WriteConcern},
    sdam::ServerInfo,
    selection_criteria::SelectionCriteria,
    test::{
        get_client_options,
        get_primary,
        log_uncaptured,
        topology_is_standalone,
        util::event_buffer::EventBuffer,
        Event,
        EventClient,
    },
    Client,
    Collection,
};

/// Macro defining a closure that returns a future populated by an operation on the
/// provided client identifier.
macro_rules! client_op {
    ($client:ident, $body:expr) => {
        |$client| async move {
            $body.await.unwrap();
        }
    };
}

/// Macro defining a closure that returns a future populated by an operation on the
/// provided database identifier.
macro_rules! db_op {
    ($test_name:expr, $db:ident, $body:expr) => {
        |client| async move {
            let $db = client.database($test_name);
            $body.await.unwrap();
        }
    };
}

/// Macro defining a closure that returns a future populated by an operation on the
/// provided collection identifier.
macro_rules! collection_op {
    ($test_name:expr, $coll:ident, $body:expr) => {
        |client| async move {
            let $coll = client
                .database($test_name)
                .collection::<crate::bson::Document>($test_name);
            $body.await.unwrap();
        }
    };
}

/// Macro that runs the provided function with each operation that uses a session.
macro_rules! for_each_op {
    ($test_name:expr, $test_func:ident) => {{
        // collection operations
        $test_func(
            "insert",
            collection_op!($test_name, coll, coll.insert_one(doc! { "x": 1 })),
        )
        .await;
        $test_func(
            "insert",
            collection_op!($test_name, coll, coll.insert_many(vec![doc! { "x": 1 }])),
        )
        .await;
        $test_func(
            "update",
            collection_op!(
                $test_name,
                coll,
                coll.replace_one(doc! { "x": 1 }, doc! { "x": 2 })
            ),
        )
        .await;
        $test_func(
            "update",
            collection_op!(
                $test_name,
                coll,
                coll.update_one(doc! {}, doc! { "$inc": {"x": 5 } })
            ),
        )
        .await;
        $test_func(
            "update",
            collection_op!(
                $test_name,
                coll,
                coll.update_many(doc! {}, doc! { "$inc": {"x": 5 } })
            ),
        )
        .await;
        $test_func(
            "delete",
            collection_op!($test_name, coll, coll.delete_one(doc! { "x": 1 })),
        )
        .await;
        $test_func(
            "delete",
            collection_op!($test_name, coll, coll.delete_many(doc! { "x": 1 })),
        )
        .await;
        $test_func(
            "findAndModify",
            collection_op!($test_name, coll, coll.find_one_and_delete(doc! { "x": 1 })),
        )
        .await;
        $test_func(
            "findAndModify",
            collection_op!(
                $test_name,
                coll,
                coll.find_one_and_update(doc! {}, doc! { "$inc": { "x": 1 } })
            ),
        )
        .await;
        $test_func(
            "findAndModify",
            collection_op!(
                $test_name,
                coll,
                coll.find_one_and_replace(doc! {}, doc! {"x": 1})
            ),
        )
        .await;
        $test_func(
            "aggregate",
            collection_op!(
                $test_name,
                coll,
                coll.aggregate(vec![doc! { "$match": { "x": 1 } }])
            ),
        )
        .await;
        $test_func(
            "find",
            collection_op!($test_name, coll, coll.find(doc! { "x": 1 })),
        )
        .await;
        $test_func(
            "find",
            collection_op!($test_name, coll, coll.find_one(doc! { "x": 1 })),
        )
        .await;
        $test_func(
            "distinct",
            collection_op!($test_name, coll, coll.distinct("x", doc! {})),
        )
        .await;
        $test_func(
            "aggregate",
            collection_op!($test_name, coll, coll.count_documents(doc! {})),
        )
        .await;
        $test_func("drop", collection_op!($test_name, coll, coll.drop())).await;

        // db operations
        $test_func(
            "listCollections",
            db_op!($test_name, db, db.list_collections()),
        )
        .await;
        $test_func(
            "ping",
            db_op!($test_name, db, db.run_command(doc! { "ping":  1 })),
        )
        .await;
        $test_func(
            "create",
            db_op!($test_name, db, db.create_collection("sessionopcoll")),
        )
        .await;
        $test_func("dropDatabase", db_op!($test_name, db, db.drop())).await;

        // client operations
        $test_func("listDatabases", client_op!(client, client.list_databases())).await;
        $test_func(
            "listDatabases",
            client_op!(client, client.list_database_names()),
        )
        .await;
    }};
}

/// Prose test 1 from sessions spec.
/// This test also satisifies the `endSession` testing requirement of prose test 5.
#[tokio::test]
async fn pool_is_lifo() {
    if topology_is_standalone().await {
        return;
    }

    let client = Client::for_test().await;
    // Wait for the implicit sessions created in TestClient::new to be returned to the pool.
    tokio::time::sleep(Duration::from_millis(500)).await;

    let a = client.start_session().await.unwrap();
    let b = client.start_session().await.unwrap();

    let a_id = a.id().clone();
    let b_id = b.id().clone();

    // End both sessions, waiting after each to ensure the background task got scheduled
    // in the Drop impls.
    drop(a);
    tokio::time::sleep(Duration::from_millis(250)).await;

    drop(b);
    tokio::time::sleep(Duration::from_millis(250)).await;

    let s1 = client.start_session().await.unwrap();
    assert_eq!(s1.id(), &b_id);

    let s2 = client.start_session().await.unwrap();
    assert_eq!(s2.id(), &a_id);
}

/// Prose test 2 from sessions spec.
#[tokio::test]
#[function_name::named]
async fn cluster_time_in_commands() {
    if topology_is_standalone().await {
        log_uncaptured("skipping cluster_time_in_commands test due to standalone topology");
        return;
    }

    async fn cluster_time_test<F, G, R>(
        command_name: &str,
        client: &Client,
        event_buffer: &EventBuffer,
        operation: F,
    ) where
        F: Fn(Client) -> G,
        G: Future<Output = Result<R>>,
    {
        let mut event_stream = event_buffer.stream();

        operation(client.clone())
            .await
            .expect("operation should succeed");

        operation(client.clone())
            .await
            .expect("operation should succeed");

        let (first_command_started, first_command_succeeded) = event_stream
            .next_successful_command_execution(Duration::from_secs(5), command_name)
            .await
            .unwrap_or_else(|| {
                panic!("did not see command started and succeeded events for {command_name}")
            });

        assert!(first_command_started.command.get("$clusterTime").is_some());
        let response_cluster_time = first_command_succeeded
            .reply
            .get("$clusterTime")
            .expect("should get cluster time from command response");

        let (second_command_started, _) = event_stream
            .next_successful_command_execution(Duration::from_secs(5), command_name)
            .await
            .unwrap_or_else(|| {
                panic!("did not see command started and succeeded events for {command_name}")
            });

        assert_eq!(
            response_cluster_time,
            second_command_started
                .command
                .get("$clusterTime")
                .expect("second command should contain cluster time"),
            "cluster time not equal for {command_name}"
        );
    }

    let buffer = EventBuffer::new();
    let mut options = get_client_options().await.clone();
    options.heartbeat_freq = Some(Duration::from_secs(1000));
    options.command_event_handler = Some(buffer.handler());
    options.sdam_event_handler = Some(buffer.handler());

    // Ensure we only connect to one server so the monitor checks from other servers
    // don't affect the TopologyDescription's clusterTime value between commands.
    if options.load_balanced != Some(true) {
        options.direct_connection = Some(true);

        // Since we need to run an insert below, ensure the single host is a primary
        // if we're connected to a replica set.
        if let Some(primary) = get_primary().await {
            options.hosts = vec![primary];
        } else {
            options.hosts.drain(1..);
        }
    }

    let mut event_stream = buffer.stream();

    let client = Client::with_options(options).unwrap();

    // Wait for initial monitor check to complete and discover the server.
    event_stream
        .next_match(Duration::from_secs(5), |event| match event {
            Event::Sdam(SdamEvent::ServerDescriptionChanged(e)) => {
                !e.previous_description.server_type().is_available()
                    && e.new_description.server_type().is_available()
            }
            _ => false,
        })
        .await
        .expect("server should be discovered");

    // LoadBalanced topologies don't have monitors, so the client needs to get a clusterTime from
    // a command invocation.
    client
        .database("admin")
        .run_command(doc! { "ping": 1 })
        .await
        .unwrap();

    cluster_time_test("ping", &client, &buffer, |client| async move {
        client
            .database(function_name!())
            .run_command(doc! { "ping": 1 })
            .await
    })
    .await;

    cluster_time_test("aggregate", &client, &buffer, |client| async move {
        client
            .database(function_name!())
            .collection::<Document>(function_name!())
            .aggregate(vec![doc! { "$match": { "x": 1 } }])
            .await
    })
    .await;

    cluster_time_test("find", &client, &buffer, |client| async move {
        client
            .database(function_name!())
            .collection::<Document>(function_name!())
            .find(doc! {})
            .await
    })
    .await;

    cluster_time_test("insert", &client, &buffer, |client| async move {
        client
            .database(function_name!())
            .collection::<Document>(function_name!())
            .insert_one(doc! {})
            .await
    })
    .await;
}

/// Prose test 3 from sessions spec.
#[tokio::test]
#[function_name::named]
async fn session_usage() {
    if topology_is_standalone().await {
        return;
    }

    async fn session_usage_test<F, G>(command_name: &str, operation: F)
    where
        F: Fn(EventClient) -> G,
        G: Future<Output = ()>,
    {
        let client = Client::for_test().monitor_events().await;
        operation(client.clone()).await;
        let (command_started, _) = client.events.get_successful_command_execution(command_name);
        assert!(
            command_started.command.get("lsid").is_some(),
            "implicit session not passed to {command_name}"
        );
    }

    for_each_op!(function_name!(), session_usage_test)
}

/// Prose test 7 from sessions spec.
#[tokio::test]
#[function_name::named]
async fn implicit_session_returned_after_immediate_exhaust() {
    if topology_is_standalone().await {
        return;
    }

    let client = Client::for_test().monitor_events().await;

    let coll = client
        .init_db_and_coll(function_name!(), function_name!())
        .await;
    coll.insert_many(vec![doc! {}, doc! {}])
        .await
        .expect("insert should succeed");

    // wait for sessions to be returned to the pool and clear them out.
    tokio::time::sleep(Duration::from_millis(250)).await;
    client.clear_session_pool().await;

    let mut cursor = coll.find(doc! {}).await.expect("find should succeed");
    assert!(matches!(cursor.next().await, Some(Ok(_))));

    let (find_started, _) = client.events.get_successful_command_execution("find");
    let session_id = find_started
        .command
        .get("lsid")
        .expect("find should use implicit session")
        .as_document()
        .expect("session id should be a document");

    tokio::time::sleep(Duration::from_millis(250)).await;
    assert!(
        client.is_session_checked_in(session_id).await,
        "session not checked back in"
    );

    assert!(matches!(cursor.next().await, Some(Ok(_))));
}

/// Prose test 8 from sessions spec.
#[tokio::test]
#[function_name::named]
async fn implicit_session_returned_after_exhaust_by_get_more() {
    if topology_is_standalone().await {
        return;
    }

    let client = Client::for_test().monitor_events().await;
    let coll = client
        .init_db_and_coll(function_name!(), function_name!())
        .await;
    for _ in 0..5 {
        coll.insert_one(doc! {})
            .await
            .expect("insert should succeed");
    }

    // wait for sessions to be returned to the pool and clear them out.
    tokio::time::sleep(Duration::from_millis(250)).await;
    client.clear_session_pool().await;

    let mut cursor = coll
        .find(doc! {})
        .batch_size(3)
        .await
        .expect("find should succeed");

    for _ in 0..4 {
        assert!(matches!(cursor.next().await, Some(Ok(_))));
    }

    let (find_started, _) = client.events.get_successful_command_execution("find");

    let session_id = find_started
        .command
        .get("lsid")
        .expect("find should use implicit session")
        .as_document()
        .expect("session id should be a document");

    tokio::time::sleep(Duration::from_millis(250)).await;
    assert!(
        client.is_session_checked_in(session_id).await,
        "session not checked back in"
    );

    assert!(matches!(cursor.next().await, Some(Ok(_))));
}

/// Prose test 10 from sessions spec.
#[tokio::test]
#[function_name::named]
async fn find_and_getmore_share_session() {
    if topology_is_standalone().await {
        log_uncaptured(
            "skipping find_and_getmore_share_session due to unsupported topology: Standalone",
        );
        return;
    }

    let client = Client::for_test().monitor_events().await;

    let coll = client
        .init_db_and_coll(function_name!(), function_name!())
        .await;

    coll.insert_many(vec![doc! {}; 3])
        .write_concern(WriteConcern::majority())
        .await
        .unwrap();

    let read_preferences: Vec<ReadPreference> = vec![
        ReadPreference::Primary,
        ReadPreference::PrimaryPreferred {
            options: Default::default(),
        },
        ReadPreference::Secondary {
            options: Default::default(),
        },
        ReadPreference::SecondaryPreferred {
            options: Default::default(),
        },
        ReadPreference::Nearest {
            options: Default::default(),
        },
    ];

    async fn run_test(
        client: &EventClient,
        coll: &Collection<Document>,
        read_preference: ReadPreference,
    ) {
        client.events.clone().clear_cached_events();

        let options = FindOptions::builder()
            .batch_size(2)
            .selection_criteria(SelectionCriteria::ReadPreference(read_preference.clone()))
            .read_concern(ReadConcern::local())
            .build();

        // Loop until data is found to avoid racing with replication.
        let mut cursor;
        loop {
            cursor = coll
                .find(doc! {})
                .with_options(options.clone())
                .await
                .expect("find should succeed");
            if cursor.has_next() {
                break;
            }
        }

        for _ in 0..3 {
            cursor
                .next()
                .await
                .unwrap_or_else(|| {
                    panic!("should get result with read preference {read_preference:?}")
                })
                .unwrap_or_else(|e| {
                    panic!(
                        "result should not be error with read preference {read_preference:?}, but \
                         got {e:?}"
                    )
                });
        }

        let (find_started, _) = client.events.get_successful_command_execution("find");
        let session_id = find_started
            .command
            .get("lsid")
            .expect("find should use implicit session");
        assert!(session_id != &Bson::Null);

        let (command_started, _) = client.events.get_successful_command_execution("getMore");
        let getmore_session_id = command_started
            .command
            .get("lsid")
            .expect("count documents should use implicit session");
        assert_eq!(getmore_session_id, session_id);
    }

    let topology_description = client.topology_description();
    for (addr, server) in topology_description.servers {
        if !server.server_type.is_data_bearing() {
            continue;
        }

        let a = addr.clone();
        let rp = Arc::new(move |si: &ServerInfo| si.address() == &a);
        let options = CountOptions::builder()
            .selection_criteria(SelectionCriteria::Predicate(rp))
            .read_concern(ReadConcern::local())
            .build();

        while coll
            .count_documents(doc! {})
            .with_options(options.clone())
            .await
            .unwrap()
            != 3
        {}
    }

    for read_pref in read_preferences {
        run_test(&client, &coll, read_pref).await;
    }
}

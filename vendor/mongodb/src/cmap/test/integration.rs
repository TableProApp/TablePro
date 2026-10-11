use crate::{bson::rawdoc, sdam::topology::TopologyShutdown};
use serde::Deserialize;

use super::EVENT_TIMEOUT;
use crate::{
    bson::{doc, Document},
    cmap::{
        establish::{ConnectionEstablisher, EstablisherOptions},
        options::ConnectionPoolOptions,
        Command,
        ConnectionPool,
    },
    event::cmap::{CmapEvent, ConnectionClosedReason},
    hello::LEGACY_HELLO_COMMAND_NAME,
    operation::CommandResponse,
    runtime,
    sdam::TopologyUpdater,
    selection_criteria::ReadPreference,
    test::{
        get_client_options,
        log_uncaptured,
        topology_is_load_balanced,
        util::{
            event_buffer::EventBuffer,
            fail_point::{FailPoint, FailPointMode},
        },
    },
    Client,
};
use std::time::Duration;

#[derive(Debug, Deserialize)]
struct ListDatabasesResponse {
    databases: Vec<DatabaseEntry>,
}

#[derive(Debug, Deserialize)]
struct DatabaseEntry {
    name: String,
}

#[tokio::test]
async fn acquire_connection_and_send_command() {
    let client_options = get_client_options().await.clone();
    let mut pool_options = ConnectionPoolOptions::from_client_options(&client_options);
    pool_options.ready = Some(true);

    let pool = ConnectionPool::new(
        client_options.hosts[0].clone(),
        ConnectionEstablisher::new(EstablisherOptions::from(&client_options)).unwrap(),
        TopologyUpdater::channel().0,
        Some(pool_options),
        TopologyShutdown::new(),
        #[cfg(feature = "tracing-unstable")]
        crate::bson::oid::ObjectId::new(),
    );
    let mut connection = pool.check_out().await.unwrap();

    let body = rawdoc! { "listDatabases": 1 };
    let read_pref = ReadPreference::PrimaryPreferred {
        options: Default::default(),
    };
    let mut cmd = Command::new_raw("listDatabases".to_string(), "admin".to_string(), body);
    cmd.set_read_preference(read_pref);
    if let Some(server_api) = client_options.server_api.as_ref() {
        cmd.set_server_api(server_api);
    }

    let response = connection.send_message(cmd).await.unwrap();
    let doc_response: CommandResponse<Document> = response.body().unwrap();

    assert!(doc_response.is_success());

    let response: ListDatabasesResponse =
        crate::bson_compat::deserialize_from_document(doc_response.body).unwrap();

    let names: Vec<_> = response
        .databases
        .into_iter()
        .map(|entry| entry.name)
        .collect();

    assert!(names.iter().any(|name| name == "admin"));
    assert!(names.iter().any(|name| name == "config"));
}

#[tokio::test]
async fn concurrent_connections() {
    let mut options = get_client_options().await.clone();
    if options.load_balanced.unwrap_or(false) {
        log_uncaptured("skipping concurrent_connections test due to load-balanced topology");
        return;
    }
    options.direct_connection = Some(true);
    options.hosts.drain(1..);

    let client = Client::for_test().options(options).await;

    // stall creating connections for a while
    let failpoint = doc! {
        "configureFailPoint": "failCommand",
        "mode": "alwaysOn",
        "data": { "failCommands": [LEGACY_HELLO_COMMAND_NAME, "hello"], "blockConnection": true, "blockTimeMS": 1000 }
    };
    client
        .database("admin")
        .run_command(failpoint)
        .await
        .expect("failpoint should succeed");

    let buffer = EventBuffer::<CmapEvent>::new();
    let client_options = get_client_options().await.clone();
    let mut options = ConnectionPoolOptions::from_client_options(&client_options);
    options.cmap_event_handler = Some(buffer.handler());
    options.ready = Some(true);

    let pool = ConnectionPool::new(
        get_client_options().await.hosts[0].clone(),
        ConnectionEstablisher::new(EstablisherOptions::from(&client_options)).unwrap(),
        TopologyUpdater::channel().0,
        Some(options),
        TopologyShutdown::new(),
        #[cfg(feature = "tracing-unstable")]
        crate::bson::oid::ObjectId::new(),
    );

    let tasks = (0..2).map(|_| {
        let pool_clone = pool.clone();
        runtime::spawn(async move {
            pool_clone.check_out().await.unwrap();
        })
    });
    futures::future::join_all(tasks).await;

    {
        // ensure all three ConnectionCreatedEvents were emitted before one ConnectionReadyEvent.
        let events = buffer.all();
        let mut consecutive_creations = 0;
        for event in events.iter() {
            match event {
                CmapEvent::ConnectionCreated(_) => {
                    consecutive_creations += 1;
                }
                CmapEvent::ConnectionReady(_) => {
                    assert!(
                        consecutive_creations >= 2,
                        "connections not created concurrently"
                    );
                }
                _ => (),
            }
        }
    }

    // clear the fail point
    client
        .database("admin")
        .run_command(doc! { "configureFailPoint": "failCommand", "mode": "off" })
        .await
        .expect("disabling fail point should succeed");
}

#[tokio::test(flavor = "multi_thread")]
async fn connection_error_during_establishment() {
    if topology_is_load_balanced().await {
        log_uncaptured(
            "skipping connection_error_during_establishment test due to load-balanced topology",
        );
        return;
    }

    let mut client_options = get_client_options().await.clone();
    client_options.heartbeat_freq = Duration::from_secs(300).into(); // high so that monitors dont trip failpoint
    client_options.hosts.drain(1..);
    client_options.direct_connection = Some(true);
    client_options.repl_set_name = None;

    let client = Client::for_test().options(client_options.clone()).await;

    let fail_point = FailPoint::fail_command(
        &[LEGACY_HELLO_COMMAND_NAME, "hello"],
        FailPointMode::Times(10),
    )
    .error_code(1234);
    let _guard = client.enable_fail_point(fail_point).await.unwrap();

    let buffer = EventBuffer::<CmapEvent>::new();

    let mut event_stream = buffer.stream();

    let mut options = ConnectionPoolOptions::from_client_options(&client_options);
    options.ready = Some(true);
    options.cmap_event_handler = Some(buffer.handler());
    let pool = ConnectionPool::new(
        client_options.hosts[0].clone(),
        ConnectionEstablisher::new(EstablisherOptions::from(&client_options)).unwrap(),
        TopologyUpdater::channel().0,
        Some(options),
        TopologyShutdown::new(),
        #[cfg(feature = "tracing-unstable")]
        crate::bson::oid::ObjectId::new(),
    );

    pool.check_out().await.expect_err("check out should fail");

    event_stream
        .next_match(EVENT_TIMEOUT, |e| match e {
            CmapEvent::ConnectionClosed(event) => {
                event.connection_id == 1 && event.reason == ConnectionClosedReason::Error
            }
            _ => false,
        })
        .await
        .expect("closed event with error reason should have been seen");
}

#[tokio::test(flavor = "multi_thread")]
async fn connection_error_during_operation() {
    let mut options = get_client_options().await.clone();
    let buffer = EventBuffer::<CmapEvent>::new();
    options.cmap_event_handler = Some(buffer.handler());
    options.hosts.drain(1..);
    options.max_pool_size = Some(1);

    let client = Client::for_test().options(options).await;

    let fail_point =
        FailPoint::fail_command(&["ping"], FailPointMode::Times(10)).close_connection(true);
    let _guard = client.enable_fail_point(fail_point).await.unwrap();

    let mut event_stream = buffer.stream();

    client
        .database("test")
        .run_command(doc! { "ping": 1 })
        .await
        .expect_err("ping should fail due to fail point");

    event_stream
        .next_match(EVENT_TIMEOUT, |e| match e {
            CmapEvent::ConnectionClosed(event) => {
                event.connection_id == 1 && event.reason == ConnectionClosedReason::Error
            }
            _ => false,
        })
        .await
        .expect("closed event with error reason should have been seen");
}

use std::{
    collections::HashSet,
    time::{Duration, Instant},
};

use crate::bson::doc;

use crate::{
    client::options::{ClientOptions, ServerAddress},
    cmap::RawCommandResponse,
    error::{Error, ErrorKind},
    event::{cmap::CmapEvent, sdam::SdamEvent},
    hello::{LEGACY_HELLO_COMMAND_NAME, LEGACY_HELLO_COMMAND_NAME_LOWERCASE},
    sdam::{ServerDescription, Topology},
    test::{
        fail_command_appname_initial_handshake_supported,
        get_client_options,
        log_uncaptured,
        server_version_matches,
        topology_is_load_balanced,
        topology_is_replica_set,
        util::{
            event_buffer::EventBuffer,
            fail_point::{FailPoint, FailPointMode},
        },
        Event,
    },
    Client,
};

#[tokio::test(flavor = "multi_thread")]
async fn min_heartbeat_frequency() {
    if cfg!(target_os = "macos") {
        log_uncaptured("skipping min_heartbeat_frequency: flaky on macos");
        return;
    }
    if topology_is_load_balanced().await {
        log_uncaptured("skipping min_heartbeat_frequency test due to load-balanced topology");
        return;
    }
    if !fail_command_appname_initial_handshake_supported().await {
        log_uncaptured(
            "skipping min_heartbeat_frequency test due to server not supporting failcommand \
             appname",
        );
        return;
    }

    let mut setup_client_options = get_client_options().await.clone();
    setup_client_options.hosts.drain(1..);
    setup_client_options.direct_connection = Some(true);

    let setup_client = Client::for_test()
        .options(setup_client_options.clone())
        .await;

    let _guard = setup_client
        .enable_fail_point(
            FailPoint::fail_command(
                &[LEGACY_HELLO_COMMAND_NAME, "hello"],
                FailPointMode::Times(5),
            )
            .app_name("SDAMMinHeartbeatFrequencyTest")
            .error_code(1234),
        )
        .await
        .unwrap();

    let mut options = setup_client_options;
    options.app_name = Some("SDAMMinHeartbeatFrequencyTest".to_string());
    options.server_selection_timeout = Some(Duration::from_secs(5));
    let client = Client::with_options(options).expect("client creation succeeds");

    let start = Instant::now();
    client
        .database("admin")
        .run_command(doc! { "ping": 1 })
        .await
        .expect("ping should eventually succeed");

    let elapsed = Instant::now().duration_since(start).as_millis();
    assert!(
        elapsed >= 2000,
        "expected to take at least 2 seconds, instead took {elapsed}ms"
    );
    assert!(
        elapsed <= 3500,
        "expected to take at most 3.5 seconds, instead took {elapsed}ms"
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "SERVER-128517"]
async fn sdam_pool_management() {
    if cfg!(target_os = "macos") {
        log_uncaptured("skipping sdam_pool_management: flaky on macos");
        return;
    }

    let mut options = get_client_options().await.clone();
    if options.load_balanced.unwrap_or(false) {
        log_uncaptured("skipping sdam_pool_management test due to load-balanced topology");
        return;
    }
    options.hosts.drain(1..);
    options.direct_connection = Some(true);
    options.app_name = Some("SDAMPoolManagementTest".to_string());
    options.heartbeat_freq = Some(Duration::from_millis(50));

    let client = Client::for_test()
        .options(options)
        .use_single_mongos()
        .min_heartbeat_freq(Duration::from_millis(50))
        .monitor_events()
        .await;

    let mut subscriber = client.events.stream_all();

    subscriber
        .next_match(Duration::from_millis(500), |event| {
            matches!(event, Event::Cmap(CmapEvent::PoolReady(_)))
        })
        .await
        .expect("should see pool ready event");

    subscriber
        .next_match(Duration::from_millis(500), |event| {
            matches!(event, Event::Sdam(SdamEvent::ServerHeartbeatSucceeded(_)))
        })
        .await
        .expect("should see server heartbeat succeeded event");

    let _guard = client
        .enable_fail_point(
            FailPoint::fail_command(
                &[LEGACY_HELLO_COMMAND_NAME, "hello"],
                FailPointMode::Times(4),
            )
            .app_name("SDAMPoolManagementTest")
            .error_code(1234),
        )
        .await
        .unwrap();

    // Since there is no deterministic ordering, simply collect all the events and check for their
    // presence.
    let events = subscriber.collect(Duration::from_secs(1), |_| true).await;
    assert!(events
        .iter()
        .any(|e| matches!(e, Event::Sdam(SdamEvent::ServerHeartbeatFailed(_)))));
    assert!(events
        .iter()
        .any(|e| matches!(e, Event::Cmap(CmapEvent::PoolCleared(_)))));
    assert!(events
        .iter()
        .any(|e| matches!(e, Event::Cmap(CmapEvent::PoolReady(_)))));
    assert!(events
        .iter()
        .any(|e| matches!(e, Event::Sdam(SdamEvent::ServerHeartbeatSucceeded(_)))));
}

#[tokio::test(flavor = "multi_thread")]
async fn hello_ok_true() {
    if !server_version_matches(">= 4.4.5").await {
        log_uncaptured("skipping hello_ok_true test due to server not supporting hello");
        return;
    }

    let mut setup_client_options = get_client_options().await.clone();
    setup_client_options.hosts.drain(1..);

    if setup_client_options.server_api.is_some() {
        log_uncaptured("skipping hello_ok_true test due to ServerApi being configured");
        return;
    }

    if setup_client_options.load_balanced == Some(true) {
        log_uncaptured("skipping hello_ok_true test due to load balanced topology");
        return;
    }

    let buffer = EventBuffer::new();

    let mut event_stream = buffer.stream();

    let mut options = setup_client_options.clone();
    options.sdam_event_handler = Some(buffer.handler());
    options.direct_connection = Some(true);
    options.heartbeat_freq = Some(Duration::from_millis(500));
    let _client = Client::with_options(options).expect("client creation should succeed");

    // first heartbeat should be legacy hello but contain helloOk
    event_stream
        .next_match(Duration::from_millis(2000), |event| {
            if let Event::Sdam(SdamEvent::ServerHeartbeatSucceeded(e)) = event {
                assert!(e.reply.get_bool("helloOk").unwrap());
                assert!(e.reply.get(LEGACY_HELLO_COMMAND_NAME_LOWERCASE).is_some());
                assert!(e.reply.get("isWritablePrimary").is_none());
                return true;
            }
            false
        })
        .await
        .expect("first heartbeat reply should contain helloOk: true");

    // subsequent heartbeats should just be hello
    for _ in 0..3 {
        event_stream
            .next_match(Duration::from_millis(2000), |event| {
                if let Event::Sdam(SdamEvent::ServerHeartbeatSucceeded(e)) = event {
                    assert!(e.reply.get("isWritablePrimary").is_some());
                    assert!(e.reply.get(LEGACY_HELLO_COMMAND_NAME_LOWERCASE).is_none());
                    return true;
                }
                false
            })
            .await
            .expect("subsequent heartbeats should use hello");
    }
}

#[tokio::test]
async fn repl_set_name_mismatch() -> crate::error::Result<()> {
    if !topology_is_replica_set().await {
        log_uncaptured("skipping repl_set_name_mismatch due to non-replica set topology");
        return Ok(());
    }

    let mut options = get_client_options().await.clone();
    options.hosts.drain(1..);
    options.direct_connection = Some(true);
    options.repl_set_name = Some("invalid".to_string());
    options.server_selection_timeout = Some(Duration::from_secs(5));
    let client = Client::with_options(options)?;
    let result = client.list_database_names().await;
    assert!(
        match result {
            Err(Error { ref kind, .. }) => matches!(**kind, ErrorKind::ServerSelection { .. }),
            _ => false,
        },
        "Unexpected result {result:?}"
    );

    Ok(())
}

/// Test verifying that a server's monitor stops after the server has been removed from the
/// topology.
#[tokio::test(flavor = "multi_thread")]
async fn removed_server_monitor_stops() -> crate::error::Result<()> {
    let buffer = EventBuffer::new();
    let options = ClientOptions::builder()
        .hosts(vec![
            ServerAddress::parse("localhost:49152")?,
            ServerAddress::parse("localhost:49153")?,
            ServerAddress::parse("localhost:49154")?,
        ])
        .heartbeat_freq(Duration::from_millis(50))
        .sdam_event_handler(buffer.handler())
        .repl_set_name("foo".to_string())
        .build();

    let hosts = options.hosts.clone();
    let set_name = options.repl_set_name.clone().unwrap();

    let mut event_stream = buffer.stream();
    let topology = Topology::new(options)?;

    // Wait until all three monitors have started.
    let mut seen_monitors = HashSet::new();
    event_stream
        .next_match(Duration::from_millis(500), |event| {
            if let Event::Sdam(SdamEvent::ServerHeartbeatStarted(e)) = event {
                seen_monitors.insert(e.server_address.clone());
            }
            seen_monitors.len() == hosts.len()
        })
        .await
        .expect("should see all three monitors start");

    // Remove the third host from the topology.
    let hello = doc! {
        "ok": 1,
        "isWritablePrimary": true,
        "hosts": [
            hosts[0].clone().to_string(),
            hosts[1].clone().to_string(),
        ],
        "me": hosts[0].clone().to_string(),
        "setName": set_name,
        "maxBsonObjectSize": 1234,
        "maxWriteBatchSize": 1234,
        "maxMessageSizeBytes": 1234,
        "minWireVersion": 0,
        "maxWireVersion": 13,
    };
    let hello_reply = RawCommandResponse::with_document_and_address(hosts[0].clone(), hello)
        .unwrap()
        .into_hello_reply()
        .unwrap();

    topology
        .updater()
        .update(ServerDescription::new_from_hello_reply(
            hosts[0].clone(),
            hello_reply,
            Duration::from_millis(10),
        ))
        .await;

    event_stream.next_match(Duration::from_secs(1), |event| {
        matches!(event, Event::Sdam(SdamEvent::ServerClosed(e)) if e.address == hosts[2])
    }).await.expect("should see server closed event");

    // Capture heartbeat events for 1 second. The monitor for the removed server should stop
    // publishing them.
    let events = event_stream.collect(Duration::from_secs(1), |event| {
        matches!(event, Event::Sdam(SdamEvent::ServerHeartbeatStarted(e)) if e.server_address == hosts[2])
    }).await;

    // Use 3 to account for any heartbeats that happen to start between emitting the ServerClosed
    // event and actually publishing the state with the closed server.
    assert!(
        events.len() < 3,
        "expected monitor for removed server to stop performing checks, but saw {} heartbeats",
        events.len()
    );

    Ok(())
}

#[test]
fn ipv6_invalid_me() {
    let addr = ServerAddress::Tcp {
        host: "::1".to_string(),
        port: Some(8191),
    };
    let desc = ServerDescription {
        address: addr.clone(),
        server_type: super::ServerType::RsSecondary,
        last_update_time: None,
        average_round_trip_time: None,
        reply: Ok(Some(crate::hello::HelloReply {
            server_address: addr.clone(),
            command_response: crate::hello::HelloCommandResponse {
                me: Some("[::1]:8191".to_string()),
                ..Default::default()
            },
            raw_command_response: crate::bson::RawDocumentBuf::new(),
            cluster_time: None,
        })),
    };
    assert!(!desc.invalid_me().unwrap());
}

/// Regression test: Client::shutdown() must not deadlock.
///
/// The topology worker's shutdown sequence closes monitors and waits for them to exit.
/// Meanwhile, a monitor in streaming mode may complete a hello and call
/// topology_updater.update(), which waits for acknowledgment from the topology worker.
/// Since the worker has already exited its processing loop, neither side makes progress.
///
/// The fix is to drop the topology worker's update_receiver before closing monitors,
/// so that the monitor's update() call fails immediately.
#[tokio::test(flavor = "multi_thread")]
async fn shutdown_does_not_deadlock() {
    let mut options = get_client_options().await.clone();
    options.heartbeat_freq = Some(Duration::from_millis(500));
    options.test_options_mut().topology_worker_shutdown_delay = Some(Duration::from_millis(600));

    // Add a command event handler to introduce callback overhead on every command
    // (including the monitor's streaming hello). This widens the race window between
    // the monitor's topology_updater.update() and the topology worker's shutdown.
    use crate::event::{command::CommandEvent, EventHandler};
    options.command_event_handler = Some(EventHandler::callback(|_event: CommandEvent| {
        // Simulate cross-language callback overhead.
        std::thread::yield_now();
    }));

    for i in 0..5 {
        let client = Client::with_options(options.clone()).unwrap();

        let _ = client
            .database("admin")
            .run_command(doc! { "ping": 1 })
            .await;
        tokio::time::sleep(Duration::from_millis(20)).await;

        let result = tokio::time::timeout(Duration::from_secs(5), async {
            client.shutdown().immediate(true).await;
        })
        .await;

        assert!(result.is_ok(), "shutdown() deadlocked on iteration {}", i);
    }
}

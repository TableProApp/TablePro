use std::{collections::HashMap, sync::Arc, time::Duration};

use crate::{
    bson::{doc, Document},
    bson_util::round_clamp,
};
use approx::abs_diff_eq;
use serde::Deserialize;

use crate::{
    cmap::DEFAULT_MAX_POOL_SIZE,
    error::Result,
    event::cmap::CmapEvent,
    options::ServerAddress,
    runtime::{self, AsyncJoinHandle},
    sdam::{description::topology::server_selection, Server},
    selection_criteria::{ReadPreference, SelectionCriteria},
    test::{
        auth_enabled,
        get_client_options,
        log_uncaptured,
        run_spec_test,
        topology_is_sharded,
        util::fail_point::{FailPoint, FailPointMode},
        Event,
        EventClient,
    },
    Client,
};

use super::TestTopologyDescription;

#[derive(Debug, Deserialize)]
struct TestFile {
    description: String,
    topology_description: TestTopologyDescription,
    mocked_topology_state: Vec<TestServer>,
    iterations: u32,
    outcome: TestOutcome,
}

#[derive(Debug, Deserialize)]
struct TestOutcome {
    tolerance: f64,
    expected_frequencies: HashMap<ServerAddress, f64>,
}

#[derive(Debug, Deserialize)]
struct TestServer {
    address: ServerAddress,
    operation_count: u32,
}

async fn run_test(test_file: TestFile) {
    println!("Running {}", test_file.description);

    let mut tallies: HashMap<ServerAddress, u32> = HashMap::new();

    let servers: HashMap<ServerAddress, Arc<Server>> = test_file
        .mocked_topology_state
        .into_iter()
        .map(|desc| {
            (
                desc.address.clone(),
                Arc::new(Server::new_mocked(desc.address, desc.operation_count)),
            )
        })
        .collect();

    let topology_description = test_file
        .topology_description
        .into_topology_description(None);

    let read_pref = ReadPreference::Nearest {
        options: Default::default(),
    }
    .into();

    for _ in 0..test_file.iterations {
        let selection = server_selection::attempt_to_select_server(
            &read_pref,
            &topology_description,
            &servers,
            None,
        )
        .expect("selection should not fail")
        .expect("a server should have been selected");
        *tallies.entry(selection.address.clone()).or_insert(0) += 1;
    }

    for (address, expected_frequency) in test_file.outcome.expected_frequencies {
        let actual_frequency =
            tallies.get(&address).cloned().unwrap_or(0) as f64 / (test_file.iterations as f64);

        let epsilon = if expected_frequency != 1.0 && expected_frequency != 0.0 {
            test_file.outcome.tolerance
        } else {
            f64::EPSILON
        };

        assert!(
            abs_diff_eq!(actual_frequency, expected_frequency, epsilon = epsilon),
            "{}: for server {} expected frequency = {}, actual = {}",
            test_file.description,
            address,
            expected_frequency,
            actual_frequency
        );
    }
}

#[tokio::test]
async fn select_in_window() {
    run_spec_test(&["server-selection", "in_window"], run_test).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn load_balancing_test() {
    if !topology_is_sharded().await {
        log_uncaptured("skipping load_balancing_test test due to topology not being sharded");
        return;
    }
    if get_client_options().await.hosts.len() != 2 {
        log_uncaptured("skipping load_balancing_test test due to topology not having 2 mongoses");
        return;
    }
    if auth_enabled().await {
        log_uncaptured("skipping load_balancing_test test due to auth being enabled");
        return;
    }

    let mut setup_client_options = get_client_options().await.clone();

    setup_client_options.hosts.drain(1..);
    setup_client_options.direct_connection = Some(true);
    let setup_client = Client::for_test().options(setup_client_options).await;

    // clear the collection so subsequent test runs don't increase linearly in time
    setup_client
        .database("load_balancing_test")
        .collection::<Document>("load_balancing_test")
        .drop()
        .await
        .unwrap();

    // seed the collection with a document so the find commands do some work
    setup_client
        .database("load_balancing_test")
        .collection("load_balancing_test")
        .insert_one(doc! {})
        .await
        .unwrap();

    /// min_share is the lower bound for the % of times the the less selected server
    /// was selected. max_share is the upper bound.
    async fn do_test(client: &EventClient, min_share: f64, max_share: f64, iterations: usize) {
        {
            let mut events = client.events.clone();
            events.clear_cached_events();
        }

        let mut handles: Vec<AsyncJoinHandle<Result<()>>> = Vec::new();
        for _ in 0..10 {
            let collection = client
                .database("load_balancing_test")
                .collection::<Document>("load_balancing_test");
            handles.push(runtime::spawn(async move {
                for _ in 0..iterations {
                    collection.find_one(doc! {}).await?;
                }
                Ok(())
            }))
        }

        for handle in handles {
            handle.await.unwrap();
        }

        let mut tallies: HashMap<ServerAddress, u32> = HashMap::new();
        for event in client.events.get_command_started_events(&["find"]) {
            *tallies.entry(event.connection.address.clone()).or_insert(0) += 1;
        }

        assert_eq!(tallies.len(), 2);
        let mut counts: Vec<_> = tallies.values().collect();
        counts.sort();

        let share_of_selections = (*counts[0] as f64) / ((*counts[0] + *counts[1]) as f64);
        #[allow(clippy::cast_possible_truncation)]
        {
            assert!(
                share_of_selections <= max_share,
                "expected no more than {}% of selections, instead got {}%",
                round_clamp::<u32>(max_share * 100.0),
                round_clamp::<u32>(share_of_selections * 100.0)
            );
            assert!(
                share_of_selections >= min_share,
                "expected at least {}% of selections, instead got {}%",
                round_clamp::<u32>(min_share * 100.0),
                round_clamp::<u32>(share_of_selections * 100.0)
            );
        }
    }

    let mut options = get_client_options().await.clone();
    let max_pool_size = DEFAULT_MAX_POOL_SIZE;
    options.local_threshold = Duration::from_secs(30).into();
    options.min_pool_size = Some(max_pool_size);
    let client = Client::for_test()
        .options(options)
        .monitor_events()
        .retain_startup_events()
        .await;

    let mut subscriber = client.events.stream_all();

    // wait for both servers pools to be saturated.
    client.warm_connection_pool().await;
    let mut conns = 0;
    while conns < max_pool_size * 2 {
        subscriber
            .next_match(Duration::from_secs(30), |event| {
                matches!(event, Event::Cmap(CmapEvent::ConnectionReady(_)))
            })
            .await
            .expect("timed out waiting for both pools to be saturated");
        conns += 1;
    }

    // enable a failpoint on one of the mongoses to slow it down
    let slow_host = get_client_options().await.hosts[0].clone();
    let slow_host_criteria =
        SelectionCriteria::Predicate(Arc::new(move |si| si.address() == &slow_host));
    let fail_point = FailPoint::fail_command(&["find"], FailPointMode::AlwaysOn)
        .block_connection(Duration::from_millis(500))
        .selection_criteria(slow_host_criteria);
    let guard = setup_client.enable_fail_point(fail_point).await.unwrap();

    // verify that the lesser picked server (slower one) was picked less than 25% of the time.
    const FLUFF: f64 = 0.02; // See RUST-2044.
    do_test(&client, 0.05, 0.25 + FLUFF, 10).await;

    // disable failpoint and rerun, should be back to even split
    drop(guard);
    do_test(&client, 0.40, 0.50, 100).await;
}

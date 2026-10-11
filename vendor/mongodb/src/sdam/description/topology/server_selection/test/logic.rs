use std::{
    collections::HashSet,
    convert::{TryFrom, TryInto},
    time::Duration,
};

use serde::{Deserialize, Serialize};

use crate::{
    error::{Error, Result},
    options::{ReadPreference, ReadPreferenceOptions, TagSet},
    test::run_spec_test,
};

use super::{TestServerDescription, TestTopologyDescription};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TestFile {
    #[serde(rename = "heartbeatFrequencyMS")]
    heartbeat_frequency_ms: Option<u64>,
    topology_description: TestTopologyDescription,
    read_preference: TestReadPreference,
    suitable_servers: Option<Vec<TestServerDescription>>,
    in_latency_window: Option<Vec<TestServerDescription>>,
    #[serde(default)]
    deprioritized_servers: Vec<TestServerDescription>,
    error: Option<bool>,
    #[serde(rename = "operation")]
    // don't need this since we don't have separate server selection functions for reads/writes
    _operation: Option<String>,
}

// Deserialize into a helper struct to avoid deserialization errors for invalid read preferences.
#[derive(Debug, Deserialize, Serialize)]
struct TestReadPreference {
    mode: Option<String>,
    tag_sets: Option<Vec<TagSet>>,
    #[serde(rename = "maxStalenessSeconds")]
    max_staleness_seconds: Option<u64>,
}

impl TryFrom<TestReadPreference> for ReadPreference {
    type Error = Error;

    fn try_from(test_read_pref: TestReadPreference) -> Result<Self> {
        let max_staleness = test_read_pref
            .max_staleness_seconds
            .map(Duration::from_secs);
        let options = ReadPreferenceOptions::builder()
            .tag_sets(test_read_pref.tag_sets)
            .max_staleness(max_staleness)
            .build();

        let rp = match &test_read_pref.mode.as_deref() {
            Some("Primary") | None => {
                if !options.is_default() {
                    return Err(Error::invalid_argument(
                        "cannot use non-default options with read preference mode primary",
                    ));
                }
                ReadPreference::Primary
            }
            Some("Secondary") => ReadPreference::Secondary {
                options: Some(options),
            },
            Some("PrimaryPreferred") => ReadPreference::PrimaryPreferred {
                options: Some(options),
            },
            Some("SecondaryPreferred") => ReadPreference::SecondaryPreferred {
                options: Some(options),
            },
            Some("Nearest") => ReadPreference::Nearest {
                options: Some(options),
            },
            Some(m) => {
                return Err(Error::invalid_argument(
                    format!("invalid read preference mode: {m}").as_str(),
                ))
            }
        };

        Ok(rp)
    }
}

macro_rules! get_sorted_addresses {
    ($servers:expr) => {{
        let mut servers: Vec<_> = $servers.iter().map(|s| s.address.to_string()).collect();
        servers.sort_unstable();
        servers
    }};
}

async fn run_test(test_file: TestFile) {
    if let Some(ref expected_suitable_servers) = test_file.suitable_servers {
        let topology = test_file
            .topology_description
            .into_topology_description(test_file.heartbeat_frequency_ms.map(Duration::from_millis));

        let read_preference = ReadPreference::try_from(test_file.read_preference).unwrap();
        let deprioritized = test_file
            .deprioritized_servers
            .iter()
            .map(|d| d.address.clone())
            .collect::<HashSet<_>>();
        let mut suitable_servers = topology
            .filter_servers_by_selection_criteria(&read_preference.into(), Some(&deprioritized));

        assert_eq!(
            get_sorted_addresses!(&suitable_servers),
            get_sorted_addresses!(expected_suitable_servers),
        );

        if let Some(ref expected_in_latency_window) = test_file.in_latency_window {
            topology.retain_servers_within_latency_window(&mut suitable_servers);

            assert_eq!(
                get_sorted_addresses!(expected_in_latency_window),
                get_sorted_addresses!(&suitable_servers)
            );
        }
    } else if test_file.error == Some(true) {
        use crate::{
            client::options::ClientOptions,
            selection_criteria::SelectionCriteria,
            Client,
        };

        let mut uri_options = Vec::new();
        if let Some(ref mode) = test_file.read_preference.mode {
            uri_options.push(format!("readPreference={mode}"));
        }
        if let Some(max_staleness_seconds) = test_file.read_preference.max_staleness_seconds {
            uri_options.push(format!("maxStalenessSeconds={max_staleness_seconds}"));
        }
        if let Some(heartbeat_freq) = test_file.heartbeat_frequency_ms {
            uri_options.push(format!("heartbeatFrequencyMS={heartbeat_freq}"));
        }

        let uri_str = format!("mongodb://localhost:27017/?{}", uri_options.join("&"));
        ClientOptions::parse(&uri_str)
            .await
            .err()
            .unwrap_or_else(|| {
                panic!(
                    "expected client construction to fail with read preference {:#?}",
                    test_file.read_preference
                )
            });

        // if the options contain a read preference that is supported by the type system, ensure
        // that it still can't be used to construct a client.
        if let Ok(rp) = test_file.read_preference.try_into() {
            let mut opts = ClientOptions::builder()
                .selection_criteria(SelectionCriteria::ReadPreference(rp))
                .build();
            if let Some(heartbeat_freq) = test_file.heartbeat_frequency_ms {
                opts.heartbeat_freq = Some(Duration::from_secs(heartbeat_freq));
            }
            Client::with_options(opts.clone()).err().unwrap_or_else(|| {
                panic!("expected client construction to fail with options: {opts:#?}")
            });
        }
    }
}

#[tokio::test]
async fn server_selection_replica_set_no_primary() {
    run_spec_test(
        &[
            "server-selection",
            "server_selection",
            "ReplicaSetNoPrimary",
            "read",
        ],
        run_test,
    )
    .await;
}

#[tokio::test]
async fn server_selection_replica_set_with_primary() {
    run_spec_test(
        &[
            "server-selection",
            "server_selection",
            "ReplicaSetWithPrimary",
            "read",
        ],
        run_test,
    )
    .await;
}

#[tokio::test]
async fn server_selection_sharded() {
    run_spec_test(
        &["server-selection", "server_selection", "Sharded", "read"],
        run_test,
    )
    .await;
}

#[tokio::test]
async fn server_selection_single() {
    run_spec_test(
        &["server-selection", "server_selection", "Single", "read"],
        run_test,
    )
    .await;
}

#[tokio::test]
async fn server_selection_unknown() {
    run_spec_test(
        &["server-selection", "server_selection", "Unknown", "read"],
        run_test,
    )
    .await;
}

#[tokio::test]
async fn server_selection_load_balanced() {
    run_spec_test(
        &[
            "server-selection",
            "server_selection",
            "LoadBalanced",
            "read",
        ],
        run_test,
    )
    .await;
}

#[tokio::test]
async fn max_staleness_replica_set_no_primary() {
    run_spec_test(&["max-staleness", "ReplicaSetNoPrimary"], run_test).await;
}

#[tokio::test]
async fn max_staleness_replica_set_with_primary() {
    run_spec_test(&["max-staleness", "ReplicaSetWithPrimary"], run_test).await;
}

#[tokio::test]
async fn max_staleness_sharded() {
    run_spec_test(&["max-staleness", "Sharded"], run_test).await;
}

#[tokio::test]
async fn max_staleness_single() {
    run_spec_test(&["max-staleness", "Single"], run_test).await;
}

#[tokio::test]
async fn max_staleness_unknown() {
    run_spec_test(&["max-staleness", "Unknown"], run_test).await;
}

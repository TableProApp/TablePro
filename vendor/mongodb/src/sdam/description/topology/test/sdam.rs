use std::{collections::HashMap, sync::Arc, time::Duration};

use serde::Deserialize;

use super::TestSdamEvent;

use crate::{
    bson::{doc, oid::ObjectId, Document},
    client::Client,
    cmap::{conn::ConnectionGeneration, PoolGeneration},
    error::{CommandError, Error, ErrorKind, InsertManyError},
    event::sdam::SdamEvent,
    hello::{HelloCommandResponse, HelloReply, LastWrite, LEGACY_HELLO_COMMAND_NAME},
    options::{ClientOptions, ReadPreference, SelectionCriteria, ServerAddress},
    sdam::{
        description::{
            server::{ServerDescription, ServerType},
            topology::TopologyType,
        },
        HandshakePhase,
        Topology,
        TopologyDescription,
        TopologyVersion,
    },
    selection_criteria::TagSet,
    test::{
        fail_command_appname_initial_handshake_supported,
        get_client_options,
        log_uncaptured,
        run_spec_test,
        topology_is_load_balanced,
        topology_is_replica_set,
        util::{
            event_buffer::EventBuffer,
            fail_point::{FailPoint, FailPointMode},
        },
        Event,
    },
};

#[derive(Debug, Deserialize)]
pub struct TestFile {
    description: String,
    uri: String,
    phases: Vec<Phase>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Phase {
    description: Option<String>,
    #[serde(default)]
    responses: Vec<Response>,
    #[serde(default)]
    application_errors: Vec<ApplicationError>,
    outcome: Outcome,
}

#[derive(Debug, Deserialize)]
pub struct Response(String, TestHelloCommandResponse);

#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TestHelloCommandResponse {
    pub is_writable_primary: Option<bool>,
    #[serde(rename = "ismaster")]
    pub is_master: Option<bool>,
    pub hello_ok: Option<bool>,
    pub ok: Option<f32>,
    pub hosts: Option<Vec<String>>,
    pub passives: Option<Vec<String>>,
    pub arbiters: Option<Vec<String>>,
    pub msg: Option<String>,
    pub me: Option<String>,
    pub set_version: Option<i32>,
    pub set_name: Option<String>,
    pub hidden: Option<bool>,
    pub secondary: Option<bool>,
    pub arbiter_only: Option<bool>,
    #[serde(rename = "isreplicaset")]
    pub is_replica_set: Option<bool>,
    #[serde(default, with = "crate::bson_util::option_u64_as_i64")]
    pub logical_session_timeout_minutes: Option<u64>,
    pub last_write: Option<LastWrite>,
    pub min_wire_version: Option<i32>,
    pub max_wire_version: Option<i32>,
    pub tags: Option<TagSet>,
    pub election_id: Option<ObjectId>,
    pub primary: Option<String>,
    pub sasl_supported_mechs: Option<Vec<String>>,
    pub speculative_authenticate: Option<Document>,
    pub max_bson_object_size: Option<i64>,
    pub max_write_batch_size: Option<i64>,
    pub service_id: Option<ObjectId>,
    pub topology_version: Option<TopologyVersion>,
}

impl From<TestHelloCommandResponse> for HelloCommandResponse {
    fn from(test: TestHelloCommandResponse) -> Self {
        HelloCommandResponse {
            is_writable_primary: test.is_writable_primary,
            is_master: test.is_master,
            hosts: test.hosts,
            passives: test.passives,
            arbiters: test.arbiters,
            msg: test.msg,
            me: test.me,
            set_version: test.set_version,
            set_name: test.set_name,
            hidden: test.hidden,
            secondary: test.secondary,
            arbiter_only: test.arbiter_only,
            is_replica_set: test.is_replica_set,
            logical_session_timeout_minutes: test.logical_session_timeout_minutes,
            last_write: test.last_write,
            min_wire_version: test.min_wire_version,
            max_wire_version: test.max_wire_version,
            tags: test.tags,
            election_id: test.election_id,
            primary: test.primary,
            sasl_supported_mechs: test.sasl_supported_mechs,
            speculative_authenticate: test.speculative_authenticate,
            max_bson_object_size: test.max_bson_object_size.unwrap_or(1234),
            max_write_batch_size: Some(test.max_write_batch_size.unwrap_or(1234)),
            service_id: test.service_id,
            topology_version: test.topology_version,
            compressors: None,
            hello_ok: test.hello_ok,
            max_message_size_bytes: 48 * 1024 * 1024,
            connection_id: None,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplicationError {
    address: ServerAddress,
    generation: Option<u32>,
    max_wire_version: i32,
    when: ErrorHandshakePhase,
    #[serde(rename = "type")]
    error_type: ErrorType,
    response: Option<ServerError>,
}

impl ApplicationError {
    fn to_error(&self) -> Error {
        match self.error_type {
            ErrorType::Command => self.response.clone().unwrap().into(),
            ErrorType::Network => {
                ErrorKind::Io(Arc::new(std::io::ErrorKind::UnexpectedEof.into())).into()
            }
            ErrorType::Timeout => {
                ErrorKind::Io(Arc::new(std::io::ErrorKind::TimedOut.into())).into()
            }
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ErrorHandshakePhase {
    BeforeHandshakeCompletes,
    AfterHandshakeCompletes,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ErrorType {
    Command,
    Network,
    Timeout,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(untagged)]
pub enum ServerError {
    CommandError(CommandError),
    WriteError(InsertManyError),
}

impl From<ServerError> for Error {
    fn from(server_error: ServerError) -> Self {
        match server_error {
            ServerError::CommandError(command_error) => ErrorKind::Command(command_error).into(),
            ServerError::WriteError(bwf) => ErrorKind::InsertMany(bwf).into(),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum Outcome {
    Description(DescriptionOutcome),
    Events(EventsOutcome),
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DescriptionOutcome {
    topology_type: TopologyType,
    set_name: Option<String>,
    servers: HashMap<String, Server>,
    #[serde(default, with = "crate::bson_util::option_u64_as_i64")]
    logical_session_timeout_minutes: Option<u64>,
    compatible: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct EventsOutcome {
    events: Vec<TestSdamEvent>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Server {
    #[serde(rename = "type")]
    server_type: String,
    set_name: Option<String>,
    set_version: Option<i32>,
    election_id: Option<ObjectId>,
    #[serde(default, with = "crate::bson_util::option_u64_as_i64")]
    logical_session_timeout_minutes: Option<u64>,
    min_wire_version: Option<i32>,
    max_wire_version: Option<i32>,
    topology_version: Option<TopologyVersion>,
    pool: Option<Pool>,
}

#[derive(Debug, Deserialize)]
pub struct Pool {
    generation: u32,
}

fn server_type_from_str(s: &str) -> Option<ServerType> {
    let t = match s {
        "Standalone" => ServerType::Standalone,
        "Mongos" => ServerType::Mongos,
        "RSPrimary" => ServerType::RsPrimary,
        "RSSecondary" => ServerType::RsSecondary,
        "RSArbiter" => ServerType::RsArbiter,
        "RSOther" => ServerType::RsOther,
        "RSGhost" => ServerType::RsGhost,
        "LoadBalancer" => ServerType::LoadBalancer,
        "Unknown" | "PossiblePrimary" => ServerType::Unknown,
        _ => return None,
    };

    Some(t)
}

async fn run_test(test_file: TestFile) {
    let test_description = &test_file.description;

    // TODO: RUST-1081 unskip tests
    let skip_keywords = doc! {
        "election Id": "(RUST-1081)",
        "electionId": "(RUST-1081)",
        "ElectionId": "(RUST-1081)"
    };

    for (keyword, skip_reason) in skip_keywords {
        if test_description.contains(keyword.as_str()) {
            log_uncaptured(format!(
                "Skipping {}: {}",
                test_description,
                skip_reason.as_str().unwrap()
            ));
            return;
        }
    }

    log_uncaptured(format!("Executing {test_description}"));

    let mut options = ClientOptions::parse(&test_file.uri)
        .await
        .expect(test_description);

    let buffer = EventBuffer::new();
    options.sdam_event_handler = Some(buffer.handler());
    options.test_options_mut().disable_monitoring_threads = true;

    let mut event_stream = buffer.stream();
    let topology = Topology::new(options).unwrap();

    for (i, phase) in test_file.phases.into_iter().enumerate() {
        for Response(address, command_response) in phase.responses {
            let address = ServerAddress::parse(&address).unwrap_or_else(|_| {
                panic!(
                    "{}: couldn't parse address \"{:?}\"",
                    test_description.as_str(),
                    address
                )
            });

            let hello_reply = if command_response.ok != Some(1.0) {
                Err(Error::from(ErrorKind::Command(CommandError {
                    code: 1234,
                    code_name: "dummy error".to_string(),
                    message: "dummy".to_string(),
                    topology_version: None,
                    base_backoff: None,
                })))
            } else if command_response == Default::default() {
                Err(Error::from(ErrorKind::Io(Arc::new(
                    std::io::ErrorKind::BrokenPipe.into(),
                ))))
            } else {
                Ok(HelloReply {
                    server_address: address.clone(),
                    command_response: command_response.into(),
                    cluster_time: None,
                    raw_command_response: Default::default(), // doesn't matter for tests
                })
            };

            match hello_reply {
                Ok(reply) => {
                    let new_sd = ServerDescription::new_from_hello_reply(
                        address.clone(),
                        reply,
                        Duration::from_secs(1),
                    );
                    topology.updater().update(new_sd).await;
                }
                Err(e) => {
                    topology.updater().handle_monitor_error(address, e).await;
                }
            }
        }

        for application_error in phase.application_errors {
            if let Some(server) = topology.watcher().servers().get(&application_error.address) {
                let mut error = application_error.to_error();
                let pool_generation = application_error
                    .generation
                    .map(PoolGeneration::Normal)
                    .unwrap_or_else(|| server.pool.generation());
                let conn_generation = application_error
                    .generation
                    .or_else(|| server.pool.generation().as_normal())
                    .unwrap_or(0);
                let conn_generation = ConnectionGeneration::Normal(conn_generation);
                let handshake_phase = match application_error.when {
                    ErrorHandshakePhase::BeforeHandshakeCompletes => {
                        error = error.with_backpressure_labels();
                        HandshakePhase::PreHello {
                            generation: pool_generation,
                        }
                    }
                    ErrorHandshakePhase::AfterHandshakeCompletes => {
                        HandshakePhase::AfterCompletion {
                            generation: conn_generation,
                            max_wire_version: application_error.max_wire_version,
                        }
                    }
                };

                topology
                    .updater()
                    .handle_application_error(server.address.clone(), error, handshake_phase)
                    .await;
            }
        }

        topology.watcher().clone().wait_until_initialized().await;
        let topology_description = topology.watcher().description();
        let servers = topology.watcher().servers();
        let phase_description = phase.description.unwrap_or_else(|| format!("{i}"));

        match phase.outcome {
            Outcome::Description(outcome) => {
                verify_description_outcome(
                    outcome,
                    topology_description,
                    servers,
                    test_description,
                    phase_description,
                );
            }
            Outcome::Events(EventsOutcome { events: expected }) => {
                let actual = event_stream
                    .collect(Duration::from_millis(500), |e| matches!(e, Event::Sdam(_)))
                    .await
                    .into_iter()
                    .map(|e| e.unwrap_sdam_event());

                assert_eq!(
                    actual.len(),
                    expected.len(),
                    "{test_description}: {phase_description}: event list length mismatch:\n \
                     actual: {actual:#?}, expected: {expected:#?}"
                );
                for (actual, expected) in actual.zip(expected) {
                    assert_eq!(
                        actual, expected,
                        "{test_description}: {phase_description}: SDAM events do not match:\n \
                         actual: {actual:#?}, expected: {expected:#?}"
                    );
                }
            }
        }
    }
}

fn verify_description_outcome(
    outcome: DescriptionOutcome,
    topology_description: TopologyDescription,
    servers: HashMap<ServerAddress, Arc<crate::sdam::Server>>,
    test_description: &str,
    phase_description: String,
) {
    assert_eq!(
        topology_description.topology_type, outcome.topology_type,
        "{test_description}: {phase_description}"
    );

    assert_eq!(
        topology_description.set_name, outcome.set_name,
        "{test_description}: {phase_description}",
    );

    let expected_timeout = outcome
        .logical_session_timeout_minutes
        .map(|mins| Duration::from_secs(mins * 60));
    assert_eq!(
        topology_description.logical_session_timeout, expected_timeout,
        "{test_description}: {phase_description}"
    );

    if let Some(compatible) = outcome.compatible {
        assert_eq!(
            topology_description.compatibility_error.is_none(),
            compatible,
            "{test_description}: {phase_description}",
        );
    }

    assert_eq!(
        topology_description.servers.len(),
        outcome.servers.len(),
        "{test_description}: {phase_description}"
    );

    for (address, server) in outcome.servers {
        let address = ServerAddress::parse(&address).unwrap_or_else(|_| {
            panic!("{test_description}: couldn't parse address \"{address:?}\"")
        });
        let actual_server = &topology_description
            .servers
            .get(&address)
            .unwrap_or_else(|| panic!("{test_description} (phase {phase_description})"));

        let server_type = server_type_from_str(&server.server_type)
            .unwrap_or_else(|| panic!("{test_description} (phase {phase_description})"));

        assert_eq!(
            actual_server.server_type, server_type,
            "{test_description} (phase {phase_description}, address: {address})",
        );

        assert_eq!(
            actual_server.set_name().unwrap_or(None),
            server.set_name,
            "{test_description} (phase {phase_description})"
        );

        assert_eq!(
            actual_server.set_version().unwrap_or(None),
            server.set_version,
            "{test_description} (phase {phase_description})"
        );

        assert_eq!(
            actual_server.election_id().unwrap_or(None),
            server.election_id,
            "{test_description} (phase {phase_description})"
        );

        if let Some(logical_session_timeout_minutes) = server.logical_session_timeout_minutes {
            assert_eq!(
                actual_server.logical_session_timeout().unwrap(),
                Some(Duration::from_secs(logical_session_timeout_minutes * 60)),
                "{test_description} (phase {phase_description})"
            );
        }

        if let Some(min_wire_version) = server.min_wire_version {
            assert_eq!(
                actual_server.min_wire_version().unwrap(),
                Some(min_wire_version),
                "{test_description} (phase {phase_description})"
            );
        }

        if let Some(max_wire_version) = server.max_wire_version {
            assert_eq!(
                actual_server.max_wire_version().unwrap(),
                Some(max_wire_version),
                "{test_description} (phase {phase_description})"
            );
        }

        if let Some(topology_version) = server.topology_version {
            assert_eq!(
                actual_server.topology_version(),
                Some(topology_version),
                "{test_description} (phase {phase_description})"
            )
        }

        if let Some(generation) = server.pool.map(|p| p.generation) {
            assert_eq!(
                servers
                    .get(&address)
                    .unwrap()
                    .pool
                    .generation()
                    .as_normal()
                    .unwrap(),
                generation,
                "{test_description} (phase {phase_description})"
            );
        }
    }
}

#[tokio::test]
async fn single() {
    run_spec_test(&["server-discovery-and-monitoring", "single"], run_test).await;
}

#[tokio::test]
async fn rs() {
    run_spec_test(&["server-discovery-and-monitoring", "rs"], run_test).await;
}

#[tokio::test]
async fn sharded() {
    run_spec_test(&["server-discovery-and-monitoring", "sharded"], run_test).await;
}

#[tokio::test]
async fn errors() {
    run_spec_test(&["server-discovery-and-monitoring", "errors"], run_test).await;
}

#[tokio::test]
async fn monitoring() {
    run_spec_test(&["server-discovery-and-monitoring", "monitoring"], run_test).await;
}

#[tokio::test]
async fn load_balanced() {
    run_spec_test(
        &["server-discovery-and-monitoring", "load-balanced"],
        run_test,
    )
    .await;
}

#[tokio::test]
#[function_name::named]
async fn topology_closed_event_last() {
    let client = Client::for_test()
        .use_single_mongos()
        .min_heartbeat_freq(Duration::from_millis(50))
        .monitor_events()
        .await;
    let events = client.events.clone();

    let mut subscriber = events.stream_all();

    client
        .database(function_name!())
        .collection(function_name!())
        .insert_one(doc! { "x": 1 })
        .await
        .unwrap();
    drop(client);

    subscriber
        .next_match(Duration::from_millis(1000), |event| {
            matches!(event, Event::Sdam(SdamEvent::TopologyClosed(_)))
        })
        .await
        .expect("should see topology closed event");

    // no further SDAM events should be emitted after the TopologyClosedEvent
    let event = subscriber
        .next_match(Duration::from_millis(1000), |event| {
            matches!(event, Event::Sdam(_))
        })
        .await;
    assert!(
        event.is_none(),
        "expected no more SDAM events, got {event:#?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "SERVER-128517"]
async fn heartbeat_events() {
    if topology_is_load_balanced().await {
        log_uncaptured("skipping heartbeat_events tests due to load-balanced topology");
        return;
    }

    let mut options = get_client_options().await.clone();
    options.hosts.drain(1..);
    options.heartbeat_freq = Some(Duration::from_millis(50));
    options.app_name = "heartbeat_events".to_string().into();

    let client = Client::for_test()
        .options(options.clone())
        .use_single_mongos()
        .min_heartbeat_freq(Duration::from_millis(50))
        .monitor_events()
        .await;

    let mut subscriber = client.events.stream_all();

    subscriber
        .next_match(Duration::from_millis(500), |event| {
            matches!(event, Event::Sdam(SdamEvent::ServerHeartbeatStarted(_)))
        })
        .await
        .expect("should see server heartbeat started event");

    subscriber
        .next_match(Duration::from_millis(500), |event| {
            matches!(event, Event::Sdam(SdamEvent::ServerHeartbeatSucceeded(_)))
        })
        .await
        .expect("should see server heartbeat succeeded event");

    if !fail_command_appname_initial_handshake_supported().await {
        return;
    }

    options.app_name = None;
    options.heartbeat_freq = None;
    let fp_client = Client::for_test().options(options).await;

    let fail_point = FailPoint::fail_command(
        &[LEGACY_HELLO_COMMAND_NAME, "hello"],
        FailPointMode::AlwaysOn,
    )
    .app_name("heartbeat_events")
    .error_code(1234);
    let _guard = fp_client.enable_fail_point(fail_point).await.unwrap();

    subscriber
        .next_match(Duration::from_millis(500), |event| {
            matches!(event, Event::Sdam(SdamEvent::ServerHeartbeatFailed(_)))
        })
        .await
        .expect("should see server heartbeat failed event");
}

#[tokio::test]
#[function_name::named]
async fn direct_connection() {
    if !topology_is_replica_set().await {
        log_uncaptured("Skipping direct_connection test due to non-replica set topology");
        return;
    }

    let test_client = Client::for_test().await;

    let criteria = SelectionCriteria::ReadPreference(ReadPreference::Secondary {
        options: Default::default(),
    });
    let secondary_address = test_client
        .test_select_server(Some(&criteria))
        .await
        .expect("failed to select secondary");

    let mut secondary_options = get_client_options().await.clone();
    secondary_options.hosts = vec![secondary_address];

    let mut direct_false_options = secondary_options.clone();
    direct_false_options.direct_connection = Some(false);
    let direct_false_client =
        Client::with_options(direct_false_options).expect("client construction should succeed");
    direct_false_client
        .database(function_name!())
        .collection(function_name!())
        .insert_one(doc! {})
        .await
        .expect("write should succeed with directConnection=false on secondary");

    let mut direct_true_options = secondary_options.clone();
    direct_true_options.direct_connection = Some(true);
    let direct_true_client =
        Client::with_options(direct_true_options).expect("client construction should succeed");
    let error = direct_true_client
        .database(function_name!())
        .collection(function_name!())
        .insert_one(doc! {})
        .await
        .expect_err("write should fail with directConnection=true on secondary");
    assert!(error.is_notwritableprimary());

    let client =
        Client::with_options(secondary_options).expect("client construction should succeed");
    client
        .database(function_name!())
        .collection(function_name!())
        .insert_one(doc! {})
        .await
        .expect("write should succeed with directConnection unspecified");
}

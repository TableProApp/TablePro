use std::{collections::HashMap, sync::Arc, time::Duration};

use serde::Deserialize;

use crate::{
    bson::{doc, DateTime},
    hello::{HelloCommandResponse, HelloReply, LastWrite},
    options::ServerAddress,
    sdam::{
        description::topology::{test::f64_ms_as_duration, TopologyType},
        ServerDescription,
        ServerType,
        TopologyDescription,
    },
    selection_criteria::{SelectionCriteria, TagSet},
};

mod in_window;
mod logic;

#[derive(Debug, Deserialize)]
struct TestTopologyDescription {
    #[serde(rename = "type")]
    topology_type: TopologyType,
    servers: Vec<TestServerDescription>,
}

impl TestTopologyDescription {
    fn into_topology_description(
        self,
        heartbeat_frequency: Option<Duration>,
    ) -> TopologyDescription {
        let servers: HashMap<ServerAddress, ServerDescription> = self
            .servers
            .into_iter()
            .filter_map(|sd| {
                sd.into_server_description()
                    .map(|sd| (sd.address.clone(), sd))
            })
            .collect();

        TopologyDescription {
            single_seed: servers.len() == 1,
            topology_type: self.topology_type,
            set_name: None,
            max_set_version: None,
            max_election_id: None,
            compatibility_error: None,
            logical_session_timeout: None,
            transaction_support_status: Default::default(),
            cluster_time: None,
            local_threshold: None,
            heartbeat_freq: heartbeat_frequency,
            servers,
            srv_max_hosts: None,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TestServerDescription {
    address: ServerAddress,
    #[serde(rename = "avg_rtt_ms")]
    avg_rtt_ms: Option<f64>,
    #[serde(rename = "type")]
    server_type: TestServerType,
    tags: Option<TagSet>,
    last_update_time: Option<i32>,
    last_write: Option<LastWriteDate>,
    // We don't need to use this field, but it needs to be included during deserialization so that
    // we can use the deny_unknown_fields tag.
    _max_wire_version: Option<i32>,
}

impl TestServerDescription {
    fn into_server_description(self) -> Option<ServerDescription> {
        let server_type = self.server_type.into_server_type()?;

        let tags = self.tags;
        let last_write = self.last_write;
        let avg_rtt_ms = self.avg_rtt_ms;
        let reply = hello_response_from_server_type(server_type).map(|mut command_response| {
            command_response.tags = tags;
            command_response.last_write = last_write.map(|last_write| LastWrite {
                last_write_date: DateTime::from_millis(last_write.last_write_date),
            });
            HelloReply {
                server_address: self.address.clone(),
                command_response,
                cluster_time: None,
                raw_command_response: Default::default(),
            }
        });

        let mut server_desc = match reply {
            Some(reply) => ServerDescription::new_from_hello_reply(
                self.address,
                reply,
                avg_rtt_ms.map(f64_ms_as_duration).unwrap(),
            ),
            None => ServerDescription::new(&self.address),
        };
        server_desc.last_update_time = self
            .last_update_time
            .map(|i| DateTime::from_millis(i.into()));

        Some(server_desc)
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LastWriteDate {
    last_write_date: i64,
}

#[derive(Clone, Copy, Debug, Deserialize)]
enum TestServerType {
    Standalone,
    Mongos,
    #[serde(rename = "RSPrimary")]
    RsPrimary,
    #[serde(rename = "RSSecondary")]
    RsSecondary,
    #[serde(rename = "RSArbiter")]
    RsArbiter,
    #[serde(rename = "RSOther")]
    RsOther,
    #[serde(rename = "RSGhost")]
    RsGhost,
    LoadBalancer,
    Unknown,
    PossiblePrimary,
}

impl TestServerType {
    fn into_server_type(self) -> Option<ServerType> {
        match self {
            TestServerType::Standalone => Some(ServerType::Standalone),
            TestServerType::Mongos => Some(ServerType::Mongos),
            TestServerType::RsPrimary => Some(ServerType::RsPrimary),
            TestServerType::RsSecondary => Some(ServerType::RsSecondary),
            TestServerType::RsArbiter => Some(ServerType::RsArbiter),
            TestServerType::RsOther => Some(ServerType::RsOther),
            TestServerType::RsGhost => Some(ServerType::RsGhost),
            TestServerType::LoadBalancer => Some(ServerType::LoadBalancer),
            TestServerType::Unknown => Some(ServerType::Unknown),
            TestServerType::PossiblePrimary => None,
        }
    }
}

fn hello_response_from_server_type(server_type: ServerType) -> Option<HelloCommandResponse> {
    let mut response = HelloCommandResponse::default();

    match server_type {
        ServerType::Unknown => {
            return None;
        }
        ServerType::Mongos => {
            response.msg = Some("isdbgrid".into());
        }
        ServerType::RsPrimary => {
            response.set_name = Some("foo".into());
            response.is_writable_primary = Some(true);
        }
        ServerType::RsOther => {
            response.set_name = Some("foo".into());
            response.hidden = Some(true);
        }
        ServerType::RsSecondary => {
            response.set_name = Some("foo".into());
            response.secondary = Some(true);
        }
        ServerType::RsArbiter => {
            response.set_name = Some("foo".into());
            response.arbiter_only = Some(true);
        }
        ServerType::RsGhost => {
            response.is_replica_set = Some(true);
        }
        ServerType::Standalone | ServerType::LoadBalancer => {}
    };

    Some(response)
}

#[test]
fn predicate_omits_unavailable() {
    let criteria = SelectionCriteria::Predicate(Arc::new(|si| {
        !matches!(si.server_type(), ServerType::RsPrimary)
    }));

    let desc = TestTopologyDescription {
        topology_type: TopologyType::ReplicaSetWithPrimary,
        servers: vec![
            TestServerDescription {
                address: ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27017),
                },
                avg_rtt_ms: Some(12.0),
                server_type: TestServerType::RsPrimary,
                tags: None,
                last_update_time: None,
                last_write: None,
                _max_wire_version: None,
            },
            TestServerDescription {
                address: ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27018),
                },
                avg_rtt_ms: Some(12.0),
                server_type: TestServerType::Unknown,
                tags: None,
                last_update_time: None,
                last_write: None,
                _max_wire_version: None,
            },
            TestServerDescription {
                address: ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27019),
                },
                avg_rtt_ms: Some(12.0),
                server_type: TestServerType::RsArbiter,
                tags: None,
                last_update_time: None,
                last_write: None,
                _max_wire_version: None,
            },
            TestServerDescription {
                address: ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27020),
                },
                avg_rtt_ms: Some(12.0),
                server_type: TestServerType::RsGhost,
                tags: None,
                last_update_time: None,
                last_write: None,
                _max_wire_version: None,
            },
            TestServerDescription {
                address: ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27021),
                },
                avg_rtt_ms: Some(12.0),
                server_type: TestServerType::RsOther,
                tags: None,
                last_update_time: None,
                last_write: None,
                _max_wire_version: None,
            },
        ],
    }
    .into_topology_description(None);
    assert!(desc
        .filter_servers_by_selection_criteria(&criteria, None)
        .is_empty());
}

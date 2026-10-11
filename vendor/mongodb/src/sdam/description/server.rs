use std::time::Duration;

use crate::bson::{bson, rawdoc, Bson, RawBson};
use serde::{Deserialize, Serialize};

use crate::{
    bson::{oid::ObjectId, DateTime},
    client::ClusterTime,
    error::{Error, ErrorKind, Result},
    hello::{HelloCommandResponse, HelloReply},
    options::ServerAddress,
    selection_criteria::TagSet,
    serde_util,
};

const DRIVER_MIN_DB_VERSION: &str = "4.4";
const DRIVER_MIN_WIRE_VERSION: i32 = 9;
const DRIVER_MAX_WIRE_VERSION: i32 = 29;

/// Enum representing the possible types of servers that the driver can connect to.
#[derive(Debug, Deserialize, Clone, Copy, Eq, PartialEq, Serialize, Default)]
#[non_exhaustive]
pub enum ServerType {
    /// A single, non-replica set mongod.
    Standalone,

    /// A router used in sharded deployments.
    Mongos,

    /// The primary node in a replica set.
    #[serde(rename = "RSPrimary")]
    RsPrimary,

    /// A secondary node in a replica set.
    #[serde(rename = "RSSecondary")]
    RsSecondary,

    /// A non-data bearing node in a replica set which can participate in elections.
    #[serde(rename = "RSArbiter")]
    RsArbiter,

    /// Hidden, starting up, or recovering nodes in a replica set.
    #[serde(rename = "RSOther")]
    RsOther,

    /// A member of an uninitialized replica set or a member that has been removed from the replica
    /// set config.
    #[serde(rename = "RSGhost")]
    RsGhost,

    /// A load-balancing proxy between the driver and the MongoDB deployment.
    LoadBalancer,

    /// A server that the driver hasn't yet communicated with or can't connect to.
    #[serde(alias = "PossiblePrimary")]
    #[default]
    Unknown,
}

impl std::fmt::Display for ServerType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ServerType::Standalone => write!(f, "Standalone"),
            ServerType::Mongos => write!(f, "Mongos"),
            ServerType::RsPrimary => write!(f, "RSPrimary"),
            ServerType::RsSecondary => write!(f, "RSSecondary"),
            ServerType::RsArbiter => write!(f, "RSArbiter"),
            ServerType::RsOther => write!(f, "RSOther"),
            ServerType::RsGhost => write!(f, "RSGhost"),
            ServerType::LoadBalancer => write!(f, "LoadBalancer"),
            ServerType::Unknown => write!(f, "Unknown"),
        }
    }
}

impl ServerType {
    pub(crate) fn can_auth(self) -> bool {
        !matches!(self, ServerType::RsArbiter)
    }

    pub(crate) fn is_data_bearing(self) -> bool {
        matches!(
            self,
            ServerType::Standalone
                | ServerType::RsPrimary
                | ServerType::RsSecondary
                | ServerType::Mongos
                | ServerType::LoadBalancer
        )
    }

    pub(crate) fn is_available(self) -> bool {
        !matches!(self, ServerType::Unknown)
    }
}

/// Struct modeling the `topologyVersion` field included in the server's hello and legacy hello
/// responses.
#[derive(Debug, Copy, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TopologyVersion {
    pub(crate) process_id: ObjectId,
    pub(crate) counter: i64,
}

impl TopologyVersion {
    pub(crate) fn is_more_recent_than(&self, existing_tv: TopologyVersion) -> bool {
        self.process_id != existing_tv.process_id || self.counter > existing_tv.counter
    }
}

impl From<TopologyVersion> for Bson {
    fn from(tv: TopologyVersion) -> Self {
        bson!({
            "processId": tv.process_id,
            "counter": tv.counter
        })
    }
}

impl From<TopologyVersion> for RawBson {
    fn from(tv: TopologyVersion) -> Self {
        RawBson::Document(rawdoc! {
            "processId": tv.process_id,
            "counter": tv.counter
        })
    }
}

#[cfg(feature = "bson-3")]
impl crate::bson::raw::BindRawBsonRef for TopologyVersion {
    type Target = crate::bson::raw::BindValue<Self>;
}

/// A description of the most up-to-date information known about a server.
#[derive(Debug, Clone, Serialize)]
pub(crate) struct ServerDescription {
    /// The address of this server.
    pub(crate) address: ServerAddress,

    /// The type of this server.
    pub(crate) server_type: ServerType,

    /// The last time this server was updated.
    pub(crate) last_update_time: Option<DateTime>,

    /// The average duration of this server's hello calls.
    pub(crate) average_round_trip_time: Option<Duration>,

    // The SDAM spec indicates that a ServerDescription needs to contain an error message if an
    // error occurred when trying to send an hello for the server's heartbeat. Additionally,
    // we need to be able to create a server description that doesn't contain either an hello
    // reply or an error, since there's a gap between when a server is newly added to the topology
    // and when the first heartbeat occurs.
    //
    // In order to represent all these states, we store a Result directly in the ServerDescription,
    // which either contains the aforementioned error message or an Option<HelloReply>. This
    // allows us to ensure that only valid states are possible (e.g. preventing that both an error
    // and a reply are present) while still making it easy to define helper methods on
    // ServerDescription for information we need from the hello reply by propagating with `?`.
    #[serde(serialize_with = "serde_util::serialize_result_error_as_string")]
    pub(crate) reply: Result<Option<HelloReply>>,
}

// Server description equality has a specific notion of what fields in a hello command response
// should be compared (https://specifications.readthedocs.io/en/latest/server-discovery-and-monitoring/server-discovery-and-monitoring/#server-description-equality).
fn hello_command_eq(a: &HelloCommandResponse, b: &HelloCommandResponse) -> bool {
    a.server_type() == b.server_type()
        && a.min_wire_version == b.min_wire_version
        && a.max_wire_version == b.max_wire_version
        && a.me == b.me
        && a.hosts == b.hosts
        && a.passives == b.passives
        && a.arbiters == b.arbiters
        && a.tags == b.tags
        && a.set_name == b.set_name
        && a.set_version == b.set_version
        && a.election_id == b.election_id
        && a.primary == b.primary
        && a.logical_session_timeout_minutes == b.logical_session_timeout_minutes
        && a.topology_version == b.topology_version
}

impl PartialEq for ServerDescription {
    fn eq(&self, other: &Self) -> bool {
        if self.address != other.address || self.server_type != other.server_type {
            return false;
        }

        match (self.reply.as_ref(), other.reply.as_ref()) {
            (Ok(self_reply), Ok(other_reply)) => {
                let self_response = self_reply.as_ref().map(|r| &r.command_response);
                let other_response = other_reply.as_ref().map(|r| &r.command_response);

                match (self_response, other_response) {
                    (Some(a), Some(b)) => hello_command_eq(a, b),
                    (None, None) => true,
                    _ => false,
                }
            }
            (Err(self_err), Err(other_err)) => {
                match (self_err.kind.as_ref(), other_err.kind.as_ref()) {
                    (
                        ErrorKind::Command(self_command_err),
                        ErrorKind::Command(other_command_err),
                    ) => self_command_err.code == other_command_err.code,
                    _ => self_err.to_string() == other_err.to_string(),
                }
            }
            _ => false,
        }
    }
}

impl ServerDescription {
    pub(crate) fn new(address: &ServerAddress) -> Self {
        Self {
            address: match address {
                ServerAddress::Tcp { host, port } => ServerAddress::Tcp {
                    host: host.to_lowercase(),
                    port: *port,
                },
                #[cfg(unix)]
                ServerAddress::Unix { path } => ServerAddress::Unix { path: path.clone() },
            },
            server_type: Default::default(),
            last_update_time: None,
            reply: Ok(None),
            average_round_trip_time: None,
        }
    }

    pub(crate) fn new_from_hello_reply(
        address: ServerAddress,
        mut reply: HelloReply,
        average_rtt: Duration,
    ) -> Self {
        let mut description = Self::new(&address);
        description.average_round_trip_time = Some(average_rtt);
        description.last_update_time = Some(DateTime::now());

        // Infer the server type from the hello response.
        description.server_type = reply.command_response.server_type();

        // Normalize all instances of hostnames to lowercase.
        if let Some(ref mut hosts) = reply.command_response.hosts {
            let normalized_hostnames = hosts
                .drain(..)
                .map(|hostname| hostname.to_lowercase())
                .collect();

            *hosts = normalized_hostnames;
        }

        if let Some(ref mut passives) = reply.command_response.passives {
            let normalized_hostnames = passives
                .drain(..)
                .map(|hostname| hostname.to_lowercase())
                .collect();

            *passives = normalized_hostnames;
        }

        if let Some(ref mut arbiters) = reply.command_response.arbiters {
            let normalized_hostnames = arbiters
                .drain(..)
                .map(|hostname| hostname.to_lowercase())
                .collect();

            *arbiters = normalized_hostnames;
        }

        if let Some(ref mut me) = reply.command_response.me {
            *me = me.to_lowercase();
        }

        description.reply = Ok(Some(reply));

        description
    }

    pub(crate) fn new_from_error(address: ServerAddress, error: Error) -> Self {
        let mut description = Self::new(&address);
        description.last_update_time = Some(DateTime::now());
        description.average_round_trip_time = None;
        description.reply = Err(error);
        description
    }

    /// Whether this server is "available" as per the definition in the server selection spec.
    pub(crate) fn is_available(&self) -> bool {
        self.server_type.is_available()
    }

    pub(crate) fn compatibility_error_message(&self) -> Option<String> {
        if let Ok(Some(ref reply)) = self.reply {
            let hello_min_wire_version = reply.command_response.min_wire_version.unwrap_or(0);

            if hello_min_wire_version > DRIVER_MAX_WIRE_VERSION {
                return Some(format!(
                    "Server at {} requires wire version {}, but this version of the MongoDB Rust \
                     driver only supports up to {}",
                    self.address, hello_min_wire_version, DRIVER_MAX_WIRE_VERSION,
                ));
            }

            let hello_max_wire_version = reply.command_response.max_wire_version.unwrap_or(0);

            if hello_max_wire_version < DRIVER_MIN_WIRE_VERSION {
                return Some(format!(
                    "Server at {} reports wire version {}, but this version of the MongoDB Rust \
                     driver requires at least {} (MongoDB {}).",
                    self.address,
                    hello_max_wire_version,
                    DRIVER_MIN_WIRE_VERSION,
                    DRIVER_MIN_DB_VERSION
                ));
            }
        }

        None
    }

    pub(crate) fn set_name(&self) -> Result<Option<String>> {
        let set_name = self
            .reply
            .as_ref()
            .map_err(Clone::clone)?
            .as_ref()
            .and_then(|reply| reply.command_response.set_name.clone());
        Ok(set_name)
    }

    pub(crate) fn known_hosts(&self) -> Result<Vec<ServerAddress>> {
        let known_hosts = self
            .reply
            .as_ref()
            .map_err(Clone::clone)?
            .as_ref()
            .map(|reply| {
                let hosts = reply.command_response.hosts.as_ref();
                let passives = reply.command_response.passives.as_ref();
                let arbiters = reply.command_response.arbiters.as_ref();

                hosts
                    .into_iter()
                    .flatten()
                    .chain(passives.into_iter().flatten())
                    .chain(arbiters.into_iter().flatten())
            });

        known_hosts
            .into_iter()
            .flatten()
            .map(ServerAddress::parse)
            .collect()
    }

    pub(crate) fn invalid_me(&self) -> Result<bool> {
        if let Some(ref reply) = self.reply.as_ref().map_err(Clone::clone)? {
            if let Some(ref me) = reply.command_response.me {
                return Ok(self.address != ServerAddress::parse(me)?);
            }
        }

        Ok(false)
    }

    pub(crate) fn set_version(&self) -> Result<Option<i32>> {
        let me = self
            .reply
            .as_ref()
            .map_err(Clone::clone)?
            .as_ref()
            .and_then(|reply| reply.command_response.set_version);
        Ok(me)
    }

    pub(crate) fn election_id(&self) -> Result<Option<ObjectId>> {
        let me = self
            .reply
            .as_ref()
            .map_err(Clone::clone)?
            .as_ref()
            .and_then(|reply| reply.command_response.election_id);
        Ok(me)
    }

    #[cfg(test)]
    pub(crate) fn min_wire_version(&self) -> Result<Option<i32>> {
        let me = self
            .reply
            .as_ref()
            .map_err(Clone::clone)?
            .as_ref()
            .and_then(|reply| reply.command_response.min_wire_version);
        Ok(me)
    }

    pub(crate) fn max_wire_version(&self) -> Result<Option<i32>> {
        let me = self
            .reply
            .as_ref()
            .map_err(Clone::clone)?
            .as_ref()
            .and_then(|reply| reply.command_response.max_wire_version);
        Ok(me)
    }

    pub(crate) fn last_write_date(&self) -> Result<Option<DateTime>> {
        match self.reply {
            Ok(None) => Ok(None),
            Ok(Some(ref reply)) => Ok(reply
                .command_response
                .last_write
                .as_ref()
                .map(|write| write.last_write_date)),
            Err(ref e) => Err(e.clone()),
        }
    }

    pub(crate) fn logical_session_timeout(&self) -> Result<Option<Duration>> {
        match self.reply {
            Ok(None) => Ok(None),
            Ok(Some(ref reply)) => Ok(reply
                .command_response
                .logical_session_timeout_minutes
                .map(|timeout| Duration::from_secs(timeout * 60))),
            Err(ref e) => Err(e.clone()),
        }
    }

    pub(crate) fn cluster_time(&self) -> Result<Option<ClusterTime>> {
        match self.reply {
            Ok(None) => Ok(None),
            Ok(Some(ref reply)) => Ok(reply.cluster_time.clone()),
            Err(ref e) => Err(e.clone()),
        }
    }

    pub(crate) fn topology_version(&self) -> Option<TopologyVersion> {
        match self.reply {
            Ok(None) => None,
            Ok(Some(ref reply)) => reply.command_response.topology_version,
            Err(ref e) => e.topology_version(),
        }
    }

    pub(crate) fn matches_tag_set(&self, tag_set: &TagSet) -> bool {
        // An empty tag set matches any server.
        if tag_set.is_empty() {
            return true;
        }

        let reply = match self.reply.as_ref() {
            Ok(Some(ref reply)) => reply,
            _ => return false,
        };

        let server_tags = match reply.command_response.tags {
            Some(ref tags) => tags,
            None => return false,
        };

        tag_set
            .iter()
            .all(|(key, val)| server_tags.get(key) == Some(val))
    }
}

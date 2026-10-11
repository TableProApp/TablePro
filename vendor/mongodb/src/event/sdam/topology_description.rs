use std::{collections::HashMap, fmt};

use serde::Serialize;

use crate::{
    bson::oid::ObjectId,
    client::options::ServerAddress,
    sdam::{ServerInfo, TopologyType},
    selection_criteria::{ReadPreference, SelectionCriteria},
};

/// A description of the most up-to-date information known about a topology. Further details can
/// be found in the [Server Discovery and Monitoring specification](https://specifications.readthedocs.io/en/latest/server-discovery-and-monitoring/server-discovery-and-monitoring/).
#[derive(Clone, derive_more::Display)]
#[display("{description}")]
pub struct TopologyDescription {
    pub(crate) description: crate::sdam::TopologyDescription,
}

impl Serialize for TopologyDescription {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.description.serialize(serializer)
    }
}

impl From<crate::sdam::TopologyDescription> for TopologyDescription {
    fn from(description: crate::sdam::TopologyDescription) -> Self {
        Self { description }
    }
}

impl TopologyDescription {
    /// Whether this topology has a readable server available that satisfies the specified selection
    /// criteria.
    pub fn has_readable_server(&self, selection_criteria: Option<SelectionCriteria>) -> bool {
        let mut servers = self.description.filter_servers_by_selection_criteria(
            &selection_criteria.unwrap_or(ReadPreference::Primary.into()),
            None,
        );
        self.description
            .retain_servers_within_latency_window(&mut servers);
        !servers.is_empty()
    }

    /// Whether this topology has a writable server available.
    pub fn has_writable_server(&self) -> bool {
        match self.description.topology_type {
            TopologyType::Unknown | TopologyType::ReplicaSetNoPrimary => false,
            TopologyType::Single | TopologyType::Sharded => {
                self.description.has_available_servers()
            }
            TopologyType::ReplicaSetWithPrimary | TopologyType::LoadBalanced => true,
        }
    }

    /// Gets the type of the topology.
    pub fn topology_type(&self) -> TopologyType {
        self.description.topology_type
    }

    /// Gets the set name of the topology.
    pub fn set_name(&self) -> Option<&String> {
        self.description.set_name.as_ref()
    }

    /// Gets the max set version of the topology.
    pub fn max_set_version(&self) -> Option<i32> {
        self.description.max_set_version
    }

    /// Gets the max election ID of the topology.
    pub fn max_election_id(&self) -> Option<ObjectId> {
        self.description.max_election_id
    }

    /// Gets the compatibility error of the topology.
    pub fn compatibility_error(&self) -> Option<&String> {
        self.description.compatibility_error.as_ref()
    }

    /// Gets the servers in the topology.
    pub fn servers(&self) -> HashMap<&ServerAddress, ServerInfo<'_>> {
        self.description
            .servers
            .iter()
            .map(|(address, description)| (address, ServerInfo::new_borrowed(description)))
            .collect()
    }
}

impl fmt::Debug for TopologyDescription {
    fn fmt(&self, f: &mut fmt::Formatter) -> std::result::Result<(), fmt::Error> {
        f.debug_struct("Topology Description")
            .field("Type", &self.topology_type())
            .field("Set Name", &self.set_name())
            .field("Max Set Version", &self.max_set_version())
            .field("Max Election ID", &self.max_election_id())
            .field("Compatibility Error", &self.compatibility_error())
            .field("Servers", &self.servers().values())
            .finish()
    }
}

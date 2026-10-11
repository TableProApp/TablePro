#[cfg(test)]
mod test;

use std::{
    collections::{HashMap, HashSet},
    fmt,
    ops::Deref,
    sync::Arc,
    time::Duration,
};

use super::TopologyDescription;
use crate::{
    error::{ErrorKind, Result},
    options::ServerAddress,
    sdam::{
        description::{
            server::{ServerDescription, ServerType},
            topology::TopologyType,
        },
        Server,
        ServerInfo,
    },
    selection_criteria::{ReadPreference, SelectionCriteria, TagSet},
};

const DEFAULT_LOCAL_THRESHOLD: Duration = Duration::from_millis(15);
pub(crate) const IDLE_WRITE_PERIOD: Duration = Duration::from_secs(10);

/// Struct encapsulating a selected server that handles the opcount accounting.
#[derive(Debug)]
pub(crate) struct SelectedServer {
    server: Arc<Server>,
}

impl SelectedServer {
    fn new(server: Arc<Server>) -> Self {
        server.increment_operation_count();
        Self { server }
    }
}

impl Deref for SelectedServer {
    type Target = Server;

    fn deref(&self) -> &Server {
        self.server.deref()
    }
}

impl Drop for SelectedServer {
    fn drop(&mut self) {
        self.server.decrement_operation_count();
    }
}

/// Attempt to select a server, returning None if no server could be selected
/// that matched the provided criteria.
pub(crate) fn attempt_to_select_server<'a>(
    criteria: &'a SelectionCriteria,
    topology_description: &'a TopologyDescription,
    servers: &'a HashMap<ServerAddress, Arc<Server>>,
    deprioritized: Option<&HashSet<ServerAddress>>,
) -> Result<Option<SelectedServer>> {
    if let Some(message) = topology_description.compatibility_error() {
        return Err(ErrorKind::ServerSelection {
            message: message.to_string(),
        }
        .into());
    }
    if topology_description.is_replica_set() {
        if let Some(max_staleness) = criteria.as_read_pref().and_then(|rp| rp.max_staleness()) {
            super::verify_max_staleness(max_staleness, topology_description.heartbeat_frequency())?;
        }
    }

    let mut servers_matching_criteria =
        topology_description.filter_servers_by_selection_criteria(criteria, deprioritized);

    topology_description.retain_servers_within_latency_window(&mut servers_matching_criteria);
    let in_window_servers = servers_matching_criteria
        .into_iter()
        .flat_map(|description| servers.get(&description.address))
        .collect::<Vec<_>>();

    let selected_server = if in_window_servers.len() < 2 {
        in_window_servers.first()
    } else {
        super::choose_n(&in_window_servers, 2).min_by_key(|s| s.operation_count())
    }
    .cloned();
    Ok(selected_server.map(|s| SelectedServer::new(s.clone())))
}

impl TopologyDescription {
    pub(crate) fn server_selection_timeout_error_message(
        &self,
        criteria: &SelectionCriteria,
    ) -> String {
        if self.has_available_servers() {
            format!(
                "Server selection timeout: None of the available servers suitable for criteria \
                 {criteria:?}. Topology: {self}"
            )
        } else {
            format!("Server selection timeout: No available servers. Topology: {self}")
        }
    }

    pub(crate) fn has_available_servers(&self) -> bool {
        self.servers.values().any(|server| server.is_available())
    }

    pub(crate) fn filter_servers_by_selection_criteria(
        &self,
        selection_criteria: &SelectionCriteria,
        deprioritized: Option<&HashSet<ServerAddress>>,
    ) -> Vec<&ServerDescription> {
        let mut servers_matching_criteria =
            self.filter_servers_by_selection_criteria_inner(selection_criteria, deprioritized);
        if servers_matching_criteria.is_empty() && deprioritized.is_some_and(|d| !d.is_empty()) {
            servers_matching_criteria =
                self.filter_servers_by_selection_criteria_inner(selection_criteria, None);
        }
        servers_matching_criteria
    }

    fn filter_servers_by_selection_criteria_inner(
        &self,
        selection_criteria: &SelectionCriteria,
        deprioritized: Option<&HashSet<ServerAddress>>,
    ) -> Vec<&ServerDescription> {
        let prioritized = self.servers.iter().filter_map(|(address, description)| {
            if deprioritized.is_none_or(|d| !d.contains(address)) {
                Some(description)
            } else {
                None
            }
        });

        match selection_criteria {
            SelectionCriteria::ReadPreference(read_preference) => match self.topology_type {
                TopologyType::Unknown => Vec::new(),
                TopologyType::Single | TopologyType::LoadBalanced => prioritized.collect(),
                TopologyType::Sharded => prioritized
                    .filter(|sd| sd.server_type == ServerType::Mongos)
                    .collect(),
                TopologyType::ReplicaSetWithPrimary | TopologyType::ReplicaSetNoPrimary => {
                    self.filter_servers_in_replica_set(prioritized, read_preference)
                }
            },
            SelectionCriteria::Predicate(ref predicate) => prioritized
                .filter(|s| {
                    // If we're direct-connected or connected to a standalone, ignore whether the
                    // single server in the topology is data-bearing.
                    (self.topology_type == TopologyType::Single || s.server_type.is_data_bearing())
                        && predicate(&ServerInfo::new_borrowed(s))
                })
                .collect(),
        }
    }

    fn filter_servers_in_replica_set<'a>(
        &self,
        servers: impl Iterator<Item = &'a ServerDescription> + Clone,
        read_preference: &ReadPreference,
    ) -> Vec<&'a ServerDescription> {
        match read_preference {
            ReadPreference::Primary => servers
                .filter(|sd| sd.server_type == ServerType::RsPrimary)
                .collect(),
            ReadPreference::Secondary { .. } => self.filter_servers_with_read_preference(
                servers,
                &[ServerType::RsSecondary],
                read_preference,
            ),
            ReadPreference::PrimaryPreferred { .. } => {
                let primary = servers
                    .clone()
                    .filter(|sd| sd.server_type == ServerType::RsPrimary)
                    .collect::<Vec<_>>();
                if !primary.is_empty() {
                    primary
                } else {
                    self.filter_servers_with_read_preference(
                        servers,
                        &[ServerType::RsSecondary],
                        read_preference,
                    )
                }
            }
            ReadPreference::SecondaryPreferred { .. } => {
                let primary = servers
                    .clone()
                    .filter(|sd| sd.server_type == ServerType::RsPrimary);
                let secondaries = self.filter_servers_with_read_preference(
                    servers,
                    &[ServerType::RsSecondary],
                    read_preference,
                );
                if !secondaries.is_empty() {
                    secondaries
                } else {
                    primary.collect()
                }
            }
            ReadPreference::Nearest { .. } => self.filter_servers_with_read_preference(
                servers,
                &[ServerType::RsPrimary, ServerType::RsSecondary],
                read_preference,
            ),
        }
    }

    pub(crate) fn retain_servers_within_latency_window(
        &self,
        suitable_servers: &mut Vec<&ServerDescription>,
    ) {
        let shortest_average_rtt = suitable_servers
            .iter()
            .filter_map(|server_desc| server_desc.average_round_trip_time)
            .fold(Option::<Duration>::None, |min, curr| match min {
                Some(prev) => Some(prev.min(curr)),
                None => Some(curr),
            });

        let local_threshold = self.local_threshold.unwrap_or(DEFAULT_LOCAL_THRESHOLD);

        let max_rtt_within_window = shortest_average_rtt
            .map(|rtt| rtt.checked_add(local_threshold).unwrap_or(Duration::MAX));

        suitable_servers.retain(move |server_desc| {
            if let Some(server_rtt) = server_desc.average_round_trip_time {
                // unwrap() is safe here because this server's avg rtt being Some indicates that
                // there exists a max rtt as well.
                server_rtt <= max_rtt_within_window.unwrap()
            } else {
                // SDAM isn't performed with a load balanced topology, so the load balancer won't
                // have an RTT. Instead, we just select it.
                matches!(server_desc.server_type, ServerType::LoadBalancer)
            }
        });
    }

    pub(crate) fn primary(&self) -> Option<&ServerDescription> {
        self.servers
            .values()
            .find(|sd| sd.server_type == ServerType::RsPrimary)
    }

    fn filter_servers_with_read_preference<'a>(
        &self,
        servers: impl Iterator<Item = &'a ServerDescription>,
        types: &[ServerType],
        read_preference: &ReadPreference,
    ) -> Vec<&'a ServerDescription> {
        let tag_sets = read_preference.tag_sets();
        let max_staleness = read_preference.max_staleness();

        let mut servers = servers
            .filter(|sd| types.contains(&sd.server_type))
            .collect();

        // We don't need to check for the Client's default max_staleness because it would be passed
        // in as part of the Client's default ReadPreference if none is specified for the operation.
        if let Some(max_staleness) = max_staleness {
            // According to the spec, max staleness <= 0 is the same as no max staleness.
            if max_staleness > Duration::from_secs(0) {
                self.filter_servers_by_max_staleness(&mut servers, max_staleness);
            }
        }

        if let Some(tag_sets) = tag_sets {
            filter_servers_by_tag_sets(&mut servers, tag_sets);
        }

        servers
    }

    fn filter_servers_by_max_staleness(
        &self,
        servers: &mut Vec<&ServerDescription>,
        max_staleness: Duration,
    ) {
        match self.primary() {
            Some(primary) => {
                self.filter_servers_by_max_staleness_with_primary(servers, primary, max_staleness)
            }
            None => self.filter_servers_by_max_staleness_without_primary(servers, max_staleness),
        };
    }

    fn filter_servers_by_max_staleness_with_primary(
        &self,
        servers: &mut Vec<&ServerDescription>,
        primary: &ServerDescription,
        max_staleness: Duration,
    ) {
        let max_staleness_ms = max_staleness.as_millis().try_into().unwrap_or(i64::MAX);

        servers.retain(|server| {
            let server_staleness = self.calculate_secondary_staleness_with_primary(server, primary);

            server_staleness
                .map(|staleness| staleness <= max_staleness_ms)
                .unwrap_or(false)
        })
    }

    fn filter_servers_by_max_staleness_without_primary(
        &self,
        servers: &mut Vec<&ServerDescription>,
        max_staleness: Duration,
    ) {
        let max_staleness = max_staleness.as_millis().try_into().unwrap_or(i64::MAX);
        let max_write_date = self
            .servers
            .values()
            .filter(|server| server.server_type == ServerType::RsSecondary)
            .filter_map(|server| {
                server
                    .last_write_date()
                    .ok()
                    .and_then(std::convert::identity)
            })
            .map(|last_write_date| last_write_date.timestamp_millis())
            .max();

        let secondary_max_write_date = match max_write_date {
            Some(max_write_date) => max_write_date,
            None => return,
        };

        servers.retain(|server| {
            let server_staleness = self
                .calculate_secondary_staleness_without_primary(server, secondary_max_write_date);

            server_staleness
                .map(|staleness| staleness <= max_staleness)
                .unwrap_or(false)
        })
    }

    fn calculate_secondary_staleness_with_primary(
        &self,
        secondary: &ServerDescription,
        primary: &ServerDescription,
    ) -> Option<i64> {
        let primary_last_update = primary.last_update_time?.timestamp_millis();
        let primary_last_write = primary.last_write_date().ok()??.timestamp_millis();

        let secondary_last_update = secondary.last_update_time?.timestamp_millis();
        let secondary_last_write = secondary.last_write_date().ok()??.timestamp_millis();

        let heartbeat_frequency = self
            .heartbeat_frequency()
            .as_millis()
            .try_into()
            .unwrap_or(i64::MAX);

        let staleness = (secondary_last_update - secondary_last_write)
            - (primary_last_update - primary_last_write)
            + heartbeat_frequency;

        Some(staleness)
    }

    fn calculate_secondary_staleness_without_primary(
        &self,
        secondary: &ServerDescription,
        max_last_write_date: i64,
    ) -> Option<i64> {
        let secondary_last_write = secondary.last_write_date().ok()??.timestamp_millis();
        let heartbeat_frequency = self
            .heartbeat_frequency()
            .as_millis()
            .try_into()
            .unwrap_or(i64::MAX);

        let staleness = max_last_write_date - secondary_last_write + heartbeat_frequency;
        Some(staleness)
    }
}

impl fmt::Display for TopologyDescription {
    fn fmt(&self, f: &mut fmt::Formatter) -> std::result::Result<(), fmt::Error> {
        write!(f, "{{ Type: {}", self.topology_type)?;

        if let Some(ref set_name) = self.set_name {
            write!(f, ", Set Name: {set_name}")?;
        }

        if let Some(max_set_version) = self.max_set_version {
            write!(f, ", Max Set Version: {max_set_version}")?;
        }

        if let Some(max_election_id) = self.max_election_id {
            write!(f, ", Max Election ID: {max_election_id}")?;
        }

        if let Some(ref compatibility_error) = self.compatibility_error {
            write!(f, ", Compatibility Error: {compatibility_error}")?;
        }

        if !self.servers.is_empty() {
            write!(f, ", Servers: [ ")?;
            let mut iter = self.servers.values();
            if let Some(server) = iter.next() {
                write!(f, "{}", ServerInfo::new_borrowed(server))?;
            }
            for server in iter {
                write!(f, ", {}", ServerInfo::new_borrowed(server))?;
            }
            write!(f, " ]")?;
        }

        write!(f, " }}")
    }
}

fn filter_servers_by_tag_sets(servers: &mut Vec<&ServerDescription>, tag_sets: &[TagSet]) {
    if tag_sets.is_empty() {
        return;
    }

    for tag_set in tag_sets {
        let matches_tag_set = |server: &&ServerDescription| server.matches_tag_set(tag_set);

        if servers.iter().any(matches_tag_set) {
            servers.retain(matches_tag_set);

            return;
        }
    }

    servers.clear();
}

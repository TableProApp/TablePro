use serde::{Deserialize, Serialize};

use crate::{ConfigError, DriverCapabilities, LocalSocket, NetworkEndpoint, TransportClass};

/// What a network engine reads beyond a host, a port and a database. An
/// option is offered only where the driver's capabilities list it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct NetworkOptions {
    /// Find the servers from the host's DNS seed list, its SRV and TXT
    /// records, instead of connecting to the host. The port is the
    /// records' to give.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub dns_seed_list: bool,
    /// The database the login's user is defined in, where that is not
    /// the connection's own database.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth_database: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replica_set: Option<String>,
    // Members besides the host, as `host:port`, for the client to find the set from.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub more_hosts: Vec<String>,
}

impl NetworkOptions {
    pub fn is_default(&self) -> bool {
        *self == Self::default()
    }

    /// Refuse an option the driver does not read, which only a saved or
    /// imported connection can carry, and a seed list over a forward.
    pub fn validate(&self, capabilities: &DriverCapabilities, route: TransportClass) -> Result<(), ConfigError> {
        let unread = (self.dns_seed_list && !capabilities.offers(NetworkOption::DnsSeedList))
            || (self.auth_database().is_some() && !capabilities.offers(NetworkOption::AuthDatabase))
            || (self.uses_host_list() && !capabilities.offers(NetworkOption::HostList));
        if unread {
            return Err(ConfigError::NetworkOptionUnsupported);
        }
        if self.dns_seed_list && route == TransportClass::SshForward {
            return Err(ConfigError::SeedListOverSsh);
        }
        if self.uses_host_list() && route == TransportClass::SshForward {
            return Err(ConfigError::HostListOverSsh);
        }
        if self.dns_seed_list && !self.more_hosts.is_empty() {
            return Err(ConfigError::HostListWithSeedList);
        }
        let default_port = capabilities.default_port().unwrap_or(1);
        self.more_hosts(default_port).map(|_| ())
    }

    /// The authentication database, blank as none.
    pub fn auth_database(&self) -> Option<&str> {
        self.auth_database
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
    }

    pub fn replica_set(&self) -> Option<&str> {
        self.replica_set
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
    }

    pub fn uses_host_list(&self) -> bool {
        self.replica_set().is_some() || !self.more_hosts.is_empty()
    }

    pub fn more_hosts(&self, default_port: u16) -> Result<Vec<NetworkEndpoint>, ConfigError> {
        self.more_hosts
            .iter()
            .map(|entry| NetworkEndpoint::parse(entry, default_port))
            .collect()
    }
}

/// One of the `NetworkOptions` a driver reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NetworkOption {
    DnsSeedList,
    AuthDatabase,
    // A replica set name and more members to seed it from.
    HostList,
    // A host that is an absolute path names the server's socket, as the engine's client names it.
    LocalSocket(LocalSocket),
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::meta::ObjectKind;
    use crate::{
        AuthMode, CommitResolutionSupport, DataModel, EndpointKind, EstimateQuality, ReadOnlyEnforcement,
        ScriptExecution, StatementStop, WriteAtomicity,
    };

    const READS_NONE: DriverCapabilities = DriverCapabilities {
        data_model: DataModel::Relational,
        endpoint: EndpointKind::Network { default_port: 5432 },
        auth_modes: &[AuthMode::Password],
        username_required: true,
        tls: None,
        read_only: ReadOnlyEnforcement::SessionDefault,
        dml_writes: WriteAtomicity::Transactional,
        ddl_writes: WriteAtomicity::Transactional,
        script_execution: ScriptExecution::NativeBatch,
        commit_resolution: CommitResolutionSupport::ServerTransactionStatus,
        row_count_estimate: EstimateQuality::Statistics,
        object_kinds: &[ObjectKind::Table],
        database_required: false,
        network_options: &[],
        statement_stop: StatementStop::Server,
    };

    const READS_BOTH: DriverCapabilities = DriverCapabilities {
        network_options: &[NetworkOption::DnsSeedList, NetworkOption::AuthDatabase],
        ..READS_NONE
    };

    const READS_HOST_LIST: DriverCapabilities = DriverCapabilities {
        endpoint: EndpointKind::Network { default_port: 27017 },
        network_options: &[NetworkOption::DnsSeedList, NetworkOption::HostList],
        ..READS_NONE
    };

    #[test]
    fn a_host_list_needs_a_driver_that_reads_one_a_direct_route_and_hosts_that_parse() {
        let replica = NetworkOptions {
            replica_set: Some(" rs0 ".to_owned()),
            more_hosts: vec!["mongo2.example.com:27018".to_owned(), "[::1]".to_owned()],
            ..NetworkOptions::default()
        };

        assert_eq!(replica.validate(&READS_HOST_LIST, TransportClass::DirectTcp), Ok(()));
        assert_eq!(replica.replica_set(), Some("rs0"));
        let hosts: Vec<String> = replica
            .more_hosts(27017)
            .unwrap()
            .iter()
            .map(ToString::to_string)
            .collect();
        assert_eq!(hosts, ["mongo2.example.com:27018", "[::1]:27017"]);
        assert_eq!(
            replica.validate(&READS_BOTH, TransportClass::DirectTcp),
            Err(ConfigError::NetworkOptionUnsupported)
        );
        assert_eq!(
            replica.validate(&READS_HOST_LIST, TransportClass::SshForward),
            Err(ConfigError::HostListOverSsh)
        );
        let seeded = NetworkOptions {
            dns_seed_list: true,
            ..replica.clone()
        };
        assert_eq!(
            seeded.validate(&READS_HOST_LIST, TransportClass::DirectTcp),
            Err(ConfigError::HostListWithSeedList)
        );
        let bad_port = NetworkOptions {
            more_hosts: vec!["mongo2.example.com:99999".to_owned()],
            ..NetworkOptions::default()
        };
        assert_eq!(
            bad_port.validate(&READS_HOST_LIST, TransportClass::DirectTcp),
            Err(ConfigError::InvalidPort)
        );
        let blank_set = NetworkOptions {
            replica_set: Some("  ".to_owned()),
            ..NetworkOptions::default()
        };
        assert!(!blank_set.uses_host_list());
    }

    #[test]
    fn an_option_the_driver_does_not_read_or_a_seed_list_over_ssh_is_refused() {
        let seed_list = NetworkOptions {
            dns_seed_list: true,
            ..NetworkOptions::default()
        };
        let auth = NetworkOptions {
            auth_database: Some("admin".to_owned()),
            ..NetworkOptions::default()
        };

        assert_eq!(
            seed_list.validate(&READS_NONE, TransportClass::DirectTcp),
            Err(ConfigError::NetworkOptionUnsupported)
        );
        assert_eq!(
            auth.validate(&READS_NONE, TransportClass::DirectTcp),
            Err(ConfigError::NetworkOptionUnsupported)
        );
        assert_eq!(seed_list.validate(&READS_BOTH, TransportClass::DirectTcp), Ok(()));
        assert_eq!(
            seed_list.validate(&READS_BOTH, TransportClass::SshForward),
            Err(ConfigError::SeedListOverSsh)
        );
        assert_eq!(auth.validate(&READS_BOTH, TransportClass::SshForward), Ok(()));
        assert_eq!(
            NetworkOptions::default().validate(&READS_NONE, TransportClass::SshForward),
            Ok(())
        );
    }

    #[test]
    fn options_left_alone_write_nothing() {
        assert_eq!(
            serde_json::to_string(&NetworkOptions::default()).ok().as_deref(),
            Some("{}")
        );
        let options = NetworkOptions {
            dns_seed_list: true,
            auth_database: Some(" admin ".to_owned()),
            ..NetworkOptions::default()
        };
        let written = serde_json::to_string(&options).unwrap_or_default();
        assert_eq!(written, r#"{"dns_seed_list":true,"auth_database":" admin "}"#);
        assert_eq!(
            serde_json::from_str::<NetworkOptions>(&written).ok(),
            Some(options.clone())
        );
        assert_eq!(options.auth_database(), Some("admin"));
        assert!(NetworkOptions::default().is_default());
        assert_eq!(
            NetworkOptions {
                auth_database: Some("  ".to_owned()),
                ..NetworkOptions::default()
            }
            .auth_database(),
            None
        );
    }
}

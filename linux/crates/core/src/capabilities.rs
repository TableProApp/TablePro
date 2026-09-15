use crate::connection::AuthMode;
use crate::meta::ObjectKind;
use crate::tls_capabilities::TlsCapabilities;
use crate::write_ledger::WriteAtomicity;

/// Where a driver connects to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EndpointKind {
    Network { default_port: u16 },
    File,
}

/// How a read-only connection is held to it.
///
/// The three differ in what the user can do about a refused write: a
/// setting on this connection, a session default the server can
/// override, or a login that simply cannot write.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReadOnlyEnforcement {
    EngineEnforced,
    SessionDefault,
    LoginPrivileges,
}

/// Whether the engine runs a script as one unit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScriptExecution {
    NativeBatch,
    /// One statement per round trip, which is what the editor splits
    /// for.
    SingleStatement,
}

/// How a commit whose answer never arrived can be resolved afterwards.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CommitResolutionSupport {
    /// The server can be asked about the transaction directly.
    ServerTransactionStatus,
    /// The queries that ran are recorded and can be looked up.
    QueryLog,
    Unavailable,
}

/// How good a row-count estimate the engine can give without counting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EstimateQuality {
    /// From the planner's statistics, so "about N".
    Statistics,
    /// The engine keeps an exact count in its metadata.
    ExactMetadata,
    Unavailable,
}

/// What a driver can do, before any connection exists.
///
/// The UI reads this to decide what to offer: whether to show a
/// Kerberos row, whether a save is one transaction or a sequence of
/// statements, whether a row count can be shown as exact.
#[derive(Debug, Clone, PartialEq)]
pub struct DriverCapabilities {
    pub endpoint: EndpointKind,
    pub auth_modes: &'static [AuthMode],
    pub tls: Option<TlsCapabilities>,
    pub read_only: ReadOnlyEnforcement,
    pub dml_writes: WriteAtomicity,
    pub ddl_writes: WriteAtomicity,
    pub script_execution: ScriptExecution,
    pub commit_resolution: CommitResolutionSupport,
    pub row_count_estimate: EstimateQuality,
    pub object_kinds: &'static [ObjectKind],
    /// Whether a connection needs a database name before it can open.
    pub database_required: bool,
}

impl DriverCapabilities {
    pub fn default_port(&self) -> Option<u16> {
        match self.endpoint {
            EndpointKind::Network { default_port } => Some(default_port),
            EndpointKind::File => None,
        }
    }

    pub fn is_file_based(&self) -> bool {
        matches!(self.endpoint, EndpointKind::File)
    }

    pub fn supports(&self, mode: AuthMode) -> bool {
        self.auth_modes.contains(&mode)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NETWORK: DriverCapabilities = DriverCapabilities {
        endpoint: EndpointKind::Network { default_port: 5432 },
        auth_modes: &[AuthMode::Password],
        tls: None,
        read_only: ReadOnlyEnforcement::SessionDefault,
        dml_writes: WriteAtomicity::Transactional,
        ddl_writes: WriteAtomicity::Transactional,
        script_execution: ScriptExecution::NativeBatch,
        commit_resolution: CommitResolutionSupport::ServerTransactionStatus,
        row_count_estimate: EstimateQuality::Statistics,
        object_kinds: &[ObjectKind::Table, ObjectKind::View],
        database_required: false,
    };

    #[test]
    fn a_file_engine_has_no_port_to_offer() {
        let file = DriverCapabilities {
            endpoint: EndpointKind::File,
            auth_modes: &[],
            ..NETWORK
        };

        assert_eq!(file.default_port(), None);
        assert!(file.is_file_based());
        assert!(!file.supports(AuthMode::Password), "a file has no login");
    }

    #[test]
    fn a_network_engine_offers_its_port_and_its_logins() {
        assert_eq!(NETWORK.default_port(), Some(5432));
        assert!(!NETWORK.is_file_based());
        assert!(NETWORK.supports(AuthMode::Password));
        assert!(!NETWORK.supports(AuthMode::Kerberos));
    }
}

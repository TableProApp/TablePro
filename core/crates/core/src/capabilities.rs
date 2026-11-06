use crate::auth_mode::AuthMode;
use crate::config_error::ConfigError;
use crate::file_format::FileFormat;
use crate::local_socket::{LocalSocket, is_local_socket_host};
use crate::meta::ObjectKind;
use crate::network_options::NetworkOption;
use crate::tls_capabilities::TlsCapabilities;
use crate::tls_mode::TlsMode;
use crate::write_ledger::WriteAtomicity;

/// Where a driver connects to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EndpointKind {
    Network { default_port: u16 },
    File(FileFormat),
}

/// How a read-only connection is held to it.
///
/// They differ in what the user can do about a refused write: a setting
/// on this connection, a session default the server can override, a
/// login that simply cannot write, or nothing but the app's own check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReadOnlyEnforcement {
    EngineEnforced,
    SessionDefault,
    LoginPrivileges,
    /// The engine has no read-only session, so only the app's own check
    /// of each command stands between the user and a write.
    ClientGuard,
}

/// What an engine holds, which decides what the sidebar lists, what an
/// object opens in and the language the editor takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DataModel {
    /// Schemas of tables, read and written in SQL.
    Relational,
    /// Numbered databases of keys, each holding a typed value, read and
    /// written with commands.
    KeyValue,
    /// Databases of collections, whose documents each hold fields of
    /// their own, read and written with the engine's shell language.
    /// A collection opens in a table tab, its fields as columns.
    Document,
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

/// What stopping a statement does on the server.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StatementStop {
    /// The engine has a stop of its own: a cancel request, a KILL, an
    /// attention, an interrupt.
    Server,
    /// The protocol carries no stop, as CQL's does not. The driver stops
    /// waiting and drops the request, and the server runs the statement
    /// to its own timeout.
    Abandon,
}

/// What a driver can do, before any connection exists.
///
/// The UI reads this to decide what to offer: whether to show a
/// Kerberos row, whether a save is one transaction or a sequence of
/// statements, whether a row count can be shown as exact.
#[derive(Debug, Clone, PartialEq)]
pub struct DriverCapabilities {
    pub data_model: DataModel,
    pub endpoint: EndpointKind,
    pub auth_modes: &'static [AuthMode],
    /// Whether a password login needs a username. Redis takes a password
    /// alone, for its default user.
    pub username_required: bool,
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
    /// The `NetworkOptions` the connect dialog offers for this engine.
    pub network_options: &'static [NetworkOption],
    pub statement_stop: StatementStop,
}

impl DriverCapabilities {
    pub fn default_port(&self) -> Option<u16> {
        match self.endpoint {
            EndpointKind::Network { default_port } => Some(default_port),
            EndpointKind::File(_) => None,
        }
    }

    pub fn is_file_based(&self) -> bool {
        self.file_format().is_some()
    }

    /// The engine's database files, for an engine that opens one.
    pub fn file_format(&self) -> Option<&FileFormat> {
        match &self.endpoint {
            EndpointKind::File(format) => Some(format),
            EndpointKind::Network { .. } => None,
        }
    }

    pub fn supports(&self, mode: AuthMode) -> bool {
        self.auth_modes.contains(&mode)
    }

    pub fn is_key_value(&self) -> bool {
        self.data_model == DataModel::KeyValue
    }

    pub fn is_document(&self) -> bool {
        self.data_model == DataModel::Document
    }

    pub fn offers(&self, option: NetworkOption) -> bool {
        self.network_options.contains(&option)
    }

    pub fn local_socket(&self) -> Option<LocalSocket> {
        self.network_options.iter().find_map(|option| match option {
            NetworkOption::LocalSocket(socket) => Some(*socket),
            _ => None,
        })
    }

    // The socket is this machine's, so a tunnel never reaches it, and TLS there is the engine's to take.
    pub fn check_socket_host(&self, host: &str, tunnelled: bool, tls: TlsMode) -> Result<(), ConfigError> {
        if !is_local_socket_host(host.trim()) {
            return Ok(());
        }
        let Some(socket) = self.local_socket() else {
            return Err(ConfigError::LocalSocketUnsupported);
        };
        if tunnelled {
            return Err(ConfigError::LocalSocketOverSsh);
        }
        if tls.encrypts() && !socket.takes_tls() {
            return Err(ConfigError::TlsOverLocalSocket);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::file_format::FileSignature;

    const NETWORK: DriverCapabilities = DriverCapabilities {
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
        object_kinds: &[ObjectKind::Table, ObjectKind::View],
        database_required: false,
        network_options: &[],
        statement_stop: StatementStop::Server,
    };

    #[test]
    fn a_file_engine_has_no_port_to_offer() {
        let format = FileFormat {
            signature: FileSignature {
                offset: 0,
                bytes: b"SQLite format 3\0",
            },
            suffixes: &["sqlite3"],
            mime_types: &[],
            empty_file_is_database: true,
        };
        let file = DriverCapabilities {
            endpoint: EndpointKind::File(format),
            auth_modes: &[],
            ..NETWORK
        };

        assert_eq!(file.default_port(), None);
        assert!(file.is_file_based());
        assert_eq!(file.file_format(), Some(&format));
        assert!(!file.supports(AuthMode::Password), "a file has no login");
    }

    #[test]
    fn a_network_engine_offers_its_port_and_its_logins() {
        assert_eq!(NETWORK.default_port(), Some(5432));
        assert!(!NETWORK.is_file_based());
        assert_eq!(NETWORK.file_format(), None);
        assert!(NETWORK.supports(AuthMode::Password));
        assert!(!NETWORK.supports(AuthMode::Kerberos));
    }

    #[test]
    fn a_socket_host_needs_an_engine_that_reads_one_and_no_tunnel() {
        const SOCKET: LocalSocket = LocalSocket::Folder {
            file_prefix: ".s.PGSQL.",
            defaults: &["/run/postgresql"],
        };
        let with_socket = DriverCapabilities {
            network_options: &[NetworkOption::LocalSocket(SOCKET)],
            ..NETWORK
        };

        const FILE: LocalSocket = LocalSocket::File {
            defaults: &["/run/mysqld/mysqld.sock"],
        };
        let with_file = DriverCapabilities {
            network_options: &[NetworkOption::LocalSocket(FILE)],
            ..NETWORK
        };
        let plain = TlsMode::Disable;

        assert_eq!(with_socket.local_socket(), Some(SOCKET));
        assert_eq!(NETWORK.local_socket(), None);
        assert_eq!(with_socket.check_socket_host("/run/postgresql", false, plain), Ok(()));
        assert_eq!(
            with_socket.check_socket_host("db.example.com", true, TlsMode::VerifyFull),
            Ok(())
        );
        assert_eq!(
            with_socket.check_socket_host("/run/postgresql", true, plain),
            Err(ConfigError::LocalSocketOverSsh)
        );
        assert_eq!(
            NETWORK.check_socket_host(" /run/postgresql", false, plain),
            Err(ConfigError::LocalSocketUnsupported)
        );
        assert_eq!(
            with_socket.check_socket_host("/run/postgresql", false, TlsMode::Require),
            Err(ConfigError::TlsOverLocalSocket)
        );
        assert_eq!(
            with_file.check_socket_host("/run/mysqld/mysqld.sock", false, TlsMode::VerifyFull),
            Ok(())
        );
    }
}

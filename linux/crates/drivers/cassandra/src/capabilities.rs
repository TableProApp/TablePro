use tablepro_core::meta::ObjectKind;
use tablepro_core::{
    AuthMode, CommitResolutionSupport, DataModel, DriverCapabilities, EndpointKind, EstimateQuality,
    ReadOnlyEnforcement, ScriptExecution, ServerNameOverride, StatementStop, TlsCapabilities, TlsMode, WriteAtomicity,
};

pub(crate) const DEFAULT_PORT: u16 = 9042;

pub(crate) static CAPABILITIES: DriverCapabilities = DriverCapabilities {
    data_model: DataModel::Relational,
    endpoint: EndpointKind::Network {
        default_port: DEFAULT_PORT,
    },
    auth_modes: &[AuthMode::Password],
    // A server on AllowAllAuthenticator takes no login, and an empty
    // username sends none.
    username_required: false,
    // The relay hands rustls a loopback address, so the certificate is
    // checked against the name the driver supplies on every route.
    tls: Some(TlsCapabilities {
        modes: &[TlsMode::Disable, TlsMode::Require, TlsMode::VerifyFull],
        ca_file: true,
        client_identity: true,
        server_name_override: ServerNameOverride::AnyRoute,
    }),
    // CQL has no read-only session. A role granted only SELECT is the
    // guarantee; the app refuses writes before they are sent.
    read_only: ReadOnlyEnforcement::LoginPrivileges,
    // No transactions: every statement lands on its own, a batch
    // included, which is atomic only within one partition.
    dml_writes: WriteAtomicity::StatementByStatement,
    ddl_writes: WriteAtomicity::StatementByStatement,
    script_execution: ScriptExecution::SingleStatement,
    commit_resolution: CommitResolutionSupport::Unavailable,
    row_count_estimate: EstimateQuality::Unavailable,
    object_kinds: &[ObjectKind::Table, ObjectKind::MaterializedView],
    database_required: false,
    network_options: &[],
    statement_stop: StatementStop::Abandon,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_match_driver_contract() {
        assert_eq!(CAPABILITIES.default_port(), Some(9042));
        assert!(CAPABILITIES.supports(AuthMode::Password));
        assert!(!CAPABILITIES.supports(AuthMode::Kerberos));
        let tls = CAPABILITIES.tls.expect("CQL offers TLS");
        assert_eq!(tls.modes.len(), 3);
        assert!(tls.ca_file && tls.client_identity);
        assert_eq!(CAPABILITIES.read_only, ReadOnlyEnforcement::LoginPrivileges);
        assert_eq!(CAPABILITIES.dml_writes, WriteAtomicity::StatementByStatement);
        assert_eq!(CAPABILITIES.ddl_writes, WriteAtomicity::StatementByStatement);
        assert_eq!(CAPABILITIES.commit_resolution, CommitResolutionSupport::Unavailable);
        assert_eq!(CAPABILITIES.statement_stop, StatementStop::Abandon);
        assert!(!CAPABILITIES.database_required);
    }
}

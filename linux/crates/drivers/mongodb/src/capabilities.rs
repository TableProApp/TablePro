use tablepro_core::meta::ObjectKind;
use tablepro_core::{
    AuthMode, CommitResolutionSupport, DataModel, DriverCapabilities, EndpointKind, EstimateQuality, NetworkOption,
    ReadOnlyEnforcement, ScriptExecution, ServerNameOverride, TlsCapabilities, TlsMode, WriteAtomicity,
};

pub(crate) const DEFAULT_PORT: u16 = 27017;

pub(crate) static CAPABILITIES: DriverCapabilities = DriverCapabilities {
    data_model: DataModel::Document,
    endpoint: EndpointKind::Network {
        default_port: DEFAULT_PORT,
    },
    auth_modes: &[AuthMode::Password],
    // A server without access control takes no login, so the username is
    // optional; one given needs its password.
    username_required: false,
    tls: Some(TlsCapabilities {
        modes: &[TlsMode::Disable, TlsMode::Require, TlsMode::VerifyFull],
        ca_file: true,
        client_identity: true,
        // On a direct route the client checks each server it finds under
        // that server's own name.
        server_name_override: ServerNameOverride::SshForwardOnly,
    }),
    // MongoDB has no read-only session, so the driver refuses every
    // statement that is not a read before it is sent.
    read_only: ReadOnlyEnforcement::ClientGuard,
    // Each grid change is its own single-document write.
    dml_writes: WriteAtomicity::StatementByStatement,
    ddl_writes: WriteAtomicity::StatementByStatement,
    script_execution: ScriptExecution::SingleStatement,
    commit_resolution: CommitResolutionSupport::Unavailable,
    row_count_estimate: EstimateQuality::Statistics,
    object_kinds: &[ObjectKind::Table, ObjectKind::View],
    database_required: false,
    network_options: &[NetworkOption::DnsSeedList, NetworkOption::AuthDatabase],
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_match_driver_contract() {
        assert_eq!(CAPABILITIES.data_model, DataModel::Document);
        assert_eq!(CAPABILITIES.default_port(), Some(27017));
        assert!(CAPABILITIES.supports(AuthMode::Password));
        assert!(!CAPABILITIES.supports(AuthMode::Kerberos));
        assert!(!CAPABILITIES.username_required);
        let tls = CAPABILITIES.tls.expect("MongoDB offers TLS");
        assert_eq!(tls.modes.len(), 3);
        assert!(tls.ca_file && tls.client_identity);
        assert_eq!(tls.server_name_override, ServerNameOverride::SshForwardOnly);
        assert_eq!(CAPABILITIES.read_only, ReadOnlyEnforcement::ClientGuard);
        assert_eq!(CAPABILITIES.script_execution, ScriptExecution::SingleStatement);
        assert!(CAPABILITIES.offers(NetworkOption::DnsSeedList));
        assert!(CAPABILITIES.offers(NetworkOption::AuthDatabase));
        assert!(!CAPABILITIES.database_required);
    }
}

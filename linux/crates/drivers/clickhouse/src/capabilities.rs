use tablepro_core::meta::ObjectKind;
use tablepro_core::{
    AuthMode, CommitResolutionSupport, DriverCapabilities, EndpointKind, EstimateQuality, ReadOnlyEnforcement,
    ScriptExecution, ServerNameOverride, TlsCapabilities, TlsMode, WriteAtomicity,
};

pub(crate) const DEFAULT_PORT: u16 = 8123;

pub(crate) static CAPABILITIES: DriverCapabilities = DriverCapabilities {
    endpoint: EndpointKind::Network {
        default_port: DEFAULT_PORT,
    },
    auth_modes: &[AuthMode::Password],
    tls: Some(TlsCapabilities {
        modes: &[TlsMode::Disable, TlsMode::Require, TlsMode::VerifyFull],
        ca_file: true,
        client_identity: true,
        server_name_override: ServerNameOverride::AnyRoute,
    }),
    // `readonly=2` travels with every request of a read-only connection,
    // and the server refuses a write under it whatever the SQL says.
    read_only: ReadOnlyEnforcement::EngineEnforced,
    // A mutation is neither atomic nor stoppable, so a save is a sequence
    // of statements that each land on their own.
    dml_writes: WriteAtomicity::StatementByStatement,
    ddl_writes: WriteAtomicity::StatementByStatement,
    script_execution: ScriptExecution::SingleStatement,
    commit_resolution: CommitResolutionSupport::QueryLog,
    row_count_estimate: EstimateQuality::ExactMetadata,
    object_kinds: &[
        ObjectKind::Table,
        ObjectKind::View,
        ObjectKind::MaterializedView,
        ObjectKind::Dictionary,
        ObjectKind::Function,
    ],
    database_required: false,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_match_driver_contract() {
        assert_eq!(CAPABILITIES.default_port(), Some(8123));
        assert!(CAPABILITIES.supports(AuthMode::Password));
        assert!(!CAPABILITIES.supports(AuthMode::Kerberos));
        let tls = CAPABILITIES.tls.expect("ClickHouse offers TLS");
        assert_eq!(tls.modes.len(), 3);
        assert!(tls.ca_file && tls.client_identity);
        assert_eq!(CAPABILITIES.read_only, ReadOnlyEnforcement::EngineEnforced);
        assert_eq!(CAPABILITIES.dml_writes, WriteAtomicity::StatementByStatement);
        assert_eq!(CAPABILITIES.ddl_writes, WriteAtomicity::StatementByStatement);
        assert_eq!(CAPABILITIES.script_execution, ScriptExecution::SingleStatement);
        assert_eq!(CAPABILITIES.commit_resolution, CommitResolutionSupport::QueryLog);
        assert_eq!(CAPABILITIES.row_count_estimate, EstimateQuality::ExactMetadata);
        assert_eq!(CAPABILITIES.object_kinds.len(), 5);
        assert!(!CAPABILITIES.database_required);
    }
}

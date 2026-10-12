use tablepro_core::meta::ObjectKind;
use tablepro_core::{
    AuthMode, CommitResolutionSupport, DriverCapabilities, EndpointKind, EstimateQuality, ReadOnlyEnforcement,
    ScriptExecution, ServerNameOverride, TlsCapabilities, TlsMode, WriteAtomicity,
};

pub(crate) const DEFAULT_PORT: u16 = 5432;

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
    // Read-only is a property of each transaction the driver opens, which
    // a user's own SET TRANSACTION can still override.
    read_only: ReadOnlyEnforcement::SessionDefault,
    dml_writes: WriteAtomicity::Transactional,
    ddl_writes: WriteAtomicity::Transactional,
    script_execution: ScriptExecution::NativeBatch,
    commit_resolution: CommitResolutionSupport::ServerTransactionStatus,
    row_count_estimate: EstimateQuality::Statistics,
    object_kinds: &[
        ObjectKind::Table,
        ObjectKind::PartitionedTable,
        ObjectKind::View,
        ObjectKind::MaterializedView,
        ObjectKind::ForeignTable,
        ObjectKind::Sequence,
        ObjectKind::Function,
        ObjectKind::Procedure,
    ],
    database_required: false,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_match_driver_contract() {
        assert_eq!(CAPABILITIES.default_port(), Some(5432));
        assert!(CAPABILITIES.supports(AuthMode::Password));
        assert!(!CAPABILITIES.supports(AuthMode::Kerberos));
        let tls = CAPABILITIES.tls.expect("PostgreSQL offers TLS");
        assert_eq!(tls.modes.len(), 3);
        assert!(tls.ca_file && tls.client_identity);
        assert_eq!(tls.server_name_override, ServerNameOverride::AnyRoute);
        assert_eq!(CAPABILITIES.read_only, ReadOnlyEnforcement::SessionDefault);
        assert_eq!(CAPABILITIES.dml_writes, WriteAtomicity::Transactional);
        assert_eq!(CAPABILITIES.ddl_writes, WriteAtomicity::Transactional);
        assert_eq!(
            CAPABILITIES.commit_resolution,
            CommitResolutionSupport::ServerTransactionStatus
        );
        assert_eq!(CAPABILITIES.object_kinds.len(), 8);
        assert!(!CAPABILITIES.database_required);
    }
}

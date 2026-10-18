use tablepro_core::meta::ObjectKind;
use tablepro_core::{
    AuthMode, CommitResolutionSupport, DriverCapabilities, EndpointKind, EstimateQuality, ReadOnlyEnforcement,
    ScriptExecution, ServerNameOverride, TlsCapabilities, TlsMode, WriteAtomicity,
};

pub(crate) const DEFAULT_PORT: u16 = 3306;

pub(crate) static CAPABILITIES: DriverCapabilities = DriverCapabilities {
    endpoint: EndpointKind::Network {
        default_port: DEFAULT_PORT,
    },
    auth_modes: &[AuthMode::Password],
    tls: Some(TlsCapabilities {
        modes: &[TlsMode::Disable, TlsMode::Require, TlsMode::VerifyFull],
        ca_file: true,
        client_identity: true,
        // sqlx dials and verifies the same `host`, so a name other than
        // the one dialled can only be given where the dial goes to a
        // socket path instead.
        server_name_override: ServerNameOverride::SshForwardOnly,
    }),
    // A session default the user's own SET TRANSACTION can lift.
    read_only: ReadOnlyEnforcement::SessionDefault,
    // Row changes are transactional on InnoDB; every DDL statement
    // commits on its own.
    dml_writes: WriteAtomicity::Transactional,
    ddl_writes: WriteAtomicity::StatementByStatement,
    script_execution: ScriptExecution::NativeBatch,
    commit_resolution: CommitResolutionSupport::Unavailable,
    row_count_estimate: EstimateQuality::Statistics,
    object_kinds: &[
        ObjectKind::Table,
        ObjectKind::View,
        ObjectKind::Sequence,
        ObjectKind::Function,
        ObjectKind::Procedure,
    ],
    database_required: true,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_match_driver_contract() {
        assert_eq!(CAPABILITIES.default_port(), Some(3306));
        assert!(CAPABILITIES.supports(AuthMode::Password));
        assert!(!CAPABILITIES.supports(AuthMode::Kerberos));
        let tls = CAPABILITIES.tls.expect("MySQL offers TLS");
        assert_eq!(tls.modes.len(), 3);
        assert!(tls.ca_file && tls.client_identity);
        assert_eq!(tls.server_name_override, ServerNameOverride::SshForwardOnly);
        assert_eq!(CAPABILITIES.read_only, ReadOnlyEnforcement::SessionDefault);
        assert_eq!(CAPABILITIES.dml_writes, WriteAtomicity::Transactional);
        assert_eq!(CAPABILITIES.ddl_writes, WriteAtomicity::StatementByStatement);
        assert_eq!(CAPABILITIES.script_execution, ScriptExecution::NativeBatch);
        assert_eq!(CAPABILITIES.commit_resolution, CommitResolutionSupport::Unavailable);
        assert_eq!(CAPABILITIES.row_count_estimate, EstimateQuality::Statistics);
        assert_eq!(CAPABILITIES.object_kinds.len(), 5);
        assert!(CAPABILITIES.database_required);
    }
}

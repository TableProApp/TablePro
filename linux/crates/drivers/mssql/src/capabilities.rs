use tablepro_core::meta::ObjectKind;
use tablepro_core::{
    AuthMode, CommitResolutionSupport, DriverCapabilities, EndpointKind, EstimateQuality, ReadOnlyEnforcement,
    ScriptExecution, ServerNameOverride, TlsCapabilities, TlsMode, WriteAtomicity,
};

pub(crate) const DEFAULT_PORT: u16 = 1433;

/// Integrated login needs MIT Kerberos at build time, so a build without
/// it never offers the mode.
#[cfg(feature = "kerberos")]
const AUTH_MODES: &[AuthMode] = &[AuthMode::Password, AuthMode::Kerberos];
#[cfg(not(feature = "kerberos"))]
const AUTH_MODES: &[AuthMode] = &[AuthMode::Password];

pub(crate) static CAPABILITIES: DriverCapabilities = DriverCapabilities {
    endpoint: EndpointKind::Network {
        default_port: DEFAULT_PORT,
    },
    auth_modes: AUTH_MODES,
    // tiberius can present a client certificate, but SQL Server logins
    // are not authenticated by one, so there is nothing for it to prove.
    tls: Some(TlsCapabilities {
        modes: &[TlsMode::Disable, TlsMode::Require, TlsMode::VerifyFull],
        ca_file: true,
        client_identity: false,
        server_name_override: ServerNameOverride::AnyRoute,
    }),
    // SQL Server has no read-only session, so only the login's own
    // permissions hold a read-only connection to it.
    read_only: ReadOnlyEnforcement::LoginPrivileges,
    dml_writes: WriteAtomicity::Transactional,
    ddl_writes: WriteAtomicity::Transactional,
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
    database_required: false,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_modes_follow_kerberos_feature() {
        assert!(CAPABILITIES.supports(AuthMode::Password));
        assert_eq!(CAPABILITIES.supports(AuthMode::Kerberos), cfg!(feature = "kerberos"));
    }

    #[test]
    fn capabilities_match_driver_contract() {
        assert_eq!(CAPABILITIES.default_port(), Some(1433));
        let tls = CAPABILITIES.tls.expect("SQL Server offers TLS");
        assert_eq!(tls.modes.len(), 3);
        assert!(tls.ca_file);
        assert!(!tls.client_identity);
        assert_eq!(tls.server_name_override, ServerNameOverride::AnyRoute);
        assert_eq!(CAPABILITIES.read_only, ReadOnlyEnforcement::LoginPrivileges);
        assert_eq!(CAPABILITIES.dml_writes, WriteAtomicity::Transactional);
        assert_eq!(CAPABILITIES.ddl_writes, WriteAtomicity::Transactional);
        assert_eq!(CAPABILITIES.script_execution, ScriptExecution::NativeBatch);
        assert_eq!(CAPABILITIES.commit_resolution, CommitResolutionSupport::Unavailable);
        assert_eq!(CAPABILITIES.row_count_estimate, EstimateQuality::Statistics);
        assert_eq!(CAPABILITIES.object_kinds.len(), 5);
        assert!(!CAPABILITIES.database_required);
    }
}

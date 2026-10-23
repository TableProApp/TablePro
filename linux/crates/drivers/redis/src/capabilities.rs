use tablepro_core::meta::{KeyKind, ObjectKind};
use tablepro_core::{
    AuthMode, CommitResolutionSupport, DataModel, DriverCapabilities, EndpointKind, EstimateQuality,
    ReadOnlyEnforcement, ScriptExecution, ServerNameOverride, TlsCapabilities, TlsMode, WriteAtomicity,
};

pub(crate) const DEFAULT_PORT: u16 = 6379;

pub(crate) static CAPABILITIES: DriverCapabilities = DriverCapabilities {
    data_model: DataModel::KeyValue,
    endpoint: EndpointKind::Network {
        default_port: DEFAULT_PORT,
    },
    auth_modes: &[AuthMode::Password],
    // An empty username logs in as the default user, which is all a
    // server with only `requirepass` has.
    username_required: false,
    tls: Some(TlsCapabilities {
        modes: &[TlsMode::Disable, TlsMode::Require, TlsMode::VerifyFull],
        ca_file: true,
        client_identity: true,
        server_name_override: ServerNameOverride::AnyRoute,
    }),
    // Redis has no read-only session, so the driver refuses every command
    // its table does not list as a read before it is sent.
    read_only: ReadOnlyEnforcement::ClientGuard,
    // Commands land one at a time and MULTI/EXEC has no rollback.
    dml_writes: WriteAtomicity::StatementByStatement,
    ddl_writes: WriteAtomicity::StatementByStatement,
    script_execution: ScriptExecution::SingleStatement,
    commit_resolution: CommitResolutionSupport::Unavailable,
    row_count_estimate: EstimateQuality::ExactMetadata,
    object_kinds: &[
        ObjectKind::Key(KeyKind::String),
        ObjectKind::Key(KeyKind::Hash),
        ObjectKind::Key(KeyKind::List),
        ObjectKind::Key(KeyKind::Set),
        ObjectKind::Key(KeyKind::SortedSet),
        ObjectKind::Key(KeyKind::Stream),
        ObjectKind::Key(KeyKind::Other),
    ],
    database_required: false,
    network_options: &[],
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_match_driver_contract() {
        assert_eq!(CAPABILITIES.data_model, DataModel::KeyValue);
        assert_eq!(CAPABILITIES.default_port(), Some(6379));
        assert!(CAPABILITIES.supports(AuthMode::Password));
        assert!(!CAPABILITIES.supports(AuthMode::Kerberos));
        assert!(!CAPABILITIES.username_required);
        let tls = CAPABILITIES.tls.expect("Redis offers TLS");
        assert_eq!(tls.modes.len(), 3);
        assert!(tls.ca_file && tls.client_identity);
        assert_eq!(CAPABILITIES.read_only, ReadOnlyEnforcement::ClientGuard);
        assert_eq!(CAPABILITIES.script_execution, ScriptExecution::SingleStatement);
        assert_eq!(CAPABILITIES.commit_resolution, CommitResolutionSupport::Unavailable);
        assert!(CAPABILITIES.object_kinds.iter().all(|kind| kind.is_key()));
        assert!(!CAPABILITIES.database_required);
    }
}

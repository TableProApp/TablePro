use tablepro_core::meta::ObjectKind;
use tablepro_core::{
    CommitResolutionSupport, DriverCapabilities, EndpointKind, EstimateQuality, ReadOnlyEnforcement, ScriptExecution,
    WriteAtomicity,
};

/// A file with no login and no TLS. A read-only connection is opened
/// read-only, so SQLite itself refuses every write. Saves and schema
/// changes are one transaction each. A COMMIT never crosses a network,
/// so there is nothing to resolve afterwards.
pub(crate) static CAPABILITIES: DriverCapabilities = DriverCapabilities {
    endpoint: EndpointKind::File,
    auth_modes: &[],
    tls: None,
    read_only: ReadOnlyEnforcement::EngineEnforced,
    dml_writes: WriteAtomicity::Transactional,
    ddl_writes: WriteAtomicity::Transactional,
    script_execution: ScriptExecution::NativeBatch,
    commit_resolution: CommitResolutionSupport::Unavailable,
    row_count_estimate: EstimateQuality::Statistics,
    object_kinds: &[ObjectKind::Table, ObjectKind::View],
    database_required: false,
};

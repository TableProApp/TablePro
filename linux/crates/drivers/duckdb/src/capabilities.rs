use tablepro_core::meta::ObjectKind;
use tablepro_core::{
    CommitResolutionSupport, DriverCapabilities, EndpointKind, EstimateQuality, FileFormat, FileSignature,
    ReadOnlyEnforcement, ScriptExecution, StatementStop, WriteAtomicity,
};

/// Every database file carries `DUCK` eight bytes in, after a checksum.
/// The shared MIME database has no type for it, and an empty file is not
/// a database to DuckDB.
pub(crate) const FILE_FORMAT: FileFormat = FileFormat {
    signature: FileSignature {
        offset: 8,
        bytes: b"DUCK",
    },
    suffixes: &["duckdb", "ddb"],
    mime_types: &[],
    empty_file_is_database: false,
};

/// A file with no login and no TLS, opened read-only by DuckDB itself
/// when the connection is. Saves and schema changes are one transaction
/// each, and a COMMIT never crosses a network.
pub(crate) static CAPABILITIES: DriverCapabilities = DriverCapabilities {
    data_model: tablepro_core::DataModel::Relational,
    endpoint: EndpointKind::File(FILE_FORMAT),
    auth_modes: &[],
    username_required: false,
    tls: None,
    read_only: ReadOnlyEnforcement::EngineEnforced,
    dml_writes: WriteAtomicity::Transactional,
    ddl_writes: WriteAtomicity::Transactional,
    script_execution: ScriptExecution::NativeBatch,
    commit_resolution: CommitResolutionSupport::Unavailable,
    row_count_estimate: EstimateQuality::Statistics,
    object_kinds: &[ObjectKind::Table, ObjectKind::View],
    database_required: false,
    network_options: &[],
    statement_stop: StatementStop::Server,
};

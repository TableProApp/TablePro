use tablepro_core::meta::ObjectKind;
use tablepro_core::{
    CommitResolutionSupport, DriverCapabilities, EndpointKind, EstimateQuality, FileFormat, FileSignature,
    ReadOnlyEnforcement, ScriptExecution, StatementStop, WriteAtomicity,
};

/// A database file begins with this header, the shared MIME database
/// knows it by these types, and SQLite reads an empty file as an empty
/// database.
pub(crate) const FILE_FORMAT: FileFormat = FileFormat {
    signature: FileSignature {
        offset: 0,
        bytes: b"SQLite format 3\0",
    },
    suffixes: &["sqlite3", "sqlite", "db", "db3"],
    mime_types: &["application/vnd.sqlite3", "application/x-sqlite3"],
    empty_file_is_database: true,
};

/// A file with no login and no TLS. A read-only connection is opened
/// read-only, so SQLite itself refuses every write. Saves and schema
/// changes are one transaction each. A COMMIT never crosses a network,
/// so there is nothing to resolve afterwards.
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
    object_kinds: &[ObjectKind::Table, ObjectKind::View, ObjectKind::Trigger],
    database_required: false,
    network_options: &[],
    statement_stop: StatementStop::Server,
};

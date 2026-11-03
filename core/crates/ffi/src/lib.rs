//! The core as a library other languages load: one UniFFI API for the
//! control calls, and a C ABI for the grid's window fetch
//! (`core/docs/decisions/0002-uniffi-bindings.md`, `0003-result-windows-for-native-grids.md`).
//!
//! Every async export runs on the one runtime this library owns and is
//! aborted when the foreign side drops its future. Foreign code is
//! called only from a runtime thread and never under a lock.

mod cancel_token;
mod catalog;
mod connection_url;
mod core_handle;
#[cfg(windows)]
mod credential_manager;
mod drivers;
mod editor;
mod error;
mod host;
mod library;
mod results;
mod run;
mod runtime;
mod session;
mod syntax;
pub mod window_abi;

pub use cancel_token::CancelToken;
pub use catalog::{ColumnEntry, ObjectEntry, ObjectKindTag, ObjectScopeArg, SchemaEntry, TableName};
pub use connection_url::{ParsedConnectionUrl, parse_connection_url};
pub use core_handle::{Core, FileOpenRequest};
pub use drivers::{DataModelTag, DriverInfo, EndpointInfo, EngineCategoryTag};
pub use editor::{QueryEditor, RunSettings};
pub use error::{CoreError, ErrorInfo, ServerMessage};
pub use host::{HostConfig, HostSecretError, HostSecretStore, HostSecrets, SecretItemTag, SecretKindTag};
pub use library::{
    ConnectionLibrary, ConnectionRecord, ConnectionSecrets, GroupRecord, ImportSummary, LibrarySnapshot, SafeModeTag,
    SshAuthTag, SshSettings, TagRecord, TlsModeTag, TlsSettings,
};
pub use results::{ResultColumnInfo, ResultSet, ValueKind};
pub use run::{QueryRun, RunEvent, RunListener, RunOutcome, TransactionStateTag, TruncationTag};
pub use session::{ColumnSort, DatabaseSession, FailureCauseTag, SessionHealthTag, TableQuery};

uniffi::setup_scaffolding!();

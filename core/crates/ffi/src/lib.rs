// Foreign code is called only from a runtime thread, never under a lock (core/ARCHITECTURE.md, Bindings).

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
pub use error::{CoreError, ErrorInfo, ServerMessage, TlsFailureTag};
pub use host::{HostConfig, HostSecretError, HostSecretStore, HostSecrets, SecretItemTag, SecretKindTag};
pub use library::{
    ConnectionLibrary, ConnectionRecord, ConnectionSecrets, GroupRecord, ImportSummary, LibrarySnapshot, SafeModeTag,
    SshAuthTag, SshSettings, TagRecord, TlsModeTag, TlsSettings,
};
pub use results::{ResultColumnInfo, ResultSet, ValueKind};
pub use run::{QueryRun, RunEvent, RunListener, RunOutcome, TransactionStateTag, TruncationTag};
pub use session::{ColumnSort, DatabaseSession, FailureCauseTag, SessionHealthTag, TableQuery};

uniffi::setup_scaffolding!();

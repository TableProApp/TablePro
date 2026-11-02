//! The core as a library other languages load: one UniFFI API for the
//! control calls, and a C ABI for the grid's window fetch
//! (`core/docs/decisions/0002-uniffi-bindings.md`, `0003-result-windows-for-native-grids.md`).
//!
//! Every async export runs on the one runtime this library owns and is
//! aborted when the foreign side drops its future. Foreign code is
//! called only from a runtime thread and never under a lock.

mod cancel_token;
mod catalog;
mod core_handle;
mod drivers;
mod editor;
mod error;
mod host;
mod results;
mod run;
mod runtime;
mod session;
mod syntax;
pub mod window_abi;

pub use cancel_token::CancelToken;
pub use catalog::{ColumnEntry, ObjectEntry, ObjectKindTag, ObjectScopeArg, SchemaEntry, TableName};
pub use core_handle::{Core, FileOpenRequest};
pub use drivers::{DataModelTag, DriverInfo, EndpointInfo};
pub use editor::{QueryEditor, RunSettings};
pub use error::{CoreError, ErrorInfo, ServerMessage};
pub use host::{HostConfig, HostSecretError, HostSecretStore, HostSecrets, SecretItemTag, SecretKindTag};
pub use results::{ResultColumnInfo, ResultSet, ValueKind};
pub use run::{QueryRun, RunEvent, RunListener, RunOutcome, TruncationTag};
pub use session::DatabaseSession;

uniffi::setup_scaffolding!();

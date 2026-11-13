// Foreign code is called only from a runtime thread, never under a lock (core/ARCHITECTURE.md, Bindings).

mod account;
mod cancel_token;
mod catalog;
mod cloud;
mod connection_url;
mod core_handle;
#[cfg(windows)]
mod credential_manager;
#[cfg(any(windows, test))]
mod credential_parts;
mod definition;
mod drivers;
mod editor;
mod error;
mod export;
mod filter;
mod history;
mod host;
mod host_key;
mod library;
mod prompter;
mod results;
mod row_edits;
mod run;
mod runtime;
mod safe_mode_gate;
mod session;
mod statement_at;
mod structure;
mod syntax;
pub mod window_abi;

pub use account::{
    AccountConfig, AccountListener, AccountService, AccountStateTag, AccountStatusInfo, CreatedShareInfo, DeviceInfo,
    EntitlementProblemTag, FeatureAccessTag, HostBrowser, HostBrowserError, LicenseInfo, MembershipInfo, ProfileInfo,
    SecretHitInfo, SecretHitKindTag, ShareExpiryTag, ShareInfo, ShareKindTag, ShareLimitsInfo, SharePageInfo,
    ShareRequestArg, SharedLinkInfo, TeamInfo, scan_columns_for_secrets, scan_sql_for_secrets, share_token_from_link,
};
pub use cancel_token::CancelToken;
pub use catalog::{ColumnEntry, ObjectEntry, ObjectKindTag, ObjectScopeArg, SchemaEntry, TableName};
pub use cloud::{CloudConnectionFields, CloudGroupFields, CloudLibraryPull, CloudLibraryRecords};
pub use connection_url::{ParsedConnectionUrl, parse_connection_url};
pub use core_handle::{Core, FileOpenRequest};
pub use definition::ObjectSource;
pub use drivers::{DataModelTag, DriverInfo, EndpointInfo, EngineCategoryTag, ServerNameOverrideTag};
pub use editor::{QueryEditor, RunSettings};
pub use error::{BoxedErrorInfo, CoreError, ErrorInfo, HostKeyFailure, ServerMessage, TlsFailureTag};
pub use export::ExportFormatTag;
pub use filter::{
    CombinatorTag, FilterChoices, FilterColumn, FilterOpTag, FilterRuleArg, FilterValueArg, TableFilterArg,
};
pub use history::{
    HistoryCursorArg, HistoryEntryInfo, HistoryOutcomeTag, HistoryPageInfo, HistoryRun, QueryHistoryStore,
};
pub use host::{HostConfig, HostSecretError, HostSecretStore, HostSecrets, SecretItemTag, SecretKindTag};
pub use library::{
    ConnectionLibrary, ConnectionRecord, ConnectionSecrets, GroupRecord, ImportSummary, LibrarySnapshot, SafeModeTag,
    SshAuthTag, SshSettings, TagRecord, TlsModeTag, TlsSettings,
};
pub use prompter::{HostPrompter, PromptAnswer, PromptFieldInfo, PromptPurposeTag, PromptReasonTag, PromptRequest};
pub use results::{ResultColumnInfo, ResultSet, ValueKind};
pub use row_edits::{
    CellChange, CellEdit, EditColumnInfo, EditLock, EditStart, PlannedStatement, RowEdit, RowSave, RowSaveOutcome,
    SaveGate, TableEditor,
};
pub use run::{QueryRun, RunEvent, RunListener, RunOutcome, TransactionStateTag, TruncationTag};
pub use safe_mode_gate::RunGate;
pub use session::{ColumnSort, DatabaseSession, FailureCauseTag, RowEstimate, SessionHealthTag, TablePageRead};
pub use statement_at::StatementSpan;
pub use structure::{StructureColumn, StructureForeignKey, StructureIndex, TableStructure};

use secrecy::{ExposeSecret, SecretString};

uniffi::setup_scaffolding!();

// The app sees a String; here a lifted secret is wiped on drop. core/ARCHITECTURE.md, Bindings, lists what is not.
uniffi::custom_type!(SecretString, String, {
    remote,
    lower: |secret| secret.expose_secret().to_owned(),
    try_lift: |text| Ok(SecretString::from(text)),
});

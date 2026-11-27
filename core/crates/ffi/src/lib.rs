// Foreign code is called only from a runtime thread, never under a lock (core/ARCHITECTURE.md, Bindings).

mod account;
mod ai;
mod app_link;
mod cancel_token;
mod catalog;
mod catalog_change;
mod cloud;
pub mod command_line;
mod completion;
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
mod favourites;
mod filter;
mod foreign_import;
mod history;
mod host;
mod host_key;
mod host_stores;
mod import;
mod key_read;
mod keymap;
mod library;
mod library_contents;
mod library_details;
mod masking;
mod mcp;
mod prompter;
mod references;
mod results;
mod row_edits;
mod run;
mod runtime;
mod safe_mode_gate;
mod saved_queries;
mod saved_query_database;
mod session;
mod statement_at;
mod structure;
mod sync;
mod syntax;
mod table_folders;
#[cfg(test)]
mod test_session;
pub mod window_abi;

pub use account::{
    AccessTokenInfo, AccountConfig, AccountListener, AccountService, AccountStateTag, AccountStatusInfo, AppClientTag,
    CreatedShareInfo, DeviceInfo, EntitlementProblemTag, FeatureAccessTag, HostBrowser, HostBrowserError,
    HostWebAuthenticator, LicenseInfo, LicenseStateTag, ManagedPolicyArg, ManagedPolicyValues, MembershipInfo,
    PersonalSyncChoices, ProfileInfo, SecretHitInfo, SecretHitKindTag, ServerInfo, ServerLicenseInfo, ShareExpiryTag,
    ShareInfo, ShareKindTag, ShareLimitsInfo, SharePageInfo, ShareRequestArg, ShareTeamInfo, SharedLinkInfo,
    SignOutCauseTag, SyncProviderTag, TeamInfo, personal_sync_choices, scan_columns_for_secrets, scan_sql_for_secrets,
    settled_sync_provider, share_token_from_link,
};
pub use ai::{
    AiActionTag, AiAssistant, AiChatArg, AiConversationArg, AiConversationStart, AiFailureInfo, AiMessageArg,
    AiModelInfo, AiProviderInfo, AiProviderTag, AiReply, AiReplyEvent, AiReplyListener, AiRoleTag, AiSettingsArg,
    AiStopTag, ai_action_message, ai_address_is_valid, ai_host_of, ai_providers,
};
pub use app_link::{AppLinkInfo, parse_app_link};
pub use cancel_token::CancelToken;
pub use catalog::{ColumnEntry, ObjectEntry, ObjectKindTag, ObjectScopeArg, SchemaEntry, TableName};
pub use catalog_change::{
    CatalogAbilities, CatalogChange, CatalogChangeOutcome, CatalogOperation, CharacterSetInfo, DataCenterReplicas,
    DatabaseChoicesInfo, DatabaseDraftArg, DatabaseFieldsInfo, ReplicationArg,
};
pub use cloud::{CloudConnectionFields, CloudGroupFields, CloudLibraryPull, CloudLibraryRecords};
pub use completion::{
    CompletionItem, CompletionKindTag, CompletionList, CompletionPage, FormattedSql, MatchedSpan, format_sql,
    format_sql_selection,
};
pub use connection_url::{ParsedConnectionUrl, parse_connection_url};
pub use core_handle::{Core, FileOpenRequest};
pub use definition::ObjectSource;
pub use drivers::{DataModelTag, DriverInfo, EndpointInfo, EngineCategoryTag, ServerNameOverrideTag};
pub use editor::{QueryEditor, RunSettings};
pub use error::{BoxedErrorInfo, CoreError, ErrorInfo, HostKeyFailure, ServerMessage, TlsFailureTag};
pub use export::{ExportFormatTag, ExportProgress};
pub use favourites::{DatabaseEnvironmentTag, FavouriteDatabaseInfo, FavouriteStore, FavouriteTableInfo};
pub use filter::{
    CombinatorTag, FilterChoices, FilterColumn, FilterOpTag, FilterRuleArg, FilterValueArg, TableFilterArg,
};
pub use foreign_import::{
    ExistingConnectionInfo, ForeignAppDirsArg, ForeignAppTag, ForeignConnectionChoice, ForeignConnectionRow,
    ForeignImportChoices, ForeignImportOutcome, ForeignImportRequest, ForeignImportReview, ForeignQueryChoice,
    ForeignQueryRow, ForeignSourceInfo, ForeignSslModeTag, PasswordOfferTag, PasswordOutcomeTag, PasswordSourceTag,
    QueryAvailabilityTag, ResolutionTag, RowNoteInfo, SavedQuerySupportTag, ScanDepthTag, SourceAvailabilityTag,
    TlsFileReasonTag,
};
pub use history::{
    HistoryCursorArg, HistoryEntryInfo, HistoryExportFormat, HistoryFilterArg, HistoryFingerprintArg,
    HistoryOutcomeTag, HistoryPageInfo, HistoryRun, HistoryRunDetails, HistorySourceTag, HistoryStatusTag,
    QueryHistoryStore, StatementTypeTag,
};
pub use host::{HostConfig, HostSecretError, HostSecretStore, HostSecrets, SecretItemTag, SecretKindTag};
pub use host_stores::{
    FavouriteDatabaseKey, FavouriteDatabaseRecord, FavouriteDigestsRecord, FavouriteRecordWrite,
    FavouriteStoreContents, FavouriteTableRecord, HistoryDetailsRecord, HistoryEntryRecord, HistoryIdentityInfo,
    SavedQueryFolderRecord, SavedQueryRecord, SavedQueryRecordWrite, SavedQueryStoreContents, SavedQueryWriteOutcome,
    TableFolderRecordWrite, TableFolderStoreContents, TableKeyRecord, TablePlacementRecord,
};
pub use import::{
    CsvDelimiterTag, CsvImport, CsvImportCheck, CsvImportOutcome, CsvPreview, CsvReadOptions, CsvRowFault,
    ImportColumnInfo, LineSpan,
};
pub use key_read::{KeyKindTag, KeyReader, KeyTtlTag, KeyWindowInfo};
pub use keymap::{KeymapBindingInfo, KeymapPlatformTag, KeymapPresetInfo, keymap_preset, keymap_presets};
pub use library::{
    AiPolicyTag, ConnectionLibrary, ConnectionRecord, ConnectionSecrets, ExternalAccessTag, GroupRecord, ImportSummary,
    LibraryIconRecord, LibrarySnapshot, RemoteFileAccessTag, SafeModeTag, SshAuthTag, SshJumpAuthTag,
    SshJumpHostRecord, SshOptionsRecord, SshSettings, SshTotpAlgorithmTag, SshTotpModeTag, SshTotpRecord, TagRecord,
    TlsModeTag, TlsSettings, check_jump_hosts, jump_hosts_text, parse_jump_hosts,
};
pub use library_contents::{
    LibraryConnectionRecord, LibraryContents, LibraryWriteRecord, library_icon_for_symbol, library_icon_symbol,
};
pub use library_details::{
    CloudSqlAuthTag, CloudSqlProxyRecord, CloudflareAuthTag, CloudflareTunnelRecord, ConnectionDetailsRecord,
    CredentialPasswordRecord, CredentialProfileRecord, CredentialReferenceRecord, DeviceSettingsRecord,
    LocalPasswordSourceRecord, SocksProxyRecord, SshProfileRecord, SshRouteHopRecord, SshRouteRecord,
    SshRouteTargetRecord, TunnelCommandMethodTag, TunnelCommandRecord, VaultAuthRecord,
};
pub use masking::{
    MaskReason, MaskStyleTag, MaskSuggestionInfo, PersonalDataHitInfo, SensitiveKindTag, ShareColumnChoice,
    ShareColumnMasking, ShareRefusal, ShareSummary,
};
pub use mcp::{
    McpAppHost, McpListener, McpService, McpStatusTag, McpWriteRequest, SeenClientInfo, mcp_address, mcp_default_port,
};
pub use prompter::{HostPrompter, PromptAnswer, PromptFieldInfo, PromptPurposeTag, PromptReasonTag, PromptRequest};
pub use references::{FollowedReference, ReferenceRefusal, RowReferenceChoice, RowReferences, TableKeys};
pub use results::{CellBytes, CellTextHead, ResultColumnInfo, ResultSet, ValueKind};
pub use row_edits::{
    CellChange, CellEdit, EditColumnInfo, EditLock, EditStart, PlannedStatement, RowEdit, RowSave, RowSaveOutcome,
    SaveGate, TableEditor,
};
pub use run::{QueryRun, RunEvent, RunListener, RunOutcome, TransactionStateTag, TruncationTag};
pub use safe_mode_gate::RunGate;
pub use saved_queries::{SavedQueriesInfo, SavedQueryDraft, SavedQueryFolderInfo, SavedQueryInfo, SavedQueryStore};
pub use saved_query_database::{SavedQueryDatabaseStore, StoreFilesInfo};
pub use session::{
    ColumnSort, DatabaseLayoutTag, DatabaseSession, FailureCauseTag, PageResume, RowEstimate, SessionHealthTag,
    TableInfoRecord, TablePageRead,
};
pub use statement_at::StatementSpan;
pub use structure::{StructureColumn, StructureForeignKey, StructureIndex, TableStructure};
pub use sync::{
    AccountDeviceInfo, ApprovalRequestInfo, ApprovalSessionInfo, CloudKitAccount, CloudKitChanges, CloudKitDeletion,
    CloudKitFailure, CloudKitFetched, CloudKitField, CloudKitOutcome, CloudKitRecord, CloudKitTransport, CloudKitValue,
    ConflictChoiceTag, CredentialToRotateInfo, DeviceItemClassTag, DeviceItemTag, FingerprintInfo, GenesisOutcomeTag,
    HeldReasonTag, HeldRecordInfo, HeldRestartInfo, HostDeviceStore, HostLegacyMirror, HostSettings, KeyChangeInfo,
    KeyNoticeInfo, KeyNoticeKindTag, KeyStateInfo, KeyVersionStateTag, LegacyMetadataArg, LegacyRecordArg,
    LegacyStandingArg, LegacyStandingTag, LegacyTombstoneArg, LockCauseTag, MemberKeyStatusTag, MemberKeysInfo,
    MoveBackPlanInfo, MovePlanInfo, NewIdentityChoiceTag, NewIdentityPlanInfo, PassReasonTag, PendingApprovalInfo,
    PendingResetInfo, RecoveryKeyDraftInfo, RemovalReviewInfo, ResetKindTag, ResetStateTag, ReviewedDeviceInfo,
    ReviewedMemberInfo, RotationDraftInfo, ScopeStatusInfo, SessionEndTag, SessionPhaseTag, SessionRoleTag,
    SettingsCategoryArg, SignOutOutcomeTag, StopCauseTag, StoppedDeviceInfo, SyncCategoriesArg, SyncConfig,
    SyncFailureInfo, SyncListener, SyncPhaseTag, SyncPlatformTag, SyncRecordRef, SyncService, SyncStatusInfo,
    TeamConflictInfo, TeamKeysInfo, TeamRoleTag, device_item_class,
};
pub use sync::{
    TeamConnectionArg, TeamDeclinedArg, TeamFolderArg, TeamImportedEditArg, TeamLibraryImportArg, TeamLibraryItemInfo,
    TeamLibraryItemRef, TeamLibraryKindTag, TeamLibraryOwnerArg, TeamLibraryTeamInfo, TeamPublishInfo, TeamQueryArg,
    TeamScopeStatusInfo, UnsentTeamEditInfo, UnsentTeamEditTag,
};
pub use syntax::SqlGrammarTag;
pub use table_folders::{TableFolderItemRecord, TableFolderRecord, TableFolderStore, TableRefRecord};

use secrecy::{ExposeSecret, SecretString};

uniffi::setup_scaffolding!();

// The app sees a String; here a lifted secret is wiped on drop. core/ARCHITECTURE.md, Bindings, lists what is not.
uniffi::custom_type!(SecretString, String, {
    remote,
    lower: |secret| secret.expose_secret().to_owned(),
    try_lift: |text| Ok(SecretString::from(text)),
});

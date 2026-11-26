// The sync surface the apps call (core ADRs 0054 and 0056): `SyncService`, its listener, and the callbacks the
// apps implement, and Team Library over the engine. Its bodies answer `sync.unimplemented` until the engine and key
// lanes fill them.

mod cloudkit;
mod host;
mod keys;
mod legacy;
mod service;
mod team_library;

pub use cloudkit::{
    CloudKitAccount, CloudKitChanges, CloudKitDeletion, CloudKitFailure, CloudKitFetched, CloudKitField,
    CloudKitOutcome, CloudKitRecord, CloudKitTransport, CloudKitValue,
};
pub use host::{
    DeviceItemClassTag, DeviceItemTag, HostDeviceStore, HostSettings, SettingsCategoryArg, device_item_class,
};
pub use keys::{
    AccountDeviceInfo, ApprovalRequestInfo, ApprovalSessionInfo, FingerprintInfo, GenesisOutcomeTag, HeldRestartInfo,
    KeyChangeInfo, KeyNoticeInfo, KeyNoticeKindTag, KeyStateInfo, KeyVersionStateTag, LockCauseTag, MemberKeyStatusTag,
    MemberKeysInfo, PendingResetInfo, RecoveryKeyDraftInfo, RemovalReviewInfo, ResetKindTag, ResetStateTag,
    ReviewedDeviceInfo, ReviewedMemberInfo, RotationDraftInfo, SessionEndTag, SessionPhaseTag, SessionRoleTag,
    SignOutOutcomeTag, StopCauseTag, StoppedDeviceInfo, TeamKeysInfo, TeamRoleTag,
};
pub use legacy::{
    HostLegacyMirror, LegacyMetadataArg, LegacyRecordArg, LegacyStandingArg, LegacyStandingTag, LegacyTombstoneArg,
};
pub use service::{
    ConflictChoiceTag, HeldReasonTag, HeldRecordInfo, MoveBackPlanInfo, MovePlanInfo, NewIdentityChoiceTag,
    PassReasonTag, PendingApprovalInfo, SyncCategoriesArg, SyncConfig, SyncFailureInfo, SyncListener, SyncPhaseTag,
    SyncPlatformTag, SyncRecordRef, SyncService, SyncStatusInfo, TeamConflictInfo,
};
pub use team_library::{
    TeamConnectionArg, TeamDeclinedArg, TeamFolderArg, TeamImportedEditArg, TeamLibraryImportArg, TeamLibraryItemInfo,
    TeamLibraryItemRef, TeamLibraryKindTag, TeamLibraryOwnerArg, TeamLibraryTeamInfo, TeamPublishInfo, TeamQueryArg,
    TeamScopeStatusInfo, UnsentTeamEditInfo, UnsentTeamEditTag,
};

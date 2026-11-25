// The sync surface the apps call (core ADRs 0054 and 0056): `SyncService`, its listener, and the callbacks the
// apps implement. Its bodies answer `sync.unimplemented` until the engine and key lanes fill them.

mod cloudkit;
mod host;
mod keys;
mod service;

pub use cloudkit::{
    CloudKitAccount, CloudKitChanges, CloudKitDeletion, CloudKitFailure, CloudKitFetched, CloudKitField,
    CloudKitOutcome, CloudKitRecord, CloudKitTransport, CloudKitValue,
};
pub use host::{
    DeviceItemClassTag, DeviceItemTag, HostDeviceStore, HostSettings, SettingsCategoryArg, device_item_class,
};
pub use keys::{
    AccountDeviceInfo, ApprovalRequestInfo, ApprovalSessionInfo, FingerprintInfo, GenesisOutcomeTag, KeyNoticeInfo,
    KeyNoticeKindTag, KeyStateInfo, KeyVersionStateTag, LockCauseTag, MemberKeyStatusTag, MemberKeysInfo,
    PendingResetInfo, RecoveryKeyDraftInfo, RemovalReviewInfo, ResetKindTag, ResetStateTag, ReviewedDeviceInfo,
    ReviewedMemberInfo, SessionEndTag, SessionPhaseTag, SessionRoleTag, SignOutOutcomeTag, StopCauseTag, TeamKeysInfo,
    TeamRoleTag,
};
pub use service::{
    ConflictChoiceTag, HeldReasonTag, HeldRecordInfo, MoveBackPlanInfo, MovePlanInfo, NewIdentityChoiceTag,
    PassReasonTag, PendingApprovalInfo, SyncConfig, SyncListener, SyncPhaseTag, SyncPlatformTag, SyncRecordRef,
    SyncService, SyncStatusInfo, TeamConflictInfo,
};

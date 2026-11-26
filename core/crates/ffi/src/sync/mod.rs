// The sync surface the apps call (core ADRs 0054 and 0056): `SyncService` over the engine, its listener, and the
// callbacks the apps implement.

mod cloudkit;
mod engines;
mod events;
mod host;
mod key_records;
mod keys;
mod legacy;
mod names;
mod open;
mod service;
mod service_records;
#[cfg(test)]
mod tests;

pub use cloudkit::{
    CloudKitAccount, CloudKitChanges, CloudKitDeletion, CloudKitFailure, CloudKitFetched, CloudKitField,
    CloudKitOutcome, CloudKitRecord, CloudKitTransport, CloudKitValue,
};
pub use host::{
    DeviceItemClassTag, DeviceItemTag, HostDeviceStore, HostSettings, SettingsCategoryArg, device_item_class,
};
#[cfg(windows)]
pub(crate) use host::{device_item_target, device_store_error};
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
    PassReasonTag, PendingApprovalInfo, ScopeStatusInfo, SyncCategoriesArg, SyncConfig, SyncFailureInfo, SyncListener,
    SyncPhaseTag, SyncPlatformTag, SyncRecordRef, SyncService, SyncStatusInfo, TeamConflictInfo,
};

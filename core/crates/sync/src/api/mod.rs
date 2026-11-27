// The contracts the engine, the transports, the key flows and the FFI build against (0051, 0054, 0056).

pub mod adapter;
pub mod cloudkit;
pub mod control;
pub mod device_store;
pub mod error;
pub mod ids;
pub mod key_flows;
pub mod legacy;
pub mod scopes;
pub mod state;
pub mod team_library;
pub mod transport;

pub use adapter::{
    HostSettings, LocalChange, LocalRecord, LocalRecords, PulledWriter, RecordAdapter, SettingsDocument, StoreStamp,
};
pub use cloudkit::{
    CloudKitAccount, CloudKitChanges, CloudKitDeletion, CloudKitFailure, CloudKitFetched, CloudKitField,
    CloudKitOutcome, CloudKitRecord, CloudKitTransport, CloudKitValue,
};
pub use control::SyncControl;
pub use device_store::{DeviceItem, DeviceItemClass, DeviceStoreError, HostDeviceStore};
pub use error::{AdapterError, StateError, SyncError};
pub use ids::{
    ChangeTag, Cursor, DeviceRowId, EpochId, FileId, IdempotencyKey, KindName, RecordKey, ScopeName, StateName,
};
pub use key_flows::{
    AccountFlows, ApprovalFlows, DeviceFlows, KeyFlows, KeyHooks, ResetFlows, RestoreFlows, StopFlows, TeamFlows,
};
pub use legacy::{LegacyMetadata, LegacyMirror};
pub use scopes::{ScopeInfo, ScopesAnswer, ScopesBody};
pub use state::{Row, RowKey, RowRange, StateFiles, StateStore, StateTxn, Table};
pub use team_library::{
    FacadeBase, ImportedEdit, SignInGuard, TeamConnection, TeamFolder, TeamItem, TeamItemRef, TeamLibraryControl,
    TeamLibraryError, TeamLibraryImport, TeamLibraryPolicy, TeamLibraryTeam, TeamPublish, TeamQuery, TeamScopeStatus,
    UnsentState, UnsentTeamEdit,
};
pub use transport::{
    Change, ChangeOp, ChangeOutcome, DpopKey, Proof, PullRequest, PulledPage, PulledRecord, PushAnswer, PushBatch,
    RejectedCode, ServiceTransport, Transport, TransportError,
};

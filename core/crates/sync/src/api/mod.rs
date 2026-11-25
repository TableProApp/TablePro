// The contracts the engine, the transports, the key flows and the FFI build against (0051, 0054, 0056).

pub mod adapter;
pub mod cloudkit;
pub mod control;
pub mod device_store;
pub mod error;
pub mod ids;
pub mod key_flows;
pub mod scopes;
pub mod state;
pub mod transport;

pub use adapter::{HostSettings, LocalChange, LocalRecord, LocalRecords, RecordAdapter, SettingsDocument, StoreStamp};
pub use cloudkit::{
    CloudKitAccount, CloudKitChanges, CloudKitDeletion, CloudKitFailure, CloudKitFetched, CloudKitField,
    CloudKitOutcome, CloudKitRecord, CloudKitTransport, CloudKitValue,
};
pub use control::SyncControl;
pub use device_store::{DeviceItem, DeviceItemClass, DeviceStoreError, HostDeviceStore};
pub use error::{AdapterError, StateError, SyncError};
pub use ids::{ChangeTag, Cursor, DeviceRowId, EpochId, FileId, IdempotencyKey, KindName, RecordKey, ScopeName};
pub use key_flows::{
    AccountFlows, ApprovalFlows, DeviceFlows, KeyFlows, KeyHooks, ResetFlows, RestoreFlows, StopFlows, TeamFlows,
};
pub use scopes::{ScopeInfo, ScopesAnswer, ScopesBody};
pub use state::{Row, RowKey, RowRange, StateFiles, StateStore, StateTxn, Table};
pub use transport::{
    Change, ChangeOp, ChangeOutcome, DpopKey, Proof, PullRequest, PulledPage, PulledRecord, PushAnswer, PushBatch,
    RejectedCode, ServiceTransport, Transport, TransportError,
};

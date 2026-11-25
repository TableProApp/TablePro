// The end-to-end flows of 0056 over the `api` contracts. `KeyService` is the one type the K7 lanes implement
// `api::key_flows`'s traits on, each in its own files: K7-1 `account*`, `pins*` and `personal*`; K7-2 `approval*`,
// `reset*` and `rotation*`; K7-3 `team*`; K7-4 `restore*` and `stop*`. What every lane shares sits here: the parts
// the service runs on, the drafts a flow keeps between two calls, and the key objects the state file holds.

mod account;
mod account_flows;
pub mod personal;
pub mod pins;

use std::any::Any;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use tablepro_keys::body::KeyObject;
use tablepro_keys::encoding::{AccountId, Origin, random_uuid};
use tablepro_keys::record_id::KeyKind;
use tokio::sync::Mutex as AsyncMutex;

use crate::api::device_store::HostDeviceStore;
use crate::api::error::SyncError;
use crate::api::ids::{DeviceRowId, ScopeName};
use crate::api::key_flows::{DraftId, KeyHooks};
use crate::api::state::{StateStore, StateTxn};
use crate::api::transport::{Change, ChangeOutcome, DpopKey, ServiceTransport};

pub use account::{AccountObjectsPlan, HeldDeviceKeys, KeptDevice, OwnAccount};
pub use personal::{CurrentPersonal, ScopeKeyPlan};
pub use pins::{IkStanding, PinChange};

// Microseconds since the Unix epoch in UTC, as the service's times are (0051, Pull).
pub trait Clock: Send + Sync {
    fn now_us(&self) -> i64;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_us(&self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| i64::try_from(since.as_micros()).unwrap_or(i64::MAX))
    }
}

// What a `KeyService` runs on, for one (origin, account, device row) on TablePro Sync.
pub struct KeyServiceParts {
    pub origin: Origin,
    pub account: AccountId,
    pub device_row: DeviceRowId,
    pub state: Arc<dyn StateStore>,
    pub device_store: Arc<dyn HostDeviceStore>,
    pub transport: Arc<dyn ServiceTransport>,
    pub hooks: Arc<dyn KeyHooks>,
    pub clock: Arc<dyn Clock>,
}

pub struct KeyService {
    origin: Origin,
    account: AccountId,
    device_row: DeviceRowId,
    state: Arc<dyn StateStore>,
    device_store: Arc<dyn HostDeviceStore>,
    transport: Arc<dyn ServiceTransport>,
    hooks: Arc<dyn KeyHooks>,
    clock: Arc<dyn Clock>,
    drafts: Drafts,
    // One key flow or `apply_*` call changes the key tables at a time.
    serial: AsyncMutex<()>,
}

impl KeyService {
    pub fn new(parts: KeyServiceParts) -> Self {
        Self {
            origin: parts.origin,
            account: parts.account,
            device_row: parts.device_row,
            state: parts.state,
            device_store: parts.device_store,
            transport: parts.transport,
            hooks: parts.hooks,
            clock: parts.clock,
            drafts: Drafts::default(),
            serial: AsyncMutex::new(()),
        }
    }

    pub fn origin(&self) -> &Origin {
        &self.origin
    }

    pub fn account(&self) -> AccountId {
        self.account
    }

    pub fn device_row(&self) -> &DeviceRowId {
        &self.device_row
    }

    pub fn state(&self) -> &Arc<dyn StateStore> {
        &self.state
    }

    pub fn device_store(&self) -> &Arc<dyn HostDeviceStore> {
        &self.device_store
    }

    pub fn transport(&self) -> &Arc<dyn ServiceTransport> {
        &self.transport
    }

    pub fn hooks(&self) -> &Arc<dyn KeyHooks> {
        &self.hooks
    }

    pub fn now_us(&self) -> i64 {
        self.clock.now_us()
    }

    pub fn drafts(&self) -> &Drafts {
        &self.drafts
    }

    // Held for the whole of a flow or an `apply_*` call, so two never interleave their reads and writes.
    pub async fn serialized(&self) -> tokio::sync::MutexGuard<'_, ()> {
        self.serial.lock().await
    }

    pub async fn begin(&self) -> Result<Box<dyn StateTxn>, SyncError> {
        Ok(self.state.begin().await?)
    }

    // A key object at its id in a scope, as `key_objects` holds it.
    pub async fn held_object(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        kind: KeyKind,
        record_id: &str,
    ) -> Result<Option<HeldObject>, SyncError> {
        let _ = (txn, scope, kind, record_id);
        Err(SyncError::unimplemented("keys.held_object"))
    }

    // Every key object of one kind in a scope, in record id order.
    pub async fn held_objects(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        kind: KeyKind,
    ) -> Result<Vec<HeldObject>, SyncError> {
        let _ = (txn, scope, kind);
        Err(SyncError::unimplemented("keys.held_objects"))
    }

    // Keeps a key object served or written. Every key kind is create-only: another object at the id of an applied one
    // is `keys.conflict`, while this device's own candidate gives way to what the server serves (0054, `key_objects`).
    pub async fn hold_object(
        &self,
        txn: &mut dyn StateTxn,
        scope: ScopeName,
        object: &KeyObject,
        applied: bool,
    ) -> Result<(), SyncError> {
        let _ = (txn, scope, object, applied);
        Err(SyncError::unimplemented("keys.hold_object"))
    }

    // One change set as one push, applied whole or not at all (0051, Change sets), under the epoch the scope holds.
    pub async fn push_change_set(
        &self,
        scope: ScopeName,
        changes: Vec<Change>,
        proof: DpopKey,
    ) -> Result<Vec<ChangeOutcome>, SyncError> {
        let _ = (scope, changes, proof);
        Err(SyncError::unimplemented("keys.push_change_set"))
    }
}

// A key object as `key_objects` holds it: parsed, with the exact `fields` text and whether it is in force.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeldObject {
    pub object: KeyObject,
    pub fields: String,
    pub applied: bool,
}

// The create change of a key object: no base, its `fields` as the patch (0051, Push).
pub fn create_change(object: &KeyObject) -> Result<Change, SyncError> {
    let _ = object;
    Err(SyncError::unimplemented("keys.create_change"))
}

// What a flow keeps between two calls, by draft id: a recovery key shown and not yet typed back, a review, a session.
// Each lane stores its own type and takes it back by the same type; another type at the id is `sync.unknown`.
#[derive(Default)]
pub struct Drafts {
    held: Mutex<HashMap<DraftId, Box<dyn Any + Send>>>,
}

impl Drafts {
    fn lock(&self) -> MutexGuard<'_, HashMap<DraftId, Box<dyn Any + Send>>> {
        self.held.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn put<T: Any + Send>(&self, value: T) -> Result<DraftId, SyncError> {
        let id = DraftId(random_uuid()?);
        self.lock().insert(id, Box::new(value));
        Ok(id)
    }

    pub fn take<T: Any + Send>(&self, id: DraftId) -> Result<T, SyncError> {
        let mut held = self.lock();
        if !held.get(&id).is_some_and(|value| value.is::<T>()) {
            return Err(SyncError::Unknown { what: "draft" });
        }
        held.remove(&id)
            .and_then(|value| value.downcast::<T>().ok())
            .map(|value| *value)
            .ok_or(SyncError::Unknown { what: "draft" })
    }

    // Runs `f` on the draft in place, leaving it held.
    pub fn with<T: Any + Send, R>(&self, id: DraftId, f: impl FnOnce(&mut T) -> R) -> Result<R, SyncError> {
        let mut held = self.lock();
        let value = held
            .get_mut(&id)
            .and_then(|value| value.downcast_mut::<T>())
            .ok_or(SyncError::Unknown { what: "draft" })?;
        Ok(f(value))
    }

    pub fn remove(&self, id: DraftId) {
        self.lock().remove(&id);
    }
}

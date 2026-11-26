// A device store as 0054 and 0056 describe the platforms' (Integrity and freshness; Device stores): items of the
// anchor's class read only while the device is unlocked and go when the passcode is turned off; a backup brings keys
// back only to the same device and never brings the anchor back.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tablepro_sync::api::device_store::{DeviceItem, DeviceItemClass, DeviceStoreError, HostDeviceStore};
use zeroize::Zeroizing;

#[derive(Debug, Default)]
struct State {
    items: HashMap<DeviceItem, Zeroizing<Vec<u8>>>,
    locked: bool,
    unavailable: bool,
    // The host declares no store at all.
    absent: bool,
    fail_next: Vec<DeviceStoreError>,
}

#[derive(Debug, Default)]
pub struct FakeDeviceStore {
    state: Mutex<State>,
}

// What a device backup holds of the store.
#[derive(Debug, Clone)]
pub struct DeviceBackup(HashMap<DeviceItem, Zeroizing<Vec<u8>>>);

impl FakeDeviceStore {
    pub fn new() -> Self {
        Self::default()
    }

    // A Linux session with no Secret Service.
    pub fn without_store() -> Self {
        let store = Self::default();
        store.lock().unavailable = true;
        store.lock().absent = true;
        store
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn set_locked(&self, locked: bool) {
        self.lock().locked = locked;
    }

    // Turning the passcode off deletes every item of the anchor's class.
    pub fn remove_passcode(&self) {
        self.lock()
            .items
            .retain(|item, _| item.class() != DeviceItemClass::Anchor);
    }

    pub fn fail_next(&self, error: DeviceStoreError) {
        self.lock().fail_next.push(error);
    }

    pub fn holds(&self, item: &DeviceItem) -> bool {
        self.lock().items.contains_key(item)
    }

    pub fn len(&self) -> usize {
        self.lock().items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn backup(&self) -> DeviceBackup {
        DeviceBackup(
            self.lock()
                .items
                .iter()
                .filter(|(item, _)| item.class() == DeviceItemClass::Keys)
                .map(|(item, value)| (item.clone(), value.clone()))
                .collect(),
        )
    }

    // A restore puts the keys back on the device they were backed up from, and nothing on another device.
    pub fn restore(&self, backup: &DeviceBackup, same_device: bool) {
        let mut state = self.lock();
        state.items.clear();
        if same_device {
            state
                .items
                .extend(backup.0.iter().map(|(item, value)| (item.clone(), value.clone())));
        }
    }

    fn admit(&self, item: &DeviceItem) -> Result<MutexGuard<'_, State>, DeviceStoreError> {
        let mut state = self.lock();
        if !state.fail_next.is_empty() {
            return Err(state.fail_next.remove(0));
        }
        if state.unavailable {
            return Err(DeviceStoreError::Unavailable {
                detail: "no secret service".to_owned(),
            });
        }
        if state.locked && item.class() == DeviceItemClass::Anchor {
            return Err(DeviceStoreError::Locked);
        }
        Ok(state)
    }
}

#[async_trait]
impl HostDeviceStore for FakeDeviceStore {
    async fn load(&self, item: DeviceItem) -> Result<Option<Zeroizing<Vec<u8>>>, DeviceStoreError> {
        let state = self.admit(&item)?;
        Ok(state.items.get(&item).cloned())
    }

    async fn store(&self, item: DeviceItem, value: Zeroizing<Vec<u8>>) -> Result<(), DeviceStoreError> {
        let mut state = self.admit(&item)?;
        state.items.insert(item, value);
        Ok(())
    }

    async fn delete(&self, item: DeviceItem) -> Result<(), DeviceStoreError> {
        let mut state = self.admit(&item)?;
        state.items.remove(&item);
        Ok(())
    }

    fn present(&self) -> bool {
        !self.lock().absent
    }
}

#[cfg(test)]
mod tests {
    use tablepro_keys::encoding::{AccountId, Origin, Version};
    use tablepro_sync::api::ids::{DeviceRowId, StateName};
    use uuid::Uuid;

    use super::*;

    fn keys() -> DeviceItem {
        DeviceItem::AccountKeys {
            origin: Origin::parse("https://api.tablepro.app").unwrap(),
            account: AccountId(Uuid::nil()),
            av: Version::new(1).unwrap(),
        }
    }

    fn device_keys() -> DeviceItem {
        DeviceItem::DeviceKeys {
            origin: Origin::parse("https://api.tablepro.app").unwrap(),
            account: AccountId(Uuid::nil()),
            device_row: DeviceRowId("dev_a".to_owned()),
        }
    }

    fn anchor() -> DeviceItem {
        DeviceItem::AnchorRoot {
            state: StateName("ab".repeat(32)),
        }
    }

    async fn filled() -> FakeDeviceStore {
        let store = FakeDeviceStore::new();
        for item in [keys(), device_keys(), anchor()] {
            store.store(item, Zeroizing::new(vec![1, 2])).await.unwrap();
        }
        store
    }

    #[tokio::test]
    async fn a_locked_device_reads_its_keys_but_not_its_anchor() {
        let store = filled().await;

        store.set_locked(true);

        assert!(store.load(keys()).await.unwrap().is_some());
        assert_eq!(store.load(anchor()).await.unwrap_err(), DeviceStoreError::Locked);
    }

    #[tokio::test]
    async fn turning_the_passcode_off_deletes_the_anchor_and_keeps_the_keys() {
        let store = filled().await;

        store.remove_passcode();

        assert!(!store.holds(&anchor()));
        assert!(store.holds(&keys()) && store.holds(&device_keys()));
    }

    #[tokio::test]
    async fn a_backup_restores_keys_to_the_same_device_and_never_the_anchor() {
        let store = filled().await;
        let backup = store.backup();

        store.restore(&backup, true);
        let same = (store.holds(&keys()), store.holds(&anchor()));
        store.restore(&backup, false);

        assert_eq!(same, (true, false));
        assert!(store.is_empty());
    }

    #[tokio::test]
    async fn a_device_without_a_store_holds_nothing() {
        let store = FakeDeviceStore::without_store();

        let stored = store.store(keys(), Zeroizing::new(vec![1])).await;

        assert!(matches!(stored, Err(DeviceStoreError::Unavailable { .. })));
    }

    #[tokio::test]
    async fn deleting_an_item_that_is_not_there_succeeds() {
        let store = FakeDeviceStore::new();

        store.delete(keys()).await.unwrap();
        store.store(keys(), Zeroizing::new(vec![1])).await.unwrap();
        store.delete(keys()).await.unwrap();

        assert!(store.load(keys()).await.unwrap().is_none());
    }
}

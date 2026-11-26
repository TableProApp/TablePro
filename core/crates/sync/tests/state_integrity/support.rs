// A device store that keeps a copy of itself after every write, so a test can stop a commit at any step, and helpers
// that copy and restore a state file the way a backup does.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use tablepro_keys::encoding::{AccountId, Origin};
use tablepro_sync::api::device_store::{DeviceItem, DeviceStoreError, HostDeviceStore};
use tablepro_sync::api::ids::DeviceRowId;
use tablepro_sync::api::state::{Row, RowKey, RowRange, StateFiles, StateIdentity, StateStore, Table};
use tablepro_sync::state::SqliteStateFiles;
use uuid::Uuid;
use zeroize::Zeroizing;

pub type Items = HashMap<DeviceItem, Zeroizing<Vec<u8>>>;

#[derive(Default)]
struct Inner {
    items: Items,
    recording: Option<Vec<Items>>,
    locked: bool,
    // A Linux session with no Secret Service.
    unavailable: bool,
    fail_mac_key_write: bool,
    // Fails the nth root write from now, counting from 1.
    fail_root_write: Option<usize>,
}

impl Inner {
    fn admit(&self) -> Result<(), DeviceStoreError> {
        if self.unavailable {
            return Err(DeviceStoreError::Unavailable {
                detail: "no secret service".to_owned(),
            });
        }
        if self.locked {
            return Err(DeviceStoreError::Locked);
        }
        Ok(())
    }
}

#[derive(Default)]
pub struct Store(Mutex<Inner>);

impl Store {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn items(&self) -> Items {
        self.lock().items.clone()
    }

    pub fn set_items(&self, items: Items) {
        self.lock().items = items;
    }

    pub fn set_locked(&self, locked: bool) {
        self.lock().locked = locked;
    }

    pub fn set_unavailable(&self, unavailable: bool) {
        self.lock().unavailable = unavailable;
    }

    pub fn fail_mac_key_write(&self) {
        self.lock().fail_mac_key_write = true;
    }

    pub fn fail_root_write(&self, nth: usize) {
        self.lock().fail_root_write = Some(nth);
    }

    // Copies of the store after each write from now on, until `recorded`.
    pub fn record(&self) {
        let mut inner = self.lock();
        let start = inner.items.clone();
        inner.recording = Some(vec![start]);
    }

    pub fn recorded(&self) -> Vec<Items> {
        self.lock().recording.take().unwrap_or_default()
    }

    pub fn count(&self, matches: impl Fn(&DeviceItem) -> bool) -> usize {
        self.lock().items.keys().filter(|item| matches(item)).count()
    }

    // Turning the passcode off deletes every item of the anchor's class.
    pub fn remove_passcode(&self) {
        self.lock()
            .items
            .retain(|item, _| item.class() != tablepro_sync::api::device_store::DeviceItemClass::Anchor);
    }

    fn change(&self, item: &DeviceItem, apply: impl FnOnce(&mut Items)) -> Result<(), DeviceStoreError> {
        let mut inner = self.lock();
        inner.admit()?;
        if matches!(item, DeviceItem::StateMacKey { .. }) && inner.fail_mac_key_write {
            inner.fail_mac_key_write = false;
            return Err(DeviceStoreError::Failed {
                detail: "MAC key write failed".to_owned(),
            });
        }
        if matches!(item, DeviceItem::AnchorRoot { .. })
            && let Some(nth) = inner.fail_root_write
        {
            if nth <= 1 {
                inner.fail_root_write = None;
                return Err(DeviceStoreError::Failed {
                    detail: "root write failed".to_owned(),
                });
            }
            inner.fail_root_write = Some(nth - 1);
        }
        apply(&mut inner.items);
        let copy = inner.items.clone();
        if let Some(recording) = inner.recording.as_mut() {
            recording.push(copy);
        }
        Ok(())
    }
}

#[async_trait]
impl HostDeviceStore for Store {
    async fn load(&self, item: DeviceItem) -> Result<Option<Zeroizing<Vec<u8>>>, DeviceStoreError> {
        let inner = self.lock();
        inner.admit()?;
        Ok(inner.items.get(&item).cloned())
    }

    async fn store(&self, item: DeviceItem, value: Zeroizing<Vec<u8>>) -> Result<(), DeviceStoreError> {
        self.change(&item, |items| {
            items.insert(item.clone(), value);
        })
    }

    async fn delete(&self, item: DeviceItem) -> Result<(), DeviceStoreError> {
        self.change(&item, |items| {
            items.remove(&item);
        })
    }
}

pub fn is_root(item: &DeviceItem) -> bool {
    matches!(item, DeviceItem::AnchorRoot { .. })
}

pub fn is_checkpoint(item: &DeviceItem) -> bool {
    matches!(item, DeviceItem::AnchorCheckpoint { .. })
}

pub fn origin() -> Origin {
    Origin::parse("https://sync.example.com").unwrap()
}

pub fn account() -> AccountId {
    AccountId(Uuid::from_u128(0x6f1c_2a9e_0b4d_4c8e_9a51_3d7e_2b1f_0c01))
}

pub fn identity() -> StateIdentity {
    StateIdentity::Service {
        origin: origin(),
        sign_in: "sign-in".to_owned(),
        account: account(),
        device_row: DeviceRowId("dev_mac".to_owned()),
    }
}

pub fn icloud() -> StateIdentity {
    StateIdentity::ICloud {
        user_record_name: "_4e2a".to_owned(),
    }
}

// One device's state files over a folder and a device store, which a restart keeps.
pub struct Disk {
    _dir: tempfile::TempDir,
    pub store: Arc<Store>,
    pub files: SqliteStateFiles,
}

impl Disk {
    pub fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new();
        let files = SqliteStateFiles::at(dir.path().to_path_buf(), Arc::clone(&store) as Arc<dyn HostDeviceStore>);
        Self {
            _dir: dir,
            store,
            files,
        }
    }

    pub async fn open(&self) -> Arc<dyn StateStore> {
        self.files.open(identity()).await.unwrap()
    }

    pub async fn open_as(&self, identity: &StateIdentity) -> Arc<dyn StateStore> {
        self.files.open(identity.clone()).await.unwrap()
    }

    pub fn path(&self, identity: &StateIdentity) -> PathBuf {
        self.files.path(identity)
    }

    // The file as a backup copies it, once no store holds it.
    pub async fn copy(&self, identity: &StateIdentity) -> Vec<u8> {
        self.files.release(identity).await.unwrap();
        std::fs::read(self.path(identity)).unwrap()
    }

    // Puts a copy back, as a restore does, over whatever the folder holds.
    pub async fn restore(&self, identity: &StateIdentity, copy: &[u8]) {
        self.files.release(identity).await.unwrap();
        let path = self.path(identity);
        remove_wal(&path);
        std::fs::write(&path, copy).unwrap();
    }

    pub async fn remove(&self, identity: &StateIdentity) {
        self.files.release(identity).await.unwrap();
        let path = self.path(identity);
        remove_wal(&path);
        std::fs::remove_file(path).unwrap();
    }

    // Runs `statement` on the file outside the store, as a local writer would.
    pub async fn tamper(&self, identity: &StateIdentity, statement: &str, binds: Vec<Vec<u8>>) {
        self.files.release(identity).await.unwrap();
        let options = sqlx::sqlite::SqliteConnectOptions::new().filename(self.path(identity));
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .unwrap();
        let mut query = sqlx::query(sqlx::AssertSqlSafe(statement.to_owned()));
        for bind in binds {
            query = query.bind(bind);
        }
        query.execute(&pool).await.unwrap();
        pool.close().await;
    }

    // One stored row as the file holds it: its encoded key and its columns.
    pub async fn raw(&self, identity: &StateIdentity, table: Table, key: &RowKey) -> Vec<u8> {
        self.files.release(identity).await.unwrap();
        let options = sqlx::sqlite::SqliteConnectOptions::new().filename(self.path(identity));
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .unwrap();
        let statement = format!("SELECT columns FROM {} WHERE key = ?", table.name());
        let columns: Vec<u8> = sqlx::query_scalar(sqlx::AssertSqlSafe(statement))
            .bind(key.encoded())
            .fetch_one(&pool)
            .await
            .unwrap();
        pool.close().await;
        columns
    }
}

fn remove_wal(path: &Path) {
    for suffix in ["-wal", "-shm"] {
        let mut name = path.to_path_buf().into_os_string();
        name.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(name));
    }
}

pub async fn put(state: &Arc<dyn StateStore>, rows: Vec<Row>) -> u64 {
    let mut txn = state.begin().await.unwrap();
    for row in rows {
        txn.put(row).await.unwrap();
    }
    txn.commit().await.unwrap().counter
}

pub async fn get(state: &Arc<dyn StateStore>, key: RowKey) -> Option<Row> {
    state.begin().await.unwrap().get(&key).await.unwrap()
}

pub async fn table(state: &Arc<dyn StateStore>, table: Table) -> Vec<Row> {
    state
        .begin()
        .await
        .unwrap()
        .scan(&RowRange::Table(table))
        .await
        .unwrap()
}

pub async fn every_row(state: &Arc<dyn StateStore>) -> Vec<Row> {
    let mut rows = Vec::new();
    for name in Table::SYNC.into_iter().chain(Table::KEY) {
        rows.extend(table(state, name).await);
    }
    rows
}

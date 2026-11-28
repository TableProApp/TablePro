// A state file in memory: one per identity, refusing none it was not made for, with transactions that commit whole
// and raise the counter, and an `Opened` a test sets to stand for what an anchor check found. It computes no MAC and
// keeps no anchor; those are the real file's (K6a-1, K6d). Like the real file's one connection, it holds one
// transaction at a time, and a begin waits for the one open before it.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_sync::api::error::StateError;
use tablepro_sync::api::ids::FileId;
use tablepro_sync::api::state::{
    BindingRow, Committed, Opened, Provider, Row, RowKey, RowRange, StateFiles, StateIdentity, StateStore, StateTxn,
    Table,
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use uuid::Uuid;

// No transaction here waits on anything slow, so a begin still waiting after this long waits on one its own caller
// holds: the real file then stalls for sqlx's 30 s acquire timeout and fails with `sync.state.io`.
const NESTED_BEGIN: Duration = Duration::from_secs(2);

type Rows = BTreeMap<(Table, Vec<u8>), Row>;

#[derive(Debug, Default)]
pub struct MemoryStateFiles {
    files: Mutex<HashMap<StateIdentity, Arc<MemoryState>>>,
    opened: Mutex<HashMap<StateIdentity, Opened>>,
}

impl MemoryStateFiles {
    pub fn new() -> Self {
        Self::default()
    }

    // What the next open of this identity reports, as a stale or unanchored file would.
    pub fn set_opened(&self, identity: StateIdentity, opened: Opened) {
        lock(&self.opened).insert(identity, opened);
    }

    pub fn exists(&self, identity: &StateIdentity) -> bool {
        lock(&self.files).contains_key(identity)
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn binding(identity: &StateIdentity) -> BindingRow {
    let (provider, origin, account, device) = match identity {
        StateIdentity::Service {
            origin,
            account,
            device_row,
            ..
        } => (
            Provider::Service,
            Some(origin.clone()),
            account.to_wire(),
            device_row.0.clone(),
        ),
        StateIdentity::ICloud { user_record_name } => (Provider::ICloud, None, user_record_name.clone(), String::new()),
    };
    BindingRow {
        provider,
        origin,
        account,
        device,
        schema_version: tablepro_sync::state::SCHEMA_VERSION,
        file_id: FileId(*Uuid::new_v4().as_bytes()),
        counter: 0,
        state_mac: [0; 32],
    }
}

#[async_trait]
impl StateFiles for MemoryStateFiles {
    async fn open(&self, identity: StateIdentity) -> Result<Arc<dyn StateStore>, StateError> {
        let opened = lock(&self.opened).remove(&identity).unwrap_or(Opened::FRESH);
        let mut files = lock(&self.files);
        let file = files
            .entry(identity.clone())
            .or_insert_with(|| {
                let mut rows = Rows::new();
                rows.insert((Table::Binding, Vec::new()), Row::Binding(binding(&identity)));
                Arc::new(MemoryState {
                    identity: identity.clone(),
                    opened: opened.clone(),
                    rows: Arc::new(Mutex::new(rows)),
                    writer: Arc::new(Semaphore::new(1)),
                    last_synced: Arc::default(),
                })
            })
            .clone();
        let reopened = MemoryState {
            identity: file.identity.clone(),
            opened,
            rows: Arc::clone(&file.rows),
            writer: Arc::clone(&file.writer),
            last_synced: Arc::clone(&file.last_synced),
        };
        Ok(Arc::new(reopened))
    }

    async fn delete(&self, identity: StateIdentity) -> Result<(), StateError> {
        lock(&self.files).remove(&identity);
        Ok(())
    }
}

#[derive(Debug)]
pub struct MemoryState {
    identity: StateIdentity,
    opened: Opened,
    rows: Arc<Mutex<Rows>>,
    writer: Arc<Semaphore>,
    last_synced: Arc<Mutex<Option<i64>>>,
}

#[async_trait]
impl StateStore for MemoryState {
    fn identity(&self) -> &StateIdentity {
        &self.identity
    }

    fn opened(&self) -> &Opened {
        &self.opened
    }

    #[expect(
        clippy::panic,
        reason = "a begin under a transaction its caller holds is a bug the panic's backtrace names"
    )]
    async fn begin(&self) -> Result<Box<dyn StateTxn>, StateError> {
        let writer = match tokio::time::timeout(NESTED_BEGIN, Arc::clone(&self.writer).acquire_owned()).await {
            Ok(Ok(writer)) => writer,
            Ok(Err(closed)) => {
                return Err(StateError::Io {
                    detail: closed.to_string(),
                });
            }
            Err(_) => panic!("a state transaction began while its caller held one open"),
        };
        let view = lock(&self.rows).clone();
        Ok(Box::new(MemoryTxn {
            rows: Arc::clone(&self.rows),
            view,
            writes: Vec::new(),
            _writer: writer,
        }))
    }

    async fn last_synced_ms(&self) -> Result<Option<i64>, StateError> {
        Ok(*lock(&self.last_synced))
    }

    async fn set_last_synced_ms(&self, at_ms: i64) -> Result<(), StateError> {
        *lock(&self.last_synced) = Some(at_ms);
        Ok(())
    }
}

#[derive(Debug)]
enum Write {
    Put(Box<Row>),
    Delete(RowKey),
    ClearKeyTables,
}

#[derive(Debug)]
struct MemoryTxn {
    rows: Arc<Mutex<Rows>>,
    // The rows as this transaction sees them, its own writes included.
    view: Rows,
    writes: Vec<Write>,
    _writer: OwnedSemaphorePermit,
}

fn slot(key: &RowKey) -> (Table, Vec<u8>) {
    (key.table(), key.encoded())
}

fn apply(rows: &mut Rows, write: &Write) {
    match write {
        Write::Put(row) => {
            rows.insert(slot(&row.key()), Row::clone(row));
        }
        Write::Delete(key) => {
            rows.remove(&slot(key));
        }
        Write::ClearKeyTables => rows.retain(|(table, _), _| !table.is_key_table()),
    }
}

#[async_trait]
impl StateTxn for MemoryTxn {
    async fn get(&mut self, key: &RowKey) -> Result<Option<Row>, StateError> {
        Ok(self.view.get(&slot(key)).cloned())
    }

    async fn scan(&mut self, range: &RowRange) -> Result<Vec<Row>, StateError> {
        let prefix = range.encoded_prefix();
        Ok(self
            .view
            .iter()
            .filter(|((table, key), _)| *table == range.table() && key.starts_with(&prefix))
            .map(|(_, row)| row.clone())
            .collect())
    }

    async fn put(&mut self, row: Row) -> Result<(), StateError> {
        let write = Write::Put(Box::new(row));
        apply(&mut self.view, &write);
        self.writes.push(write);
        Ok(())
    }

    async fn delete(&mut self, key: &RowKey) -> Result<(), StateError> {
        let write = Write::Delete(key.clone());
        apply(&mut self.view, &write);
        self.writes.push(write);
        Ok(())
    }

    async fn clear_key_tables(&mut self) -> Result<(), StateError> {
        apply(&mut self.view, &Write::ClearKeyTables);
        self.writes.push(Write::ClearKeyTables);
        Ok(())
    }

    // On a copy, published only once it is whole, so a refused commit leaves the file as it was.
    async fn commit(self: Box<Self>) -> Result<Committed, StateError> {
        let mut rows = lock(&self.rows);
        let mut next = rows.clone();
        for write in &self.writes {
            apply(&mut next, write);
        }
        let Some(Row::Binding(binding)) = next.get_mut(&(Table::Binding, Vec::new())) else {
            return Err(StateError::Integrity);
        };
        binding.counter += 1;
        let committed = Committed {
            counter: binding.counter,
        };
        *rows = next;
        Ok(committed)
    }
}

#[cfg(test)]
mod tests;

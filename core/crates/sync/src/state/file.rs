use std::collections::HashMap;
use std::fs::{File, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use async_trait::async_trait;
use sqlx::sqlite::{
    SqliteConnectOptions, SqliteJournalMode, SqliteLockingMode, SqlitePool, SqlitePoolOptions, SqliteSynchronous,
};
use sqlx::{AssertSqlSafe, ConnectOptions, Sqlite, Transaction};
use tablepro_storage::StoragePaths;
use uuid::Uuid;

use super::codec;
use super::integrity::{self, Bound, Seal, Written};
use super::name::state_path;
use crate::api::device_store::HostDeviceStore;
use crate::api::error::StateError;
use crate::api::ids::FileId;
use crate::api::state::{
    BindingRow, Committed, KeysSettled, Opened, Provider, Row, RowKey, RowRange, StateFiles, StateIdentity, StateStore,
    StateTxn, Table,
};

// 2 since 0066: `stores_kinds` and `refused`, a scope's `push_wait`, a key object's `served` and a replace point per
// replaced IK. An open reads a schema 1 file and upgrades it (`integrity::upgrade`).
pub const SCHEMA_VERSION: u32 = 2;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations/state");

fn io(error: impl std::fmt::Display) -> StateError {
    StateError::Io {
        detail: error.to_string(),
    }
}

// SQLITE_BUSY and SQLITE_LOCKED, with their extended codes in the bits above the first byte.
pub(super) fn sql(error: sqlx::Error) -> StateError {
    let busy = error
        .as_database_error()
        .and_then(|database| database.code())
        .and_then(|code| code.parse::<i64>().ok())
        .is_some_and(|code| matches!(code & 0xff, 5 | 6));
    if busy { StateError::Busy } else { io(error) }
}

// The state files under `<state>/sync`, one per provider and account (0054, The state file), each sealed and anchored
// in the device store.
#[derive(Clone)]
pub struct SqliteStateFiles {
    root: PathBuf,
    // Each file's pool outlives the store that used it, so a delete or a reopen closes its connection first: Windows
    // keeps an open file from being deleted, and a dropped pool closes in the background.
    pools: Arc<Mutex<HashMap<PathBuf, SqlitePool>>>,
    device_store: Arc<dyn HostDeviceStore>,
}

impl std::fmt::Debug for SqliteStateFiles {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SqliteStateFiles")
            .field("root", &self.root)
            .finish_non_exhaustive()
    }
}

impl SqliteStateFiles {
    pub fn new(paths: &StoragePaths, device_store: Arc<dyn HostDeviceStore>) -> Self {
        Self::at(paths.state.join("sync"), device_store)
    }

    pub fn at(root: PathBuf, device_store: Arc<dyn HostDeviceStore>) -> Self {
        Self {
            root,
            pools: Arc::default(),
            device_store,
        }
    }

    // Closes the file's connection once no store holds it, so the file on disk is whole: a backup can copy it.
    pub async fn release(&self, identity: &StateIdentity) -> Result<(), StateError> {
        let path = self.path(identity);
        let _lock = take_lock(&path)?;
        self.close(&path).await;
        Ok(())
    }

    pub fn path(&self, identity: &StateIdentity) -> PathBuf {
        state_path(&self.root, identity)
    }

    fn pools(&self) -> MutexGuard<'_, HashMap<PathBuf, SqlitePool>> {
        self.pools.lock().unwrap_or_else(PoisonError::into_inner)
    }

    // Called with the file's lock held, so no store still uses the pool.
    async fn close(&self, path: &Path) {
        let held = self.pools().remove(path);
        if let Some(pool) = held {
            pool.close().await;
        }
    }
}

fn lock_path(path: &Path) -> PathBuf {
    path.with_extension("lock")
}

// One process per state file (0054, Scheduling). The lock lives beside the file, so deleting the file never frees it.
fn take_lock(path: &Path) -> Result<File, StateError> {
    if let Some(parent) = path.parent() {
        tablepro_storage::fs::ensure_private_dir(parent).map_err(io)?;
    }
    let file = private_options().open(lock_path(path)).map_err(io)?;
    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(TryLockError::WouldBlock) => Err(StateError::Busy),
        Err(TryLockError::Error(error)) => Err(io(error)),
    }
}

fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
}

fn expected_binding(identity: &StateIdentity) -> (Provider, Option<String>, String, String) {
    match identity {
        StateIdentity::Service {
            origin,
            account,
            device_row,
            ..
        } => (
            Provider::Service,
            Some(origin.as_str().to_owned()),
            account.to_wire(),
            device_row.0.clone(),
        ),
        StateIdentity::ICloud { user_record_name } => (Provider::ICloud, None, user_record_name.clone(), String::new()),
    }
}

fn fresh_binding(identity: &StateIdentity) -> BindingRow {
    let (provider, _, account, device) = expected_binding(identity);
    let origin = match identity {
        StateIdentity::Service { origin, .. } => Some(origin.clone()),
        StateIdentity::ICloud { .. } => None,
    };
    BindingRow {
        provider,
        origin,
        account,
        device,
        schema_version: SCHEMA_VERSION,
        file_id: FileId(*Uuid::new_v4().as_bytes()),
        counter: 0,
        state_mac: [0; 32],
    }
}

fn bound_to(binding: &BindingRow, identity: &StateIdentity) -> bool {
    let (provider, origin, account, device) = expected_binding(identity);
    binding.provider == provider
        && binding.origin.as_ref().map(|held| held.as_str()) == origin.as_deref()
        && binding.account == account
        && binding.device == device
}

async fn connect(path: &Path) -> Result<SqlitePool, StateError> {
    // Pre-created at 0600 so the WAL and SHM copy its mode.
    tablepro_storage::fs::create_private_file_if_missing(path).map_err(io)?;
    // Held exclusively for as long as the store is open, so no other process writes rows a commit would then seal.
    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .locking_mode(SqliteLockingMode::Exclusive)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Full)
        .pragma("trusted_schema", "OFF")
        // What a delete removes is overwritten in its pages, so it never lingers in free pages (`purge`).
        .pragma("secure_delete", "ON")
        .disable_statement_logging();
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .idle_timeout(None)
        .max_lifetime(None)
        .connect_with(options)
        .await
        .map_err(sql)?;
    check_schema(&pool).await?;
    MIGRATOR.run(&pool).await.map_err(io)?;
    check_schema(&pool).await?;
    check_rows(&pool).await?;
    Ok(pool)
}

// The digests read every row in key order, and the store finds rows by their keys: a key stored as text sorts and
// hashes the same yet is never found, and a damaged b-tree can show a scan rows a lookup misses. Either would hide
// rows the MAC still covers.
async fn check_rows(pool: &SqlitePool) -> Result<(), StateError> {
    for table in Table::SYNC.into_iter().chain(Table::KEY) {
        let statement = format!(
            "SELECT EXISTS (SELECT 1 FROM {} WHERE typeof(key) != 'blob' OR typeof(columns) != 'blob')",
            table.name()
        );
        let mistyped: bool = sqlx::query_scalar(AssertSqlSafe(statement))
            .fetch_one(pool)
            .await
            .map_err(sql)?;
        if mistyped {
            return Err(StateError::Integrity);
        }
    }
    let checked: Vec<String> = sqlx::query_scalar("PRAGMA quick_check")
        .fetch_all(pool)
        .await
        .map_err(sql)?;
    if checked != ["ok"] {
        return Err(StateError::Integrity);
    }
    Ok(())
}

// The MAC covers rows, not the schema: a trigger or a view a local writer added could change what a commit then seals.
// So the file holds only the tables the migrations make, each as they make it.
async fn check_schema(pool: &SqlitePool) -> Result<(), StateError> {
    let objects: Vec<(String, String, Option<String>)> = sqlx::query_as("SELECT type, name, sql FROM sqlite_schema")
        .fetch_all(pool)
        .await
        .map_err(sql)?;
    for (kind, name, statement) in objects {
        let expected = match kind.as_str() {
            "table" if name == "_sqlx_migrations" => true,
            "table" => Table::SYNC.into_iter().chain(Table::KEY).any(|table| {
                table.name() == name
                    && statement.as_deref()
                        == Some(&*format!(
                            "CREATE TABLE {name} (key BLOB PRIMARY KEY NOT NULL, columns BLOB NOT NULL) WITHOUT ROWID"
                        ))
            }),
            // The index SQLite makes for a primary key has no SQL of its own.
            "index" => statement.is_none(),
            _ => false,
        };
        if !expected {
            return Err(StateError::Integrity);
        }
    }
    Ok(())
}

// A file is bound once, when it is made, in the commit that anchors it. One that holds rows and no binding was not made
// by this code, and is refused.
async fn bind(tx: &mut Transaction<'static, Sqlite>, identity: &StateIdentity) -> Result<Bound, StateError> {
    match read(tx, &RowKey::Binding).await? {
        // A newer build's file is not read, and never started over (0012).
        Some(Row::Binding(binding)) if bound_to(&binding, identity) => {
            if !(1..=SCHEMA_VERSION).contains(&binding.schema_version) {
                return Err(StateError::Integrity);
            }
            Ok(Bound {
                binding,
                new_file: false,
            })
        }
        Some(_) => Err(StateError::WrongIdentity),
        None => {
            for table in Table::SYNC.into_iter().chain(Table::KEY) {
                let statement = format!("SELECT EXISTS (SELECT 1 FROM {})", table.name());
                let held: bool = sqlx::query_scalar(AssertSqlSafe(statement))
                    .fetch_one(&mut **tx)
                    .await
                    .map_err(sql)?;
                if held {
                    return Err(StateError::Integrity);
                }
            }
            let binding = fresh_binding(identity);
            write(tx, &Row::Binding(binding.clone())).await?;
            Ok(Bound {
                binding,
                new_file: true,
            })
        }
    }
}

#[async_trait]
impl StateFiles for SqliteStateFiles {
    async fn open(&self, identity: StateIdentity) -> Result<Arc<dyn StateStore>, StateError> {
        let path = self.path(&identity);
        let lock = take_lock(&path)?;
        self.close(&path).await;
        let pool = connect(&path).await?;
        let mut tx = pool.begin_with("BEGIN IMMEDIATE").await.map_err(sql)?;
        let bound = bind(&mut tx, &identity).await?;
        let (seal, opened) = integrity::open(tx, &identity, bound, Arc::clone(&self.device_store)).await?;
        self.pools().insert(path, pool.clone());
        Ok(Arc::new(SqliteState {
            identity,
            opened,
            pool,
            seal,
            _lock: lock,
        }))
    }

    async fn delete(&self, identity: StateIdentity) -> Result<(), StateError> {
        let path = self.path(&identity);
        let lock = take_lock(&path)?;
        self.close(&path).await;
        // The WAL first: one left beside a new file of the same name would be replayed into it.
        for suffix in ["-wal", "-shm", ""] {
            let mut name = path.clone().into_os_string();
            name.push(suffix);
            match std::fs::remove_file(PathBuf::from(name)) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(io(error)),
            }
        }
        integrity::forget(self.device_store.as_ref(), &identity).await?;
        drop(lock);
        Ok(())
    }
}

#[derive(Debug)]
pub struct SqliteState {
    identity: StateIdentity,
    opened: Opened,
    pool: SqlitePool,
    seal: Arc<Seal>,
    _lock: File,
}

#[async_trait]
impl StateStore for SqliteState {
    fn identity(&self) -> &StateIdentity {
        &self.identity
    }

    fn opened(&self) -> &Opened {
        &self.opened
    }

    // One writer at a time: the pool holds one connection, and the transaction takes the write lock at once.
    async fn begin(&self) -> Result<Box<dyn StateTxn>, StateError> {
        let tx = self.pool.begin_with("BEGIN IMMEDIATE").await.map_err(sql)?;
        Ok(Box::new(SqliteTxn {
            tx,
            seal: Arc::clone(&self.seal),
            written: Written::default(),
        }))
    }

    // `secure_delete` zeroes what a delete removes in its pages, but a page freed before it was on can still hold
    // older copies: the file is rebuilt, then the frames before it leave with a checkpoint that empties the WAL. A
    // state file is small and held exclusively, so neither waits on a reader or holds the file long.
    async fn purge(&self) -> Result<(), StateError> {
        sqlx::query("VACUUM").execute(&self.pool).await.map_err(sql)?;
        let (busy, _, _): (i64, i64, i64) = sqlx::query_as("PRAGMA wal_checkpoint(TRUNCATE)")
            .fetch_one(&self.pool)
            .await
            .map_err(sql)?;
        if busy != 0 {
            return Err(StateError::Io {
                detail: "the WAL could not be checkpointed whole".to_owned(),
            });
        }
        Ok(())
    }
}

struct SqliteTxn {
    tx: Transaction<'static, Sqlite>,
    seal: Arc<Seal>,
    written: Written,
}

impl SqliteTxn {
    // An iCloud file has no key tables (0054, The device's key state).
    fn writes(&mut self, table: Table) -> Result<(), StateError> {
        if table.is_key_table() {
            if self.seal.provider() == Provider::ICloud {
                return Err(StateError::WrongIdentity);
            }
            self.written.key_tables = true;
        }
        Ok(())
    }
}

pub(super) async fn read(tx: &mut Transaction<'static, Sqlite>, key: &RowKey) -> Result<Option<Row>, StateError> {
    let table = key.table();
    let encoded = key.encoded();
    let statement = format!("SELECT columns FROM {} WHERE key = ?", table.name());
    let columns: Option<Vec<u8>> = sqlx::query_scalar(AssertSqlSafe(statement))
        .bind(&encoded)
        .fetch_optional(&mut **tx)
        .await
        .map_err(sql)?;
    columns
        .map(|columns| codec::decode(table, &encoded, &columns))
        .transpose()
}

pub(super) async fn write(tx: &mut Transaction<'static, Sqlite>, row: &Row) -> Result<(), StateError> {
    let key = row.key();
    let statement = format!(
        "INSERT INTO {} (key, columns) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET columns = excluded.columns",
        key.table().name()
    );
    sqlx::query(AssertSqlSafe(statement))
        .bind(key.encoded())
        .bind(codec::columns(row))
        .execute(&mut **tx)
        .await
        .map_err(sql)?;
    Ok(())
}

// The least byte string above every string that starts with `prefix`, or None when no string is.
fn after_prefix(prefix: &[u8]) -> Option<Vec<u8>> {
    let mut upper = prefix.to_vec();
    while let Some(last) = upper.pop() {
        if last < u8::MAX {
            upper.push(last + 1);
            return Some(upper);
        }
    }
    None
}

#[async_trait]
impl StateTxn for SqliteTxn {
    async fn get(&mut self, key: &RowKey) -> Result<Option<Row>, StateError> {
        read(&mut self.tx, key).await
    }

    async fn scan(&mut self, range: &RowRange) -> Result<Vec<Row>, StateError> {
        let table = range.table();
        let prefix = range.encoded_prefix();
        let upper = after_prefix(&prefix);
        let bound = if upper.is_some() { " AND key < ?" } else { "" };
        let statement = format!(
            "SELECT key, columns FROM {} WHERE key >= ?{bound} ORDER BY key",
            table.name()
        );
        let mut query = sqlx::query_as::<_, (Vec<u8>, Vec<u8>)>(AssertSqlSafe(statement)).bind(prefix);
        if let Some(upper) = upper {
            query = query.bind(upper);
        }
        let rows = query.fetch_all(&mut *self.tx).await.map_err(sql)?;
        rows.iter()
            .map(|(key, columns)| codec::decode(table, key, columns))
            .collect()
    }

    // The binding row is the store's: what the file is bound to, its counter and the MAC the commit computes. A put of
    // it changes nothing.
    async fn put(&mut self, row: Row) -> Result<(), StateError> {
        if matches!(row, Row::Binding(_)) {
            return Ok(());
        }
        self.writes(row.key().table())?;
        write(&mut self.tx, &row).await
    }

    async fn delete(&mut self, key: &RowKey) -> Result<(), StateError> {
        if *key == RowKey::Binding {
            return Err(StateError::WrongIdentity);
        }
        self.writes(key.table())?;
        let statement = format!("DELETE FROM {} WHERE key = ?", key.table().name());
        sqlx::query(AssertSqlSafe(statement))
            .bind(key.encoded())
            .execute(&mut *self.tx)
            .await
            .map_err(sql)?;
        Ok(())
    }

    async fn clear_key_tables(&mut self) -> Result<(), StateError> {
        self.written.key_tables = true;
        self.written.settles.clear();
        for table in Table::KEY {
            let statement = format!("DELETE FROM {}", table.name());
            sqlx::query(AssertSqlSafe(statement))
                .execute(&mut *self.tx)
                .await
                .map_err(sql)?;
        }
        Ok(())
    }

    fn settle_keys(&mut self, settled: KeysSettled) {
        self.written.settles.add(settled);
    }

    async fn commit(self: Box<Self>) -> Result<Committed, StateError> {
        let Self { tx, seal, written } = *self;
        integrity::commit(&seal, tx, written).await
    }
}

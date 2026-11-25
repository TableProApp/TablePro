use std::fs::{File, OpenOptions, TryLockError};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePool, SqlitePoolOptions, SqliteSynchronous};
use sqlx::{AssertSqlSafe, ConnectOptions, Sqlite, Transaction};
use tablepro_storage::StoragePaths;
use uuid::Uuid;

use super::codec;
use super::name::state_path;
use crate::api::error::StateError;
use crate::api::ids::FileId;
use crate::api::state::{
    BindingRow, Committed, Opened, Provider, Row, RowKey, RowRange, StateFiles, StateIdentity, StateStore, StateTxn,
    Table,
};

pub const SCHEMA_VERSION: u32 = 1;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations/state");

fn io(error: impl std::fmt::Display) -> StateError {
    StateError::Io {
        detail: error.to_string(),
    }
}

fn sql(error: sqlx::Error) -> StateError {
    let busy = error
        .as_database_error()
        .and_then(|database| database.code())
        .is_some_and(|code| code == "5" || code == "6");
    if busy { StateError::Busy } else { io(error) }
}

// The state files under `<state>/sync`, one per provider and account (0054, The state file).
#[derive(Debug, Clone)]
pub struct SqliteStateFiles {
    root: PathBuf,
}

impl SqliteStateFiles {
    pub fn new(paths: &StoragePaths) -> Self {
        Self::at(paths.state.join("sync"))
    }

    pub fn at(root: PathBuf) -> Self {
        Self { root }
    }

    pub fn path(&self, identity: &StateIdentity) -> PathBuf {
        state_path(&self.root, identity)
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
    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Full)
        .disable_statement_logging();
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(sql)?;
    MIGRATOR.run(&pool).await.map_err(io)?;
    Ok(pool)
}

async fn bind(pool: &SqlitePool, identity: &StateIdentity) -> Result<(), StateError> {
    let mut tx = pool.begin_with("BEGIN IMMEDIATE").await.map_err(sql)?;
    match read(&mut tx, &RowKey::Binding).await? {
        Some(Row::Binding(binding)) if bound_to(&binding, identity) => {}
        Some(_) => return Err(StateError::WrongIdentity),
        None => write(&mut tx, &Row::Binding(fresh_binding(identity))).await?,
    }
    tx.commit().await.map_err(sql)
}

#[async_trait]
impl StateFiles for SqliteStateFiles {
    async fn open(&self, identity: StateIdentity) -> Result<Arc<dyn StateStore>, StateError> {
        let path = self.path(&identity);
        let lock = take_lock(&path)?;
        let pool = connect(&path).await?;
        bind(&pool, &identity).await?;
        Ok(Arc::new(SqliteState {
            identity,
            opened: Opened::FRESH,
            pool,
            _lock: lock,
        }))
    }

    async fn delete(&self, identity: StateIdentity) -> Result<(), StateError> {
        let path = self.path(&identity);
        let lock = take_lock(&path)?;
        for suffix in ["", "-wal", "-shm"] {
            let mut name = path.clone().into_os_string();
            name.push(suffix);
            match std::fs::remove_file(PathBuf::from(name)) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(io(error)),
            }
        }
        drop(lock);
        Ok(())
    }
}

#[derive(Debug)]
pub struct SqliteState {
    identity: StateIdentity,
    opened: Opened,
    pool: SqlitePool,
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
        Ok(Box::new(SqliteTxn { tx }))
    }
}

struct SqliteTxn {
    tx: Transaction<'static, Sqlite>,
}

async fn read(tx: &mut Transaction<'static, Sqlite>, key: &RowKey) -> Result<Option<Row>, StateError> {
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

async fn write(tx: &mut Transaction<'static, Sqlite>, row: &Row) -> Result<(), StateError> {
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

    // The counter is the store's: a binding row put keeps the stored one.
    async fn put(&mut self, row: Row) -> Result<(), StateError> {
        let row = match (row, read(&mut self.tx, &RowKey::Binding).await?) {
            (Row::Binding(mut binding), Some(Row::Binding(stored))) => {
                binding.counter = stored.counter;
                Row::Binding(binding)
            }
            (row, _) => row,
        };
        write(&mut self.tx, &row).await
    }

    async fn delete(&mut self, key: &RowKey) -> Result<(), StateError> {
        if *key == RowKey::Binding {
            return Err(StateError::WrongIdentity);
        }
        let statement = format!("DELETE FROM {} WHERE key = ?", key.table().name());
        sqlx::query(AssertSqlSafe(statement))
            .bind(key.encoded())
            .execute(&mut *self.tx)
            .await
            .map_err(sql)?;
        Ok(())
    }

    async fn clear_key_tables(&mut self) -> Result<(), StateError> {
        for table in Table::KEY {
            let statement = format!("DELETE FROM {}", table.name());
            sqlx::query(AssertSqlSafe(statement))
                .execute(&mut *self.tx)
                .await
                .map_err(sql)?;
        }
        Ok(())
    }

    async fn commit(mut self: Box<Self>) -> Result<Committed, StateError> {
        let Some(Row::Binding(mut binding)) = read(&mut self.tx, &RowKey::Binding).await? else {
            return Err(StateError::Integrity);
        };
        binding.counter = binding.counter.checked_add(1).ok_or(StateError::Integrity)?;
        write(&mut self.tx, &Row::Binding(binding.clone())).await?;
        self.tx.commit().await.map_err(sql)?;
        Ok(Committed {
            counter: binding.counter,
        })
    }
}

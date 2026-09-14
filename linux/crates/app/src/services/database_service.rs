use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use tablepro_core::{ConnectOptions, Connection, DatabaseDriver};
use tablepro_ssh::{SshConfig, SshTunnel};

use super::connection_monitor;

static SERVICE: OnceLock<DatabaseService> = OnceLock::new();

pub fn instance() -> &'static DatabaseService {
    SERVICE.get_or_init(DatabaseService::new)
}

pub(super) struct EntryInner {
    pub(super) connection: Arc<dyn Connection>,
    pub(super) tunnel: Option<SshTunnel>,
    pub(super) health: ConnectionHealth,
}

#[derive(Debug, Clone)]
pub struct ConnectionMetadata {
    pub id: Uuid,
    pub name: String,
    pub driver_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionHealth {
    Healthy,
    Reconnecting { attempt: u32 },
}

pub struct ReconnectParams {
    pub driver: Arc<dyn DatabaseDriver>,
    pub opts: ConnectOptions,
    pub ssh: Option<SshConfig>,
    pub read_only: bool,
}

struct Entry {
    inner: Arc<Mutex<EntryInner>>,
    metadata: ConnectionMetadata,
    read_only: bool,
    cancel: CancellationToken,
    _monitor: tokio::task::JoinHandle<()>,
}

pub struct DatabaseService {
    connections: Mutex<HashMap<Uuid, Entry>>,
    active: Mutex<Option<Uuid>>,
}

impl DatabaseService {
    fn new() -> Self {
        Self {
            connections: Mutex::new(HashMap::new()),
            active: Mutex::new(None),
        }
    }

    pub fn add(
        &self,
        id: Uuid,
        metadata: ConnectionMetadata,
        connection: Box<dyn Connection>,
        tunnel: Option<SshTunnel>,
        read_only: bool,
        params: ReconnectParams,
    ) {
        let arc: Arc<dyn Connection> = Arc::from(connection);
        let inner = Arc::new(Mutex::new(EntryInner {
            connection: arc,
            tunnel,
            health: ConnectionHealth::Healthy,
        }));
        let cancel = CancellationToken::new();
        let monitor = tokio::spawn(connection_monitor::run(inner.clone(), params, cancel.clone()));
        let entry = Entry {
            inner,
            metadata,
            read_only,
            cancel,
            _monitor: monitor,
        };
        self.connections
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id, entry);
        *self.active.lock().unwrap_or_else(PoisonError::into_inner) = Some(id);
    }

    pub fn active_metadata(&self) -> Option<ConnectionMetadata> {
        let id = self.active_id()?;
        let entries = self.connections.lock().unwrap_or_else(PoisonError::into_inner);
        entries.get(&id).map(|e| e.metadata.clone())
    }

    pub fn all_connections(&self) -> Vec<ConnectionMetadata> {
        let entries = self.connections.lock().unwrap_or_else(PoisonError::into_inner);
        let mut out: Vec<_> = entries.values().map(|e| e.metadata.clone()).collect();
        out.sort_by_cached_key(|metadata| metadata.name.to_lowercase());
        out
    }

    pub fn get(&self, id: Uuid) -> Option<Arc<dyn Connection>> {
        let entries = self.connections.lock().unwrap_or_else(PoisonError::into_inner);
        let entry = entries.get(&id)?;
        let inner = entry.inner.lock().unwrap_or_else(PoisonError::into_inner);
        Some(inner.connection.clone())
    }

    pub fn active(&self) -> Option<Arc<dyn Connection>> {
        let id = self.active_id()?;
        self.get(id)
    }

    pub fn active_id(&self) -> Option<Uuid> {
        *self.active.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn active_health(&self) -> Option<ConnectionHealth> {
        let id = self.active_id()?;
        let entries = self.connections.lock().unwrap_or_else(PoisonError::into_inner);
        let entry = entries.get(&id)?;
        let inner = entry.inner.lock().unwrap_or_else(PoisonError::into_inner);
        Some(inner.health.clone())
    }

    pub fn is_active_read_only(&self) -> bool {
        let id = match self.active_id() {
            Some(id) => id,
            None => return false,
        };
        self.connections
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&id)
            .map(|e| e.read_only)
            .unwrap_or(false)
    }

    pub fn remove(&self, id: Uuid) {
        let mut entries = self.connections.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(entry) = entries.remove(&id) {
            entry.cancel.cancel();
        }
        let mut active = self.active.lock().unwrap_or_else(PoisonError::into_inner);
        if *active == Some(id) {
            *active = None;
        }
    }

    pub fn clear_all(&self) {
        let mut entries = self.connections.lock().unwrap_or_else(PoisonError::into_inner);
        for (_, entry) in entries.drain() {
            entry.cancel.cancel();
        }
        *self.active.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn instance_is_singleton() {
        let a = instance() as *const _;
        let b = instance() as *const _;
        assert_eq!(a, b);
    }
}

use std::collections::HashMap;
use std::sync::{Arc, Mutex, mpsc};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::workspace_disk;

#[derive(Clone)]
pub struct WorkspaceStore {
    inner: Arc<WorkspaceStoreInner>,
}

struct WorkspaceStoreInner {
    file_lock: Arc<Mutex<()>>,
    memory: Mutex<Memory>,
    writer: WorkspaceWriter,
    paths: WorkspacePaths,
}

#[derive(Clone)]
struct WorkspacePaths {
    state: Option<std::path::PathBuf>,
    drafts: std::path::PathBuf,
}

#[derive(Default)]
struct Memory {
    cache: HashMap<Uuid, Option<ConnectionWorkspaceState>>,
    saved_at: HashMap<Uuid, u64>,
    clock: u64,
}

struct WorkspaceWriter {
    wake: mpsc::SyncSender<()>,
    queue: Arc<Mutex<WorkspaceQueue>>,
}

#[derive(Default)]
struct WorkspaceQueue {
    next_sequence: u64,
    persisted_sequence: u64,
    pending: HashMap<Uuid, PendingWorkspace>,
    flushes: Vec<(u64, mpsc::Sender<Result<(), WorkspaceFlushError>>)>,
}

struct PendingWorkspace {
    sequence: u64,
    state: ConnectionWorkspaceState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkspaceFlushError {
    WriteFailed,
    WriterUnavailable,
}

impl WorkspaceQueue {
    fn save(&mut self, id: Uuid, state: ConnectionWorkspaceState) {
        self.next_sequence = self.next_sequence.wrapping_add(1);
        self.pending.insert(
            id,
            PendingWorkspace {
                sequence: self.next_sequence,
                state,
            },
        );
    }

    fn flush(&mut self, sender: mpsc::Sender<Result<(), WorkspaceFlushError>>) {
        if self.persisted_sequence >= self.next_sequence {
            let _ = sender.send(Ok(()));
        } else {
            self.flushes.push((self.next_sequence, sender));
        }
    }

    fn take_pending(&mut self) -> Vec<(Uuid, PendingWorkspace)> {
        self.pending.drain().collect()
    }

    fn restore_pending(&mut self, pending: Vec<(Uuid, PendingWorkspace)>) {
        for (id, entry) in pending {
            if self
                .pending
                .get(&id)
                .is_none_or(|current| current.sequence < entry.sequence)
            {
                self.pending.insert(id, entry);
            }
        }
    }

    fn complete_attempt(&mut self, sequence: u64, result: Result<(), WorkspaceFlushError>) {
        if result.is_ok() {
            self.persisted_sequence = self.persisted_sequence.max(sequence);
        }
        let mut waiting = Vec::new();
        self.flushes.retain(|(target, sender)| {
            if *target <= sequence {
                waiting.push(sender.clone());
                false
            } else {
                true
            }
        });
        for sender in waiting {
            let _ = sender.send(result);
        }
    }

    fn fail_flushes(&mut self, error: WorkspaceFlushError) {
        for (_, sender) in self.flushes.drain(..) {
            let _ = sender.send(Err(error));
        }
    }
}

const MAX_TABS_PER_CONNECTION: usize = 32;
const MAX_TABLE_NAME_BYTES: usize = 256;
const MAX_COLLAPSED_GROUPS: usize = 256;
const MAX_COLLAPSED_KEY_BYTES: usize = 600;
const MAX_SCHEMA_NAME_BYTES: usize = 256;
const MAX_HIDDEN_SCHEMAS: usize = 256;

const PAGE_SIZE_OPTIONS: &[u64] = &[100, 500, 1_000, 5_000, 10_000];
const DEFAULT_PAGE_SIZE: u64 = 1_000;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WorkspaceState {
    #[serde(default)]
    pub connections: HashMap<String, ConnectionWorkspaceState>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ConnectionWorkspaceState {
    pub tabs: Vec<WorkspaceTabRecord>,
    #[serde(default)]
    pub active_idx: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub collapsed_groups: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hidden_schemas: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum WorkspaceTabRecord {
    Browse {
        schema: Option<String>,
        table: String,
        #[serde(default)]
        offset: u64,
        #[serde(default = "default_page_size")]
        page_size: u64,
        #[serde(default)]
        sort_col: Option<usize>,
        #[serde(default)]
        sort_asc: Option<bool>,
    },
    Editor {
        #[serde(default, skip_serializing_if = "String::is_empty")]
        query: String,
        #[serde(default)]
        draft_id: Option<Uuid>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        file: Option<std::path::PathBuf>,
    },
    Structure {
        schema: Option<String>,
        table: String,
    },
    Table {
        schema: Option<String>,
        table: String,
        #[serde(default)]
        mode: PersistedTableMode,
        #[serde(default)]
        offset: u64,
        #[serde(default = "default_page_size")]
        page_size: u64,
        #[serde(default)]
        sort_col: Option<usize>,
        #[serde(default)]
        sort_asc: Option<bool>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        preview: bool,
    },
    #[serde(other)]
    Unknown,
}

fn default_page_size() -> u64 {
    DEFAULT_PAGE_SIZE
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PersistedTableMode {
    #[default]
    Data,
    Structure,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RestoredWorkspaceTab {
    Editor {
        query: String,
        draft_id: Option<Uuid>,
        file: Option<std::path::PathBuf>,
    },
    Table {
        schema: Option<String>,
        table: String,
        offset: u64,
        page_size: u64,
        sort: Option<(usize, bool)>,
        preview: bool,
    },
    Structure {
        schema: Option<String>,
        table: String,
    },
}

pub fn restored_workspace_tab(record: &WorkspaceTabRecord) -> Option<RestoredWorkspaceTab> {
    match record {
        WorkspaceTabRecord::Editor { query, draft_id, file } => Some(RestoredWorkspaceTab::Editor {
            query: query.clone(),
            draft_id: *draft_id,
            file: file.clone(),
        }),
        WorkspaceTabRecord::Table {
            schema,
            table,
            mode: PersistedTableMode::Data,
            offset,
            page_size,
            sort_col,
            sort_asc,
            preview,
        } => Some(RestoredWorkspaceTab::Table {
            schema: schema.clone(),
            table: table.clone(),
            offset: *offset,
            page_size: *page_size,
            sort: match (sort_col, sort_asc) {
                (Some(column), Some(ascending)) => Some((*column, *ascending)),
                _ => None,
            },
            preview: *preview,
        }),
        WorkspaceTabRecord::Table {
            schema,
            table,
            mode: PersistedTableMode::Structure,
            ..
        }
        | WorkspaceTabRecord::Structure { schema, table } => {
            if table.is_empty() {
                None
            } else {
                Some(RestoredWorkspaceTab::Structure {
                    schema: schema.clone(),
                    table: table.clone(),
                })
            }
        }
        WorkspaceTabRecord::Browse { .. } | WorkspaceTabRecord::Unknown => None,
    }
}

mod preview_tabs;

fn load_locked(paths: &WorkspacePaths) -> Result<WorkspaceState, WorkspaceFlushError> {
    let path = paths.state.as_deref().ok_or(WorkspaceFlushError::WriteFailed)?;
    let mut state = workspace_disk::load(path, &paths.drafts).map_err(|error| {
        tracing::warn!(%error, "workspace could not be read; existing files will be preserved");
        WorkspaceFlushError::WriteFailed
    })?;
    clamp(&mut state);
    Ok(state)
}

fn save_locked(paths: &WorkspacePaths, state: &WorkspaceState) -> Result<(), WorkspaceFlushError> {
    let path = paths.state.as_deref().ok_or(WorkspaceFlushError::WriteFailed)?;
    let mut snapshot = state.clone();
    clamp(&mut snapshot);
    workspace_disk::save(path, &paths.drafts, &snapshot).map_err(|error| {
        tracing::warn!(%error, "workspace could not be saved");
        WorkspaceFlushError::WriteFailed
    })
}

impl WorkspaceStore {
    pub fn new(state: Option<std::path::PathBuf>, drafts: std::path::PathBuf) -> Self {
        let paths = WorkspacePaths { state, drafts };
        let writer_paths = paths.clone();
        let file_lock = Arc::new(Mutex::new(()));
        let (wake, receiver) = mpsc::sync_channel(1);
        let queue = Arc::new(Mutex::new(WorkspaceQueue::default()));
        let writer_queue = Arc::clone(&queue);
        let writer_file_lock = Arc::clone(&file_lock);
        let _writer = std::thread::spawn(move || run_writer(receiver, writer_queue, writer_file_lock, writer_paths));
        Self {
            inner: Arc::new(WorkspaceStoreInner {
                file_lock,
                memory: Mutex::new(Memory::default()),
                writer: WorkspaceWriter { wake, queue },
                paths,
            }),
        }
    }

    pub fn prefetch_connections(&self, ids: &[Uuid]) -> Result<(), WorkspaceFlushError> {
        prefetch_connections_coordinated(
            &self.inner.memory,
            ids,
            || {
                let receiver = self.flush();
                if !matches!(receiver.recv(), Ok(Ok(()))) {
                    tracing::warn!("workspace_state: preload flush failed");
                }
            },
            || {
                let _guard = self
                    .inner
                    .file_lock
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                load_locked(&self.inner.paths)
            },
        )
    }

    pub fn load_connection(&self, id: Uuid) -> Option<ConnectionWorkspaceState> {
        self.inner
            .memory
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .cache
            .get(&id)
            .cloned()
            .flatten()
    }

    pub fn save_connection(&self, id: Uuid, mut conn_state: ConnectionWorkspaceState) {
        clamp_connection(&mut conn_state);
        save_connection_coordinated(&self.inner.memory, &self.inner.writer.queue, id, conn_state);
        wake_writer(&self.inner.writer);
    }

    pub fn forget_connection(&self, id: Uuid) {
        {
            let mut memory = self
                .inner
                .memory
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            memory.cache.remove(&id);
            memory.saved_at.remove(&id);
        }
        {
            let _guard = self
                .inner
                .file_lock
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            match load_locked(&self.inner.paths) {
                Ok(mut state) => {
                    if state.connections.remove(&id.to_string()).is_some()
                        && let Err(error) = save_locked(&self.inner.paths, &state)
                    {
                        tracing::warn!(%id, ?error, "could not remove deleted connection from workspace state");
                    }
                }
                Err(error) => {
                    tracing::warn!(%id, ?error, "could not load workspace state to remove a deleted connection");
                }
            }
        }
        let path = self.inner.paths.drafts.join(id.to_string());
        if let Err(error) = std::fs::remove_dir_all(&path)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!(%id, %error, "could not remove drafts for a deleted connection");
        }
    }

    pub fn flush(&self) -> mpsc::Receiver<Result<(), WorkspaceFlushError>> {
        let (sender, receiver) = mpsc::channel();
        self.inner
            .writer
            .queue
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .flush(sender);
        if !wake_writer(&self.inner.writer) {
            self.inner
                .writer
                .queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .fail_flushes(WorkspaceFlushError::WriterUnavailable);
        }
        receiver
    }
}

fn prefetch_connections_coordinated(
    memory: &Mutex<Memory>,
    ids: &[Uuid],
    flush: impl FnOnce(),
    load: impl FnOnce() -> Result<WorkspaceState, WorkspaceFlushError>,
) -> Result<(), WorkspaceFlushError> {
    let started = memory.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clock;
    flush();
    let state = load()?;
    let mut memory = memory.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    for id in ids {
        if memory.saved_at.get(id).is_some_and(|saved| *saved > started) {
            continue;
        }
        memory
            .cache
            .insert(*id, state.connections.get(&id.to_string()).cloned());
    }
    Ok(())
}

fn save_connection_coordinated(
    memory: &Mutex<Memory>,
    queue: &Mutex<WorkspaceQueue>,
    id: Uuid,
    state: ConnectionWorkspaceState,
) {
    let mut memory = memory.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    memory.clock += 1;
    let clock = memory.clock;
    memory.saved_at.insert(id, clock);
    memory.cache.insert(id, Some(state.clone()));
    queue
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .save(id, state);
}

fn wake_writer(writer: &WorkspaceWriter) -> bool {
    if let Err(mpsc::TrySendError::Disconnected(())) = writer.wake.try_send(()) {
        tracing::warn!("workspace_state: writer unavailable");
        return false;
    }
    true
}

fn run_writer(
    receiver: mpsc::Receiver<()>,
    queue: Arc<Mutex<WorkspaceQueue>>,
    file_lock: Arc<Mutex<()>>,
    paths: WorkspacePaths,
) {
    while receiver.recv().is_ok() {
        let pending = queue
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take_pending();
        if pending.is_empty() {
            continue;
        }
        let attempted_sequence = pending.iter().map(|(_, entry)| entry.sequence).max().unwrap_or(0);
        let result = {
            let _guard = file_lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            load_locked(&paths).and_then(|mut state| {
                for (id, entry) in &pending {
                    state.connections.insert(id.to_string(), entry.state.clone());
                }
                save_locked(&paths, &state)
            })
        };
        let mut queue = queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if result.is_err() {
            queue.restore_pending(pending);
        }
        queue.complete_attempt(attempted_sequence, result);
    }
}

fn clamp(state: &mut WorkspaceState) {
    for conn in state.connections.values_mut() {
        clamp_connection(conn);
    }
}

fn clamp_connection(conn: &mut ConnectionWorkspaceState) {
    conn.collapsed_groups.retain(|key| key.len() <= MAX_COLLAPSED_KEY_BYTES);
    conn.collapsed_groups.truncate(MAX_COLLAPSED_GROUPS);
    conn.hidden_schemas
        .retain(|schema| !schema.is_empty() && schema.len() <= MAX_SCHEMA_NAME_BYTES);
    conn.hidden_schemas.sort();
    conn.hidden_schemas.dedup();
    conn.hidden_schemas.truncate(MAX_HIDDEN_SCHEMAS);
    retain_known_tabs(conn);
    if conn.tabs.len() > MAX_TABS_PER_CONNECTION {
        conn.tabs.truncate(MAX_TABS_PER_CONNECTION);
    }
    migrate_legacy_tabs(conn);
    for tab in &mut conn.tabs {
        normalize_tab(tab);
    }
    if (conn.active_idx as usize) >= conn.tabs.len() {
        conn.active_idx = 0;
    }
}

fn retain_known_tabs(conn: &mut ConnectionWorkspaceState) {
    let selected = conn.active_idx as usize;
    let mut original_index = 0;
    let mut retained_index = 0;
    let mut active_index = None;
    conn.tabs.retain(|tab| {
        let keep = !matches!(tab, WorkspaceTabRecord::Unknown);
        if keep {
            if original_index == selected {
                active_index = Some(retained_index);
            }
            retained_index += 1;
        }
        original_index += 1;
        keep
    });
    conn.active_idx = active_index.unwrap_or(0);
}

fn migrate_legacy_tabs(conn: &mut ConnectionWorkspaceState) {
    for tab in &mut conn.tabs {
        let migrated = match std::mem::replace(tab, WorkspaceTabRecord::Unknown) {
            WorkspaceTabRecord::Browse {
                schema,
                table,
                offset,
                page_size,
                sort_col,
                sort_asc,
            } => WorkspaceTabRecord::Table {
                schema,
                table,
                mode: PersistedTableMode::Data,
                offset,
                page_size,
                sort_col,
                sort_asc,
                preview: false,
            },
            WorkspaceTabRecord::Structure { schema, table } => WorkspaceTabRecord::Table {
                schema,
                table,
                mode: PersistedTableMode::Structure,
                offset: 0,
                page_size: DEFAULT_PAGE_SIZE,
                sort_col: None,
                sort_asc: None,
                preview: false,
            },
            other => other,
        };
        *tab = migrated;
    }
}

fn normalize_tab(tab: &mut WorkspaceTabRecord) {
    match tab {
        WorkspaceTabRecord::Editor { file, .. } => {
            if file.as_deref().is_some_and(|path| !is_restorable_file(path)) {
                *file = None;
            }
        }
        WorkspaceTabRecord::Table {
            schema,
            table,
            page_size,
            ..
        } => {
            if table.len() > MAX_TABLE_NAME_BYTES {
                let boundary = floor_char_boundary(table, MAX_TABLE_NAME_BYTES);
                table.truncate(boundary);
            }
            if let Some(s) = schema.as_mut()
                && s.len() > MAX_SCHEMA_NAME_BYTES
            {
                let boundary = floor_char_boundary(s, MAX_SCHEMA_NAME_BYTES);
                s.truncate(boundary);
            }
            if !PAGE_SIZE_OPTIONS.contains(page_size) {
                *page_size = DEFAULT_PAGE_SIZE;
            }
        }
        WorkspaceTabRecord::Browse { .. } | WorkspaceTabRecord::Structure { .. } => {}
        WorkspaceTabRecord::Unknown => {}
    }
}

fn floor_char_boundary(s: &str, idx: usize) -> usize {
    if idx >= s.len() {
        return s.len();
    }
    let mut b = idx;
    while b > 0 && !s.is_char_boundary(b) {
        b -= 1;
    }
    b
}

const MAX_FILE_PATH_BYTES: usize = 4096;

fn is_restorable_file(path: &std::path::Path) -> bool {
    path.is_absolute() && path.as_os_str().len() <= MAX_FILE_PATH_BYTES
}

#[cfg(test)]
mod tests;

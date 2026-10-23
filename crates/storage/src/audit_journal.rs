use std::collections::{HashMap, VecDeque};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::{FileExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex, OnceLock, Weak};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tablepro_policy::{
    AuditError, AuditErrorCategory, AuditEvent, AuditOperationClass, AuditRecordPhase, AuditSink, AuditTerminalStatus,
    AuditTransactionOutcome, Principal,
};
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::error::StorageError;

const GENESIS_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";
const LEGACY_SUFFIX: &str = "phase1";

#[path = "audit_journal_cursor.rs"]
mod cursor;

use cursor::{JournalCursor, JournalState};

type WriterSlot = Mutex<Option<JournalCursor>>;
type Writer = Arc<WriterSlot>;

static WRITERS: OnceLock<StdMutex<HashMap<PathBuf, Weak<WriterSlot>>>> = OnceLock::new();

#[derive(Debug, Clone, Serialize, Deserialize)]
struct JournalRecord {
    seq: u64,
    prev_hash: String,
    hash: String,
    event: AuditEvent,
}

/// Parses a line without committing to `AuditEvent`'s current shape --
/// `event` stays the exact bytes it was on disk so the hash can be
/// checked against what was actually written, not a re-serialization
/// of a parsed struct. A future change to `AuditEvent`'s `Serialize`
/// output would otherwise retroactively break verification of every
/// record already on disk.
#[derive(Debug, Deserialize)]
struct JournalRecordRaw<'a> {
    seq: u64,
    prev_hash: String,
    hash: String,
    #[serde(borrow)]
    event: &'a serde_json::value::RawValue,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AuditJournalRecovery {
    legacy_journal: Option<LegacyJournalRotation>,
    recovered_operation_ids: Vec<Uuid>,
    unresolved_operation_ids: Vec<Uuid>,
    unresolved_connection_ids: Vec<Uuid>,
    unresolved_global_write: bool,
}

impl AuditJournalRecovery {
    pub fn legacy_journal(&self) -> Option<&LegacyJournalRotation> {
        self.legacy_journal.as_ref()
    }

    pub fn recovered_operation_ids(&self) -> &[Uuid] {
        &self.recovered_operation_ids
    }

    pub fn unresolved_operation_ids(&self) -> &[Uuid] {
        &self.unresolved_operation_ids
    }

    pub fn unresolved_connection_ids(&self) -> &[Uuid] {
        &self.unresolved_connection_ids
    }

    pub fn has_unresolved_global_writes(&self) -> bool {
        self.unresolved_global_write
    }

    pub fn has_unresolved_writes(&self) -> bool {
        !self.unresolved_operation_ids.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LegacyJournalRotation {
    path: PathBuf,
    records: u64,
}

impl LegacyJournalRotation {
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn records(&self) -> u64 {
        self.records
    }
}

struct VerifiedJournal {
    tail: JournalTail,
    pending_intents: Vec<AuditEvent>,
    unresolved_operation_connections: HashMap<Uuid, Uuid>,
}

struct JournalTail {
    seq: u64,
    hash: String,
}

pub struct AuditJournal {
    path: PathBuf,
    writer: Writer,
    recovery: AuditJournalRecovery,
    // GUI and agentd share the journal. This lease prevents another live
    // process from treating an in-flight intent as a crash during startup.
    _active_lock_file: File,
}

impl AuditJournal {
    pub fn open_default() -> Result<Self, StorageError> {
        Self::open_validated(journal_path()?)
    }

    pub fn open_validated(path: PathBuf) -> Result<Self, StorageError> {
        let path = absolute_path(path);
        let (recovery, active_lock_file, cursor) = initialize(&path)?;
        let writer = writer_for(&path);
        if let Ok(mut current) = writer.try_lock() {
            *current = Some(cursor);
        }
        Ok(Self {
            writer,
            path,
            recovery,
            _active_lock_file: active_lock_file,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn recovery(&self) -> &AuditJournalRecovery {
        &self.recovery
    }

    pub async fn append(&self, event: AuditEvent) -> Result<(), StorageError> {
        self.append_record(event, false).await
    }

    pub async fn append_durable(&self, event: AuditEvent) -> Result<(), StorageError> {
        self.append_record(event, true).await
    }

    pub async fn verify_chain(&self) -> Result<u64, StorageError> {
        let _writer = self.writer.lock().await;
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || {
            let initialization_lock = open_initialization_lock(&path)?;
            let _initialization_guard = FileLock::exclusive(&initialization_lock.file)?;
            let mut file = open_file(&path)?.file;
            let _lock = FileLock::exclusive(&file)?;
            Ok(verify_locked(&mut file, false)?.tail.seq)
        })
        .await
        .map_err(join_error)?
    }

    pub async fn recent(&self, limit: usize) -> Result<Vec<AuditEvent>, StorageError> {
        let _writer = self.writer.lock().await;
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || {
            let initialization_lock = open_initialization_lock(&path)?;
            let _initialization_guard = FileLock::exclusive(&initialization_lock.file)?;
            let mut file = open_file(&path)?.file;
            let _lock = FileLock::exclusive(&file)?;
            let (_, events) = verify_locked_with_recent(&mut file, false, Some(limit))?;
            Ok(events)
        })
        .await
        .map_err(join_error)?
    }

    async fn append_record(&self, event: AuditEvent, durable: bool) -> Result<(), StorageError> {
        let mut writer = self.writer.lock().await;
        let path = self.path.clone();
        let cursor = writer.take();
        let next = tokio::task::spawn_blocking(move || append_locked(&path, event, durable, cursor))
            .await
            .map_err(join_error)??;
        *writer = Some(next);
        Ok(())
    }
}

fn writer_for(path: &Path) -> Writer {
    let writers = WRITERS.get_or_init(|| StdMutex::new(HashMap::new()));
    let mut writers = writers.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    writers.retain(|_, writer| writer.strong_count() > 0);
    if let Some(writer) = writers.get(path).and_then(Weak::upgrade) {
        return writer;
    }
    let writer = Arc::new(Mutex::new(None));
    writers.insert(path.to_path_buf(), Arc::downgrade(&writer));
    writer
}

fn absolute_path(path: PathBuf) -> PathBuf {
    if path.is_absolute() {
        return path;
    }
    std::env::current_dir().map_or(path.clone(), |current| current.join(path))
}

fn initialize(path: &Path) -> Result<(AuditJournalRecovery, File, JournalCursor), StorageError> {
    create_parent(path)?;
    let lock_file = open_initialization_lock(path)?;
    let active_lock = open_active_lock(path)?;
    let initialization_lock = FileLock::exclusive(&lock_file.file)?;

    if !try_exclusive_lock(&active_lock.file)? {
        // A live owner exists. Validate its journal state without repairing it.
        drop(initialization_lock);
        acquire_shared_lock(&active_lock.file)?;
        let _initialization_lock = FileLock::exclusive(&lock_file.file)?;
        let mut opened = open_file(path)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        let _journal_lock = FileLock::exclusive(&opened.file)?;
        let verified = verify_locked(&mut opened.file, false)?;
        let recovery = AuditJournalRecovery {
            legacy_journal: None,
            recovered_operation_ids: Vec::new(),
            unresolved_operation_ids: sorted_operation_ids(&verified.unresolved_operation_connections),
            unresolved_connection_ids: unresolved_connection_ids(&verified),
            unresolved_global_write: has_unresolved_global_write(&verified),
        };
        let cursor = JournalCursor::at_end_of(&opened.file, JournalState::from_verified(verified))?;
        return Ok((recovery, active_lock.file, cursor));
    }

    let legacy_journal = rotate_legacy_journal(path)?;
    let mut opened = open_file(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    let verified = verify_locked(&mut opened.file, true)?;
    let verified = recover_pending_intents(&mut opened.file, verified)?;
    opened.file.flush()?;
    sync_created_file_and_parent(&opened, path)?;
    acquire_shared_lock(&active_lock.file)?;
    let unresolved_operation_ids = sorted_operation_ids(&verified.unresolved_operation_connections);
    let recovery = AuditJournalRecovery {
        legacy_journal,
        recovered_operation_ids: unresolved_operation_ids.clone(),
        unresolved_operation_ids,
        unresolved_connection_ids: unresolved_connection_ids(&verified),
        unresolved_global_write: has_unresolved_global_write(&verified),
    };
    let cursor = JournalCursor::at_end_of(&opened.file, JournalState::from_verified(verified))?;
    Ok((recovery, active_lock.file, cursor))
}

fn create_parent(path: &Path) -> Result<(), StorageError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}

struct OpenedFile {
    file: File,
    created: bool,
}

fn open_file(path: &Path) -> Result<OpenedFile, StorageError> {
    open_file_with_options(path, true)
}

fn open_initialization_lock(path: &Path) -> Result<OpenedFile, StorageError> {
    let lock_path = sibling_path(path, "lock")?;
    let opened = open_file_with_options(&lock_path, false)?;
    sync_created_file_and_parent(&opened, &lock_path)?;
    Ok(opened)
}

fn open_active_lock(path: &Path) -> Result<OpenedFile, StorageError> {
    let lock_path = sibling_path(path, "active")?;
    let opened = open_file_with_options(&lock_path, false)?;
    std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o600))?;
    sync_created_file_and_parent(&opened, &lock_path)?;
    Ok(opened)
}

fn try_exclusive_lock(file: &File) -> Result<bool, StorageError> {
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result == 0 {
        return Ok(true);
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::WouldBlock {
        return Ok(false);
    }
    Err(error.into())
}

fn acquire_shared_lock(file: &File) -> Result<(), StorageError> {
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH) };
    if result != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

fn open_file_with_options(path: &Path, append: bool) -> Result<OpenedFile, StorageError> {
    let created = !path.exists();
    let file = OpenOptions::new()
        .read(true)
        .write(!append)
        .append(append)
        .create(true)
        .mode(0o600)
        .open(path)?;
    Ok(OpenedFile { file, created })
}

fn sync_created_file_and_parent(opened: &OpenedFile, path: &Path) -> Result<(), StorageError> {
    if !opened.created {
        return Ok(());
    }
    opened.file.sync_all()?;
    sync_parent(path)
}

fn sync_parent(path: &Path) -> Result<(), StorageError> {
    let Some(parent) = path.parent() else {
        return Ok(());
    };
    File::open(parent)?.sync_all()?;
    Ok(())
}

fn rotate_legacy_journal(path: &Path) -> Result<Option<LegacyJournalRotation>, StorageError> {
    if !path.exists() || std::fs::metadata(path)?.len() == 0 {
        return Ok(None);
    }
    let bytes = std::fs::read(path)?;
    let Some(first_line) = first_record_line(&bytes) else {
        return Ok(None);
    };
    if serde_json::from_slice::<JournalRecord>(first_line).is_ok() {
        return Ok(None);
    }

    let records = verify_legacy_chain(&bytes)?;
    let legacy_path = sibling_path(path, LEGACY_SUFFIX)?;
    if legacy_path.exists() {
        return Err(StorageError::Schema(format!(
            "legacy audit journal backup already exists at {}",
            legacy_path.display()
        )));
    }
    std::fs::rename(path, &legacy_path)?;
    std::fs::set_permissions(&legacy_path, std::fs::Permissions::from_mode(0o600))?;
    File::open(&legacy_path)?.sync_all()?;
    sync_parent(path)?;

    Ok(Some(LegacyJournalRotation {
        path: legacy_path,
        records,
    }))
}

fn sibling_path(path: &Path, suffix: &str) -> Result<PathBuf, StorageError> {
    let file_name = path
        .file_name()
        .ok_or_else(|| StorageError::Schema("audit journal path has no file name".into()))?;
    let mut suffixed = file_name.to_os_string();
    suffixed.push(".");
    suffixed.push(suffix);
    Ok(path.with_file_name(suffixed))
}

fn first_record_line(bytes: &[u8]) -> Option<&[u8]> {
    bytes
        .split(|byte| *byte == b'\n')
        .find(|line| !line.iter().all(u8::is_ascii_whitespace))
}

fn append_locked(
    path: &Path,
    event: AuditEvent,
    durable: bool,
    cursor: Option<JournalCursor>,
) -> Result<JournalCursor, StorageError> {
    create_parent(path)?;
    let initialization_lock = open_initialization_lock(path)?;
    let _initialization_guard = FileLock::exclusive(&initialization_lock.file)?;
    let mut opened = open_file(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    let _lock = FileLock::exclusive(&opened.file)?;
    let mut state = resume_verified_state(&mut opened.file, cursor)?;
    reject_new_write_intent(&event, &state.pending, &state.unresolved)?;
    track_operation_state(&mut state.pending, &mut state.unresolved, &event);
    state.tail = append_to_file(&mut opened.file, state.tail, event, durable)?;
    sync_created_file_and_parent(&opened, path)?;
    JournalCursor::at_end_of(&opened.file, state)
}

fn resume_verified_state(file: &mut File, cursor: Option<JournalCursor>) -> Result<JournalState, StorageError> {
    let metadata = file.metadata()?;
    let resumable = match &cursor {
        Some(cursor) => cursor.still_describes(&metadata) && starts_a_line(file, cursor.offset)?,
        None => false,
    };
    let (state, offset) = match cursor {
        Some(cursor) if resumable => (cursor.state, cursor.offset),
        _ => (JournalState::genesis(), 0),
    };
    scan_records(file, state, offset, true, None).map(|(state, _)| state)
}

fn append_to_file(
    file: &mut File,
    tail: JournalTail,
    event: AuditEvent,
    durable: bool,
) -> Result<JournalTail, StorageError> {
    append_to_file_with_sync(file, tail, event, durable, File::sync_data)
}

fn append_to_file_with_sync(
    file: &mut File,
    tail: JournalTail,
    event: AuditEvent,
    durable: bool,
    sync_data: impl FnOnce(&File) -> std::io::Result<()>,
) -> Result<JournalTail, StorageError> {
    let seq = tail
        .seq
        .checked_add(1)
        .ok_or_else(|| StorageError::Schema("audit journal sequence exhausted".into()))?;
    let payload = serde_json::to_vec(&event)?;
    let hash = record_hash(&tail.hash, seq, &payload);
    let record = JournalRecord {
        seq,
        prev_hash: tail.hash,
        hash: hash.clone(),
        event,
    };
    let mut line = serde_json::to_vec(&record)?;
    line.push(b'\n');
    file.write_all(&line)?;
    file.flush()?;
    if durable {
        sync_data(file)?;
    }
    Ok(JournalTail { seq, hash })
}

fn verify_locked(file: &mut File, recover_partial: bool) -> Result<VerifiedJournal, StorageError> {
    verify_locked_with_recent(file, recover_partial, None).map(|(verified, _)| verified)
}

fn starts_a_line(file: &File, offset: u64) -> Result<bool, StorageError> {
    let Some(previous) = offset.checked_sub(1) else {
        return Ok(true);
    };
    let mut byte = [0u8; 1];
    file.read_exact_at(&mut byte, previous)?;
    Ok(byte[0] == b'\n')
}

fn verify_locked_with_recent(
    file: &mut File,
    recover_partial: bool,
    recent_limit: Option<usize>,
) -> Result<(VerifiedJournal, Vec<AuditEvent>), StorageError> {
    let (state, recent) = scan_records(file, JournalState::genesis(), 0, recover_partial, recent_limit)?;
    Ok((verified_journal(state.tail, state.pending, state.unresolved), recent))
}

fn scan_records(
    file: &mut File,
    mut state: JournalState,
    start: u64,
    recover_partial: bool,
    recent_limit: Option<usize>,
) -> Result<(JournalState, Vec<AuditEvent>), StorageError> {
    file.seek(SeekFrom::Start(start))?;
    let mut reader = BufReader::new(file);
    let mut recent = VecDeque::new();
    let mut offset = usize::try_from(start).map_err(|_| StorageError::Schema("audit journal is too large".into()))?;
    let mut line = Vec::new();

    loop {
        line.clear();
        let bytes_read = reader.read_until(b'\n', &mut line)?;
        if bytes_read == 0 {
            break;
        }
        let terminated = line.last() == Some(&b'\n');
        if terminated {
            line.pop();
        }
        let next_offset = offset + bytes_read;
        if line.iter().all(u8::is_ascii_whitespace) {
            if !terminated && recover_partial {
                let file = reader.get_mut();
                file.set_len(offset as u64)?;
                file.sync_data()?;
            }
            offset = next_offset;
            continue;
        }

        let raw = match serde_json::from_slice::<JournalRecordRaw>(&line) {
            Ok(raw) => raw,
            Err(_) if !terminated && recover_partial => {
                let file = reader.get_mut();
                file.set_len(offset as u64)?;
                file.sync_data()?;
                break;
            }
            Err(error) => return Err(error.into()),
        };
        state.tail = track_verified_record(&raw, &mut state, &mut recent, recent_limit)?;

        if !terminated && recover_partial {
            let file = reader.get_mut();
            file.seek(SeekFrom::End(0))?;
            file.write_all(b"\n")?;
            file.sync_data()?;
        }
        offset = next_offset;
    }

    Ok((state, recent.into_iter().collect()))
}

fn verified_journal(
    tail: JournalTail,
    pending: HashMap<Uuid, AuditEvent>,
    unresolved: HashMap<Uuid, Uuid>,
) -> VerifiedJournal {
    let mut pending_intents: Vec<_> = pending.into_values().collect();
    pending_intents.sort_by_key(|event| event.operation_id);
    VerifiedJournal {
        tail,
        pending_intents,
        unresolved_operation_connections: unresolved,
    }
}

fn track_verified_record(
    raw: &JournalRecordRaw,
    state: &mut JournalState,
    recent: &mut VecDeque<AuditEvent>,
    recent_limit: Option<usize>,
) -> Result<JournalTail, StorageError> {
    validate_chain_fields(
        raw.seq,
        &raw.prev_hash,
        &raw.hash,
        &state.tail,
        raw.event.get().as_bytes(),
    )?;
    let event: AuditEvent = serde_json::from_str(raw.event.get())?;
    track_operation_state(&mut state.pending, &mut state.unresolved, &event);
    if let Some(limit) = recent_limit.filter(|limit| *limit > 0) {
        recent.push_back(event);
        if recent.len() > limit {
            recent.pop_front();
        }
    }
    Ok(JournalTail {
        seq: raw.seq,
        hash: raw.hash.clone(),
    })
}

fn track_operation_state(
    pending: &mut HashMap<Uuid, AuditEvent>,
    unresolved: &mut HashMap<Uuid, Uuid>,
    event: &AuditEvent,
) {
    match event.phase {
        AuditRecordPhase::Intent => {
            pending.insert(event.operation_id, event.clone());
        }
        AuditRecordPhase::Outcome => {
            pending.remove(&event.operation_id);
            if event.operation_class.is_write() && event.terminal_status == AuditTerminalStatus::Unknown {
                unresolved.insert(event.operation_id, event.connection_id);
            } else {
                unresolved.remove(&event.operation_id);
            }
        }
    }
}

fn reject_new_write_intent(
    event: &AuditEvent,
    pending: &HashMap<Uuid, AuditEvent>,
    unresolved: &HashMap<Uuid, Uuid>,
) -> Result<(), StorageError> {
    if event.phase != AuditRecordPhase::Intent
        || !event.operation_class.is_write()
        || event.operation_class == AuditOperationClass::TransactionRollback
    {
        return Ok(());
    }
    let blocked_by_pending_write = pending.values().any(|intent| {
        intent.operation_class.is_write() && write_scope_blocks(event.connection_id, intent.connection_id)
    });
    let blocked_by_unresolved_write = unresolved
        .values()
        .any(|connection_id| write_scope_blocks(event.connection_id, *connection_id));
    if blocked_by_unresolved_write {
        return Err(StorageError::UnresolvedWrite);
    }
    if blocked_by_pending_write {
        return Err(StorageError::WriteInFlight);
    }
    Ok(())
}

fn write_scope_blocks(request_connection_id: Uuid, blocking_connection_id: Uuid) -> bool {
    request_connection_id.is_nil() || blocking_connection_id.is_nil() || request_connection_id == blocking_connection_id
}

fn recover_pending_intents(file: &mut File, mut verified: VerifiedJournal) -> Result<VerifiedJournal, StorageError> {
    let mut tail = verified.tail;
    for intent in std::mem::take(&mut verified.pending_intents) {
        let operation_id = intent.operation_id;
        let connection_id = intent.connection_id;
        let is_write = intent.operation_class.is_write();
        tail = append_to_file(file, tail, recovery_outcome(intent), true)?;
        if is_write {
            verified
                .unresolved_operation_connections
                .insert(operation_id, connection_id);
        }
    }
    verified.tail = tail;
    Ok(verified)
}

fn sorted_operation_ids(unresolved: &HashMap<Uuid, Uuid>) -> Vec<Uuid> {
    let mut operation_ids: Vec<_> = unresolved.keys().copied().collect();
    operation_ids.sort_unstable();
    operation_ids
}

fn unresolved_connection_ids(verified: &VerifiedJournal) -> Vec<Uuid> {
    let mut connection_ids: Vec<_> = verified
        .unresolved_operation_connections
        .values()
        .copied()
        .chain(
            verified
                .pending_intents
                .iter()
                .filter(|event| event.operation_class.is_write())
                .map(|event| event.connection_id),
        )
        .filter(|connection_id| !connection_id.is_nil())
        .collect();
    connection_ids.sort_unstable();
    connection_ids.dedup();
    connection_ids
}

fn has_unresolved_global_write(verified: &VerifiedJournal) -> bool {
    verified.unresolved_operation_connections.values().any(Uuid::is_nil)
        || verified
            .pending_intents
            .iter()
            .any(|event| event.operation_class.is_write() && event.connection_id.is_nil())
}

fn recovery_outcome(mut intent: AuditEvent) -> AuditEvent {
    intent.timestamp = Utc::now();
    intent.phase = AuditRecordPhase::Outcome;
    intent.terminal_status = AuditTerminalStatus::Unknown;
    intent.transaction_outcome = if matches!(
        intent.operation_class,
        AuditOperationClass::TransactionCommit | AuditOperationClass::TransactionRollback
    ) {
        AuditTransactionOutcome::Unknown
    } else {
        AuditTransactionOutcome::NotApplicable
    };
    intent.error_category = Some(AuditErrorCategory::Audit);
    intent.error = Some("operation outcome was unknown after audit journal recovery".into());
    intent.rows_affected = None;
    intent.duration_ms = None;
    intent
}

fn validate_chain_fields(
    seq: u64,
    previous_hash: &str,
    hash: &str,
    tail: &JournalTail,
    payload: &[u8],
) -> Result<(), StorageError> {
    let expected_seq = tail
        .seq
        .checked_add(1)
        .ok_or_else(|| StorageError::Schema("audit journal sequence exhausted".into()))?;
    if seq != expected_seq {
        return Err(StorageError::Schema(format!(
            "audit journal sequence mismatch: expected {expected_seq}, found {seq}"
        )));
    }
    if previous_hash != tail.hash {
        return Err(StorageError::Schema(format!("audit journal chain break at seq {seq}")));
    }
    let expected_hash = record_hash(&tail.hash, seq, payload);
    if expected_hash != hash {
        return Err(StorageError::Schema(format!(
            "audit journal hash mismatch at seq {seq}"
        )));
    }
    Ok(())
}

fn record_hash(previous_hash: &str, seq: u64, payload: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(previous_hash.as_bytes());
    hasher.update(seq.to_string().as_bytes());
    hasher.update(payload);
    hex::encode(hasher.finalize())
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyJournalRecord {
    seq: u64,
    prev_hash: String,
    hash: String,
    event: LegacyAuditEvent,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyAuditEvent {
    timestamp: DateTime<Utc>,
    principal: LegacyPrincipal,
    connection_id: Uuid,
    connection_name: String,
    environment: LegacyEnvironment,
    driver_id: String,
    sql: String,
    decision_rule: String,
    decision_kind: String,
    rows_affected: Option<u64>,
    duration_ms: u64,
    error: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum LegacyPrincipal {
    Human {
        #[serde(default = "legacy_default_session")]
        session: String,
    },
    Agent {
        token: String,
        #[serde(default)]
        client: Option<String>,
        #[serde(default)]
        model: Option<String>,
    },
}

fn legacy_default_session() -> String {
    "gui".into()
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum LegacyEnvironment {
    Local,
    Dev,
    Staging,
    Prod,
}

fn verify_legacy_chain(bytes: &[u8]) -> Result<u64, StorageError> {
    let mut tail = JournalTail {
        seq: 0,
        hash: GENESIS_HASH.to_string(),
    };
    for line in bytes.split(|byte| *byte == b'\n') {
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let record: LegacyJournalRecord = serde_json::from_slice(line)?;
        let payload = serde_json::to_vec(&record.event)?;
        validate_chain_fields(record.seq, &record.prev_hash, &record.hash, &tail, &payload)?;
        tail = JournalTail {
            seq: record.seq,
            hash: record.hash,
        };
    }
    Ok(tail.seq)
}

struct FileLock {
    descriptor: RawFd,
}

impl FileLock {
    fn exclusive(file: &File) -> Result<Self, StorageError> {
        let descriptor = file.as_raw_fd();
        let result = unsafe { libc::flock(descriptor, libc::LOCK_EX) };
        if result != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(Self { descriptor })
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.descriptor, libc::LOCK_UN);
        }
    }
}

fn join_error(error: tokio::task::JoinError) -> StorageError {
    StorageError::Schema(format!("audit journal task failed: {error}"))
}

fn journal_path() -> Result<PathBuf, StorageError> {
    crate::data_path("audit.jsonl")
}

#[async_trait]
impl AuditSink for AuditJournal {
    async fn record(&self, event: AuditEvent) -> Result<(), AuditError> {
        let durable = event.phase == AuditRecordPhase::Intent
            || event.operation_class == AuditOperationClass::TransactionCommit
            || event.administrative_action.is_some();
        self.append_record(event, durable).await.map_err(|error| match error {
            StorageError::UnresolvedWrite => AuditError::UnresolvedWrite,
            StorageError::WriteInFlight => AuditError::WriteInFlight,
            error => AuditError::Persistence(error.to_string()),
        })
    }
}

pub fn sample_event(principal: Principal) -> AuditEvent {
    use tablepro_core::Environment;

    AuditEvent {
        timestamp: Utc::now(),
        operation_id: Uuid::new_v4(),
        batch_id: None,
        phase: AuditRecordPhase::Outcome,
        principal,
        connection_id: Uuid::nil(),
        connection_name: "test".into(),
        environment: Environment::Local,
        driver_id: "postgres".into(),
        operation_class: AuditOperationClass::Read,
        redacted_sql: "[REDACTED]".into(),
        sql_hash: hex::encode(Sha256::digest(b"SELECT 1")),
        targets: Vec::new(),
        decision_rule: "read_allow".into(),
        approval_outcome: tablepro_policy::AuditApprovalOutcome::NotRequired,
        preview_state: tablepro_policy::AuditPreviewState::NotRequested,
        terminal_status: AuditTerminalStatus::Succeeded,
        transaction_outcome: AuditTransactionOutcome::NotApplicable,
        error_category: None,
        error: None,
        rows_affected: Some(1),
        duration_ms: Some(1),
        transport_attempt: None,
        administrative_action: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_policy::Principal;
    use tempfile::TempDir;

    #[tokio::test]
    async fn append_and_verify() {
        let dir = TempDir::new().unwrap();
        let journal = AuditJournal::open_validated(dir.path().join("audit.jsonl")).unwrap();
        journal.append(sample_event(Principal::human_gui())).await.unwrap();
        journal
            .append(sample_event(Principal::Agent {
                token: "abc".into(),
                client: Some("cursor".into()),
                model: None,
            }))
            .await
            .unwrap();
        assert_eq!(journal.verify_chain().await.unwrap(), 2);
        assert_eq!(journal.recent(10).await.unwrap().len(), 2);
    }

    #[tokio::test]
    async fn recent_returns_the_requested_tail_in_chronological_order() {
        let dir = TempDir::new().unwrap();
        let journal = AuditJournal::open_validated(dir.path().join("audit.jsonl")).unwrap();
        let operation_ids = [Uuid::from_u128(1), Uuid::from_u128(2), Uuid::from_u128(3)];
        for operation_id in operation_ids {
            let mut event = sample_event(Principal::human_gui());
            event.operation_id = operation_id;
            journal.append(event).await.unwrap();
        }

        let recent = journal.recent(2).await.unwrap();
        assert_eq!(
            recent.iter().map(|event| event.operation_id).collect::<Vec<_>>(),
            operation_ids[1..].to_vec()
        );
        assert!(journal.recent(0).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn recent_preserves_a_complete_record_without_a_line_terminator() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("audit.jsonl");
        let journal = AuditJournal::open_validated(path.clone()).unwrap();
        let event = sample_event(Principal::human_gui());
        let operation_id = event.operation_id;
        journal.append(event).await.unwrap();
        let mut bytes = tokio::fs::read(&path).await.unwrap();
        assert_eq!(bytes.pop(), Some(b'\n'));
        tokio::fs::write(&path, &bytes).await.unwrap();

        let recent = journal.recent(1).await.unwrap();

        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].operation_id, operation_id);
        assert_eq!(tokio::fs::read(path).await.unwrap(), bytes);
    }

    #[test]
    fn verification_starts_at_the_beginning_of_the_file() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("audit.jsonl");
        let event = sample_event(Principal::human_gui());
        let operation_id = event.operation_id;
        append_locked(&path, event, false, None).unwrap();
        let mut file = open_file(&path).unwrap().file;
        file.seek(SeekFrom::End(0)).unwrap();

        let (_, recent) = verify_locked_with_recent(&mut file, false, Some(1)).unwrap();

        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].operation_id, operation_id);
    }

    #[tokio::test]
    async fn a_pending_write_is_distinct_from_an_unknown_outcome() {
        let dir = TempDir::new().unwrap();
        let journal = AuditJournal::open_validated(dir.path().join("audit.jsonl")).unwrap();
        let connection_id = Uuid::new_v4();
        let first = write_event(connection_id, AuditRecordPhase::Intent, AuditTerminalStatus::Pending);
        journal.record(first.clone()).await.unwrap();
        journal
            .record(write_event(
                Uuid::new_v4(),
                AuditRecordPhase::Intent,
                AuditTerminalStatus::Pending,
            ))
            .await
            .unwrap();

        let competing = write_event(connection_id, AuditRecordPhase::Intent, AuditTerminalStatus::Pending);
        assert!(matches!(
            journal.record(competing).await,
            Err(AuditError::WriteInFlight)
        ));

        journal
            .record(write_event_for(&first, AuditTerminalStatus::Succeeded))
            .await
            .unwrap();
        journal
            .record(write_event(
                connection_id,
                AuditRecordPhase::Intent,
                AuditTerminalStatus::Pending,
            ))
            .await
            .unwrap();

        let unresolved_dir = TempDir::new().unwrap();
        let unresolved = AuditJournal::open_validated(unresolved_dir.path().join("audit.jsonl")).unwrap();
        let unknown = write_event(connection_id, AuditRecordPhase::Intent, AuditTerminalStatus::Pending);
        unresolved.record(unknown.clone()).await.unwrap();
        unresolved
            .record(write_event_for(&unknown, AuditTerminalStatus::Unknown))
            .await
            .unwrap();
        let next = write_event(connection_id, AuditRecordPhase::Intent, AuditTerminalStatus::Pending);
        assert!(matches!(
            unresolved.record(next).await,
            Err(AuditError::UnresolvedWrite)
        ));
    }

    #[tokio::test]
    async fn a_rollback_is_never_blocked_by_an_unresolved_write_but_a_commit_still_is() {
        let dir = TempDir::new().unwrap();
        let journal = AuditJournal::open_validated(dir.path().join("audit.jsonl")).unwrap();
        let connection_id = Uuid::new_v4();
        let unknown = write_event(connection_id, AuditRecordPhase::Intent, AuditTerminalStatus::Pending);
        journal.record(unknown.clone()).await.unwrap();
        journal
            .record(write_event_for(&unknown, AuditTerminalStatus::Unknown))
            .await
            .unwrap();

        let mut rollback = write_event(connection_id, AuditRecordPhase::Intent, AuditTerminalStatus::Pending);
        rollback.operation_class = AuditOperationClass::TransactionRollback;
        journal
            .record(rollback.clone())
            .await
            .expect("ending a transaction on a blocked connection is allowed");
        journal
            .record(write_event_for(&rollback, AuditTerminalStatus::Succeeded))
            .await
            .unwrap();

        let mut commit = rollback.clone();
        commit.operation_id = Uuid::new_v4();
        commit.operation_class = AuditOperationClass::TransactionCommit;
        assert!(matches!(journal.record(commit).await, Err(AuditError::UnresolvedWrite)));
        let next = write_event(connection_id, AuditRecordPhase::Intent, AuditTerminalStatus::Pending);
        assert!(
            matches!(journal.record(next).await, Err(AuditError::UnresolvedWrite)),
            "the earlier outcome stays unresolved after the rollback"
        );
    }

    fn write_event(connection_id: Uuid, phase: AuditRecordPhase, status: AuditTerminalStatus) -> AuditEvent {
        let mut event = sample_event(Principal::human_gui());
        event.connection_id = connection_id;
        event.operation_class = AuditOperationClass::Mutation;
        event.phase = phase;
        event.terminal_status = status;
        event
    }

    fn write_event_for(intent: &AuditEvent, status: AuditTerminalStatus) -> AuditEvent {
        let mut event = intent.clone();
        event.phase = AuditRecordPhase::Outcome;
        event.terminal_status = status;
        event
    }

    #[test]
    fn durable_append_fails_when_data_sync_fails() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("audit.jsonl");
        let mut file = OpenOptions::new().create(true).append(true).open(path).unwrap();
        let error = append_to_file_with_sync(
            &mut file,
            JournalTail {
                seq: 0,
                hash: GENESIS_HASH.to_string(),
            },
            sample_event(Principal::human_gui()),
            true,
            |_| Err(std::io::Error::other("injected sync failure")),
        );

        assert!(error.is_err());
    }

    #[test]
    fn durable_creation_propagates_parent_sync_failure() {
        let dir = TempDir::new().unwrap();
        let parent = dir.path().join("journal");
        std::fs::create_dir(&parent).unwrap();
        let path = parent.join("audit.jsonl");
        let opened = open_file(&path).unwrap();
        assert!(opened.created);

        let moved_parent = dir.path().join("moved-journal");
        std::fs::rename(&parent, moved_parent).unwrap();

        assert!(sync_created_file_and_parent(&opened, &path).is_err());
    }

    #[tokio::test]
    async fn a_record_with_non_canonical_whitespace_in_its_event_json_still_verifies() {
        // Simulates a record written by a differently-formatted (but
        // semantically identical) serialization of AuditEvent -- e.g.
        // a future field-order or whitespace change. Hashing the raw
        // on-disk bytes must still validate it; re-serializing the
        // parsed struct to recompute the hash would not reproduce
        // these exact bytes and would wrongly reject it as tampered.
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("audit.jsonl");
        let event = sample_event(Principal::human_gui());
        let canonical = serde_json::to_string(&event).unwrap();
        let padded = canonical.replacen(':', ":  ", 1);
        assert_ne!(padded, canonical);
        let hash = record_hash(GENESIS_HASH, 1, padded.as_bytes());
        let line = format!(r#"{{"seq":1,"prev_hash":"{GENESIS_HASH}","hash":"{hash}","event":{padded}}}"#);
        tokio::fs::write(&path, format!("{line}\n")).await.unwrap();
        let journal =
            AuditJournal::open_validated(path).expect("a non-canonical but faithfully hashed record must verify");
        assert!(!journal.recovery().has_unresolved_writes());
    }

    #[tokio::test]
    async fn detects_tamper() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("audit.jsonl");
        let journal = AuditJournal::open_validated(path.clone()).unwrap();
        journal.append(sample_event(Principal::human_gui())).await.unwrap();
        let mut text = tokio::fs::read_to_string(&path).await.unwrap();
        text = text.replace("read_allow", "read_deny");
        tokio::fs::write(&path, text).await.unwrap();
        assert!(journal.verify_chain().await.is_err());
        assert!(AuditJournal::open_validated(path).is_err());
    }

    #[tokio::test]
    async fn recent_with_a_short_limit_still_detects_tampering_in_older_records() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("audit.jsonl");
        let journal = AuditJournal::open_validated(path.clone()).unwrap();
        for _ in 0..3 {
            journal.append(sample_event(Principal::human_gui())).await.unwrap();
        }
        let mut text = tokio::fs::read_to_string(&path).await.unwrap();
        text = text.replacen("read_allow", "read_deny", 1);
        tokio::fs::write(path, text).await.unwrap();

        assert!(journal.recent(1).await.is_err());
    }
}

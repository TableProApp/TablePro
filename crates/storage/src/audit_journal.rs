use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
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

static WRITERS: OnceLock<StdMutex<HashMap<PathBuf, Weak<Mutex<()>>>>> = OnceLock::new();

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
    unresolved_operation_ids: Vec<Uuid>,
}

struct JournalTail {
    seq: u64,
    hash: String,
}

pub struct AuditJournal {
    path: PathBuf,
    writer: Arc<Mutex<()>>,
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
        let (recovery, active_lock_file) = initialize(&path)?;
        Ok(Self {
            writer: writer_for(&path),
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
            verify_locked(&mut file, false)?;
            file.seek(SeekFrom::Start(0))?;
            let mut bytes = Vec::new();
            file.read_to_end(&mut bytes)?;
            let mut events = Vec::new();
            for line in bytes.split(|byte| *byte == b'\n') {
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                let record: JournalRecord = serde_json::from_slice(line)?;
                events.push(record.event);
            }
            if events.len() > limit {
                events = events.split_off(events.len() - limit);
            }
            Ok(events)
        })
        .await
        .map_err(join_error)?
    }

    async fn append_record(&self, event: AuditEvent, durable: bool) -> Result<(), StorageError> {
        let _writer = self.writer.lock().await;
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || append_locked(&path, event, durable))
            .await
            .map_err(join_error)?
    }
}

fn writer_for(path: &Path) -> Arc<Mutex<()>> {
    let writers = WRITERS.get_or_init(|| StdMutex::new(HashMap::new()));
    let mut writers = writers.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    writers.retain(|_, writer| writer.strong_count() > 0);
    if let Some(writer) = writers.get(path).and_then(Weak::upgrade) {
        return writer;
    }
    let writer = Arc::new(Mutex::new(()));
    writers.insert(path.to_path_buf(), Arc::downgrade(&writer));
    writer
}

fn absolute_path(path: PathBuf) -> PathBuf {
    if path.is_absolute() {
        return path;
    }
    std::env::current_dir().map_or(path.clone(), |current| current.join(path))
}

fn initialize(path: &Path) -> Result<(AuditJournalRecovery, File), StorageError> {
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
        return Ok((
            AuditJournalRecovery {
                legacy_journal: None,
                recovered_operation_ids: Vec::new(),
                unresolved_operation_ids: verified.unresolved_operation_ids,
            },
            active_lock.file,
        ));
    }

    let legacy_journal = rotate_legacy_journal(path)?;
    let mut opened = open_file(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    let verified = verify_locked(&mut opened.file, true)?;
    let unresolved_operation_ids = recover_pending_intents(&mut opened.file, verified)?;
    opened.file.flush()?;
    sync_created_file_and_parent(&opened, path)?;
    acquire_shared_lock(&active_lock.file)?;

    Ok((
        AuditJournalRecovery {
            legacy_journal,
            recovered_operation_ids: unresolved_operation_ids.clone(),
            unresolved_operation_ids,
        },
        active_lock.file,
    ))
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

fn append_locked(path: &Path, event: AuditEvent, durable: bool) -> Result<(), StorageError> {
    create_parent(path)?;
    let initialization_lock = open_initialization_lock(path)?;
    let _initialization_guard = FileLock::exclusive(&initialization_lock.file)?;
    let mut opened = open_file(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    let _lock = FileLock::exclusive(&opened.file)?;
    let verified = verify_locked(&mut opened.file, true)?;
    reject_new_write_intent(&event, &verified)?;
    append_to_file(&mut opened.file, verified.tail, event, durable)?;
    sync_created_file_and_parent(&opened, path)
}

fn append_to_file(
    file: &mut File,
    tail: JournalTail,
    event: AuditEvent,
    durable: bool,
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
        file.sync_data()?;
    }
    Ok(JournalTail { seq, hash })
}

fn verify_locked(file: &mut File, recover_partial: bool) -> Result<VerifiedJournal, StorageError> {
    file.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    let mut tail = JournalTail {
        seq: 0,
        hash: GENESIS_HASH.to_string(),
    };
    let mut pending = HashMap::new();
    let mut unresolved = HashMap::new();
    let mut offset = 0usize;

    while offset < bytes.len() {
        let remaining = &bytes[offset..];
        let newline = remaining.iter().position(|byte| *byte == b'\n');
        let (line, terminated) = match newline {
            Some(index) => (&remaining[..index], true),
            None => (remaining, false),
        };
        let next_offset = offset + line.len() + usize::from(terminated);
        if line.iter().all(u8::is_ascii_whitespace) {
            if !terminated && recover_partial {
                file.set_len(offset as u64)?;
                file.sync_data()?;
            }
            offset = next_offset;
            continue;
        }

        let raw = match serde_json::from_slice::<JournalRecordRaw>(line) {
            Ok(raw) => raw,
            Err(_) if !terminated && recover_partial => {
                file.set_len(offset as u64)?;
                file.sync_data()?;
                break;
            }
            Err(error) => return Err(error.into()),
        };
        validate_chain_fields(raw.seq, &raw.prev_hash, &raw.hash, &tail, raw.event.get().as_bytes())?;
        let event: AuditEvent = serde_json::from_str(raw.event.get())?;
        track_operation_state(&mut pending, &mut unresolved, &event);
        tail = JournalTail {
            seq: raw.seq,
            hash: raw.hash,
        };

        if !terminated && recover_partial {
            file.seek(SeekFrom::End(0))?;
            file.write_all(b"\n")?;
            file.sync_data()?;
        }
        offset = next_offset;
    }

    let mut pending_intents: Vec<_> = pending.into_values().collect();
    pending_intents.sort_by_key(|event| event.operation_id);
    let mut unresolved_operation_ids: Vec<_> = unresolved.into_keys().collect();
    unresolved_operation_ids.sort_unstable();
    Ok(VerifiedJournal {
        tail,
        pending_intents,
        unresolved_operation_ids,
    })
}

fn track_operation_state(
    pending: &mut HashMap<Uuid, AuditEvent>,
    unresolved: &mut HashMap<Uuid, ()>,
    event: &AuditEvent,
) {
    match event.phase {
        AuditRecordPhase::Intent => {
            pending.insert(event.operation_id, event.clone());
        }
        AuditRecordPhase::Outcome => {
            pending.remove(&event.operation_id);
            if event.operation_class.is_write() && event.terminal_status == AuditTerminalStatus::Unknown {
                unresolved.insert(event.operation_id, ());
            } else {
                unresolved.remove(&event.operation_id);
            }
        }
    }
}

fn reject_new_write_intent(event: &AuditEvent, verified: &VerifiedJournal) -> Result<(), StorageError> {
    if event.phase != AuditRecordPhase::Intent || !event.operation_class.is_write() {
        return Ok(());
    }
    let has_pending_write = verified
        .pending_intents
        .iter()
        .any(|intent| intent.operation_class.is_write());
    if !has_pending_write && verified.unresolved_operation_ids.is_empty() {
        return Ok(());
    }
    Err(StorageError::Schema(
        "audit journal has unresolved write operations; new write intent rejected".into(),
    ))
}

fn recover_pending_intents(file: &mut File, verified: VerifiedJournal) -> Result<Vec<Uuid>, StorageError> {
    let mut tail = verified.tail;
    let mut unresolved = verified.unresolved_operation_ids;
    for intent in verified.pending_intents {
        let operation_id = intent.operation_id;
        let is_write = intent.operation_class.is_write();
        tail = append_to_file(file, tail, recovery_outcome(intent), true)?;
        if is_write {
            unresolved.push(operation_id);
        }
    }
    unresolved.sort_unstable();
    unresolved.dedup();
    Ok(unresolved)
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
        self.append_record(event, durable)
            .await
            .map_err(|error| AuditError::Persistence(error.to_string()))
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
}

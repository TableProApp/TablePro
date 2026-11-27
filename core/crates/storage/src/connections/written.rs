// Library writes the core commits itself, for a host that tags `connections.json` and re-tags only a digest the core
// reports (the Mac). Each is recorded beside the file before the file is written, under the same two locks, so a
// crash before the host reads it loses nothing. A record carries a seal made with the host's key: a record anyone
// else wrote beside the file is dropped, so a planted file is never vouched for. A host's own write through
// `replace_library_blocking` or `rebuild_library_blocking` returns its digest instead.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use hmac::{Hmac, KeyInit, Mac};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use super::ConnectionStore;
use super::write_guard::WriteGuard;
use crate::error::StorageError;

// A host that stops taking them keeps the newest; one that misses more re-tags at its own next write.
pub(super) const KEPT: usize = 64;
const VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommittedWrite {
    // SHA-256 in hex of the bytes the core wrote.
    pub digest: String,
    // SHA-256 in hex of the file the write replaced, as read under the same locks; None for no file. A host follows
    // the writes from the digest it tagged, so one made over a file someone else wrote never joins on.
    pub over: Option<String>,
    pub at: SystemTime,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Record {
    digest: String,
    over: Option<String>,
    // Unix milliseconds.
    at: i64,
    seal: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Records {
    version: u32,
    writes: Vec<Record>,
}

pub(super) fn written_path(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(".written");
    PathBuf::from(name)
}

fn mac(key: &SecretString, record: &Record) -> Option<Hmac<Sha256>> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key.expose_secret().as_bytes()).ok()?;
    mac.update(
        format!(
            "tablepro connections write\n{}\n{}\n{}",
            record.digest,
            record.over.as_deref().unwrap_or(""),
            record.at
        )
        .as_bytes(),
    );
    Some(mac)
}

fn sealed_by(key: &SecretString, record: &Record) -> bool {
    match (hex::decode(&record.seal), mac(key, record)) {
        (Ok(seal), Some(mac)) => mac.verify_slice(&seal).is_ok(),
        _ => false,
    }
}

// What cannot be read is what a newer build or someone else wrote, and vouches for nothing.
fn read(path: &Path) -> Records {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Records>(&bytes).ok())
        .filter(|records| records.version == VERSION)
        .unwrap_or_default()
}

fn write(path: &Path, records: &Records) -> Result<(), StorageError> {
    let bytes = serde_json::to_vec(records).map_err(|error| StorageError::Schema(error.to_string()))?;
    crate::fs::write_private_blocking(path, &bytes)
}

impl ConnectionStore {
    // For a host that tags the file: from here on, each write the core commits itself is recorded, sealed with `key`.
    // The host gives the same key in every process, so the records an earlier one left are read too.
    pub fn report_writes(&self, key: SecretString) {
        *self.report_key_slot() = Some(key);
    }

    // The writes recorded since the last take, oldest first, each once. A record `key` did not seal is dropped.
    pub fn take_written_blocking(&self) -> Result<Vec<CommittedWrite>, StorageError> {
        let Some(key) = self.report_key() else {
            return Ok(Vec::new());
        };
        let _held = self.lock_to_write();
        let path = written_path(&self.inner.path);
        let records = read(&path);
        match std::fs::remove_file(&path) {
            Err(source) if source.kind() != std::io::ErrorKind::NotFound => {
                return Err(StorageError::Io { path, source });
            }
            _ => {}
        }
        Ok(records
            .writes
            .into_iter()
            .filter(|record| sealed_by(&key, record))
            .map(|record| CommittedWrite {
                digest: record.digest,
                over: record.over,
                at: crate::unix_time::from_unix_millis(record.at),
            })
            .collect())
    }

    // Before the file is written, under the locks the write holds. Only a write that holds the lock beside the file
    // is recorded: without it another process may have written between the read and this write. A record that
    // cannot be written leaves the host to re-tag at its own next write, and holds back no write.
    pub(super) fn record_write(&self, guard: &WriteGuard<'_>, over: Option<String>, bytes: &[u8]) -> Option<String> {
        let key = self.report_key()?;
        if !guard.holds_file_lock() {
            return None;
        }
        let mut record = Record {
            digest: super::library::sha256_hex(bytes),
            over,
            at: crate::unix_time::to_unix_millis(SystemTime::now()),
            seal: String::new(),
        };
        record.seal = hex::encode(mac(&key, &record)?.finalize().into_bytes());
        let path = written_path(&self.inner.path);
        let mut records = read(&path);
        records.version = VERSION;
        records.writes.push(record.clone());
        let surplus = records.writes.len().saturating_sub(KEPT);
        records.writes.drain(..surplus);
        match write(&path, &records) {
            Ok(()) => Some(record.digest),
            Err(error) => {
                tracing::warn!(%error, "a library write goes unreported; the host re-tags at its next write");
                None
            }
        }
    }

    // After the file write failed: what it recorded never landed.
    pub(super) fn forget_write(&self, digest: &str) {
        let path = written_path(&self.inner.path);
        let mut records = read(&path);
        if let Some(at) = records.writes.iter().rposition(|record| record.digest == digest) {
            records.writes.remove(at);
            if let Err(error) = write(&path, &records) {
                tracing::warn!(%error, "a write that failed stays recorded; it matches no file");
            }
        }
    }

    fn report_key(&self) -> Option<SecretString> {
        self.report_key_slot().clone()
    }

    fn report_key_slot(&self) -> std::sync::MutexGuard<'_, Option<SecretString>> {
        match self.inner.report_key.lock() {
            Ok(slot) => slot,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

#[cfg(test)]
#[path = "written_tests.rs"]
mod tests;

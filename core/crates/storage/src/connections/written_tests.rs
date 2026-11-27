use std::path::Path;

use secrecy::SecretString;
use tempfile::TempDir;

use super::super::store_tests::plain;
use super::*;
use crate::StoragePaths;
use crate::connections::{LibraryChange, LibraryWrite};

fn paths(root: &TempDir) -> StoragePaths {
    StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro")
}

fn key() -> SecretString {
    SecretString::from("the host's own key".to_owned())
}

fn reporting(root: &TempDir) -> ConnectionStore {
    let store = ConnectionStore::new(&paths(root));
    store.report_writes(key());
    store
}

fn on_disk(store: &ConnectionStore) -> Option<String> {
    std::fs::read(store.path())
        .ok()
        .map(|bytes| super::super::library::sha256_hex(&bytes))
}

fn pulled(store: &ConnectionStore, name: &str) {
    let connection = plain(name);
    store
        .apply_synced_blocking(|_| {
            vec![LibraryChange::Connection {
                connection: Box::new(connection),
                favorite: false,
            }]
        })
        .expect("a pull");
}

// A pull's write is reported once, with the file it replaced, so the host can follow it from what it tagged.
#[test]
fn a_pull_reports_what_it_wrote_once() {
    let root = TempDir::new().expect("tempdir");
    let store = reporting(&root);
    store.upsert_blocking(plain("saved here")).expect("a save");
    let saved = store.take_written_blocking().expect("take");
    assert_eq!(saved.len(), 1);
    assert_eq!(saved[0].over, None);

    pulled(&store, "pulled");

    let taken = store.take_written_blocking().expect("take");
    assert_eq!(taken.len(), 1);
    assert_eq!(Some(taken[0].digest.clone()), on_disk(&store));
    assert_eq!(taken[0].over, Some(saved[0].digest.clone()));
    assert!(store.take_written_blocking().expect("take again").is_empty());
}

// A host's own write returns its digest to the host, so it is not reported a second time.
#[test]
fn a_host_write_is_not_reported() {
    let root = TempDir::new().expect("tempdir");
    let store = reporting(&root);

    let written = store
        .replace_library_blocking::<StorageError>(
            None,
            |_| {
                Ok(LibraryWrite {
                    connections: vec![plain("the host's")],
                    ..LibraryWrite::default()
                })
            },
            |_| true,
        )
        .expect("a host write");
    store
        .rebuild_library_blocking(
            LibraryWrite {
                connections: vec![plain("rebuilt")],
                ..LibraryWrite::default()
            },
            std::time::SystemTime::now(),
        )
        .expect("a rebuild");

    assert!(written.is_some());
    assert!(store.take_written_blocking().expect("take").is_empty());
}

// The record is on disk before the file is written, so a crash before the host reads it loses nothing.
#[test]
fn a_write_before_a_crash_is_reported_after_it() {
    let root = TempDir::new().expect("tempdir");
    let store = reporting(&root);
    pulled(&store, "pulled");
    let written = on_disk(&store);
    drop(store);

    let taken = reporting(&root).take_written_blocking().expect("take");

    assert_eq!(taken.len(), 1);
    assert_eq!(Some(taken[0].digest.clone()), written);
}

// A file someone else wrote is read, never reported; a write on top of it names it as the file it replaced, so a
// host that follows the writes from its own tag never reaches it.
#[test]
fn a_file_someone_else_wrote_is_never_reported() {
    let root = TempDir::new().expect("tempdir");
    let store = reporting(&root);
    store.upsert_blocking(plain("saved here")).expect("a save");
    store.take_written_blocking().expect("take");
    let mut planted = plain("planted");
    planted.host = "attacker.example".to_owned();
    let elsewhere = TempDir::new().expect("tempdir");
    let writer = ConnectionStore::new(&paths(&elsewhere));
    writer.upsert_blocking(planted).expect("the planted file");
    std::fs::copy(writer.path(), store.path()).expect("planted in place");
    let planted_digest = on_disk(&store);

    store.list_blocking().expect("a read");
    assert!(store.take_written_blocking().expect("take").is_empty());

    pulled(&store, "pulled");
    let taken = store.take_written_blocking().expect("take");
    assert_eq!(taken.len(), 1);
    assert_eq!(taken[0].over, planted_digest);
}

fn records(store: &ConnectionStore) -> std::path::PathBuf {
    written_path(store.path())
}

// A record planted beside the file, or sealed with another key, is dropped rather than vouched for.
#[test]
fn a_planted_record_is_never_reported() {
    let root = TempDir::new().expect("tempdir");
    let store = reporting(&root);
    pulled(&store, "pulled");
    let digest = on_disk(&store).expect("a file");
    let forged = format!(
        "{{\"version\":1,\"writes\":[{{\"digest\":\"{digest}\",\"over\":null,\"at\":1,\"seal\":\"{}\"}}]}}",
        "00".repeat(32)
    );
    std::fs::write(records(&store), forged).expect("a planted record");
    assert!(store.take_written_blocking().expect("take").is_empty());

    pulled(&store, "again");
    let other = ConnectionStore::new(&paths(&root));
    other.report_writes(SecretString::from("another key".to_owned()));
    assert!(other.take_written_blocking().expect("take").is_empty());
}

// Without a host that tags the file, nothing is recorded beside it.
#[test]
fn a_store_no_host_asked_records_nothing() {
    let root = TempDir::new().expect("tempdir");
    let store = ConnectionStore::new(&paths(&root));

    pulled(&store, "pulled");

    assert!(!records(&store).exists());
    assert!(store.take_written_blocking().expect("take").is_empty());
}

// A write that could not take the lock beside the file is not one the core can vouch for.
#[test]
fn a_write_without_the_file_lock_is_not_reported() {
    let root = TempDir::new().expect("tempdir");
    let store = reporting(&root);
    let mut lock = store.path().as_os_str().to_owned();
    lock.push(".lock");
    std::fs::create_dir_all(Path::new(&lock)).expect("a directory in its place");

    pulled(&store, "pulled");

    assert!(store.take_written_blocking().expect("take").is_empty());
}

// A host that stops taking keeps only the newest records.
#[test]
fn only_the_newest_records_are_kept() {
    let root = TempDir::new().expect("tempdir");
    let store = reporting(&root);
    for index in 0..KEPT + 5 {
        pulled(&store, &format!("pulled {index}"));
    }

    let taken = store.take_written_blocking().expect("take");

    assert_eq!(taken.len(), KEPT);
    assert_eq!(Some(taken[KEPT - 1].digest.clone()), on_disk(&store));
}

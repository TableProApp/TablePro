// Why a file an older build wrote is copied before its first write in a newer format: core ADR 0011.

use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use sqlx::SqlitePool;
use sqlx::migrate::Migrator;

use crate::document::VersionedDocument;
use crate::error::StorageError;

pub const KEPT_PER_FILE: usize = 3;

const MAX_NAME_ATTEMPTS: u32 = 1_000;

// Named `<name>.v<version>-<unix seconds>`, with `-<n>` after it for a second copy in one second.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpgradeCopy {
    pub path: PathBuf,
    pub version: u64,
    made_at: u64,
    attempt: u32,
}

// An `Err` means no copy was made, so the write over `path` must not happen.
pub fn keep_before_write_blocking<D: VersionedDocument>(path: &Path) -> Result<Option<PathBuf>, StorageError> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(source) => {
            return Err(StorageError::Io {
                path: path.to_owned(),
                source,
            });
        }
    };
    // A file with no version or one past ours is never written over by
    // the stores, so only an older one needs its copy.
    match crate::document::stored_version(&bytes) {
        Some(found) if found < D::VERSION => {
            keep_bytes_blocking(path, u64::from(found), &bytes, SystemTime::now()).map(Some)
        }
        _ => Ok(None),
    }
}

fn keep_bytes_blocking(path: &Path, version: u64, bytes: &[u8], now: SystemTime) -> Result<PathBuf, StorageError> {
    if let Some(newest) = copies_blocking(path)?.pop()
        && std::fs::read(&newest.path).is_ok_and(|kept| kept == bytes)
    {
        return Ok(newest.path);
    }
    let copy = vacant_name(path, version, now)?;
    crate::fs::write_private_blocking(&copy, bytes)?;
    prune_blocking(path, &copy)?;
    Ok(copy)
}

// The newest migration a database holds when `migrator` has more to apply. A new database, a current
// one and one a newer build wrote, which the migrator refuses, need no copy.
pub(crate) async fn pending_upgrade(pool: &SqlitePool, migrator: &Migrator) -> Result<Option<u64>, StorageError> {
    let tracked: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '_sqlx_migrations'")
            .fetch_one(pool)
            .await?;
    if tracked == 0 {
        return Ok(None);
    }
    let applied: Vec<i64> = sqlx::query_scalar("SELECT version FROM _sqlx_migrations")
        .fetch_all(pool)
        .await?;
    let known: Vec<i64> = migrator
        .iter()
        .filter(|migration| migration.migration_type.is_up_migration())
        .map(|migration| migration.version)
        .collect();
    let Some(newest) = applied.iter().max() else {
        return Ok(None);
    };
    let from_newer_build = applied.iter().any(|version| !known.contains(version));
    let behind = known.iter().any(|version| !applied.contains(version));
    Ok((behind && !from_newer_build)
        .then(|| u64::try_from(*newest).ok())
        .flatten())
}

// Through the connection, since a copy of the file alone leaves out what the WAL still holds.
pub(crate) async fn keep_database(pool: &SqlitePool, path: &Path, version: u64) -> Result<PathBuf, StorageError> {
    // One a crash left behind holds the history too, and nothing else would ever delete it.
    remove_partials_blocking(path)?;
    let copy = vacant_name(path, version, SystemTime::now())?;
    let partial = partial_name(&copy);
    // VACUUM INTO refuses a file that is not empty, and creates a missing
    // one from the umask: made here, it is 0600 like the database.
    crate::fs::create_private_file_if_missing(&partial)?;
    let target = partial.to_str().ok_or_else(|| StorageError::Write {
        path: partial.clone(),
        source: std::io::Error::new(ErrorKind::InvalidInput, "the path is not UTF-8"),
    })?;
    if let Err(error) = sqlx::query("VACUUM INTO ?").bind(target).execute(pool).await {
        let _ = std::fs::remove_file(&partial);
        return Err(StorageError::Write {
            path: copy,
            source: database_io_error(&error),
        });
    }
    // Renamed into place only once on disk, so a copy cut short by a
    // power cut never carries a name that says it is whole.
    let write_error = |source| StorageError::Write {
        path: copy.clone(),
        source,
    };
    // Windows flushes only a handle opened for writing.
    let landed = std::fs::OpenOptions::new()
        .write(true)
        .open(&partial)
        .and_then(|file| file.sync_all())
        .and_then(|()| std::fs::rename(&partial, &copy));
    if let Err(error) = landed {
        let _ = std::fs::remove_file(&partial);
        return Err(write_error(error));
    }
    if let Some(directory) = copy.parent() {
        tablepro_core::sync_directory(directory).map_err(write_error)?;
    }
    prune_blocking(path, &copy)?;
    Ok(copy)
}

// Oldest first.
pub fn copies_blocking(path: &Path) -> Result<Vec<UpgradeCopy>, StorageError> {
    let Some(name) = path.file_name().map(|name| name.to_string_lossy().into_owned()) else {
        return Ok(Vec::new());
    };
    let parent = parent_of(path);
    let entries = match std::fs::read_dir(parent) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(source) => {
            return Err(StorageError::Io {
                path: parent.to_owned(),
                source,
            });
        }
    };
    let mut copies = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|source| StorageError::Io {
            path: parent.to_owned(),
            source,
        })?;
        if let Some(copy) = parse(&name, &entry.file_name().to_string_lossy(), entry.path()) {
            copies.push(copy);
        }
    }
    copies.sort_by_key(|copy| (copy.made_at, copy.attempt));
    Ok(copies)
}

pub fn remove_all_blocking(path: &Path) -> Result<usize, StorageError> {
    remove_partials_blocking(path)?;
    let copies = copies_blocking(path)?;
    for copy in &copies {
        remove_if_present(&copy.path)?;
    }
    Ok(copies.len())
}

// The copy just made stays even when a clock set back dates it before the others.
// Copies of a database that never finished, as `.<name>.v<version>-<seconds>.partial`.
pub fn remove_partials_blocking(path: &Path) -> Result<(), StorageError> {
    let Some(name) = path.file_name().map(|name| name.to_string_lossy().into_owned()) else {
        return Ok(());
    };
    let parent = parent_of(path);
    let entries = match std::fs::read_dir(parent) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(source) => {
            return Err(StorageError::Io {
                path: parent.to_owned(),
                source,
            });
        }
    };
    let prefix = format!(".{name}.v");
    for entry in entries {
        let entry = entry.map_err(|source| StorageError::Io {
            path: parent.to_owned(),
            source,
        })?;
        let found = entry.file_name().to_string_lossy().into_owned();
        if found.starts_with(&prefix) && found.ends_with(".partial") {
            remove_if_present(&entry.path())?;
        }
    }
    Ok(())
}

fn prune_blocking(path: &Path, made: &Path) -> Result<(), StorageError> {
    let older: Vec<UpgradeCopy> = copies_blocking(path)?
        .into_iter()
        .filter(|copy| copy.path != made)
        .collect();
    let surplus = older.len().saturating_sub(KEPT_PER_FILE - 1);
    for copy in older.iter().take(surplus) {
        remove_if_present(&copy.path)?;
    }
    Ok(())
}

fn parse(name: &str, candidate: &str, path: PathBuf) -> Option<UpgradeCopy> {
    let rest = candidate.strip_prefix(name)?.strip_prefix(".v")?;
    let (version, stamp) = rest.split_once('-')?;
    let (made_at, attempt) = match stamp.split_once('-') {
        Some((made_at, attempt)) => (made_at, attempt.parse().ok()?),
        None => (stamp, 0),
    };
    let digits = |text: &str| !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit());
    if !digits(version) || !digits(made_at) {
        return None;
    }
    Some(UpgradeCopy {
        path,
        version: version.parse().ok()?,
        made_at: made_at.parse().ok()?,
        attempt,
    })
}

fn vacant_name(path: &Path, version: u64, now: SystemTime) -> Result<PathBuf, StorageError> {
    let seconds = now
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0);
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".to_owned());
    let parent = parent_of(path);
    for attempt in 0..MAX_NAME_ATTEMPTS {
        let candidate = match attempt {
            0 => parent.join(format!("{name}.v{version}-{seconds}")),
            _ => parent.join(format!("{name}.v{version}-{seconds}-{attempt}")),
        };
        match std::fs::symlink_metadata(&candidate) {
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(candidate),
            Ok(_) => continue,
            Err(source) => {
                return Err(StorageError::Io {
                    path: candidate,
                    source,
                });
            }
        }
    }
    Err(StorageError::Io {
        path: path.to_owned(),
        source: std::io::Error::new(ErrorKind::AlreadyExists, "no free name for a copy"),
    })
}

fn partial_name(copy: &Path) -> PathBuf {
    let name = copy.file_name().map(|name| name.to_string_lossy()).unwrap_or_default();
    parent_of(copy).join(format!(".{name}.partial"))
}

fn parent_of(path: &Path) -> &Path {
    match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => Path::new("."),
    }
}

fn remove_if_present(path: &Path) -> Result<(), StorageError> {
    match std::fs::remove_file(path) {
        Err(error) if error.kind() != ErrorKind::NotFound => Err(StorageError::Io {
            path: path.to_owned(),
            source: error,
        }),
        _ => Ok(()),
    }
}

// SQLITE_FULL is the one code the app words differently: a full disk.
fn database_io_error(error: &sqlx::Error) -> std::io::Error {
    let full = error
        .as_database_error()
        .and_then(|database| database.code())
        .is_some_and(|code| code == "13");
    match full {
        true => std::io::Error::from(ErrorKind::StorageFull),
        false => std::io::Error::other(error.to_string()),
    }
}

#[cfg(test)]
#[cfg(unix)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::time::{Duration, UNIX_EPOCH};

    use serde::{Deserialize, Serialize};

    use super::*;

    #[derive(Debug, Default, Serialize, Deserialize)]
    struct Sample {
        items: Vec<String>,
    }

    impl VersionedDocument for Sample {
        const KIND: &'static str = "sample";
        const VERSION: u32 = 3;
    }

    fn at(seconds: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(seconds)
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .expect("list")
            .map(|entry| entry.expect("entry").file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    #[derive(Debug, Default, Serialize, Deserialize)]
    struct Bumped {
        items: Vec<String>,
    }

    fn same_shape(document: serde_json::Value) -> Result<serde_json::Value, String> {
        Ok(document)
    }

    // A format bumped once, so the write path can be tested without any format the app shipped.
    impl VersionedDocument for Bumped {
        const KIND: &'static str = "bumped";
        const VERSION: u32 = 2;
        const UPGRADES: &'static [crate::document::Upgrade] = &[same_shape];
    }

    #[test]
    fn the_first_write_over_an_older_file_keeps_it_and_later_writes_do_not() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("bumped.json");
        let older = br#"{"version": 1, "items": ["a"]}"#;
        std::fs::write(&file, older).expect("seed");
        let read: Bumped =
            crate::document::decode_document(&file, &std::fs::read(&file).expect("read")).expect("upgraded");

        crate::document::write_document_blocking(&file, &read).expect("first write");
        crate::document::write_document_blocking(
            &file,
            &Bumped {
                items: vec!["b".to_owned()],
            },
        )
        .expect("second write");

        let copies = copies_blocking(&file).expect("copies");
        assert_eq!(copies.len(), 1, "{copies:?}");
        assert_eq!(copies[0].version, 1);
        assert_eq!(std::fs::read(&copies[0].path).expect("read"), older);
        let written = std::fs::read_to_string(&file).expect("read");
        assert!(
            written.contains("\"version\": 2") && written.contains("\"b\""),
            "{written}"
        );
    }

    fn migration(version: i64, sql: &'static str) -> sqlx::migrate::Migration {
        sqlx::migrate::Migration::new(
            version,
            format!("step {version}").into(),
            sqlx::migrate::MigrationType::Simple,
            sqlx::SqlSafeStr::into_sql_str(sql),
            false,
        )
    }

    fn base() -> Migrator {
        Migrator::with_migrations(vec![migration(
            1,
            "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)",
        )])
    }

    fn bumped() -> Migrator {
        Migrator::with_migrations(vec![
            migration(1, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)"),
            migration(2, "ALTER TABLE items ADD COLUMN size INTEGER"),
        ])
    }

    async fn database(path: &Path) -> SqlitePool {
        crate::fs::create_private_file_if_missing(path).expect("the file");
        let options = sqlx::sqlite::SqliteConnectOptions::new()
            .filename(path)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal);
        sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .expect("connect")
    }

    #[tokio::test]
    async fn a_database_behind_its_migrations_is_copied_with_what_its_wal_holds() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("items.db");
        let pool = database(&path).await;
        base().run(&pool).await.expect("the older schema");
        sqlx::query("INSERT INTO items (name) VALUES ('kept')")
            .execute(&pool)
            .await
            .expect("a row, still in the WAL");

        let version = pending_upgrade(&pool, &bumped())
            .await
            .expect("checked")
            .expect("behind");
        let copy = keep_database(&pool, &path, version).await.expect("a copy");

        assert_eq!(version, 1);
        assert_eq!(
            copy.file_name().expect("name").to_string_lossy().split('-').next(),
            Some("items.db.v1")
        );
        assert_eq!(
            std::fs::metadata(&copy).expect("metadata").permissions().mode() & 0o777,
            0o600
        );
        let copied = database(&copy).await;
        let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM items")
            .fetch_one(&copied)
            .await
            .expect("count");
        assert_eq!(rows, 1, "the copy missed what the WAL held");
        assert_eq!(
            names(root.path())
                .iter()
                .filter(|name| name.ends_with(".partial"))
                .count(),
            0
        );
    }

    #[tokio::test]
    async fn a_copy_a_crash_left_unfinished_is_removed_before_the_next() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("items.db");
        let abandoned = root.path().join(".items.db.v1-100.partial");
        std::fs::write(&abandoned, b"half a copy").expect("seed");
        let unrelated = root.path().join(".other.db.v1-100.partial");
        std::fs::write(&unrelated, b"another file's").expect("seed");
        let pool = database(&path).await;
        base().run(&pool).await.expect("the older schema");

        keep_database(&pool, &path, 1).await.expect("a copy");

        assert!(!abandoned.exists(), "the unfinished copy stayed");
        assert!(unrelated.exists(), "another file's copy went");
        std::fs::write(&abandoned, b"half a copy").expect("seed");
        remove_all_blocking(&path).expect("remove");
        assert!(!abandoned.exists(), "a purge left the unfinished copy");
    }

    #[tokio::test]
    async fn a_new_current_or_newer_database_needs_no_copy() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("items.db");
        let pool = database(&path).await;

        assert_eq!(pending_upgrade(&pool, &bumped()).await.expect("new"), None);
        bumped().run(&pool).await.expect("current");
        assert_eq!(pending_upgrade(&pool, &bumped()).await.expect("current"), None);
        assert_eq!(pending_upgrade(&pool, &base()).await.expect("newer"), None);
    }

    #[test]
    fn an_older_file_is_copied_byte_for_byte_and_private() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("sample.json");
        let older = br#"{"version": 2, "items": ["a"]}"#;
        std::fs::write(&file, older).expect("seed");

        let copy = keep_before_write_blocking::<Sample>(&file)
            .expect("keep")
            .expect("a copy");

        assert_eq!(std::fs::read(&copy).expect("read"), older);
        assert_eq!(std::fs::read(&file).expect("read"), older, "the file itself changed");
        assert_eq!(
            std::fs::metadata(&copy).expect("metadata").permissions().mode() & 0o777,
            0o600
        );
        let copies = copies_blocking(&file).expect("copies");
        assert_eq!(copies.len(), 1);
        assert_eq!(copies[0].version, 2);
        assert!(
            copy.file_name()
                .expect("name")
                .to_string_lossy()
                .starts_with("sample.json.v2-")
        );
    }

    #[test]
    fn a_current_newer_missing_or_unversioned_file_is_not_copied() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("sample.json");

        assert_eq!(keep_before_write_blocking::<Sample>(&file).expect("missing"), None);
        for bytes in [
            &br#"{"version": 3, "items": []}"#[..],
            br#"{"version": 4, "items": []}"#,
            br#"{"items": []}"#,
            b"not json",
        ] {
            std::fs::write(&file, bytes).expect("seed");
            assert_eq!(keep_before_write_blocking::<Sample>(&file).expect("keep"), None);
        }

        assert_eq!(names(root.path()), ["sample.json"]);
    }

    #[test]
    fn the_same_bytes_are_kept_once() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("sample.json");
        std::fs::write(&file, br#"{"version": 1, "names": []}"#).expect("seed");

        let first = keep_bytes_blocking(&file, 1, b"same", at(100)).expect("first");
        let second = keep_bytes_blocking(&file, 1, b"same", at(200)).expect("second");

        assert_eq!(first, second);
        assert_eq!(copies_blocking(&file).expect("copies").len(), 1);
    }

    #[test]
    fn only_the_newest_copies_are_kept() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("sample.json");

        for (seconds, bytes) in [(100, "a"), (300, "c"), (200, "b"), (400, "d"), (400, "e")] {
            keep_bytes_blocking(&file, 2, bytes.as_bytes(), at(seconds)).expect("keep");
        }

        let kept: Vec<Vec<u8>> = copies_blocking(&file)
            .expect("copies")
            .iter()
            .map(|copy| std::fs::read(&copy.path).expect("read"))
            .collect();
        assert_eq!(kept, [b"c".to_vec(), b"d".to_vec(), b"e".to_vec()]);
        assert_eq!(
            names(root.path()),
            ["sample.json.v2-300", "sample.json.v2-400", "sample.json.v2-400-1"]
        );
    }

    #[test]
    fn a_copy_dated_before_the_others_is_kept() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("sample.json");
        for (seconds, bytes) in [(500, "a"), (600, "b"), (700, "c")] {
            keep_bytes_blocking(&file, 2, bytes.as_bytes(), at(seconds)).expect("keep");
        }

        let made = keep_bytes_blocking(&file, 2, b"d", at(100)).expect("keep");

        assert_eq!(std::fs::read(&made).expect("the new copy"), b"d");
        assert_eq!(
            names(root.path()),
            ["sample.json.v2-100", "sample.json.v2-600", "sample.json.v2-700"]
        );
    }

    #[test]
    fn only_that_files_copies_are_counted_and_removed() {
        let root = tempfile::tempdir().expect("tempdir");
        let file = root.path().join("a.json");
        let other = root.path().join("a.json2");
        keep_bytes_blocking(&file, 1, b"a", at(100)).expect("keep");
        keep_bytes_blocking(&other, 1, b"b", at(100)).expect("keep");
        for unrelated in ["a.json.corrupt-100", "a.json.v1-", "a.json.vx-100", "a.json.v1-100-x"] {
            std::fs::write(root.path().join(unrelated), b"x").expect("seed");
        }

        assert_eq!(copies_blocking(&file).expect("copies").len(), 1);
        assert_eq!(remove_all_blocking(&file).expect("remove"), 1);

        assert!(copies_blocking(&file).expect("copies").is_empty());
        assert_eq!(copies_blocking(&other).expect("copies").len(), 1);
        assert_eq!(
            remove_all_blocking(&root.path().join("missing").join("a.json")).expect("no directory"),
            0
        );
    }
}

//! Two storage roots in one process must not see each other.
//!
//! The query history used to hold its pool in a `OnceLock`, so the
//! second root in a process silently read the first one's database.
//! Every store here is an instance, and these tests hold that line:
//! each root gets its own rows, its own file and its own permissions.

use std::error::Error;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::SystemTime;

use tablepro_storage::query_history::{NewEntry, Outcome, SearchFilter};
use tablepro_storage::{ConnectionListState, ConnectionStore, QueryHistory, SavedConnection, StoragePaths};
use uuid::Uuid;

type TestResult = Result<(), Box<dyn Error>>;

const APP_ID: &str = "app.tablepro.TablePro.Devel";

fn paths(root: &Path) -> StoragePaths {
    StoragePaths::under(root, "tablepro-test", APP_ID)
}

fn entry(query: &str, connection_id: Uuid, connection_name: &str) -> NewEntry {
    NewEntry {
        query: query.to_owned(),
        driver_id: "postgres".to_owned(),
        connection_id,
        connection_name: connection_name.to_owned(),
        executed_at: SystemTime::now(),
        duration_ms: Some(3),
        rows_affected: Some(1),
        outcome: Outcome::Success,
    }
}

fn connection(name: &str) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: name.to_owned(),
        driver_id: "postgres".to_owned(),
        host: "localhost".to_owned(),
        port: 5432,
        database: "app".to_owned(),
        username: "tablepro".to_owned(),
        use_tls: false,
        read_only: false,
        auth_mode: tablepro_core::AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group: None,
    }
}

fn all_queries(entries: &[tablepro_storage::query_history::Entry]) -> Vec<String> {
    entries.iter().map(|entry| entry.query.clone()).collect()
}

fn search_all() -> SearchFilter {
    SearchFilter {
        limit: 100,
        ..SearchFilter::default()
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn two_history_databases_in_one_process_keep_their_own_rows() -> TestResult {
    let left_root = tempfile::tempdir()?;
    let right_root = tempfile::tempdir()?;
    let left_paths = paths(left_root.path());
    let right_paths = paths(right_root.path());
    let (left, right) = tokio::join!(QueryHistory::open(&left_paths), QueryHistory::open(&right_paths));
    let (left, right) = (left?, right?);
    let connection_id = Uuid::new_v4();

    // Concurrent so a shared pool would hand one write to the other's
    // database rather than failing in a way only ordering explains.
    let (recorded_left, recorded_right) = tokio::join!(
        left.record(entry("SELECT 1", connection_id, "left")),
        right.record(entry("SELECT 2", connection_id, "right"))
    );
    recorded_left?;
    recorded_right?;

    let (found_left, found_right) = tokio::join!(left.search(search_all()), right.search(search_all()));
    assert_eq!(all_queries(&found_left?), vec!["SELECT 1".to_owned()]);
    assert_eq!(all_queries(&found_right?), vec!["SELECT 2".to_owned()]);
    assert_ne!(left.path(), right.path());
    Ok(())
}

#[tokio::test(flavor = "multi_thread")]
async fn two_connection_stores_in_one_process_keep_their_own_entries() -> TestResult {
    let left_root = tempfile::tempdir()?;
    let right_root = tempfile::tempdir()?;
    let left_paths = paths(left_root.path());
    let right_paths = paths(right_root.path());
    let left = ConnectionStore::new(&left_paths);
    let right = ConnectionStore::new(&right_paths);
    let left_connection = connection("left");
    let right_connection = connection("right");

    let (upserted_left, upserted_right) = tokio::join!(
        {
            let store = left.clone();
            let connection = left_connection.clone();
            tokio::task::spawn_blocking(move || store.upsert_blocking(connection))
        },
        {
            let store = right.clone();
            let connection = right_connection.clone();
            tokio::task::spawn_blocking(move || store.upsert_blocking(connection))
        }
    );
    upserted_left??;
    upserted_right??;

    assert_eq!(names(&left)?, vec!["left".to_owned()]);
    assert_eq!(names(&right)?, vec!["right".to_owned()]);

    // The snapshots could agree while both files hold both entries, so
    // read what actually landed on each disk.
    let left_bytes = std::fs::read_to_string(left_paths.connections_file())?;
    let right_bytes = std::fs::read_to_string(right_paths.connections_file())?;
    assert!(
        left_bytes.contains("left") && !left_bytes.contains("right"),
        "{left_bytes}"
    );
    assert!(
        right_bytes.contains("right") && !right_bytes.contains("left"),
        "{right_bytes}"
    );
    Ok(())
}

#[tokio::test(flavor = "multi_thread")]
async fn store_files_are_private_in_both_roots() -> TestResult {
    let left_root = tempfile::tempdir()?;
    let right_root = tempfile::tempdir()?;

    for root in [left_root.path(), right_root.path()] {
        let paths = paths(root);
        let history = QueryHistory::open(&paths).await?;
        history.record(entry("SELECT 1", Uuid::new_v4(), "one")).await?;
        let store = ConnectionStore::new(&paths);
        store.upsert_blocking(connection("one"))?;

        let connections_file = paths.connections_file();
        let database = paths.history_database();
        let write_ahead_log = database.with_extension("db-wal");
        for file in [&connections_file, &database, &write_ahead_log] {
            assert_eq!(mode(file)?, 0o600, "{} is not private", file.display());
        }
        for directory in [paths.config.as_path(), paths.state.as_path()] {
            assert_eq!(mode(directory)?, 0o700, "{} is not private", directory.display());
        }
    }
    Ok(())
}

fn names(store: &ConnectionStore) -> Result<Vec<String>, Box<dyn Error>> {
    match store.snapshot().state {
        ConnectionListState::Ready(connections) => Ok(connections.iter().map(|c| c.name.clone()).collect()),
        other => Err(format!("the list is not ready: {other:?}").into()),
    }
}

fn mode(path: &Path) -> Result<u32, Box<dyn Error>> {
    Ok(std::fs::metadata(path)?.permissions().mode() & 0o777)
}

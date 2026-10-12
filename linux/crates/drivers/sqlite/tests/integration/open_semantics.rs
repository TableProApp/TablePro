//! What opening a path does: open what is there, create only when
//! asked, and replace atomically.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use tablepro_core::{DriverError, ErrorCategory, FileEndpoint, Value, WorkspaceSettings};
use tokio_util::sync::CancellationToken;

use crate::support::{TestFile, apply, connect, create_database, query, writable};

#[tokio::test]
async fn open_existing_missing_path_file_not_found_no_file_created() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("missing.sqlite3");

    let opened = connect(FileEndpoint::open_existing(path.clone()).unwrap(), writable()).await;

    assert!(
        matches!(&opened, Err(DriverError::FileNotFound { path: missing }) if *missing == path),
        "{:?}",
        opened.err()
    );
    assert!(!path.exists(), "opening a missing path created a file");
}

#[tokio::test]
async fn create_new_replaces_existing_database_atomically() {
    let file = TestFile::new().await;
    let old = file.open().await;
    apply(old.as_ref(), &["CREATE TABLE old_table (a)"]).await.unwrap();
    old.close().await.unwrap();

    let created = connect(FileEndpoint::create_new(file.path.clone()).unwrap(), writable())
        .await
        .unwrap();

    let tables = query(created.as_ref(), "SELECT count(*) FROM sqlite_schema").await;
    assert_eq!(tables.rows[0][0], Value::Int(0), "the old tables survived the replace");
    let mode = std::fs::metadata(&file.path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    created.close().await.unwrap();
}

#[tokio::test]
async fn create_new_removes_stale_wal_and_shm_sidecars() {
    let file = TestFile::new().await;
    let sidecars: Vec<PathBuf> = ["-wal", "-shm", "-journal"]
        .iter()
        .map(|suffix| PathBuf::from(format!("{}{suffix}", file.path.display())))
        .collect();
    for sidecar in &sidecars {
        std::fs::write(sidecar, b"stale journal from the replaced database").unwrap();
    }

    let created = connect(FileEndpoint::create_new(file.path.clone()).unwrap(), writable())
        .await
        .unwrap();

    for sidecar in &sidecars {
        assert!(
            !sidecar.exists(),
            "{} was left beside the new database",
            sidecar.display()
        );
    }
    created.close().await.unwrap();
}

#[tokio::test]
async fn create_new_missing_parent_file_not_found() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("no such directory").join("new.sqlite3");

    let created = connect(FileEndpoint::create_new(path.clone()).unwrap(), writable()).await;

    assert!(
        matches!(&created, Err(DriverError::FileNotFound { path: missing }) if *missing == path),
        "{:?}",
        created.err()
    );
}

#[tokio::test]
async fn reconnect_new_database_with_for_reopen_keeps_tables() {
    let directory = tempfile::tempdir().unwrap();
    let endpoint = FileEndpoint::create_new(directory.path().join("new.sqlite3")).unwrap();
    let created = connect(endpoint.clone(), writable()).await.unwrap();
    apply(created.as_ref(), &["CREATE TABLE kept (a)"]).await.unwrap();
    created.close().await.unwrap();

    let reopened = connect(endpoint.for_reopen(), writable()).await.unwrap();

    let tables = query(reopened.as_ref(), "SELECT name FROM sqlite_schema").await;
    assert_eq!(tables.rows, vec![vec![Value::Text("kept".to_owned())]]);
    reopened.close().await.unwrap();
}

#[tokio::test]
async fn path_with_question_mark_and_percent41_opens_literal_file() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("odd?mode=memory&x=%41.sqlite3");
    create_database(&path).await.unwrap();

    let opened = connect(FileEndpoint::open_existing(path.clone()).unwrap(), writable())
        .await
        .unwrap();
    apply(opened.as_ref(), &["CREATE TABLE on_disk (a)"]).await.unwrap();
    opened.close().await.unwrap();

    let names: Vec<_> = std::fs::read_dir(directory.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(names, [std::ffi::OsString::from("odd?mode=memory&x=%41.sqlite3")]);
    assert!(
        std::fs::metadata(&path).unwrap().len() > 0,
        "the table did not reach the named file"
    );
}

#[tokio::test]
async fn read_only_insert_is_read_only() {
    let file = TestFile::new().await;
    let owner = file.open().await;
    apply(owner.as_ref(), &["CREATE TABLE t (a)"]).await.unwrap();
    let reader = connect(file.endpoint(), WorkspaceSettings::workspace(true))
        .await
        .unwrap();
    let session = reader
        .open_editor_session(Default::default(), CancellationToken::new())
        .await
        .unwrap();

    let (summary, _) = crate::support::run(session.as_ref(), "INSERT INTO t VALUES (1)").await;

    let tablepro_core::RunEnd::Failed(error) = &summary.end else {
        panic!("the insert ended {:?}", summary.end);
    };
    assert!(
        matches!(
            error,
            DriverError::ReadOnly(tablepro_core::ReadOnlyRefusal::ServerRejected(_))
        ),
        "{error:?}"
    );
    assert_eq!(error.category(), ErrorCategory::ReadOnly);
    session.close().await;
    reader.close().await.unwrap();
    owner.close().await.unwrap();
}

#[tokio::test]
async fn reconnect_after_move_file_not_found() {
    let file = TestFile::new().await;
    let moved = file.directory().join("moved.sqlite3");
    std::fs::rename(&file.path, &moved).unwrap();

    let reopened = connect(file.endpoint(), writable()).await;

    assert!(
        matches!(&reopened, Err(DriverError::FileNotFound { .. })),
        "{:?}",
        reopened.err()
    );
}

#[tokio::test]
async fn not_a_database_file_is_not_a_database() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("notes.txt");
    std::fs::write(
        &path,
        "these are notes, not a database, and they are long enough to have a header",
    )
    .unwrap();

    let opened = connect(FileEndpoint::open_existing(path.clone()).unwrap(), writable()).await;

    assert!(
        matches!(&opened, Err(DriverError::NotADatabase { path: refused }) if *refused == path),
        "{:?}",
        opened.err()
    );
}

#[tokio::test]
async fn the_server_info_names_the_library() {
    let file = TestFile::new().await;
    let connection = file.open().await;

    let info = connection.server_info();

    assert_eq!(info.product, "SQLite");
    assert!(info.at_least(3, 37, 0), "{info:?}");
    connection.close().await.unwrap();
}

#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    ConnectionRecord, ConnectionSecrets, Core, DatabaseSession, FileOpenRequest, HostConfig, HostSecretError,
    HostSecrets, RunGate, RunListener, RunOutcome, RunSettings, SafeModeTag, SecretItemTag, SecretKindTag, TlsModeTag,
    TlsSettings,
};

struct NoSecrets;

impl HostSecrets for NoSecrets {
    fn load(&self, _: String, _: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store(&self, _: String, _: SecretKindTag, _: SecretString, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn relabel(&self, _: String, _: SecretKindTag, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete(&self, _: String, _: SecretKindTag) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_connection(&self, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn load_item(&self, _: SecretItemTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store_item(&self, _: SecretItemTag, _: SecretString) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_item(&self, _: SecretItemTag) -> Result<(), HostSecretError> {
        Ok(())
    }
}

struct Quiet;

impl RunListener for Quiet {
    fn events_pending(&self) {}
}

fn core(dir: &Path) -> Arc<Core> {
    Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: Some(dir.display().to_string()),
        },
        Box::new(NoSecrets),
    )
    .unwrap()
}

fn file(path: &Path, read_only: bool, create: bool) -> FileOpenRequest {
    FileOpenRequest {
        path: path.display().to_string(),
        driver_id: None,
        read_only,
        create,
    }
}

async fn people(core: &Core, path: &Path) {
    let session = core.open_file(file(path, false, true), None).await.unwrap();
    let editor = session.open_editor(None, None).await.unwrap();
    let run = editor.run(
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)".to_owned(),
        RunSettings::default(),
        Box::new(Quiet),
    );
    assert!(matches!(run.outcome().await.unwrap(), RunOutcome::Completed { .. }));
    editor.close().await.unwrap();
    session.close().await.unwrap();
}

fn gate(session: &DatabaseSession, sql: &str) -> RunGate {
    session.gate_run(sql.to_owned())
}

async fn saved(core: &Core, path: &Path, safe_mode: SafeModeTag) -> Arc<DatabaseSession> {
    let record = ConnectionRecord {
        id: String::new(),
        name: "people".to_owned(),
        driver_id: "sqlite".to_owned(),
        host: String::new(),
        port: 0,
        database: path.display().to_string(),
        username: String::new(),
        integrated_auth: false,
        tls: TlsSettings {
            mode: TlsModeTag::Disable,
            ca_file: None,
            client_certificate: None,
            client_key: None,
            server_name: None,
        },
        ssh: None,
        safe_mode,
        query_timeout_secs: None,
        color: None,
        group_id: None,
        last_opened_ms: None,
        tags: Vec::new(),
    };
    let saved = core
        .library()
        .unwrap()
        .save(record, ConnectionSecrets::default())
        .await
        .unwrap();
    core.connect_saved(
        saved.id,
        None,
        ConnectionSecrets::default(),
        ConnectionSecrets::default(),
        None,
        None,
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn confirm_writes_on_a_saved_connection_asks_before_a_write_and_never_before_a_read() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    people(&core, &path).await;
    let session = saved(&core, &path, SafeModeTag::ConfirmWrites).await;

    let write = gate(&session, "SELECT 1; UPDATE people SET name = 'Ada' WHERE id = 1");
    let read = gate(&session, "SELECT * FROM people");
    session.close().await.unwrap();

    assert_eq!(write.confirm, ["UPDATE people SET name = 'Ada' WHERE id = 1"]);
    assert!(!write.destructive);
    assert!(!write.refused);
    assert_eq!(read, RunGate::default());
}

#[tokio::test]
async fn off_asks_only_before_a_statement_that_empties_a_table() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    people(&core, &path).await;
    let session = saved(&core, &path, SafeModeTag::Off).await;

    let insert = gate(&session, "INSERT INTO people (name) VALUES ('Ada')");
    let delete = gate(&session, "DELETE FROM people");
    session.close().await.unwrap();

    assert_eq!(insert, RunGate::default());
    assert_eq!(delete.confirm, ["DELETE FROM people"]);
    assert!(delete.destructive);
}

#[tokio::test]
async fn a_file_opened_read_only_keeps_a_write_back_and_lets_a_read_run() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    people(&core, &path).await;
    let session = core.open_file(file(&path, true, false), None).await.unwrap();

    let write = gate(&session, "SELECT 1; INSERT INTO people (name) VALUES ('Ada')");
    let read = gate(&session, "SELECT * FROM people");
    session.close().await.unwrap();

    assert!(write.refused);
    assert!(write.confirm.is_empty());
    assert_eq!(read, RunGate::default());
}

#[tokio::test]
async fn a_level_set_on_an_open_session_applies_at_once_but_never_across_read_only() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    people(&core, &path).await;
    let session = saved(&core, &path, SafeModeTag::Off).await;
    let update = "UPDATE people SET name = 'Ada' WHERE id = 1";

    let at_off = gate(&session, update);
    let confirmed = session.set_safe_mode(SafeModeTag::ConfirmWrites);
    let asked = gate(&session, update);
    let read_only = session.set_safe_mode(SafeModeTag::ReadOnly);
    let still_asked = gate(&session, update);
    session.close().await.unwrap();

    assert_eq!(at_off, RunGate::default());
    assert!(confirmed);
    assert_eq!(asked.confirm, [update]);
    assert!(!read_only);
    assert!(!still_asked.refused);
    assert_eq!(still_asked.confirm, [update]);
}

#[tokio::test]
async fn a_session_whose_link_is_down_still_reads_sql_by_its_own_engine() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    people(&core, &path).await;
    let session = core.open_file(file(&path, false, false), None).await.unwrap();
    session.close().await.unwrap();

    // SQLite ends a block comment at its first `*/`, so the DROP runs; PostgreSQL would read one nested comment.
    let run = gate(&session, "SELECT 1 /* /* */; DROP TABLE people; -- */");

    assert_eq!(run.confirm, ["DROP TABLE people"]);
    assert!(run.destructive);
}

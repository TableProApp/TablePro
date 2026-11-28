#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    Core, DatabaseSession, FileOpenRequest, HostConfig, HostSecretError, HostSecrets, ProfileKindTag, ResultSet,
    RunListener, RunOutcome, RunSettings, SecretDeletionTag, SecretItemTag, SecretKindTag, SqlImportEndTag,
    SqlImportErrorPolicyTag, SqlImportOptionsArg, SqlImportProgress,
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

    fn delete_profile(&self, _: String, _: ProfileKindTag) -> Result<SecretDeletionTag, HostSecretError> {
        Ok(SecretDeletionTag::Deleted)
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

async fn run(session: &DatabaseSession, sql: &str) -> Option<Arc<ResultSet>> {
    let editor = session.open_editor(None, None).await.unwrap();
    let run = editor.run(sql.to_owned(), RunSettings::default(), Box::new(Quiet));
    let outcome = run.outcome().await.unwrap();
    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    let set = run.result_set(0);
    editor.close().await.unwrap();
    set
}

async fn open(dir: &Path) -> (Arc<Core>, Arc<DatabaseSession>) {
    let core = Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: None,
        },
        Box::new(NoSecrets),
    )
    .unwrap();
    let request = FileOpenRequest {
        path: dir.join("app.sqlite").display().to_string(),
        driver_id: None,
        read_only: false,
        create: true,
    };
    let session = core.open_file(request, None).await.unwrap();
    (core, session)
}

async fn count(session: &DatabaseSession, table: &str) -> Option<String> {
    let set = run(session, &format!("SELECT count(*) FROM {table}")).await.unwrap();
    set.cell_text(0, 0).unwrap()
}

fn write(dir: &Path, name: &str, text: &str) -> String {
    let path = dir.join(name);
    std::fs::write(&path, text).unwrap();
    path.display().to_string()
}

fn options(on_error: SqlImportErrorPolicyTag) -> SqlImportOptionsArg {
    SqlImportOptionsArg {
        on_error,
        one_transaction: false,
    }
}

#[tokio::test]
async fn a_sql_file_runs_statement_by_statement() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path()).await;
    let file = write(
        dir.path(),
        "seed.sql",
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);\n\
         INSERT INTO people VALUES (1, 'Ada');\n\
         INSERT INTO people VALUES (2, 'Grace');\n",
    );
    let progress = SqlImportProgress::new();

    let report = session
        .import_sql_file(
            file,
            options(SqlImportErrorPolicyTag::Stop),
            Some(progress.clone()),
            None,
        )
        .await
        .unwrap();

    assert_eq!(report.end, SqlImportEndTag::Completed);
    assert_eq!(report.statements, 3);
    assert_eq!(report.failed, 0);
    assert_eq!(progress.statements(), 3);
    assert!(progress.bytes_read() > 0);
    assert_eq!(count(&session, "people").await.as_deref(), Some("2"));
}

#[tokio::test]
async fn a_failed_statement_stops_the_import_under_stop() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path()).await;
    let file = write(
        dir.path(),
        "bad.sql",
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);\n\
         INSERT INTO people VALUES (1, 'Ada');\n\
         INSERT INTO nope VALUES (2);\n\
         INSERT INTO people VALUES (3, 'Grace');\n",
    );

    let report = session
        .import_sql_file(file, options(SqlImportErrorPolicyTag::Stop), None, None)
        .await
        .unwrap();

    assert_eq!(report.end, SqlImportEndTag::Stopped);
    assert_eq!(report.failed, 1);
    assert_eq!(report.failures.len(), 1);
    assert_eq!(
        count(&session, "people").await.as_deref(),
        Some("1"),
        "the fourth row never ran"
    );
}

#[tokio::test]
async fn continue_runs_past_a_failed_statement() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path()).await;
    let file = write(
        dir.path(),
        "mixed.sql",
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);\n\
         INSERT INTO people VALUES (1, 'Ada');\n\
         INSERT INTO nope VALUES (2);\n\
         INSERT INTO people VALUES (3, 'Grace');\n",
    );

    let report = session
        .import_sql_file(file, options(SqlImportErrorPolicyTag::Continue), None, None)
        .await
        .unwrap();

    assert_eq!(report.end, SqlImportEndTag::Completed);
    assert_eq!(report.failed, 1);
    assert_eq!(
        count(&session, "people").await.as_deref(),
        Some("2"),
        "the fourth row still ran"
    );
}

#[tokio::test]
async fn a_missing_file_is_refused_with_a_path() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path()).await;
    let missing = dir.path().join("gone.sql").display().to_string();

    let error = session
        .import_sql_file(missing, options(SqlImportErrorPolicyTag::Stop), None, None)
        .await
        .unwrap_err();

    assert_eq!(error.code(), "sql_import.unreadable");
}

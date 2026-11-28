#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    Core, DatabaseSession, DumpProgress, DumpScopeArg, FileOpenRequest, HostConfig, HostSecretError, HostSecrets,
    ProfileKindTag, ResultSet, RunListener, RunOutcome, RunSettings, SecretDeletionTag, SecretItemTag, SecretKindTag,
    SqlImportEndTag, SqlImportErrorPolicyTag, SqlImportOptionsArg,
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

async fn open(dir: &Path, file: &str) -> (Arc<Core>, Arc<DatabaseSession>) {
    let core = Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: None,
        },
        Box::new(NoSecrets),
    )
    .unwrap();
    let request = FileOpenRequest {
        path: dir.join(file).display().to_string(),
        driver_id: None,
        read_only: false,
        create: true,
    };
    let session = core.open_file(request, None).await.unwrap();
    (core, session)
}

async fn seeded(dir: &Path, file: &str) -> (Arc<Core>, Arc<DatabaseSession>) {
    let (core, session) = open(dir, file).await;
    run(
        &session,
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL); \
         INSERT INTO people VALUES (1, 'Ada', 1.5), (2, 'Grace', 2.25)",
    )
    .await;
    (core, session)
}

async fn count(session: &DatabaseSession, table: &str) -> Option<String> {
    let set = run(session, &format!("SELECT count(*) FROM {table}")).await.unwrap();
    set.cell_text(0, 0).unwrap()
}

#[tokio::test]
async fn a_database_dump_writes_its_structure_and_rows() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = seeded(dir.path(), "app.sqlite").await;
    let path = dir.path().join("dump.sql");
    let progress = DumpProgress::new();

    let report = session
        .dump_database(
            DumpScopeArg::Database,
            true,
            path.display().to_string(),
            false,
            Some(progress.clone()),
            None,
        )
        .await
        .unwrap();

    let text = std::fs::read_to_string(&path).unwrap();
    assert_eq!((report.tables, report.rows), (1, 2));
    assert_eq!(progress.rows(), 2);
    assert_eq!(progress.tables_done(), progress.tables_total());
    assert!(text.to_uppercase().contains("CREATE TABLE"), "{text}");
    assert!(text.contains("'Ada'") && text.contains("'Grace'"), "{text}");
}

#[tokio::test]
async fn a_structure_only_dump_leaves_the_rows_out() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = seeded(dir.path(), "app.sqlite").await;
    let path = dir.path().join("schema.sql");

    let report = session
        .dump_database(
            DumpScopeArg::Database,
            false,
            path.display().to_string(),
            false,
            None,
            None,
        )
        .await
        .unwrap();

    let text = std::fs::read_to_string(&path).unwrap();
    assert_eq!(report.rows, 0);
    assert!(text.to_uppercase().contains("CREATE TABLE"), "{text}");
    assert!(!text.contains("'Ada'"), "no rows in a structure dump: {text}");
}

#[tokio::test]
async fn a_gzipped_dump_is_written_gzip() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = seeded(dir.path(), "app.sqlite").await;
    let path = dir.path().join("dump.sql.gz");

    let report = session
        .dump_database(
            DumpScopeArg::Database,
            true,
            path.display().to_string(),
            true,
            None,
            None,
        )
        .await
        .unwrap();

    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(report.rows, 2);
    assert_eq!(&bytes[..2], &[0x1f, 0x8b], "a gzip member starts 1f 8b");
}

#[tokio::test]
async fn a_dump_reloads_into_an_empty_database() {
    let dir = tempfile::tempdir().unwrap();
    let (_source_core, source) = seeded(dir.path(), "source.sqlite").await;
    let path = dir.path().join("dump.sql");
    source
        .dump_database(
            DumpScopeArg::Database,
            true,
            path.display().to_string(),
            false,
            None,
            None,
        )
        .await
        .unwrap();
    let (_target_core, target) = open(dir.path(), "target.sqlite").await;

    let report = target
        .import_sql_file(
            path.display().to_string(),
            SqlImportOptionsArg {
                on_error: SqlImportErrorPolicyTag::Stop,
                one_transaction: false,
            },
            None,
            None,
        )
        .await
        .unwrap();

    assert_eq!(report.end, SqlImportEndTag::Completed);
    assert_eq!(report.failed, 0);
    assert_eq!(count(&target, "people").await.as_deref(), Some("2"));
}

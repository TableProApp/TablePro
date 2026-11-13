#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use secrecy::SecretString;
use tablepro_ffi::{
    CellChange, CellEdit, ConnectionRecord, ConnectionSecrets, Core, DatabaseSession, EditLock, EditStart,
    ExportFormatTag, FileOpenRequest, HostConfig, HostSecretError, HostSecrets, MaskStyleTag, MaskTargetTag,
    MaskingRuleRecord, ResultSet, RowEdit, RunListener, RunOutcome, RunSettings, SafeModeTag, SecretItemTag,
    SecretKindTag, TableName, TlsModeTag, TlsSettings,
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

const SELECT: &str = "SELECT id, name, email, phone FROM people ORDER BY id";

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

fn people() -> TableName {
    TableName {
        schema: None,
        name: "people".to_owned(),
    }
}

fn rule(pattern: &str, style: MaskStyleTag) -> MaskingRuleRecord {
    MaskingRuleRecord {
        id: String::new(),
        pattern: pattern.to_owned(),
        target: MaskTargetTag::Column,
        style,
    }
}

async fn execute(session: &DatabaseSession, sql: &str, reveal_masked: bool) -> Option<Arc<ResultSet>> {
    let editor = session.open_editor(None).await.unwrap();
    let run = editor.run(sql.to_owned(), RunSettings::default(), reveal_masked, Box::new(Quiet));
    assert!(matches!(run.outcome().await.unwrap(), RunOutcome::Completed { .. }));
    let set = run.result_set(0);
    editor.close().await.unwrap();
    set
}

async fn run(session: &DatabaseSession, sql: &str, reveal_masked: bool) -> Arc<ResultSet> {
    execute(session, sql, reveal_masked).await.unwrap()
}

async fn page(session: &DatabaseSession, reveal_masked: bool) -> Arc<ResultSet> {
    let read = session
        .read_table_page(people(), None, None, 100, 0, reveal_masked, Box::new(Quiet), None)
        .await
        .unwrap();
    let run = read.run();
    assert!(matches!(run.outcome().await.unwrap(), RunOutcome::Completed { .. }));
    run.result_set(0).unwrap()
}

fn texts(set: &ResultSet, column: u32) -> Vec<Option<String>> {
    (0..set.row_count())
        .map(|row| set.cell_text(row, column).unwrap())
        .collect()
}

fn masked(set: &ResultSet) -> Vec<Option<MaskStyleTag>> {
    set.columns().into_iter().map(|column| column.masked).collect()
}

fn record(path: &Path, rules: Vec<MaskingRuleRecord>) -> ConnectionRecord {
    ConnectionRecord {
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
        safe_mode: SafeModeTag::Off,
        query_timeout_secs: None,
        masking_rules: rules,
        color: None,
        group_id: None,
        last_opened_ms: None,
        tags: Vec::new(),
    }
}

// A people table, saved as a connection with `rules`, and a session on it.
async fn connected(dir: &Path, rules: Vec<MaskingRuleRecord>) -> (Arc<Core>, ConnectionRecord, Arc<DatabaseSession>) {
    let path = dir.join("people.sqlite");
    let core = core(dir);
    let create = FileOpenRequest {
        path: path.display().to_string(),
        driver_id: None,
        read_only: false,
        create: true,
    };
    let seeding = core.open_file(create, None).await.unwrap();
    execute(
        &seeding,
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, email TEXT, phone TEXT); \
         INSERT INTO people VALUES (1, 'Ada', 'ada@example.com', '+1 555 0100'), \
         (2, 'Grace', 'grace@example.com', '+1 555 0199')",
        false,
    )
    .await;
    seeding.close().await.unwrap();
    let saved = core
        .library()
        .unwrap()
        .save(record(&path, rules), ConnectionSecrets::default())
        .await
        .unwrap();
    let session = core
        .connect_saved(
            saved.id.clone(),
            ConnectionSecrets::default(),
            ConnectionSecrets::default(),
            None,
            None,
        )
        .await
        .unwrap();
    (core, saved, session)
}

fn rules() -> Vec<MaskingRuleRecord> {
    vec![
        rule("people.email", MaskStyleTag::Email),
        rule("phone", MaskStyleTag::LastFour),
    ]
}

#[tokio::test]
async fn a_saved_connection_s_rules_mask_the_grid_and_a_revealed_run_shows_the_values() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, saved, session) = connected(dir.path(), rules()).await;

    let shown = run(&session, SELECT, false).await;
    let revealed = run(&session, SELECT, true).await;
    let table_page = page(&session, false).await;

    assert_eq!(saved.masking_rules.len(), 2);
    assert!(saved.masking_rules.iter().all(|rule| rule.id.len() == 36));
    assert_eq!(
        masked(&shown),
        [None, None, Some(MaskStyleTag::Email), Some(MaskStyleTag::LastFour)]
    );
    assert_eq!(
        texts(&shown, 2),
        [Some("a•••@example.com".to_owned()), Some("g•••@example.com".to_owned())]
    );
    assert_eq!(texts(&shown, 3)[0].as_deref(), Some("••••0100"));
    assert_eq!(masked(&revealed), [None; 4]);
    assert_eq!(texts(&revealed, 2)[0].as_deref(), Some("ada@example.com"));
    assert_eq!(texts(&table_page, 2)[1].as_deref(), Some("g•••@example.com"));
}

#[tokio::test]
async fn a_masked_cell_refuses_an_edit_and_a_masked_key_locks_the_page() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, _, session) = connected(dir.path(), rules()).await;
    let editor = session.table_editor(people(), false, None).await.unwrap();
    let shown = page(&session, false).await;

    let start = editor.edit_start(shown.clone(), 0, 2).unwrap();
    let refused = editor
        .plan(
            shown.clone(),
            vec![RowEdit::Update {
                row: 0,
                cells: vec![CellChange {
                    column: 2,
                    edit: CellEdit::Text {
                        text: "x@example.com".to_owned(),
                    },
                }],
            }],
        )
        .err()
        .unwrap();

    assert_eq!(start, EditStart::ReadOnly);
    assert_eq!(refused.code(), "edit.masked_column");
    assert_eq!(editor.lock_for(shown), None);

    let dir = tempfile::tempdir().unwrap();
    let (_core, _, keyed) = connected(dir.path(), vec![rule("id", MaskStyleTag::Hash)]).await;
    let editor = keyed.table_editor(people(), false, None).await.unwrap();
    let shown = page(&keyed, false).await;

    assert_eq!(
        editor.lock_for(shown.clone()),
        Some(EditLock::MaskedKey {
            column: "id".to_owned()
        })
    );
    let delete = editor.plan(shown, vec![RowEdit::Delete { row: 0 }]).err().unwrap();
    assert_eq!(delete.code(), "edit.masked_key");
}

#[tokio::test]
async fn an_export_masks_by_origin_even_after_a_reveal_and_a_table_export_by_table() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, _, session) = connected(dir.path(), rules()).await;
    let revealed = run(
        &session,
        "SELECT email AS contact, 'x' AS label, name FROM people ORDER BY id",
        true,
    )
    .await;
    let rows_file = dir.path().join("rows.csv");
    let table_file = dir.path().join("table.csv");

    session
        .export_rows(
            revealed.clone(),
            3,
            ExportFormatTag::Csv,
            None,
            rows_file.display().to_string(),
            None,
        )
        .await
        .unwrap();
    session
        .export_table(
            people(),
            None,
            None,
            ExportFormatTag::Csv,
            table_file.display().to_string(),
            None,
        )
        .await
        .unwrap();

    let rows = std::fs::read_to_string(&rows_file).unwrap();
    let table = std::fs::read_to_string(&table_file).unwrap();
    assert_eq!(texts(&revealed, 0)[0].as_deref(), Some("ada@example.com"));
    assert!(rows.contains("a•••@example.com,••••,Ada"), "{rows}");
    assert!(!rows.contains("ada@example.com"), "{rows}");
    assert!(table.contains("1,Ada,a•••@example.com,••••0100"), "{table}");
}

#[tokio::test]
async fn a_saved_change_to_the_rules_reaches_the_session_and_the_rows_on_screen() {
    let dir = tempfile::tempdir().unwrap();
    let (core, saved, session) = connected(dir.path(), Vec::new()).await;
    let on_screen = run(&session, SELECT, false).await;
    let revealed = run(&session, SELECT, true).await;
    assert_eq!(texts(&on_screen, 2)[0].as_deref(), Some("ada@example.com"));

    core.library()
        .unwrap()
        .save(
            ConnectionRecord {
                masking_rules: rules(),
                ..saved
            },
            ConnectionSecrets::default(),
        )
        .await
        .unwrap();
    let mut remasked = false;
    for _ in 0..200 {
        remasked = on_screen.remask();
        if remasked {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    assert!(remasked, "the rows on screen were never masked");
    assert_eq!(masked(&on_screen)[2], Some(MaskStyleTag::Email));
    assert_eq!(texts(&on_screen, 2)[0].as_deref(), Some("a•••@example.com"));
    assert_eq!(texts(&on_screen, 3)[1].as_deref(), Some("••••0199"));
    assert!(!revealed.remask(), "a revealed run was masked");
    let next = run(&session, SELECT, false).await;
    assert_eq!(texts(&next, 2)[1].as_deref(), Some("g•••@example.com"));
    let listed = core.library().unwrap().snapshot().await.unwrap();
    assert_eq!(listed.connections[0].masking_rules.len(), 2);
}

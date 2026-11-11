#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    CellChange, CellEdit, ConnectionRecord, ConnectionSecrets, Core, DatabaseSession, EditLock, EditStart,
    FileOpenRequest, HostConfig, HostSecretError, HostSecrets, ResultSet, RowEdit, RowSaveOutcome, RunListener,
    RunOutcome, RunSettings, SafeModeTag, SaveGate, SecretItemTag, SecretKindTag, TableName, TlsModeTag, TlsSettings,
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

fn file(path: &Path, read_only: bool) -> FileOpenRequest {
    FileOpenRequest {
        path: path.display().to_string(),
        driver_id: None,
        read_only,
        create: false,
    }
}

fn people() -> TableName {
    TableName {
        schema: None,
        name: "people".to_owned(),
    }
}

async fn run(session: &DatabaseSession, sql: &str) -> Option<Arc<ResultSet>> {
    let editor = session.open_editor(None).await.unwrap();
    let run = editor.run(sql.to_owned(), RunSettings::default(), Box::new(Quiet));
    assert!(matches!(run.outcome().await.unwrap(), RunOutcome::Completed { .. }));
    let set = run.result_set(0);
    editor.close().await.unwrap();
    set
}

async fn seeded(core: &Core, path: &Path) {
    let create = FileOpenRequest {
        create: true,
        ..file(path, false)
    };
    let session = core.open_file(create, None).await.unwrap();
    run(
        &session,
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, \
         joined TEXT DEFAULT 'today'); \
         INSERT INTO people (id, name, age) VALUES (1, 'Ada', 36), (2, 'Grace', 45), (3, 'Linus', 21); \
         CREATE TABLE notes (body TEXT)",
    )
    .await;
    session.close().await.unwrap();
}

// The page as a table tab reads it, through the core's own statement.
async fn page(session: &DatabaseSession) -> Arc<ResultSet> {
    let query = session.table_query(people(), None, 100, 0, None).await.unwrap();
    run(session, &query.sql).await.unwrap()
}

async fn rows(session: &DatabaseSession) -> Vec<Vec<Option<String>>> {
    let set = run(session, "SELECT id, name, age, joined FROM people ORDER BY id")
        .await
        .unwrap();
    (0..set.row_count())
        .map(|row| (0..4).map(|column| set.cell_text(row, column).unwrap()).collect())
        .collect()
}

fn text(value: &str) -> CellEdit {
    CellEdit::Text { text: value.to_owned() }
}

fn row(values: [Option<&str>; 4]) -> Vec<Option<String>> {
    values.iter().map(|value| value.map(str::to_owned)).collect()
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
    core.connect_saved(saved.id, ConnectionSecrets::default(), None, None)
        .await
        .unwrap()
}

#[tokio::test]
async fn an_update_an_insert_and_a_delete_save_as_one_batch() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let editor = session.table_editor(people(), false, None).await.unwrap();
    let shown = page(&session).await;

    let save = editor
        .plan(
            shown,
            vec![
                RowEdit::Update {
                    row: 0,
                    cells: vec![CellChange {
                        column: 1,
                        edit: text("Ada Lovelace"),
                    }],
                },
                RowEdit::Insert {
                    cells: vec![CellEdit::Default, text("Edsger"), CellEdit::Null, CellEdit::Default],
                },
                RowEdit::Delete { row: 2 },
            ],
        )
        .unwrap();
    let statements = save.statements();
    let outcome = save.run(false, None).await.unwrap();
    let again = save.run(false, None).await.err().unwrap();
    let after = rows(&session).await;
    session.close().await.unwrap();

    assert_eq!(again.code(), "edit.already_saved");
    assert_eq!(save.gate(), SaveGate::Run);
    assert_eq!(statements.len(), 3);
    assert!(statements[0].sql.starts_with("UPDATE"), "{statements:?}");
    assert_eq!(statements[0].values, ["'Ada Lovelace'", "1"]);
    assert!(statements[1].sql.starts_with("INSERT"), "{statements:?}");
    assert!(statements[2].sql.starts_with("DELETE"), "{statements:?}");
    assert_eq!(statements[2].values, ["3"]);
    assert_eq!(outcome, RowSaveOutcome::Saved { rows: Some(3) });
    assert_eq!(
        after,
        [
            row([Some("1"), Some("Ada Lovelace"), Some("36"), Some("today")]),
            row([Some("2"), Some("Grace"), Some("45"), Some("today")]),
            row([Some("4"), Some("Edsger"), None, Some("today")]),
        ]
    );
}

#[tokio::test]
async fn a_cell_edited_back_to_its_value_saves_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let editor = session.table_editor(people(), false, None).await.unwrap();
    let shown = page(&session).await;

    let save = editor
        .plan(
            shown,
            vec![RowEdit::Update {
                row: 1,
                cells: vec![
                    CellChange {
                        column: 1,
                        edit: text("Grace"),
                    },
                    CellChange {
                        column: 2,
                        edit: text("45"),
                    },
                ],
            }],
        )
        .unwrap();
    session.close().await.unwrap();

    assert!(save.is_empty());
}

#[tokio::test]
async fn text_the_column_cannot_hold_is_refused_with_its_code() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let editor = session.table_editor(people(), false, None).await.unwrap();

    let number = editor.check(2, text("forty"), false).unwrap_err();
    let required = editor.check(1, CellEdit::Null, false).unwrap_err();
    let fine = editor.check(2, text("40"), false);
    session.close().await.unwrap();

    assert_eq!(number.code(), "edit.invalid_integer");
    assert_eq!(required.code(), "edit.required");
    assert!(fine.is_ok());
}

#[tokio::test]
async fn the_editor_starts_from_the_whole_value_and_a_new_row_from_the_server_s_values() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let editor = session.table_editor(people(), false, None).await.unwrap();
    let shown = page(&session).await;

    let name = editor.edit_start(shown.clone(), 0, 1).unwrap();
    let columns = editor.columns();
    session.close().await.unwrap();

    assert_eq!(
        name,
        EditStart::Editable {
            text: "Ada".to_owned(),
            is_null: false
        }
    );
    assert_eq!(editor.lock(), None);
    let news: Vec<CellEdit> = columns.iter().map(|column| column.new_row.clone()).collect();
    assert_eq!(
        news,
        [CellEdit::Default, CellEdit::Null, CellEdit::Null, CellEdit::Default]
    );
    assert!(columns[0].primary_key);
    assert!(!columns[0].editable);
    assert!(columns[1].editable);
    assert!(columns[1].takes_empty);
    assert!(!columns[3].takes_default);
}

#[tokio::test]
async fn a_table_with_no_primary_key_and_a_read_only_file_lock_every_row() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let notes = session
        .table_editor(
            TableName {
                schema: None,
                name: "notes".to_owned(),
            },
            false,
            None,
        )
        .await
        .unwrap();
    let no_key = notes.lock();
    session.close().await.unwrap();
    let read_only = core.open_file(file(&path, true), None).await.unwrap();
    let locked = read_only.table_editor(people(), false, None).await.unwrap();
    let shown = page(&read_only).await;
    let refused = locked.plan(shown, vec![RowEdit::Delete { row: 0 }]);
    read_only.close().await.unwrap();

    assert_eq!(no_key, Some(EditLock::NoPrimaryKey));
    assert_eq!(locked.lock(), Some(EditLock::ReadOnlyConnection));
    assert_eq!(refused.err().unwrap().code(), "edit.read_only_connection");
}

#[tokio::test]
async fn confirm_writes_shows_a_save_first_and_a_stricter_level_refuses_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = saved(&core, &path, SafeModeTag::Off).await;
    let editor = session.table_editor(people(), false, None).await.unwrap();
    let shown = page(&session).await;
    let delete = vec![RowEdit::Delete { row: 0 }];

    let at_off = editor.plan(shown.clone(), delete.clone()).unwrap();
    assert!(session.set_safe_mode(SafeModeTag::ConfirmWrites));
    let refused = at_off.run(false, None).await.err().unwrap();
    let asked = editor.plan(shown, delete).unwrap();
    let unanswered = asked.run(false, None).await.err().unwrap();
    let outcome = asked.run(true, None).await.unwrap();
    let after = rows(&session).await;
    session.close().await.unwrap();

    assert_eq!(at_off.gate(), SaveGate::Run);
    assert_eq!(refused.code(), "edit.safe_mode_changed");
    assert_eq!(asked.gate(), SaveGate::Confirm);
    assert_eq!(unanswered.code(), "edit.not_confirmed");
    assert_eq!(outcome, RowSaveOutcome::Saved { rows: Some(1) });
    assert_eq!(after.len(), 2);
}

#[tokio::test]
async fn a_row_that_changed_under_the_save_rolls_every_change_back() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let editor = session.table_editor(people(), false, None).await.unwrap();
    let shown = page(&session).await;
    run(&session, "DELETE FROM people WHERE id = 2").await;

    let save = editor
        .plan(
            shown,
            vec![
                RowEdit::Update {
                    row: 0,
                    cells: vec![CellChange {
                        column: 2,
                        edit: text("37"),
                    }],
                },
                RowEdit::Update {
                    row: 1,
                    cells: vec![CellChange {
                        column: 2,
                        edit: text("46"),
                    }],
                },
            ],
        )
        .unwrap();
    let outcome = save.run(false, None).await.unwrap();
    let after = rows(&session).await;
    session.close().await.unwrap();

    match outcome {
        RowSaveOutcome::RolledBack { error, edit } => {
            assert_eq!(error.code, "driver.row_guard_failed");
            assert_eq!(edit, Some(1));
        }
        other => panic!("expected a rollback, got {other:?}"),
    }
    assert_eq!(after[0][2].as_deref(), Some("36"));
}

#[tokio::test]
async fn a_saved_row_is_written_once_and_its_key_and_default_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let editor = session.table_editor(people(), false, None).await.unwrap();
    let shown = page(&session).await;

    let key = editor.check(0, text("9"), false).unwrap_err();
    let rowid_in_new_row = editor.check(0, text("9"), true).unwrap_err();
    let default = editor.check(3, CellEdit::Default, false).unwrap_err();
    let save = editor
        .plan(
            shown,
            vec![
                RowEdit::Update {
                    row: 0,
                    cells: vec![CellChange {
                        column: 1,
                        edit: text("first"),
                    }],
                },
                RowEdit::Update {
                    row: 1,
                    cells: vec![CellChange {
                        column: 1,
                        edit: text("gone anyway"),
                    }],
                },
                RowEdit::Delete { row: 1 },
                RowEdit::Update {
                    row: 0,
                    cells: vec![
                        CellChange {
                            column: 1,
                            edit: text("Ada"),
                        },
                        CellChange {
                            column: 2,
                            edit: text("37"),
                        },
                    ],
                },
            ],
        )
        .unwrap();
    let statements = save.statements();
    session.close().await.unwrap();

    assert_eq!(key.code(), "edit.not_editable");
    // A rowid alias is the server's to fill, as the Linux grid locks an auto-increment key in a new row.
    assert_eq!(rowid_in_new_row.code(), "edit.not_editable");
    assert_eq!(default.code(), "edit.no_default");
    assert_eq!(statements.len(), 2, "{statements:?}");
    assert!(statements[0].sql.starts_with("UPDATE"), "{statements:?}");
    assert_eq!(statements[0].values, ["37", "1"]);
    assert!(statements[1].sql.starts_with("DELETE"), "{statements:?}");
}

#[tokio::test]
async fn a_page_whose_key_cannot_be_named_exactly_is_locked() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    run(
        &session,
        "CREATE TABLE readings (at REAL PRIMARY KEY, value TEXT); INSERT INTO readings VALUES (0.1, 'a')",
    )
    .await;
    let readings = TableName {
        schema: None,
        name: "readings".to_owned(),
    };
    let editor = session.table_editor(readings.clone(), false, None).await.unwrap();
    let query = session.table_query(readings, None, 100, 0, None).await.unwrap();
    let shown = run(&session, &query.sql).await.unwrap();
    let people_editor = session.table_editor(people(), false, None).await.unwrap();
    let people_page = page(&session).await;

    let lock = editor.lock_for(shown);
    let open = people_editor.lock_for(people_page);
    session.close().await.unwrap();

    assert_eq!(
        lock,
        Some(EditLock::KeyUnreadable {
            column: "at".to_owned()
        })
    );
    assert_eq!(open, None);
}

#[tokio::test]
async fn a_new_row_leaves_a_blob_null_and_a_refresh_reads_the_columns_again() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    run(
        &session,
        "CREATE TABLE files (id INTEGER PRIMARY KEY, name TEXT, body BLOB)",
    )
    .await;
    let files = TableName {
        schema: None,
        name: "files".to_owned(),
    };
    let editor = session.table_editor(files.clone(), false, None).await.unwrap();
    let query = session.table_query(files.clone(), None, 100, 0, None).await.unwrap();
    let shown = run(&session, &query.sql).await.unwrap();

    let typed = editor.check(2, text("0x00"), true).unwrap_err();
    let save = editor
        .plan(
            shown,
            vec![RowEdit::Insert {
                cells: vec![CellEdit::Default, text("notes.txt"), CellEdit::Null],
            }],
        )
        .unwrap();
    let outcome = save.run(false, None).await.unwrap();
    run(&session, "ALTER TABLE files ADD COLUMN size INTEGER").await;
    let cached = session.table_editor(files.clone(), false, None).await.unwrap();
    let refreshed = session.table_editor(files, true, None).await.unwrap();
    session.close().await.unwrap();

    assert_eq!(typed.code(), "edit.not_editable");
    assert_eq!(outcome, RowSaveOutcome::Saved { rows: Some(1) });
    assert_eq!(cached.columns().len(), 3);
    assert_eq!(refreshed.columns().len(), 4);
}

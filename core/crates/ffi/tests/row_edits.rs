#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    CellEdit, ConnectionRecord, ConnectionSecrets, Core, DatabaseSession, EditLock, EditStart, FileOpenRequest,
    HostConfig, HostSecretError, HostSecrets, ProfileKindTag, ResultSet, RowSaveOutcome, RunListener, RunOutcome,
    RunSettings, SafeModeTag, SaveGate, SecretDeletionTag, SecretItemTag, SecretKindTag, TableEditor, TableName,
    TlsModeTag, TlsSettings, ValueKind,
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
    let editor = session.open_editor(None, None).await.unwrap();
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

// The page as a table tab reads it.
async fn page_of(session: &DatabaseSession, table: TableName) -> Arc<ResultSet> {
    let read = session
        .read_table_page(table, None, None, 100, 0, None, Box::new(Quiet), None)
        .await
        .unwrap();
    let run = read.run();
    assert!(matches!(run.outcome().await.unwrap(), RunOutcome::Completed { .. }));
    run.result_set(0).unwrap()
}

async fn page(session: &DatabaseSession) -> Arc<ResultSet> {
    page_of(session, people()).await
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

// Records a cell the user committed, failing the test on a refusal.
fn set(editor: &TableEditor, shown: &Arc<ResultSet>, row: u64, column: u32, edit: CellEdit) {
    editor.set_cell(shown.clone(), row, column, edit).unwrap();
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
        ai_policy: None,
        external_access: None,
        project_id: None,
        icon: None,
        order: 0,
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
async fn an_update_an_insert_and_a_delete_save_as_one_batch() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let editor = session.table_editor(people(), false, None).await.unwrap();
    let shown = page(&session).await;

    set(&editor, &shown, 0, 1, text("Ada Lovelace"));
    editor.insert_row().unwrap();
    // The draft sits after the three data rows.
    set(&editor, &shown, 3, 1, text("Edsger"));
    set(&editor, &shown, 3, 2, CellEdit::Null);
    editor.delete_rows(shown.clone(), vec![2]).unwrap();
    let preview = editor.preview().unwrap();
    let outcome = editor.save(shown.clone(), false, None).await.unwrap();
    // The tracker settled on the commit, so a second save has nothing to send.
    let again = editor.save(shown, false, None).await.unwrap();
    let after = rows(&session).await;
    session.close().await.unwrap();

    assert_eq!(preview.gate, SaveGate::Run);
    assert_eq!(preview.statements.len(), 3);
    assert!(preview.statements[0].sql.starts_with("UPDATE"), "{preview:?}");
    assert_eq!(preview.statements[0].values, ["'Ada Lovelace'", "1"]);
    assert!(preview.statements[1].sql.starts_with("INSERT"), "{preview:?}");
    assert!(preview.statements[2].sql.starts_with("DELETE"), "{preview:?}");
    assert_eq!(preview.statements[2].values, ["3"]);
    assert_eq!(outcome, RowSaveOutcome::Saved { rows: Some(3) });
    assert_eq!(again, RowSaveOutcome::Saved { rows: Some(0) });
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

    set(&editor, &shown, 1, 1, text("Changed"));
    set(&editor, &shown, 1, 1, text("Grace"));
    set(&editor, &shown, 1, 2, text("45"));
    let preview = editor.preview().unwrap();
    session.close().await.unwrap();

    assert!(preview.is_empty);
    assert_eq!(editor.pending().pending_count, 0);
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
    let refused = locked.delete_rows(shown, vec![0]);
    read_only.close().await.unwrap();

    assert_eq!(no_key, Some(EditLock::NoPrimaryKey));
    assert_eq!(locked.lock(), Some(EditLock::ReadOnlyConnection));
    assert_eq!(refused.err().unwrap().code(), "edit.read_only_connection");
}

#[tokio::test]
async fn confirm_writes_asks_first_and_an_unanswered_save_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = saved(&core, &path, SafeModeTag::Silent).await;
    let editor = session.table_editor(people(), false, None).await.unwrap();
    let shown = page(&session).await;

    editor.delete_rows(shown.clone(), vec![0]).unwrap();
    let at_off = editor.preview().unwrap();
    assert!(session.set_safe_mode(SafeModeTag::Alert));
    let asked = editor.preview().unwrap();
    let unanswered = editor.save(shown.clone(), false, None).await.err().unwrap();
    let outcome = editor.save(shown, true, None).await.unwrap();
    let after = rows(&session).await;
    session.close().await.unwrap();

    assert_eq!(at_off.gate, SaveGate::Run);
    assert_eq!(at_off.deletes, 1);
    assert_eq!(asked.gate, SaveGate::Confirm);
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

    set(&editor, &shown, 0, 2, text("37"));
    set(&editor, &shown, 1, 2, text("46"));
    let outcome = editor.save(shown.clone(), false, None).await.unwrap();
    let after = rows(&session).await;
    session.close().await.unwrap();

    match outcome {
        RowSaveOutcome::RolledBack { error, row } => {
            assert_eq!(error.code, "driver.row_guard_failed");
            assert_eq!(row, Some(1));
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
    set(&editor, &shown, 0, 1, text("first"));
    set(&editor, &shown, 1, 1, text("gone anyway"));
    editor.delete_rows(shown.clone(), vec![1]).unwrap();
    // Back to the fetched name, so column 1 drops out and only the age is written.
    set(&editor, &shown, 0, 1, text("Ada"));
    set(&editor, &shown, 0, 2, text("37"));
    let preview = editor.preview().unwrap();
    session.close().await.unwrap();

    assert_eq!(key.code(), "edit.not_editable");
    // A rowid alias is the server's to fill, as the Linux grid locks an auto-increment key in a new row.
    assert_eq!(rowid_in_new_row.code(), "edit.not_editable");
    assert_eq!(default.code(), "edit.no_default");
    assert_eq!(preview.statements.len(), 2, "{preview:?}");
    let update = preview
        .statements
        .iter()
        .find(|statement| statement.sql.starts_with("UPDATE"))
        .expect("one UPDATE");
    assert_eq!(update.values, ["37", "1"]);
    assert!(
        preview
            .statements
            .iter()
            .any(|statement| statement.sql.starts_with("DELETE")),
        "{preview:?}"
    );
}

#[tokio::test]
async fn deleting_a_row_then_restoring_it_leaves_nothing_to_save() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let editor = session.table_editor(people(), false, None).await.unwrap();
    let shown = page(&session).await;

    let deleted = editor.delete_rows(shown.clone(), vec![0, 1]).unwrap();
    let restored = editor.restore_rows(shown.clone(), vec![0, 1]).unwrap();
    // Undo the restore: both rows are marked for deletion again.
    let undone = editor.undo();
    session.close().await.unwrap();

    assert_eq!(deleted.pending_count, 2);
    assert_eq!(restored.pending_count, 0);
    assert!(!restored.has_changes);
    assert_eq!(undone.pending_count, 2);
    assert!(undone.can_redo);
}

#[tokio::test]
async fn an_edit_survives_a_sort_and_the_overlay_follows_the_row() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let editor = session.table_editor(people(), false, None).await.unwrap();
    let ascending = page(&session).await;

    set(&editor, &ascending, 0, 1, text("Ada Lovelace"));
    // A second page in the other order: id 1 is now last.
    let descending = page_of_sorted(&session).await;
    let up = editor.overlay(ascending);
    let down = editor.overlay(descending);
    session.close().await.unwrap();

    assert_eq!(up.cells.len(), 1);
    assert_eq!(up.cells[0].row, 0);
    assert_eq!(down.cells.len(), 1);
    assert_eq!(down.cells[0].row, 2, "the edit followed id 1 to the bottom");
    assert_eq!(down.cells[0].cell.text, "Ada Lovelace");
}

async fn page_of_sorted(session: &DatabaseSession) -> Arc<ResultSet> {
    run(session, "SELECT id, name, age, joined FROM people ORDER BY id DESC")
        .await
        .unwrap()
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
    let shown = page_of(&session, files.clone()).await;

    let typed = editor.check(2, text("0x00"), true).unwrap_err();
    editor.insert_row().unwrap();
    set(&editor, &shown, 0, 1, text("notes.txt"));
    let outcome = editor.save(shown, false, None).await.unwrap();
    run(&session, "ALTER TABLE files ADD COLUMN size INTEGER").await;
    let cached = session.table_editor(files.clone(), false, None).await.unwrap();
    let refreshed = session.table_editor(files, true, None).await.unwrap();
    session.close().await.unwrap();

    assert_eq!(typed.code(), "edit.not_editable");
    assert_eq!(outcome, RowSaveOutcome::Saved { rows: Some(1) });
    assert_eq!(cached.columns().len(), 3);
    assert_eq!(refreshed.columns().len(), 4);
}

#[tokio::test]
async fn a_column_says_what_it_holds_and_an_enum_names_its_labels() {
    let dir = tempfile::tempdir().unwrap();
    let request = FileOpenRequest {
        path: dir.path().join("moods.duckdb").display().to_string(),
        driver_id: Some("duckdb".to_owned()),
        read_only: false,
        create: true,
    };
    let core = core(dir.path());
    let session = core.open_file(request, None).await.unwrap();
    run(&session, "CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy')").await;
    run(
        &session,
        "CREATE TABLE days (id INTEGER PRIMARY KEY, feeling mood, done BOOLEAN, happened DATE, logged TIMESTAMP)",
    )
    .await;
    let days = TableName {
        schema: None,
        name: "days".to_owned(),
    };

    let columns = session.table_editor(days, false, None).await.unwrap().columns();

    let kinds: Vec<_> = columns.iter().map(|column| column.kind).collect();
    assert_eq!(
        kinds,
        [
            ValueKind::Integer,
            ValueKind::Text,
            ValueKind::Bool,
            ValueKind::Date,
            ValueKind::Timestamp
        ]
    );
    assert_eq!(columns[1].labels, ["sad", "ok", "happy"]);
    assert!(!columns[1].multiple);
    assert!(
        columns
            .iter()
            .filter(|column| column.name != "feeling")
            .all(|column| column.labels.is_empty())
    );
    assert!(columns.iter().all(|column| !column.needs_offset));
}

#[tokio::test]
async fn a_timestamp_with_a_time_zone_needs_its_offset_typed() {
    let dir = tempfile::tempdir().unwrap();
    let request = FileOpenRequest {
        path: dir.path().join("stamps.duckdb").display().to_string(),
        driver_id: Some("duckdb".to_owned()),
        read_only: false,
        create: true,
    };
    let core = core(dir.path());
    let session = core.open_file(request, None).await.unwrap();
    run(
        &session,
        "CREATE TABLE stamps (id INTEGER PRIMARY KEY, zoned TIMESTAMPTZ, plain TIMESTAMP)",
    )
    .await;
    let stamps = TableName {
        schema: None,
        name: "stamps".to_owned(),
    };

    let columns = session.table_editor(stamps, false, None).await.unwrap().columns();

    let needs: Vec<_> = columns.iter().map(|column| column.needs_offset).collect();
    assert_eq!(needs, [false, true, false]);
    assert_eq!(columns[1].kind, ValueKind::TimestampWithOffset);
}

#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    CellChange, CellEdit, Core, DatabaseSession, EditLock, FileOpenRequest, HostConfig, HostSecretError, HostSecrets,
    ProfileKindTag, ResultSet, RowEdit, RowSaveOutcome, RunListener, RunOutcome, RunSettings, SecretItemTag,
    SecretKindTag,
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

    fn delete_profile(&self, _: String, _: ProfileKindTag) -> Result<(), HostSecretError> {
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

async fn lock_of(session: &DatabaseSession, sql: &str) -> Option<EditLock> {
    let set = run(session, sql).await.unwrap();
    session.result_editor(sql.to_owned(), set, None).await.unwrap().lock()
}

#[tokio::test]
async fn a_result_of_one_keyed_table_saves_an_update_an_insert_and_a_delete() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let sql = "SELECT name, id, age FROM people WHERE age > 20 ORDER BY id";
    let shown = run(&session, sql).await.unwrap();
    let editor = session
        .result_editor(sql.to_owned(), shown.clone(), None)
        .await
        .unwrap();
    let columns = editor.columns();
    let copies = editor.copies_exactly(shown.clone(), 0);

    let save = editor
        .plan(
            shown,
            vec![
                RowEdit::Update {
                    row: 0,
                    cells: vec![CellChange {
                        column: 0,
                        edit: text("Ada Lovelace"),
                    }],
                },
                RowEdit::Insert {
                    cells: vec![text("Edsger"), CellEdit::Default, CellEdit::Null],
                },
                RowEdit::Delete { row: 2 },
            ],
        )
        .unwrap();
    let statements = save.statements();
    let outcome = save.run(false, None).await.unwrap();
    let after = rows(&session).await;
    session.close().await.unwrap();

    assert_eq!(editor.lock(), None);
    assert!(copies);
    assert_eq!(editor.table().map(|table| table.name).as_deref(), Some("people"));
    assert_eq!(
        columns.iter().map(|column| column.name.as_str()).collect::<Vec<_>>(),
        ["name", "id", "age"]
    );
    assert!(columns[0].editable && !columns[1].editable && columns[1].primary_key && columns[2].editable);
    assert!(statements[0].sql.starts_with("UPDATE"), "{statements:?}");
    assert_eq!(statements[0].values, ["'Ada Lovelace'", "1"]);
    assert!(statements[1].sql.starts_with("INSERT"), "{statements:?}");
    assert!(!statements[1].sql.contains("joined"), "{statements:?}");
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
async fn a_second_copy_of_a_column_is_locked_and_left_out_of_every_statement() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let sql = "SELECT id, name, name AS again FROM people ORDER BY id";
    let shown = run(&session, sql).await.unwrap();
    let editor = session
        .result_editor(sql.to_owned(), shown.clone(), None)
        .await
        .unwrap();
    let columns = editor.columns();
    let refused = editor.check(2, text("x"), false).err().unwrap();
    let save = editor
        .plan(
            shown,
            vec![RowEdit::Insert {
                cells: vec![CellEdit::Default, text("Edsger"), text("ignored")],
            }],
        )
        .unwrap();
    let statements = save.statements();
    session.close().await.unwrap();

    assert_eq!(columns[2].name, "again");
    assert!(!columns[2].editable && !columns[2].editable_in_new_row);
    assert_eq!(refused.code(), "edit.not_editable");
    assert_eq!(statements.len(), 1);
    assert_eq!(statements[0].values, ["'Edsger'"], "{statements:?}");
}

#[tokio::test]
async fn a_result_that_is_not_one_keyed_table_s_rows_says_why() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    run(&session, "CREATE VIEW grown AS SELECT * FROM people WHERE age > 30").await;

    let joined = lock_of(&session, "SELECT * FROM people, notes").await;
    let common = lock_of(&session, "WITH p AS (SELECT * FROM people) SELECT * FROM p").await;
    let counted = lock_of(&session, "SELECT count(*) FROM people").await;
    let computed = lock_of(&session, "SELECT id, upper(name) FROM people").await;
    let keyless = lock_of(&session, "SELECT name FROM people").await;
    let no_key = lock_of(&session, "SELECT body FROM notes").await;
    let view = lock_of(&session, "SELECT * FROM grown").await;
    let pragma = lock_of(&session, "PRAGMA table_info(people)").await;
    session.close().await.unwrap();
    let read_only = core.open_file(file(&path, true), None).await.unwrap();
    let locked = lock_of(&read_only, "SELECT id, name FROM people").await;
    read_only.close().await.unwrap();

    assert_eq!(joined, Some(EditLock::MoreThanOneTable));
    assert_eq!(common, Some(EditLock::MoreThanOneTable));
    assert_eq!(counted, Some(EditLock::Collapsed));
    assert_eq!(computed, Some(EditLock::Collapsed));
    assert_eq!(keyless, Some(EditLock::KeyNotShown));
    assert_eq!(no_key, Some(EditLock::NoPrimaryKey));
    assert_eq!(view, Some(EditLock::Untraced));
    assert_eq!(pragma, Some(EditLock::NotOneSelect));
    assert_eq!(locked, Some(EditLock::ReadOnlyConnection));
}

#[tokio::test]
async fn a_locked_result_names_no_table() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let sql = "SELECT count(*) FROM people";
    let set = run(&session, sql).await.unwrap();
    let editor = session.result_editor(sql.to_owned(), set, None).await.unwrap();
    session.close().await.unwrap();

    assert_eq!(editor.table(), None);
}

#[tokio::test]
async fn edits_name_rows_of_the_editor_s_own_result_sorted_or_not() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await;
    let session = core.open_file(file(&path, false), None).await.unwrap();
    let sql = "SELECT id, name FROM people";
    let shown = run(&session, sql).await.unwrap();
    let editor = session
        .result_editor(sql.to_owned(), shown.clone(), None)
        .await
        .unwrap();
    let sorted = shown.sorted(1, false).unwrap();
    let again = run(&session, sql).await.unwrap();
    let other = run(&session, "SELECT id, age FROM people").await.unwrap();
    let sorted_lock = editor.lock_for(sorted.clone());
    let again_lock = editor.lock_for(again.clone());
    let other_lock = editor.lock_for(other.clone());
    let refused = editor.plan(again, vec![RowEdit::Delete { row: 0 }]).err().unwrap();
    let save = editor.plan(sorted, vec![RowEdit::Delete { row: 0 }]).unwrap();
    let statements = save.statements();
    session.close().await.unwrap();

    assert_eq!(sorted_lock, None);
    assert_eq!(again_lock, Some(EditLock::ColumnsChanged));
    assert_eq!(other_lock, Some(EditLock::ColumnsChanged));
    assert_eq!(refused.code(), "edit.columns_changed");
    // Linus sorts first by name, descending.
    assert_eq!(statements[0].values, ["3"]);
}

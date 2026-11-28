#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    Core, DatabaseSession, DraftColumnInput, FileOpenRequest, HostConfig, HostSecretError, HostSecrets, ObjectKindTag,
    ProfileKindTag, ResultSet, RunListener, RunOutcome, RunSettings, SafeModeTag, SaveBlockerTag, SaveGate,
    SecretDeletionTag, SecretItemTag, SecretKindTag, TableDraftInput, TableName, TableSaveOutcome,
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

fn table(name: &str) -> TableName {
    TableName {
        schema: None,
        name: name.to_owned(),
    }
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

fn column(name: &str, type_text: &str, primary_key: bool, nullable: bool) -> DraftColumnInput {
    DraftColumnInput {
        original_name: None,
        name: name.to_owned(),
        type_text: type_text.to_owned(),
        nullable,
        primary_key,
        auto_increment: false,
        default_text: String::new(),
        comment: None,
        character_set: None,
        collation: None,
    }
}

async fn column_names(session: &DatabaseSession, name: &str) -> Vec<String> {
    session
        .table_structure(table(name), ObjectKindTag::Table, None)
        .await
        .unwrap()
        .columns
        .into_iter()
        .map(|column| column.name)
        .collect()
}

#[tokio::test]
async fn a_new_table_is_created_through_the_designer() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path()).await;
    let designer = session.open_table_designer(None, None, None).await.unwrap();
    let draft = TableDraftInput {
        schema: None,
        name: "gadgets".to_owned(),
        columns: vec![
            column("id", "INTEGER", true, false),
            column("label", "TEXT", false, true),
        ],
        indexes: Vec::new(),
        foreign_keys: Vec::new(),
        options: None,
    };

    let plan = designer.plan(draft).unwrap();
    let outcome = designer.run(plan.plan_id, true, None).await.unwrap();

    assert!(plan.blocked.is_none());
    assert_eq!(plan.gate, SaveGate::Run);
    assert_eq!(plan.saved_table_name.as_deref(), Some("gadgets"));
    assert!(
        plan.statements[0].to_uppercase().contains("CREATE TABLE"),
        "{:?}",
        plan.statements
    );
    assert_eq!(outcome, TableSaveOutcome::Done);
    assert_eq!(column_names(&session, "gadgets").await, ["id", "label"]);
}

#[tokio::test]
async fn a_column_added_in_the_designer_lands_on_the_table() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path()).await;
    run(
        &session,
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
    )
    .await;
    let designer = session
        .open_table_designer(Some(table("people")), None, None)
        .await
        .unwrap();

    let mut draft = designer.starting_draft().unwrap();
    assert_eq!(
        draft
            .columns
            .iter()
            .map(|column| column.name.clone())
            .collect::<Vec<_>>(),
        ["id", "name"]
    );
    draft.columns.push(column("age", "INTEGER", false, true));
    let plan = designer.plan(draft).unwrap();
    let outcome = designer.run(plan.plan_id, true, None).await.unwrap();

    assert_eq!(plan.operations, 1);
    assert_eq!(outcome, TableSaveOutcome::Done);
    assert_eq!(column_names(&session, "people").await, ["id", "name", "age"]);
}

#[tokio::test]
async fn a_plan_runs_once_and_a_stale_id_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path()).await;
    run(&session, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)").await;
    let designer = session
        .open_table_designer(Some(table("notes")), None, None)
        .await
        .unwrap();

    let mut draft = designer.starting_draft().unwrap();
    draft.columns.push(column("tag", "TEXT", false, true));
    let plan = designer.plan(draft).unwrap();
    let first = designer.run(plan.plan_id, true, None).await.unwrap();
    let again = designer.run(plan.plan_id, true, None).await.unwrap_err();
    let stale = designer
        .run(plan.plan_id.wrapping_sub(1), true, None)
        .await
        .unwrap_err();

    assert_eq!(first, TableSaveOutcome::Done);
    assert_eq!(again.code(), "designer.already_run");
    assert_eq!(stale.code(), "designer.not_planned");
}

#[tokio::test]
async fn a_default_the_parser_refuses_holds_the_save() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path()).await;
    let designer = session.open_table_designer(None, None, None).await.unwrap();
    let mut note = column("note", "TEXT", false, true);
    note.default_text = "1 +".to_owned();
    let draft = TableDraftInput {
        schema: None,
        name: "loose".to_owned(),
        columns: vec![column("id", "INTEGER", true, false), note],
        indexes: Vec::new(),
        foreign_keys: Vec::new(),
        options: None,
    };

    let plan = designer.plan(draft).unwrap();
    let refused = designer.run(plan.plan_id, true, None).await.unwrap_err();

    assert!(
        matches!(plan.blocked, Some(SaveBlockerTag::UnparsedDefault { ref column }) if column == "note"),
        "{:?}",
        plan.blocked
    );
    assert_eq!(refused.code(), "designer.unparsed_default");
}

#[tokio::test]
async fn a_safe_mode_saved_after_the_plan_refuses_the_run() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path()).await;
    run(&session, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)").await;
    let designer = session
        .open_table_designer(Some(table("items")), None, None)
        .await
        .unwrap();

    let mut draft = designer.starting_draft().unwrap();
    draft.columns.push(column("qty", "INTEGER", false, true));
    let plan = designer.plan(draft).unwrap();
    assert!(session.set_safe_mode(SafeModeTag::Alert));
    let refused = designer.run(plan.plan_id, true, None).await.unwrap_err();

    assert_eq!(plan.gate, SaveGate::Run);
    assert_eq!(refused.code(), "designer.safe_mode_changed");
    assert_eq!(column_names(&session, "items").await, ["id", "name"]);
}

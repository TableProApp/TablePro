#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    CatalogChangeOutcome, CatalogOperation, Core, DatabaseSession, FileOpenRequest, HostConfig, HostSecretError,
    HostSecrets, ObjectScopeArg, ProfileKindTag, ResultSet, RunListener, RunOutcome, RunSettings, SafeModeTag,
    SaveGate, SecretDeletionTag, SecretItemTag, SecretKindTag, TableName,
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

async fn open(dir: &Path, file: &str, driver: Option<&str>) -> (Arc<Core>, Arc<DatabaseSession>) {
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
        driver_id: driver.map(str::to_owned),
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

async fn tables(session: &DatabaseSession) -> Vec<String> {
    session
        .refresh_objects(ObjectScopeArg::DefaultSchema, None)
        .await
        .unwrap()
        .into_iter()
        .map(|object| object.name)
        .collect()
}

#[tokio::test]
async fn a_table_is_emptied_only_once_the_question_is_answered_and_only_once() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path(), "app.sqlite", None).await;
    run(
        &session,
        "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO items (name) VALUES ('pen'), ('ink')",
    )
    .await;
    let abilities = session.catalog_abilities();
    let truncate = CatalogOperation::TruncateTable {
        table: table("items"),
        cascade: false,
        restart_identity: false,
        cluster: None,
    };

    let change = session.plan_catalog_change(truncate).unwrap();
    let unanswered = change.run(false, None).await.unwrap_err();
    let kept = count(&session, "items").await;
    let outcome = change.run(true, None).await.unwrap();
    let again = change.run(true, None).await.unwrap_err();

    assert!(abilities.truncate_table && abilities.truncate_refused_when_referenced && abilities.drop_table);
    assert!(!abilities.create_schema && !abilities.create_database);
    assert_eq!(change.statements(), ["DELETE FROM \"items\""]);
    assert_eq!(change.gate(), SaveGate::Confirm);
    assert!(change.destructive());
    assert_eq!(unanswered.code(), "catalog.not_confirmed");
    assert_eq!(kept.as_deref(), Some("2"));
    assert_eq!(outcome, CatalogChangeOutcome::Done);
    assert_eq!(count(&session, "items").await.as_deref(), Some("0"));
    assert_eq!(again.code(), "catalog.already_run");
}

#[tokio::test]
async fn a_dropped_table_leaves_the_catalog_and_the_tables_pointing_at_one_are_named() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path(), "app.sqlite", None).await;
    run(
        &session,
        "CREATE TABLE authors (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES authors(id)); \
         CREATE TABLE books (id INTEGER PRIMARY KEY, author INTEGER REFERENCES authors(id)); \
         CREATE TABLE reviews (id INTEGER PRIMARY KEY, author INTEGER REFERENCES authors(id), \
         book INTEGER REFERENCES books(id))",
    )
    .await;

    let keys = session.table_keys(table("authors"), None).await.unwrap();
    let drop = session
        .plan_catalog_change(CatalogOperation::DropTable {
            table: table("reviews"),
            cascade: false,
        })
        .unwrap();
    let outcome = drop.run(true, None).await.unwrap();

    assert_eq!(keys.referencing_tables(), [table("books"), table("reviews")]);
    assert_eq!(drop.statements(), ["DROP TABLE \"reviews\""]);
    assert_eq!(outcome, CatalogChangeOutcome::Done);
    assert!(!tables(&session).await.contains(&"reviews".to_owned()));
}

#[tokio::test]
async fn an_operation_the_engine_has_no_syntax_for_is_refused_before_anything_is_shown() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path(), "app.sqlite", None).await;

    let schema = session
        .plan_catalog_change(CatalogOperation::CreateSchema {
            name: "sales".to_owned(),
            owner: None,
        })
        .err()
        .unwrap();
    let cascade = session
        .plan_catalog_change(CatalogOperation::TruncateTable {
            table: table("items"),
            cascade: true,
            restart_identity: false,
            cluster: None,
        })
        .err()
        .unwrap();

    assert_eq!(schema.code(), "catalog.unsupported");
    assert_eq!(cascade.code(), "catalog.unsupported");
}

#[tokio::test]
async fn a_schema_is_created_and_dropped_and_the_schemas_are_read_again() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path(), "app.duckdb", Some("duckdb")).await;
    let before = session.schemas(None).await.unwrap();

    let create = session
        .plan_catalog_change(CatalogOperation::CreateSchema {
            name: "sales".to_owned(),
            owner: None,
        })
        .unwrap();
    let created = create.run(false, None).await.unwrap();
    let after_create = session.refresh_schemas(None).await.unwrap();
    let drop = session
        .plan_catalog_change(CatalogOperation::DropSchema {
            name: "sales".to_owned(),
            cascade: true,
        })
        .unwrap();
    let dropped = drop.run(true, None).await.unwrap();
    let after_drop = session.refresh_schemas(None).await.unwrap();

    assert!(session.catalog_abilities().create_schema);
    assert!(session.protects_schema("main".to_owned()));
    assert!(!session.protects_schema("sales".to_owned()));
    assert_eq!(create.statements(), ["CREATE SCHEMA \"sales\""]);
    assert_eq!(create.gate(), SaveGate::Run);
    assert_eq!(drop.statements(), ["DROP SCHEMA \"sales\" CASCADE"]);
    assert_eq!(
        (created, dropped),
        (CatalogChangeOutcome::Done, CatalogChangeOutcome::Done)
    );
    assert!(!names_of(&before).contains(&"sales".to_owned()));
    assert!(names_of(&after_create).contains(&"sales".to_owned()));
    assert!(!names_of(&after_drop).contains(&"sales".to_owned()));
}

#[tokio::test]
async fn a_level_saved_after_the_plan_refuses_it_before_anything_is_sent() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = open(dir.path(), "app.duckdb", Some("duckdb")).await;

    let create = session
        .plan_catalog_change(CatalogOperation::CreateSchema {
            name: "sales".to_owned(),
            owner: None,
        })
        .unwrap();
    assert!(session.set_safe_mode(SafeModeTag::Alert));
    let refused = create.run(false, None).await.unwrap_err();
    let asked = session
        .plan_catalog_change(CatalogOperation::CreateSchema {
            name: "sales".to_owned(),
            owner: None,
        })
        .unwrap();

    assert_eq!(create.gate(), SaveGate::Run);
    assert_eq!(refused.code(), "catalog.safe_mode_changed");
    assert_eq!(asked.gate(), SaveGate::Confirm);
    assert!(
        !names_of(&session.refresh_schemas(None).await.unwrap()).contains(&"sales".to_owned()),
        "nothing ran"
    );
}

fn names_of(schemas: &[tablepro_ffi::SchemaEntry]) -> Vec<String> {
    schemas.iter().map(|schema| schema.name.clone()).collect()
}

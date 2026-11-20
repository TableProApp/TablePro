#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    ConnectionLibrary, ConnectionRecord, ConnectionSecrets, Core, DatabaseSession, FileOpenRequest, HistoryOutcomeTag,
    HistoryRun, HostConfig, HostSecretError, HostSecrets, LibrarySnapshot, SafeModeTag, SecretItemTag, SecretKindTag,
    TlsModeTag, TlsSettings,
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

fn record(name: &str, database: &str) -> ConnectionRecord {
    ConnectionRecord {
        id: String::new(),
        name: name.to_owned(),
        driver_id: "sqlite".to_owned(),
        host: String::new(),
        port: 0,
        database: database.to_owned(),
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
        color: None,
        group_id: None,
        last_opened_ms: None,
        tags: Vec::new(),
        ai_policy: None,
        external_access: None,
        project_id: None,
    }
}

async fn saved(library: &ConnectionLibrary, name: &str, project: Option<&str>, group: Option<&str>) -> String {
    let mut record = record(name, &format!("/tmp/{name}.sqlite"));
    record.project_id = project.map(str::to_owned);
    record.group_id = group.map(str::to_owned);
    library.save(record, ConnectionSecrets::default()).await.unwrap().id
}

fn names(snapshot: &LibrarySnapshot) -> Vec<&str> {
    let mut names: Vec<&str> = snapshot
        .connections
        .iter()
        .map(|connection| connection.name.as_str())
        .collect();
    names.sort_unstable();
    names
}

fn project_of<'a>(snapshot: &'a LibrarySnapshot, id: &str) -> Option<&'a str> {
    snapshot
        .connections
        .iter()
        .find(|connection| connection.id == id)
        .unwrap()
        .project_id
        .as_deref()
}

async fn connected(core: &Core, dir: &Path, name: &str, project: Option<&str>) -> Arc<DatabaseSession> {
    let path = dir.join(format!("{name}.sqlite"));
    let request = FileOpenRequest {
        path: path.display().to_string(),
        driver_id: None,
        read_only: false,
        create: true,
    };
    core.open_file(request, None).await.unwrap().close().await.unwrap();
    let mut record = record(name, &path.display().to_string());
    record.project_id = project.map(str::to_owned);
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

fn ran(sql: &str, at_secs: i64) -> HistoryRun {
    HistoryRun {
        sql: sql.to_owned(),
        executed_at_ms: at_secs * 1_000,
        duration_ms: Some(1),
        rows_affected: None,
        outcome: HistoryOutcomeTag::Succeeded,
    }
}

#[tokio::test]
async fn projects_are_made_renamed_recoloured_reordered_and_deleted() {
    let dir = tempfile::tempdir().unwrap();
    let library = core(dir.path()).library().unwrap();

    let acme = library.create_project(" Acme ".to_owned(), None).await.unwrap();
    let globex = library
        .create_project("Globex".to_owned(), Some("red".to_owned()))
        .await
        .unwrap();
    let taken = library.create_project("ACME".to_owned(), None).await.unwrap_err();
    let empty = library.create_project("  ".to_owned(), None).await.unwrap_err();
    let renamed_onto = library
        .rename_project(globex.id.clone(), "acme".to_owned())
        .await
        .unwrap_err();
    library
        .rename_project(acme.id.clone(), "Acme Corp".to_owned())
        .await
        .unwrap();
    library
        .set_project_color(acme.id.clone(), Some("blue".to_owned()))
        .await
        .unwrap();
    library.set_project_color(globex.id.clone(), None).await.unwrap();
    library
        .move_projects(vec![globex.id.clone()], Some(acme.id.clone()))
        .await
        .unwrap();
    let ordered = library.snapshot().await.unwrap().projects;
    library.delete_project(acme.id.clone()).await.unwrap();
    let left = library.snapshot().await.unwrap().projects;
    let gone = library
        .rename_project(acme.id.clone(), "Again".to_owned())
        .await
        .unwrap_err();

    assert_eq!((acme.name.as_str(), acme.order), ("Acme", 0));
    assert_eq!((globex.color.as_deref(), globex.order), (Some("red"), 1));
    assert_eq!(taken.code(), "storage.project_name_taken");
    assert_eq!(empty.code(), "project_name.empty");
    assert_eq!(renamed_onto.code(), "storage.project_name_taken");
    let shown: Vec<(&str, Option<&str>, u32)> = ordered
        .iter()
        .map(|project| (project.name.as_str(), project.color.as_deref(), project.order))
        .collect();
    assert_eq!(shown, [("Globex", None, 0), ("Acme Corp", Some("blue"), 1)]);
    assert_eq!(left.len(), 1);
    assert_eq!(left[0].id, globex.id);
    assert_eq!(gone.code(), "storage.project_not_found");
}

#[tokio::test]
async fn a_scoped_snapshot_shows_one_project_and_an_unknown_one_shows_everything() {
    let dir = tempfile::tempdir().unwrap();
    let library = core(dir.path()).library().unwrap();
    let acme = library.create_project("Acme".to_owned(), None).await.unwrap();
    let globex = library.create_project("Globex".to_owned(), None).await.unwrap();
    let production = library
        .create_group("Production".to_owned(), None, Some(acme.id.clone()))
        .await
        .unwrap();
    let eu = library
        .create_group("EU".to_owned(), Some(production.id.clone()), Some(globex.id.clone()))
        .await
        .unwrap();
    let same_name = library
        .create_group("Production".to_owned(), None, Some(globex.id.clone()))
        .await
        .unwrap();
    let prod = saved(&library, "prod", None, Some(&eu.id)).await;
    let loose = saved(&library, "loose", Some(&acme.id), None).await;
    let other = saved(&library, "other", Some(&globex.id), None).await;
    saved(&library, "stray", None, None).await;
    library.set_favorite(prod.clone(), true).await.unwrap();
    library.set_favorite(other.clone(), true).await.unwrap();

    let whole = library.snapshot().await.unwrap();
    let in_acme = library.snapshot_in(Some(acme.id.clone())).await.unwrap();
    let in_globex = library.snapshot_in(Some(globex.id.clone())).await.unwrap();
    let unknown = library
        .snapshot_in(Some(uuid::Uuid::new_v4().to_string()))
        .await
        .unwrap();
    let malformed = library.snapshot_in(Some("acme".to_owned())).await.unwrap_err();

    assert_eq!(
        eu.project_id.as_deref(),
        Some(acme.id.as_str()),
        "a subgroup follows its top"
    );
    assert_eq!(same_name.project_id.as_deref(), Some(globex.id.as_str()));
    assert_eq!(names(&whole), ["loose", "other", "prod", "stray"]);
    assert_eq!(whole.scope, None);
    assert_eq!(project_of(&whole, &prod), Some(acme.id.as_str()));
    assert_eq!(project_of(&whole, &loose), Some(acme.id.as_str()));
    assert_eq!(names(&in_acme), ["loose", "prod"]);
    assert_eq!(in_acme.scope.as_deref(), Some(acme.id.as_str()));
    assert_eq!(in_acme.favorites, std::slice::from_ref(&prod));
    let groups: Vec<&str> = in_acme.groups.iter().map(|group| group.name.as_str()).collect();
    assert_eq!(groups, ["Production", "EU"]);
    assert_eq!(
        in_acme.projects.len(),
        2,
        "the switcher lists every project in any scope"
    );
    assert_eq!(names(&in_globex), ["other"]);
    assert_eq!(in_globex.groups.len(), 1);
    assert_eq!(names(&unknown), names(&whole));
    assert_eq!(unknown.scope, None);
    assert_eq!(library.snapshot_in(None).await.unwrap(), whole);
    assert_eq!(malformed.code(), "library.invalid_id");
}

#[tokio::test]
async fn connections_and_top_level_groups_move_between_projects() {
    let dir = tempfile::tempdir().unwrap();
    let library = core(dir.path()).library().unwrap();
    let acme = library.create_project("Acme".to_owned(), None).await.unwrap();
    let globex = library.create_project("Globex".to_owned(), None).await.unwrap();
    let work = library.create_group("Work".to_owned(), None, None).await.unwrap();
    let nested = library
        .create_group("Nested".to_owned(), Some(work.id.clone()), None)
        .await
        .unwrap();
    let grouped = saved(&library, "grouped", None, Some(&nested.id)).await;
    let loose = saved(&library, "loose", None, None).await;

    library
        .move_to_project(vec![loose.clone()], Some(acme.id.clone()))
        .await
        .unwrap();
    library
        .move_groups_to_project(vec![work.id.clone()], Some(globex.id.clone()))
        .await
        .unwrap();
    let refused_connection = library
        .move_to_project(vec![grouped.clone()], Some(acme.id.clone()))
        .await
        .unwrap_err();
    let refused_group = library
        .move_groups_to_project(vec![nested.id.clone()], Some(acme.id.clone()))
        .await
        .unwrap_err();
    let unknown = library
        .move_to_project(vec![loose.clone()], Some(uuid::Uuid::new_v4().to_string()))
        .await
        .unwrap_err();
    let moved = library.snapshot().await.unwrap();
    library.move_to_project(vec![loose.clone()], None).await.unwrap();
    library.delete_project(globex.id.clone()).await.unwrap();
    let after = library.snapshot().await.unwrap();

    assert_eq!(refused_connection.code(), "storage.connection_grouped");
    assert_eq!(refused_group.code(), "storage.group_not_top_level");
    assert_eq!(unknown.code(), "storage.project_not_found");
    assert_eq!(project_of(&moved, &loose), Some(acme.id.as_str()));
    assert_eq!(project_of(&moved, &grouped), Some(globex.id.as_str()));
    assert!(
        moved
            .groups
            .iter()
            .all(|group| group.project_id.as_deref() == Some(globex.id.as_str()))
    );
    assert_eq!(project_of(&after, &loose), None);
    assert_eq!(
        project_of(&after, &grouped),
        None,
        "a deleted project keeps its connections"
    );
    assert_eq!(after.groups.len(), 2);
}

#[tokio::test]
async fn a_save_places_a_new_connection_and_an_edit_without_a_project_keeps_it() {
    let dir = tempfile::tempdir().unwrap();
    let library = core(dir.path()).library().unwrap();
    let acme = library.create_project("Acme".to_owned(), None).await.unwrap();
    let globex = library.create_project("Globex".to_owned(), None).await.unwrap();
    let mut new = record("shop", "/tmp/shop.sqlite");
    new.project_id = Some(acme.id.clone());

    let created = library.save(new, ConnectionSecrets::default()).await.unwrap();
    let mut edit = created.clone();
    edit.name = "shop two".to_owned();
    edit.project_id = None;
    let kept = library.save(edit, ConnectionSecrets::default()).await.unwrap();
    let mut named = kept.clone();
    named.project_id = Some(globex.id.clone());
    let moved = library.save(named, ConnectionSecrets::default()).await.unwrap();
    let copy = library
        .duplicate(moved.id.clone(), "shop copy".to_owned())
        .await
        .unwrap();

    assert_eq!(created.project_id.as_deref(), Some(acme.id.as_str()));
    assert_eq!(kept.project_id.as_deref(), Some(acme.id.as_str()));
    assert_eq!(moved.project_id.as_deref(), Some(globex.id.as_str()));
    assert_eq!(
        copy.project_id.as_deref(),
        Some(globex.id.as_str()),
        "a copy stays beside its source"
    );
}

#[tokio::test]
async fn a_projects_export_holds_its_own_and_an_import_lands_in_the_project_given() {
    let dir = tempfile::tempdir().unwrap();
    let library = core(&dir.path().join("one")).library().unwrap();
    let acme = library.create_project("Acme".to_owned(), None).await.unwrap();
    saved(&library, "inside", Some(&acme.id), None).await;
    saved(&library, "outside", None, None).await;
    let scoped = dir.path().join("acme.json");
    let whole = dir.path().join("all.json");

    let scoped_count = library
        .export_file(scoped.display().to_string(), Some(acme.id.clone()))
        .await
        .unwrap();
    let whole_count = library.export_file(whole.display().to_string(), None).await.unwrap();
    let elsewhere = core(&dir.path().join("two")).library().unwrap();
    let home = elsewhere.create_project("Home".to_owned(), None).await.unwrap();
    elsewhere
        .import_file(whole.display().to_string(), Some(home.id.clone()))
        .await
        .unwrap();
    let landed = elsewhere.snapshot().await.unwrap();

    assert_eq!((scoped_count, whole_count), (1, 2));
    let text = std::fs::read_to_string(&scoped).unwrap();
    assert!(text.contains("inside") && !text.contains("outside"), "{text}");
    let project = |name: &str| {
        let connection = landed.connections.iter().find(|held| held.name == name).unwrap();
        let id = connection.project_id.as_deref()?;
        landed
            .projects
            .iter()
            .find(|held| held.id == id)
            .map(|held| held.name.as_str())
    };
    assert_eq!(project("inside"), Some("Acme"), "the file's project wins");
    assert_eq!(project("outside"), Some("Home"));
}

#[tokio::test]
async fn recent_and_the_history_follow_the_project_and_a_deleted_connections_runs_go_with_it() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let library = core.library().unwrap();
    let acme = library.create_project("Acme".to_owned(), None).await.unwrap();
    let inside = connected(&core, dir.path(), "inside", Some(&acme.id)).await;
    let outside = connected(&core, dir.path(), "outside", None).await;
    let history = core.history().await.unwrap();
    history
        .record(inside.clone(), ran("SELECT 1", 1_700_000_000))
        .await
        .unwrap()
        .unwrap();
    history
        .record(outside.clone(), ran("SELECT 2", 1_700_000_001))
        .await
        .unwrap()
        .unwrap();
    let search = |project: Option<String>| {
        let history = history.clone();
        async move {
            let page = history.search(String::new(), None, project, None, 50).await.unwrap();
            page.entries.into_iter().map(|entry| entry.sql).collect::<Vec<_>>()
        }
    };

    let scoped_recent = library.snapshot_in(Some(acme.id.clone())).await.unwrap().recent;
    let every_recent = library.snapshot().await.unwrap().recent;
    let scoped = search(Some(acme.id.clone())).await;
    let every = search(None).await;
    let unknown = search(Some(uuid::Uuid::new_v4().to_string())).await;
    let removed = history.delete_for_connection(inside.id()).await.unwrap();
    let again = history.delete_for_connection(inside.id()).await.unwrap();
    let after = search(None).await;
    let malformed = history.delete_for_connection("nope".to_owned()).await.unwrap_err();

    assert_eq!(scoped_recent, [inside.id()]);
    assert_eq!(every_recent.len(), 2);
    assert_eq!(scoped, ["SELECT 1"]);
    assert_eq!(every, ["SELECT 2", "SELECT 1"]);
    assert_eq!(unknown, every, "a project that is gone is all connections");
    assert_eq!((removed, again), (1, 0));
    assert_eq!(after, ["SELECT 2"]);
    assert_eq!(malformed.code(), "library.invalid_id");
}

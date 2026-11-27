#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use secrecy::{ExposeSecret, SecretString};
use tablepro_ffi::{
    Core, ForeignAppDirsArg, ForeignAppTag, ForeignImportRequest, ForeignSourceInfo, HostConfig, HostSecretError,
    HostSecrets, PasswordOfferTag, PasswordOutcomeTag, ProfileKindTag, QueryAvailabilityTag, ResolutionTag,
    ScanDepthTag, SecretDeletionTag, SecretItemTag, SecretKindTag, SourceAvailabilityTag,
};

#[derive(Default)]
struct Vault {
    stored: Mutex<HashMap<(String, SecretKindTag), String>>,
}

struct Shared(Arc<Vault>);

impl HostSecrets for Shared {
    fn load(&self, id: String, kind: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(self
            .0
            .stored
            .lock()
            .unwrap()
            .get(&(id, kind))
            .cloned()
            .map(SecretString::from))
    }

    fn store(&self, id: String, kind: SecretKindTag, secret: SecretString, _: String) -> Result<(), HostSecretError> {
        self.0
            .stored
            .lock()
            .unwrap()
            .insert((id, kind), secret.expose_secret().to_owned());
        Ok(())
    }

    fn relabel(&self, _: String, _: SecretKindTag, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete(&self, id: String, kind: SecretKindTag) -> Result<(), HostSecretError> {
        self.0.stored.lock().unwrap().remove(&(id, kind));
        Ok(())
    }

    fn delete_connection(&self, id: String) -> Result<(), HostSecretError> {
        self.0.stored.lock().unwrap().retain(|(stored, _), _| *stored != id);
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

fn core(dir: &Path, vault: &Arc<Vault>) -> Arc<Core> {
    Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: Some(dir.join("storage").display().to_string()),
        },
        Box::new(Shared(vault.clone())),
    )
    .unwrap()
}

fn dirs(home: &Path) -> ForeignAppDirsArg {
    ForeignAppDirsArg {
        home: home.display().to_string(),
        config: home.join("config").display().to_string(),
        data: home.join("data").display().to_string(),
    }
}

// Where DBeaver keeps its workspace on the platform the test runs on.
fn dbeaver_root(home: &Path) -> PathBuf {
    if cfg!(target_os = "macos") {
        home.join("Library")
    } else if cfg!(windows) {
        home.join("config")
    } else {
        home.join("data")
    }
}

// The importer's Windows fixture: one PostgreSQL connection whose password DBeaver encrypted, and a script bound to it.
fn dbeaver(home: &Path) {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join(
        "../foreign-import/tests/fixtures/dbeaver/windows/AppData/Roaming/DBeaverData/workspace6/General/.dbeaver",
    );
    let project = dbeaver_root(home).join("DBeaverData/workspace6/General");
    let metadata = project.join(".dbeaver");
    fs::create_dir_all(&metadata).unwrap();
    for name in ["data-sources.json", "credentials-config.json"] {
        fs::copy(fixture.join(name), metadata.join(name)).unwrap();
    }
    fs::write(
        metadata.join("project-metadata.json"),
        r#"{"resources":{"Scripts/Report.sql":{"default-datasource":"windows"}}}"#,
    )
    .unwrap();
    fs::create_dir_all(project.join("Scripts")).unwrap();
    fs::write(project.join("Scripts/Report.sql"), "select 42;").unwrap();
}

fn source(sources: &[ForeignSourceInfo], app: ForeignAppTag) -> &ForeignSourceInfo {
    sources.iter().find(|source| source.app == app).unwrap()
}

const EVERYTHING: ForeignImportRequest = ForeignImportRequest {
    include_passwords: true,
    include_saved_queries: true,
};

#[tokio::test]
async fn another_app_s_connection_lands_with_its_password_and_saved_query_once() {
    let dir = tempfile::tempdir().unwrap();
    let vault = Arc::new(Vault::default());
    let core = core(dir.path(), &vault);
    dbeaver(dir.path());

    let sources = core
        .foreign_sources(dirs(dir.path()), ScanDepthTag::Inventory)
        .await
        .unwrap();
    let review = core
        .clone()
        .read_foreign(ForeignAppTag::DBeaver, dirs(dir.path()), None, EVERYTHING, None)
        .await
        .unwrap();
    let rows = review.connections();
    let choices = review.choices();
    let outcome = review.apply(None).await.unwrap();
    let again = review.apply(None).await.err().unwrap();
    let library = core.library().unwrap().snapshot().await.unwrap();
    let saved = &library.connections[0];
    let queries = core
        .history()
        .await
        .unwrap()
        .saved_queries()
        .snapshot(saved.id.clone())
        .await
        .unwrap();

    let dbeaver = source(&sources, ForeignAppTag::DBeaver);
    assert_eq!(dbeaver.availability, SourceAvailabilityTag::Available);
    assert_eq!((dbeaver.connections, dbeaver.saved_queries), (1, 1));
    assert_eq!(dbeaver.password_offer, PasswordOfferTag::DecryptedWhileReading);
    assert!(dbeaver.offers_saved_queries && dbeaver.starts_ticked && dbeaver.preselected);
    let navicat = source(&sources, ForeignAppTag::Navicat);
    assert_eq!(navicat.file_extensions, ["ncx"]);
    assert_eq!(navicat.availability, SourceAvailabilityTag::Available);
    assert!(!navicat.starts_ticked && !navicat.preselected);
    assert_eq!(sources.iter().filter(|source| source.preselected).count(), 1);
    assert_eq!(review.passwords(), PasswordOutcomeTag::Read);
    assert_eq!(rows[0].name, "Windows PG");
    assert_eq!(rows[0].connection.as_ref().unwrap().host, "windows.example.com");
    assert!(rows[0].carries_passwords && rows[0].duplicate.is_none());
    assert!(choices.connections[0].selected && choices.importable);
    assert_eq!(choices.connections[0].resolution, Some(ResolutionTag::Add));
    assert_eq!(choices.queries[0].availability, QueryAvailabilityTag::Available);
    assert!(choices.queries[0].included);
    assert_eq!(
        (outcome.connections, outcome.passwords_not_kept, outcome.queries_added),
        (1, 0, 1)
    );
    assert_eq!(outcome.connection_ids, std::slice::from_ref(&saved.id));
    assert_eq!(again.code(), "foreign_import.applied");
    assert_eq!(library.connections.len(), 1);
    assert_eq!(saved.name, "Windows PG");
    assert_eq!(
        vault
            .stored
            .lock()
            .unwrap()
            .get(&(saved.id.clone(), SecretKindTag::DatabasePassword))
            .map(String::as_str),
        Some("windows-pass")
    );
    assert_eq!(queries.queries[0].name, "Report");
    assert_eq!(queries.queries[0].sql, "select 42;");
}

#[tokio::test]
async fn a_second_read_matches_the_saved_connection_and_keeps_it_for_the_queries() {
    let dir = tempfile::tempdir().unwrap();
    let vault = Arc::new(Vault::default());
    let core = core(dir.path(), &vault);
    dbeaver(dir.path());
    let read = || {
        core.clone()
            .read_foreign(ForeignAppTag::DBeaver, dirs(dir.path()), None, EVERYTHING, None)
    };
    read().await.unwrap().apply(None).await.unwrap();
    let saved_id = core.library().unwrap().snapshot().await.unwrap().connections[0]
        .id
        .clone();

    let review = read().await.unwrap();
    let before = review.choices();
    review.set_selected("General/windows".to_owned(), true);
    let checked = review.choices();
    let outcome = review.apply(None).await.unwrap();
    let count = core.library().unwrap().snapshot().await.unwrap().connections.len();

    assert_eq!(review.connections()[0].duplicate.as_ref().unwrap().id, saved_id);
    assert!(!before.connections[0].selected && !before.importable);
    assert_eq!(
        checked.connections[0].offered,
        [
            ResolutionTag::KeepExisting { id: saved_id.clone() },
            ResolutionTag::AddCopy,
            ResolutionTag::Replace { id: saved_id.clone() },
        ]
    );
    assert_eq!(
        checked.connections[0].resolution,
        Some(ResolutionTag::KeepExisting { id: saved_id })
    );
    assert_eq!((outcome.connections, outcome.queries_already_saved), (0, 1));
    assert!(outcome.connection_ids.is_empty());
    assert_eq!(count, 1);
}

#[tokio::test]
async fn another_app_s_connection_lands_in_the_project_the_import_names() {
    let dir = tempfile::tempdir().unwrap();
    let vault = Arc::new(Vault::default());
    let core = core(dir.path(), &vault);
    dbeaver(dir.path());
    let library = core.library().unwrap();
    let acme = library.create_project("Acme".to_owned(), None).await.unwrap();
    let review = core
        .clone()
        .read_foreign(ForeignAppTag::DBeaver, dirs(dir.path()), None, EVERYTHING, None)
        .await
        .unwrap();

    let malformed = review.apply(Some("acme".to_owned())).await.err().unwrap();
    review.apply(Some(acme.id.clone())).await.unwrap();
    let scoped = library.snapshot_in(Some(acme.id.clone())).await.unwrap();

    assert_eq!(malformed.code(), "library.invalid_id");
    assert_eq!(scoped.connections.len(), 1);
    assert_eq!(scoped.connections[0].project_id.as_deref(), Some(acme.id.as_str()));
}

#[tokio::test]
async fn a_replaced_connection_keeps_its_id_in_the_outcome() {
    let dir = tempfile::tempdir().unwrap();
    let vault = Arc::new(Vault::default());
    let core = core(dir.path(), &vault);
    dbeaver(dir.path());
    let read = || {
        core.clone()
            .read_foreign(ForeignAppTag::DBeaver, dirs(dir.path()), None, EVERYTHING, None)
    };
    read().await.unwrap().apply(None).await.unwrap();
    let saved_id = core.library().unwrap().snapshot().await.unwrap().connections[0]
        .id
        .clone();

    let review = read().await.unwrap();
    review.set_selected("General/windows".to_owned(), true);
    let replaced = review
        .resolve(
            "General/windows".to_owned(),
            ResolutionTag::Replace { id: saved_id.clone() },
        )
        .unwrap();
    let outcome = review.apply(None).await.unwrap();

    assert!(replaced);
    assert_eq!((outcome.connections, outcome.replaced), (1, 1));
    assert_eq!(outcome.connection_ids, [saved_id]);
}

#[tokio::test]
async fn the_launch_probe_reads_no_count_and_unreadable_data_says_why() {
    let dir = tempfile::tempdir().unwrap();
    let vault = Arc::new(Vault::default());
    let core = core(dir.path(), &vault);
    dbeaver(dir.path());

    let probe = core
        .foreign_sources(dirs(dir.path()), ScanDepthTag::Presence)
        .await
        .unwrap();
    let data_sources = dbeaver_root(dir.path()).join("DBeaverData/workspace6/General/.dbeaver/data-sources.json");
    fs::write(&data_sources, "{ not json").unwrap();
    let broken = core
        .foreign_sources(dirs(dir.path()), ScanDepthTag::Inventory)
        .await
        .unwrap();

    let found = source(&probe, ForeignAppTag::DBeaver);
    assert_eq!(found.availability, SourceAvailabilityTag::Available);
    assert_eq!((found.connections, found.saved_queries), (0, 0));
    assert!(!found.starts_ticked);
    let unreadable = source(&broken, ForeignAppTag::DBeaver);
    let code = match &unreadable.availability {
        SourceAvailabilityTag::Unreadable { code, .. } => Some(code.as_str()),
        _ => None,
    };
    assert_eq!(code, Some("foreign_import.parse"), "{:?}", unreadable.availability);
    assert!(!unreadable.starts_ticked && !unreadable.preselected);
    assert!(source(&broken, ForeignAppTag::Navicat).preselected);
}

#[tokio::test]
async fn a_library_that_changed_after_the_read_refuses_the_import() {
    let dir = tempfile::tempdir().unwrap();
    let vault = Arc::new(Vault::default());
    let core = core(dir.path(), &vault);
    dbeaver(dir.path());
    let first = core
        .clone()
        .read_foreign(ForeignAppTag::DBeaver, dirs(dir.path()), None, EVERYTHING, None)
        .await
        .unwrap();
    let late = core
        .clone()
        .read_foreign(ForeignAppTag::DBeaver, dirs(dir.path()), None, EVERYTHING, None)
        .await
        .unwrap();
    first.apply(None).await.unwrap();

    let refused = late.apply(None).await.err().unwrap();
    let count = core.library().unwrap().snapshot().await.unwrap().connections.len();

    assert_eq!(refused.code(), "storage.import_outdated");
    assert_eq!(count, 1);
}

#[tokio::test]
async fn an_app_with_nothing_to_read_fails_with_its_code() {
    let dir = tempfile::tempdir().unwrap();
    let vault = Arc::new(Vault::default());
    let core = core(dir.path(), &vault);

    let missing = core
        .clone()
        .read_foreign(ForeignAppTag::DBeaver, dirs(dir.path()), None, EVERYTHING, None)
        .await
        .err()
        .unwrap();
    let unreadable = core
        .clone()
        .read_foreign(
            ForeignAppTag::Navicat,
            dirs(dir.path()),
            Some(dir.path().join("none.ncx").display().to_string()),
            EVERYTHING,
            None,
        )
        .await
        .err()
        .unwrap();

    assert_eq!(missing.code(), "foreign_import.file_not_found");
    assert!(
        unreadable.code().starts_with("foreign_import."),
        "{}",
        unreadable.code()
    );
}

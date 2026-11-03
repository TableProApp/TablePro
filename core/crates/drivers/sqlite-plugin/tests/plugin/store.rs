// Installing the real library into a data folder. Signatures are Windows's to check (the Windows app's interop
// tests install a signed build); here a stand-in accepts every file, so the rest of the path runs everywhere.

use std::fs::File;
use std::path::Path;
use std::sync::Arc;

use tablepro_driver_abi::proto::{self, request, response};
use tablepro_driver_host::registry::{HostTarget, parse_manifest};
use tablepro_driver_host::{DriverState, DriverStore, Expected, INDEX_FILE, PluginError, Purpose, Trust};

use crate::support::*;

struct AcceptAll;

impl Trust for AcceptAll {
    fn verify(&self, _file: &File, _path: &Path, _purpose: Purpose) -> Result<(), PluginError> {
        Ok(())
    }
}

fn store(folder: &Path) -> DriverStore {
    DriverStore::new(folder.join("drivers"), Arc::new(AcceptAll))
}

fn sha256(path: &Path) -> String {
    use sha2::Digest;
    let bytes = std::fs::read(path).unwrap();
    sha2::Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn an_installed_driver_loads_from_the_data_folder_and_answers() {
    let folder = tempfile::tempdir().unwrap();
    let database = people_database(folder.path()).await;
    let store = store(folder.path());

    let installed = tokio::task::block_in_place(|| store.install_file(&plugin_path(), None)).unwrap();

    assert_eq!(installed.id, "sqlite");
    assert_eq!(installed.display_name, "SQLite");
    assert_eq!(installed.version, env!("CARGO_PKG_VERSION"));
    assert!(installed.path.starts_with(store.dir()));
    assert!(matches!(installed.state, DriverState::Loaded { abi_major: 1, .. }));
    let handle = store.handle("sqlite").unwrap();
    let connection = open(&handle, &database).await;
    let reply = call(&handle, read(connection, "SELECT count(*) AS n FROM people", 0)).await;
    assert!(matches!(
        reply.response.kind,
        Some(response::Kind::ReadDone(proto::ReadDone { rows: 1, .. }))
    ));
    let listed = tokio::task::block_in_place(|| store.installed()).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, "sqlite");
}

#[tokio::test(flavor = "multi_thread")]
async fn installing_again_replaces_the_driver_and_removing_takes_it_away() {
    let folder = tempfile::tempdir().unwrap();
    let store = store(folder.path());

    let first = tokio::task::block_in_place(|| store.install_file(&plugin_path(), None)).unwrap();
    let second = tokio::task::block_in_place(|| store.install_file(&plugin_path(), None)).unwrap();

    assert_ne!(first.path, second.path);
    let listed = tokio::task::block_in_place(|| store.installed()).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].path, second.path);

    tokio::task::block_in_place(|| store.remove("sqlite")).unwrap();

    assert!(tokio::task::block_in_place(|| store.installed()).unwrap().is_empty());
    assert!(store.handle("sqlite").is_none());
    assert!(!second.path.exists() || cfg!(windows));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_restart_loads_what_was_installed_and_refuses_a_file_changed_since() {
    let folder = tempfile::tempdir().unwrap();
    tokio::task::block_in_place(|| store(folder.path()).install_file(&plugin_path(), None)).unwrap();

    let restarted = store(folder.path());
    let listed = tokio::task::block_in_place(|| restarted.installed()).unwrap();
    assert!(matches!(listed[0].state, DriverState::Loaded { .. }));
    let handle = restarted.handle("sqlite").unwrap();
    let described = call(&handle, request::Kind::Describe(proto::Describe {})).await;
    assert_eq!(described.status, 0);

    // The index stands in for the file: rewriting a library the process has mapped is not safe on every system.
    let index_path = folder.path().join("drivers").join(INDEX_FILE);
    let index = std::fs::read_to_string(&index_path).unwrap();
    let found = sha256(&plugin_path());
    std::fs::write(&index_path, index.replace(&found, &"0".repeat(64))).unwrap();
    let tampered = store(folder.path());
    let listed = tokio::task::block_in_place(|| tampered.installed()).unwrap();

    let DriverState::Failed(error) = &listed[0].state else {
        panic!("a changed file loaded");
    };
    assert_eq!(error.code(), "plugin.checksum_mismatch");
}

fn manifest(version: &str, sha256: &str) -> String {
    let target = HostTarget::current();
    format!(
        r#"{{"schemaVersion": 1, "plugins": [{{"id": "sqlite", "name": "SQLite", "databaseTypeIds": ["sqlite"],
            "releases": [{{"version": "{version}", "build": 7, "channel": "stable", "abi": 1, "os": "{}",
            "arch": "{}", "url": "https://example.com/sqlite.bin", "sha256": "{sha256}"}}]}}]}}"#,
        target.os, target.arch
    )
}

#[tokio::test(flavor = "multi_thread")]
async fn a_registry_release_installs_once_its_checksum_and_identity_match() {
    let folder = tempfile::tempdir().unwrap();
    let store = store(folder.path());
    let download = plugin_path();

    let right = parse_manifest(&manifest(env!("CARGO_PKG_VERSION"), &sha256(&download))).unwrap();
    let wrong_sum = parse_manifest(&manifest(env!("CARGO_PKG_VERSION"), &"1".repeat(64))).unwrap();
    let wrong_version = parse_manifest(&manifest("9.9.9", &sha256(&download))).unwrap();

    let error = tokio::task::block_in_place(|| store.install_release(&wrong_sum.plugins[0], &download)).unwrap_err();
    assert_eq!(error.code(), "plugin.checksum_mismatch");
    let error =
        tokio::task::block_in_place(|| store.install_release(&wrong_version.plugins[0], &download)).unwrap_err();
    assert_eq!(error.code(), "plugin.wrong_driver");
    let installed = tokio::task::block_in_place(|| store.install_release(&right.plugins[0], &download)).unwrap();
    assert!(matches!(installed.state, DriverState::Loaded { .. }));
}

#[test]
fn an_expected_identity_is_checked_against_the_descriptor() {
    let folder = tempfile::tempdir().unwrap();
    let store = store(folder.path());
    let expected = Expected {
        id: "postgres".to_owned(),
        version: env!("CARGO_PKG_VERSION").to_owned(),
        sha256: sha256(&plugin_path()),
    };

    let error = store.install_file(&plugin_path(), Some(&expected)).unwrap_err();

    assert_eq!(error.code(), "plugin.wrong_driver");
    assert!(store.installed().unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn another_store_replacing_or_removing_a_driver_invalidates_the_loaded_handle() {
    let folder = tempfile::tempdir().unwrap();
    let first = store(folder.path());
    let second = store(folder.path());
    let original = tokio::task::block_in_place(|| first.install_file(&plugin_path(), None)).unwrap();
    let original_handle = first.handle("sqlite").unwrap();

    let replacement = tokio::task::block_in_place(|| second.install_file(&plugin_path(), None)).unwrap();
    let listed = tokio::task::block_in_place(|| first.installed()).unwrap();

    assert_ne!(original.path, replacement.path);
    assert_eq!(listed, [replacement]);
    let replacement_handle = first.handle("sqlite").unwrap();
    assert!(!Arc::ptr_eq(&original_handle, &replacement_handle));
    let described = call(&replacement_handle, request::Kind::Describe(proto::Describe {})).await;
    assert_eq!(described.status, 0);

    tokio::task::block_in_place(|| second.remove("sqlite")).unwrap();

    assert!(tokio::task::block_in_place(|| first.installed()).unwrap().is_empty());
    assert!(first.handle("sqlite").is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn another_store_replacing_a_failed_installation_retries_loading_it() {
    let folder = tempfile::tempdir().unwrap();
    let installer = store(folder.path());
    tokio::task::block_in_place(|| installer.install_file(&plugin_path(), None)).unwrap();
    let index_path = installer.dir().join(INDEX_FILE);
    let index = std::fs::read_to_string(&index_path).unwrap();
    let checksum = sha256(&plugin_path());
    std::fs::write(&index_path, index.replace(&checksum, &"0".repeat(64))).unwrap();
    let reader = store(folder.path());
    let failed = tokio::task::block_in_place(|| reader.installed()).unwrap();
    assert!(matches!(failed[0].state, DriverState::Failed(_)));
    assert!(reader.handle("sqlite").is_none());

    let replacement = tokio::task::block_in_place(|| installer.install_file(&plugin_path(), None)).unwrap();
    let listed = tokio::task::block_in_place(|| reader.installed()).unwrap();

    assert_eq!(listed, [replacement]);
    let handle = reader.handle("sqlite").unwrap();
    let described = call(&handle, request::Kind::Describe(proto::Describe {})).await;
    assert_eq!(described.status, 0);
}

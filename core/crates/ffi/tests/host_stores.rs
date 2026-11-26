#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    Core, DatabaseEnvironmentTag, FavouriteDatabaseKey, FavouriteDatabaseRecord, FavouriteRecordWrite,
    FavouriteTableRecord, HistoryEntryRecord, HistoryOutcomeTag, HostConfig, HostSecretError, HostSecrets,
    SavedQueryFolderRecord, SavedQueryRecord, SavedQueryRecordWrite, SecretItemTag, SecretKindTag, TableFolderRecord,
    TableFolderRecordWrite, TableKeyRecord, TablePlacementRecord, TableRefRecord,
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

const SHOP: &str = "6F0B6A4E-3A52-4C2F-9D1E-0C6A2B7F9E11";
const FOLDER: &str = "1C2D3E4F-5A6B-4C7D-8E9F-A0B1C2D3E4F5";
const QUERY: &str = "9A8B7C6D-5E4F-4A3B-8C2D-1E0F9A8B7C6D";
const RUN: &str = "0D1E2F3A-4B5C-4D6E-9F7A-8B9C0D1E2F3A";

fn started(dir: &Path) -> Arc<Core> {
    Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: Some(dir.display().to_string()),
        },
        Box::new(NoSecrets),
    )
    .unwrap()
}

fn saved_query(name: &str) -> SavedQueryRecord {
    SavedQueryRecord {
        id: QUERY.to_owned(),
        name: name.to_owned(),
        sql: "SELECT 1".to_owned(),
        keyword: Some("one".to_owned()),
        connection_id: Some(SHOP.to_owned()),
        connection_name: "shop".to_owned(),
        folder_id: Some(FOLDER.to_owned()),
        order: 4,
        created_at_ms: 1_700_000_000_123,
        updated_at_ms: 1_700_000_000_456,
    }
}

#[tokio::test]
async fn a_mac_store_moves_in_with_its_ids_times_and_places() {
    let dir = tempfile::tempdir().unwrap();
    let store = started(dir.path()).history().await.unwrap().saved_queries();
    let folder = SavedQueryFolderRecord {
        id: FOLDER.to_owned(),
        name: "Reports".to_owned(),
        connection_id: None,
        parent_id: None,
        order: 1,
        created_at_ms: 1_700_000_000_000,
        updated_at_ms: 1_700_000_000_000,
    };

    let outcome = store
        .replace_records(None, vec![saved_query("Daily")], vec![folder.clone()])
        .await
        .unwrap();

    let contents = store.contents().await.unwrap();
    assert!(outcome.settled_queries.is_empty());
    assert_eq!(outcome.digest, contents.digest);
    let held = &contents.queries[0];
    assert_eq!(held.id.to_uppercase(), QUERY);
    assert_eq!(
        held.folder_id.as_deref().map(str::to_uppercase).as_deref(),
        Some(FOLDER)
    );
    assert_eq!(
        (held.order, held.created_at_ms, held.updated_at_ms),
        (4, 1_700_000_000_123, 1_700_000_000_456)
    );
    assert_eq!(contents.folders[0].name, folder.name);
}

#[tokio::test]
async fn a_write_based_on_an_older_read_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let store = started(dir.path()).history().await.unwrap().saved_queries();
    let read = store.contents().await.unwrap();
    store
        .write_records(SavedQueryRecordWrite {
            queries: vec![saved_query("Daily")],
            folders: Vec::new(),
            removed_queries: Vec::new(),
            removed_folders: Vec::new(),
        })
        .await
        .unwrap();

    let refused = store
        .replace_records(Some(read.digest), Vec::new(), Vec::new())
        .await
        .unwrap_err();

    assert_eq!(refused.code(), "storage.import_outdated");
    assert_eq!(store.contents().await.unwrap().queries.len(), 1);
}

#[tokio::test]
async fn favourites_and_table_folders_of_every_connection_read_and_write_whole() {
    let dir = tempfile::tempdir().unwrap();
    let history = started(dir.path()).history().await.unwrap();
    let favourites = history.favourites();
    let table = FavouriteTableRecord {
        connection_id: SHOP.to_owned(),
        database: Some("shop".to_owned()),
        schema: None,
        name: "orders".to_owned(),
    };
    favourites
        .write_records(FavouriteRecordWrite {
            tables: vec![table.clone()],
            databases: vec![FavouriteDatabaseRecord {
                connection_id: SHOP.to_owned(),
                database: "shop".to_owned(),
                environment: DatabaseEnvironmentTag::Production,
            }],
            removed_tables: Vec::new(),
            removed_databases: Vec::new(),
        })
        .await
        .unwrap();
    favourites
        .write_records(FavouriteRecordWrite {
            tables: Vec::new(),
            databases: Vec::new(),
            removed_tables: Vec::new(),
            removed_databases: vec![FavouriteDatabaseKey {
                connection_id: SHOP.to_owned(),
                database: "shop".to_owned(),
            }],
        })
        .await
        .unwrap();
    let marked = favourites.contents().await.unwrap();
    assert_eq!(marked.tables.len(), 1);
    assert_eq!(marked.tables[0].name, table.name);
    assert!(marked.databases.is_empty());
    let stale = favourites
        .replace_databases(Some(marked.digests.tables.clone()), Vec::new())
        .await
        .unwrap_err();
    assert_eq!(stale.code(), "storage.import_outdated");
    let cleared = favourites
        .replace_tables(Some(marked.digests.tables), Vec::new())
        .await
        .unwrap();
    assert_eq!(cleared.databases, marked.digests.databases);
    assert!(favourites.contents().await.unwrap().tables.is_empty());

    let folders = history.table_folders();
    let reference = TableRefRecord {
        database: "shop".to_owned(),
        schema: String::new(),
        name: "orders".to_owned(),
    };
    folders
        .write_records(TableFolderRecordWrite {
            folders: vec![TableFolderRecord {
                id: FOLDER.to_owned(),
                connection_id: SHOP.to_owned(),
                database: "shop".to_owned(),
                schema: String::new(),
                name: "Billing".to_owned(),
                created_at_ms: 1_700_000_000_000,
                updated_at_ms: 1_700_000_000_001,
            }],
            items: vec![TablePlacementRecord {
                connection_id: SHOP.to_owned(),
                table: reference.clone(),
                folder_id: FOLDER.to_owned(),
            }],
            removed_folders: Vec::new(),
            removed_items: Vec::new(),
        })
        .await
        .unwrap();
    let filed = folders.contents().await.unwrap();
    assert_eq!(filed.folders[0].updated_at_ms, 1_700_000_000_001);
    assert_eq!(filed.items[0].table, reference);
    folders
        .write_records(TableFolderRecordWrite {
            folders: Vec::new(),
            items: Vec::new(),
            removed_folders: vec![FOLDER.to_owned()],
            removed_items: vec![TableKeyRecord {
                connection_id: SHOP.to_owned(),
                table: reference,
            }],
        })
        .await
        .unwrap();
    let emptied = folders.contents().await.unwrap();
    assert!(emptied.folders.is_empty() && emptied.items.is_empty());
}

#[tokio::test]
async fn history_entries_move_in_under_their_record_ids() {
    let dir = tempfile::tempdir().unwrap();
    let history = started(dir.path()).history().await.unwrap();
    let run = HistoryEntryRecord {
        record_id: RUN.to_owned(),
        sql: "SELECT 1".to_owned(),
        driver_id: "MySQL".to_owned(),
        connection_id: SHOP.to_owned(),
        connection_name: "shop".to_owned(),
        executed_at_ms: 1_700_000_000_000,
        duration_ms: Some(5),
        rows_affected: Some(1),
        outcome: HistoryOutcomeTag::Succeeded,
    };

    let added = history.put_entries(vec![run.clone(), run.clone()]).await.unwrap();

    assert_eq!(added, 1);
    let ids = history.record_ids().await.unwrap();
    assert_eq!(ids.iter().map(|id| id.to_uppercase()).collect::<Vec<_>>(), [RUN]);
    assert_eq!(history.remove_entries(ids).await.unwrap(), 1);
    assert!(history.record_ids().await.unwrap().is_empty());

    let other = HistoryEntryRecord {
        record_id: QUERY.to_owned(),
        connection_id: FOLDER.to_owned(),
        ..run.clone()
    };
    history.put_entries(vec![run, other]).await.unwrap();
    assert_eq!(history.delete_for_connection(SHOP.to_owned()).await.unwrap(), 1);
    assert_eq!(history.record_ids().await.unwrap().len(), 1);
}

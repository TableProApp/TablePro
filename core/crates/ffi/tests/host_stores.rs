#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    Core, DatabaseEnvironmentTag, FavouriteDatabaseKey, FavouriteDatabaseRecord, FavouriteRecordWrite,
    FavouriteTableRecord, HistoryDetailsRecord, HistoryEntryRecord, HistoryFilterArg, HistoryFingerprintArg,
    HistoryIdentityInfo, HistoryOutcomeTag, HistoryRunDetails, HistorySourceTag, HistoryStatusTag, HostConfig,
    HostSecretError, HostSecrets, ProfileKindTag, SavedQueryFolderRecord, SavedQueryRecord, SavedQueryRecordWrite,
    SecretDeletionTag, SecretItemTag, SecretKindTag, StatementTypeTag, TableFolderRecord, TableFolderRecordWrite,
    TableKeyRecord, TablePlacementRecord, TableRefRecord,
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
    let store = started(dir.path())
        .saved_query_database()
        .await
        .unwrap()
        .saved_queries();
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
    let store = started(dir.path())
        .saved_query_database()
        .await
        .unwrap()
        .saved_queries();
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
    let history = started(dir.path()).saved_query_database().await.unwrap();
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
        duration_us: Some(5),
        rows_affected: Some(1),
        outcome: HistoryOutcomeTag::Succeeded,
        details: Default::default(),
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

fn moved_in(record_id: &str, executed_at_ms: i64, source: HistorySourceTag) -> HistoryEntryRecord {
    HistoryEntryRecord {
        record_id: record_id.to_owned(),
        sql: "SELECT 1".to_owned(),
        driver_id: "MySQL".to_owned(),
        connection_id: SHOP.to_owned(),
        connection_name: "shop".to_owned(),
        executed_at_ms,
        duration_us: Some(5),
        rows_affected: Some(1),
        outcome: HistoryOutcomeTag::Succeeded,
        details: HistoryRunDetails {
            database: Some("shop".to_owned()),
            schema: None,
            source: Some(source),
            statement_type: Some(StatementTypeTag::Select),
            first_row_us: Some(2),
            server_us: Some(1),
            fingerprint: None,
        },
    }
}

fn everything() -> HistoryFilterArg {
    HistoryFilterArg {
        text: String::new(),
        connection_ids: None,
        project_id: None,
        sources: None,
        status: HistoryStatusTag::Any,
        executed_after_ms: None,
        executed_before_ms: None,
    }
}

// A deletion the person made stays a deletion: the entry cannot come back under its id until sync has pushed it. One
// the app's own store let go leaves no such mark.
#[tokio::test]
async fn the_person_s_deletion_keeps_the_entry_out_and_a_host_removal_does_not() {
    let dir = tempfile::tempdir().unwrap();
    let history = started(dir.path()).history().await.unwrap();
    let (deleted, removed) = (
        moved_in(RUN, 1_700_000_000_000, HistorySourceTag::Editor),
        moved_in(QUERY, 1_700_000_001_000, HistorySourceTag::Editor),
    );
    history
        .put_entries(vec![deleted.clone(), removed.clone()])
        .await
        .unwrap();

    assert_eq!(history.delete_entries(vec![RUN.to_owned()]).await.unwrap(), 1);
    assert_eq!(history.remove_entries(vec![QUERY.to_owned()]).await.unwrap(), 1);

    assert_eq!(history.put_entries(vec![deleted, removed]).await.unwrap(), 1);
    assert_eq!(
        history
            .record_ids()
            .await
            .unwrap()
            .iter()
            .map(|id| id.to_uppercase())
            .collect::<Vec<_>>(),
        [QUERY]
    );
}

#[tokio::test]
async fn the_history_pane_reads_and_clears_by_its_filters_and_every_detail_comes_back() {
    let dir = tempfile::tempdir().unwrap();
    let history = started(dir.path()).history().await.unwrap();
    let editor = moved_in(RUN, 1_700_000_000_000, HistorySourceTag::Editor);
    let browse = moved_in(QUERY, 1_700_000_060_000, HistorySourceTag::TableBrowse);
    history.put_entries(vec![editor.clone(), browse]).await.unwrap();

    let browsing = HistoryFilterArg {
        sources: Some(vec![HistorySourceTag::TableBrowse]),
        executed_after_ms: Some(1_700_000_030_000),
        ..everything()
    };
    let found = history.search(browsing.clone(), None, 50).await.unwrap();
    assert_eq!(found.entries.len(), 1);
    assert_eq!(found.entries[0].record_id.to_uppercase(), QUERY);
    let all = history.search(everything(), None, 50).await.unwrap();
    let first = all
        .entries
        .iter()
        .find(|entry| entry.record_id.to_uppercase() == RUN)
        .unwrap();
    assert_eq!(first.details, editor.details);

    let gone = history.delete_matching(browsing).await.unwrap();
    assert_eq!(gone.iter().map(|id| id.to_uppercase()).collect::<Vec<_>>(), [QUERY]);
    assert_eq!(history.search(everything(), None, 50).await.unwrap().entries.len(), 1);
}

const LATER: &str = "5E6F7A8B-9C0D-4E1F-8A2B-3C4D5E6F7A8B";

// Runs a host mirrored before it kept details get them by record id, and only where they had none: a source filled
// in brings the run under the pane's source filter. A deleted run is not brought back.
#[tokio::test]
async fn details_fill_in_on_runs_mirrored_without_them() {
    let dir = tempfile::tempdir().unwrap();
    let history = started(dir.path()).history().await.unwrap();
    let mut bare = moved_in(RUN, 1_700_000_000_000, HistorySourceTag::Editor);
    bare.details = HistoryRunDetails::default();
    let kept = moved_in(QUERY, 1_700_000_060_000, HistorySourceTag::TableBrowse);
    let mut deleted = moved_in(LATER, 1_700_000_120_000, HistorySourceTag::Editor);
    deleted.details = HistoryRunDetails::default();
    history.put_entries(vec![bare, kept.clone(), deleted]).await.unwrap();
    history.delete_entries(vec![LATER.to_owned()]).await.unwrap();
    let editor_runs = HistoryFilterArg {
        sources: Some(vec![HistorySourceTag::Editor]),
        ..everything()
    };
    assert!(
        history
            .search(editor_runs.clone(), None, 50)
            .await
            .unwrap()
            .entries
            .is_empty()
    );
    let learned = HistoryRunDetails {
        database: Some("shop".to_owned()),
        schema: Some("public".to_owned()),
        source: Some(HistorySourceTag::Editor),
        statement_type: Some(StatementTypeTag::Select),
        first_row_us: Some(3),
        server_us: Some(2),
        fingerprint: Some(7),
    };

    let changed = history
        .fill_details(
            [RUN, QUERY, LATER]
                .iter()
                .map(|id| HistoryDetailsRecord {
                    record_id: (*id).to_owned(),
                    details: learned.clone(),
                })
                .collect(),
        )
        .await
        .unwrap();

    assert_eq!(changed, 2);
    let found = history.search(editor_runs, None, 50).await.unwrap().entries;
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].record_id.to_uppercase(), RUN);
    assert_eq!(found[0].details, learned);
    let read = history.entries(vec![QUERY.to_owned()]).await.unwrap();
    assert_eq!(
        read[0].details,
        HistoryRunDetails {
            schema: Some("public".to_owned()),
            fingerprint: Some(7),
            ..kept.details
        }
    );
    assert_eq!(history.record_ids().await.unwrap().len(), 2);
}

// Runs by record id: ids the store does not hold, a deleted one among them, are left out.
#[tokio::test]
async fn runs_read_by_record_id_leave_out_what_the_store_does_not_hold() {
    let dir = tempfile::tempdir().unwrap();
    let history = started(dir.path()).history().await.unwrap();
    history
        .put_entries(vec![
            moved_in(RUN, 1_700_000_000_000, HistorySourceTag::Editor),
            moved_in(QUERY, 1_700_000_060_000, HistorySourceTag::Editor),
        ])
        .await
        .unwrap();
    history.delete_entries(vec![QUERY.to_owned()]).await.unwrap();

    let read = history
        .entries(vec![QUERY.to_owned(), RUN.to_owned(), LATER.to_owned()])
        .await
        .unwrap();

    assert_eq!(
        read.iter()
            .map(|entry| entry.record_id.to_uppercase())
            .collect::<Vec<_>>(),
        [RUN]
    );
    assert_eq!(read[0].sql, "SELECT 1");
    assert!(history.entries(vec!["not an id".to_owned()]).await.is_err());
}

#[tokio::test]
async fn a_run_with_no_fingerprint_gets_the_one_the_app_reads() {
    let dir = tempfile::tempdir().unwrap();
    let history = started(dir.path()).history().await.unwrap();
    history
        .put_entries(vec![moved_in(RUN, 1_700_000_000_000, HistorySourceTag::Editor)])
        .await
        .unwrap();

    let missing = history.entries_without_fingerprint(10).await.unwrap();
    history
        .set_fingerprints(vec![HistoryFingerprintArg {
            id: missing[0].id,
            fingerprint: 42,
        }])
        .await
        .unwrap();

    assert!(history.entries_without_fingerprint(10).await.unwrap().is_empty());
    let entries = history.search(everything(), None, 50).await.unwrap().entries;
    assert_eq!(entries[0].details.fingerprint, Some(42));
}

#[tokio::test]
async fn each_store_names_its_file_and_the_saved_queries_open_without_the_history() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());

    let files = core.store_files().unwrap();
    core.saved_query_database().await.unwrap();

    assert!(Path::new(&files.saved_query_database).is_file());
    assert!(
        !Path::new(&files.history_database).exists(),
        "the saved queries opened the history"
    );
    core.history().await.unwrap();
    assert!(Path::new(&files.history_database).is_file());
    assert_ne!(files.history_database, files.saved_query_database);
}

// The status the macOS pane filters by: Failed holds a cancelled run too, as the pane always read it.
#[tokio::test]
async fn the_pane_s_failed_holds_failed_and_cancelled_runs() {
    let dir = tempfile::tempdir().unwrap();
    let history = started(dir.path()).history().await.unwrap();
    let runs = [
        (RUN, HistoryOutcomeTag::Succeeded),
        (
            QUERY,
            HistoryOutcomeTag::Failed {
                message: "boom".to_owned(),
            },
        ),
        (FOLDER, HistoryOutcomeTag::Cancelled),
    ];
    history
        .put_entries(
            runs.iter()
                .map(|(id, outcome)| HistoryEntryRecord {
                    outcome: outcome.clone(),
                    ..moved_in(id, 1_700_000_000_000, HistorySourceTag::Editor)
                })
                .collect(),
        )
        .await
        .unwrap();

    let failed = HistoryFilterArg {
        status: HistoryStatusTag::Failed,
        ..everything()
    };
    let succeeded = HistoryFilterArg {
        status: HistoryStatusTag::Succeeded,
        ..everything()
    };
    let ids = |page: tablepro_ffi::HistoryPageInfo| {
        let mut ids: Vec<String> = page
            .entries
            .into_iter()
            .map(|entry| entry.record_id.to_uppercase())
            .collect();
        ids.sort();
        ids
    };
    let mut expected = vec![QUERY.to_owned(), FOLDER.to_owned()];
    expected.sort();
    assert_eq!(ids(history.search(failed, None, 50).await.unwrap()), expected);
    assert_eq!(ids(history.search(succeeded, None, 50).await.unwrap()), [RUN]);
}

// iOS makes the history's folder itself, with the class every file in it then gets, before the core opens anything.
#[tokio::test]
async fn store_files_make_nothing_and_the_history_keeps_to_a_folder_made_first() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());

    let files = core.store_files().unwrap();
    assert!(
        !Path::new(&files.history_folder).exists(),
        "naming the files made the folder"
    );
    std::fs::create_dir_all(&files.history_folder).unwrap();
    std::fs::write(Path::new(&files.history_folder).join("marker"), b"made by the host").unwrap();
    core.history().await.unwrap();

    assert_eq!(
        Path::new(&files.history_database).parent(),
        Some(Path::new(&files.history_folder))
    );
    assert!(Path::new(&files.history_database).is_file());
    assert!(
        Path::new(&files.history_folder).join("marker").is_file(),
        "the core made the folder again"
    );
}

async fn identity_of(dir: &Path) -> HistoryIdentityInfo {
    started(dir).history().await.unwrap().identity().await.unwrap()
}

// The history's files as they stand under another storage folder, as a backup or another device's copy brings them
// back. Nothing writes meanwhile, so the database and its WAL agree.
fn copied(from: &Arc<Core>, to: &Path) {
    let database = std::path::PathBuf::from(from.store_files().unwrap().history_database);
    let target = std::path::PathBuf::from(started(to).store_files().unwrap().history_database);
    std::fs::create_dir_all(target.parent().unwrap()).unwrap();
    for suffix in ["", "-wal"] {
        let source = format!("{}{suffix}", database.display());
        if Path::new(&source).exists() {
            std::fs::copy(&source, format!("{}{suffix}", target.display())).unwrap();
        }
    }
}

// The Mac keeps the history's identity with what it agreed with the core: the same file keeps its generation across
// opens, and each write raises the sequence.
#[tokio::test]
async fn the_history_s_identity_holds_across_opens_and_rises_with_writes() {
    let dir = tempfile::tempdir().unwrap();
    let first = identity_of(dir.path()).await;

    assert_eq!(identity_of(dir.path()).await, first);
    let history = started(dir.path()).history().await.unwrap();
    history
        .put_entries(vec![moved_in(RUN, 1_700_000_000_000, HistorySourceTag::Editor)])
        .await
        .unwrap();
    let written = history.identity().await.unwrap();

    assert_eq!(written.generation, first.generation);
    assert!(written.sequence > first.sequence, "{written:?} after {first:?}");
    assert!(uuid::Uuid::parse_str(&written.generation).is_ok());
}

// Another file in the history's place reads as another generation, and an older copy of the same file as a lower
// sequence: either way the runs it lacks are not deletions.
#[tokio::test]
async fn a_replaced_history_reads_as_another_generation_and_a_rolled_back_one_as_a_lower_sequence() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let history = core.history().await.unwrap();
    history
        .put_entries(vec![moved_in(RUN, 1_700_000_000_000, HistorySourceTag::Editor)])
        .await
        .unwrap();
    let kept = history.identity().await.unwrap();
    let rolled_back_dir = tempfile::tempdir().unwrap();
    copied(&core, rolled_back_dir.path());
    history
        .put_entries(vec![moved_in(QUERY, 1_700_000_060_000, HistorySourceTag::Editor)])
        .await
        .unwrap();
    let later = history.identity().await.unwrap();

    let rolled_back = identity_of(rolled_back_dir.path()).await;
    assert_eq!(rolled_back.generation, later.generation);
    assert_eq!(rolled_back.sequence, kept.sequence);
    assert!(rolled_back.sequence < later.sequence);

    let elsewhere = tempfile::tempdir().unwrap();
    let other_core = started(elsewhere.path());
    let theirs = other_core.history().await.unwrap().identity().await.unwrap();
    let replaced_dir = tempfile::tempdir().unwrap();
    copied(&other_core, replaced_dir.path());

    let replaced = identity_of(replaced_dir.path()).await;
    assert_eq!(replaced, theirs);
    assert_ne!(replaced.generation, later.generation);
}

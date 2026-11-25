use std::sync::Arc;
use std::time::SystemTime;

use super::*;
use crate::favourites::{DatabaseEnvironment, FavouriteTable};
use crate::journal::recording::Recording;
use crate::saved_queries::NewSavedQuery;
use crate::store_identity::StoreContinuity;
use crate::table_folders::{TableRef, TableScope};

async fn open(root: &tempfile::TempDir) -> QueryHistory {
    QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
        .await
        .expect("open")
}

fn run(query: &str, connection: Uuid) -> NewEntry {
    NewEntry {
        query: query.to_owned(),
        driver_id: "postgres".to_owned(),
        connection_id: connection,
        connection_name: "prod".to_owned(),
        executed_at: SystemTime::now(),
        duration_ms: Some(1),
        rows_affected: None,
        outcome: Outcome::Success,
    }
}

fn saved(name: &str, connection: Uuid) -> NewSavedQuery {
    NewSavedQuery {
        name: name.to_owned(),
        query: "SELECT 1".to_owned(),
        connection_id: connection,
        connection_name: "prod".to_owned(),
    }
}

const SYNCED_TABLES: [&str; 7] = [
    "history",
    "saved_queries",
    "saved_query_folders",
    "favourite_tables",
    "favourite_databases",
    "table_folders",
    "table_folder_items",
];

#[tokio::test]
async fn a_database_is_stamped_once_and_keeps_its_generation() {
    let root = tempfile::tempdir().expect("tempdir");
    let first = open(&root).await.identity().await.expect("identity");
    let again = open(&root).await.identity().await.expect("identity");

    assert_eq!(again, first);
}

// A migration that rebuilds one of these tables drops its triggers with it, and the sequence would
// stop moving for that table without a failing write.
#[tokio::test]
async fn every_synced_table_raises_the_sequence_on_insert_update_and_delete() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = open(&root).await;

    for table in SYNCED_TABLES {
        for event in ["ai", "au", "ad"] {
            let name = format!("{table}_store_sequence_{event}");
            let found: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = ? AND tbl_name = ?",
            )
            .bind(&name)
            .bind(table)
            .fetch_one(&history.pool)
            .await
            .expect("count");
            assert_eq!(found, 1, "{name}");
        }
    }
}

#[tokio::test]
async fn each_store_write_raises_the_sequence() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = open(&root).await;
    let connection = Uuid::new_v4();
    let mut seen = history.identity().await.expect("identity");
    let mut raised = |now: StoreIdentity, what: &str| {
        assert_eq!(now.generation, seen.generation, "{what}");
        assert!(now.sequence > seen.sequence, "{what}");
        seen = now;
    };

    let entry = history.record(run("SELECT 1", connection)).await.expect("record");
    raised(history.identity().await.expect("identity"), "record");
    history.set_pinned(entry, true).await.expect("pin");
    raised(history.identity().await.expect("identity"), "pin");
    let queries = history.saved_queries();
    let query = queries.save(saved("a", connection)).await.expect("save");
    raised(history.identity().await.expect("identity"), "save");
    queries.rename(query.id, "b").await.expect("rename");
    raised(history.identity().await.expect("identity"), "rename");
    history
        .saved_query_folders()
        .create(connection, "Reports", None)
        .await
        .expect("folder");
    raised(history.identity().await.expect("identity"), "folder");
    history
        .favourites()
        .set_database(connection, "shop", DatabaseEnvironment::Production)
        .await
        .expect("favourite database");
    raised(history.identity().await.expect("identity"), "favourite database");
    let folder = history
        .table_folders()
        .create(
            TableScope {
                connection_id: connection,
                database: String::new(),
                schema: String::new(),
            },
            "Sales",
        )
        .await
        .expect("table folder");
    raised(history.identity().await.expect("identity"), "table folder");
    history.table_folders().delete(folder.id).await.expect("delete folder");
    raised(history.identity().await.expect("identity"), "delete folder");
    history.delete_returning(&[entry]).await.expect("delete");
    raised(history.identity().await.expect("identity"), "delete entry");
}

#[tokio::test]
async fn a_new_generation_marks_a_restore_and_an_older_copy_reads_as_older() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = open(&root).await;
    let connection = Uuid::new_v4();
    history.record(run("SELECT 1", connection)).await.expect("record");
    let earlier = history.identity().await.expect("identity");
    history.record(run("SELECT 2", connection)).await.expect("record");
    let seen = history.identity().await.expect("identity");

    let renewed = history.start_new_generation().await.expect("renewed");

    assert_eq!(earlier.compared_with(seen), StoreContinuity::WentBack);
    assert_eq!(renewed.compared_with(seen), StoreContinuity::NewGeneration);
}

async fn journaled(root: &tempfile::TempDir) -> (QueryHistory, Arc<Recording>) {
    let history = open(root).await;
    let journal = Arc::new(Recording::default());
    history.set_journal(Some(journal.clone()));
    (history, journal)
}

#[tokio::test]
async fn every_history_write_tells_the_journal() {
    let root = tempfile::tempdir().expect("tempdir");
    let (history, journal) = journaled(&root).await;
    let connection = Uuid::new_v4();

    let entry = history.record(run("SELECT 1", connection)).await.expect("record");
    history.set_pinned(entry, true).await.expect("pin");
    let deleted = history.delete_returning(&[entry]).await.expect("delete");
    history.restore(&deleted).await.expect("restore");
    history
        .delete_for_connection(connection)
        .await
        .expect("connection gone");
    history.record(run("SELECT 2", connection)).await.expect("record");
    history.clear_all().await.expect("clear");
    history.prune(1).await.expect("nothing to prune");

    assert_eq!(journal.take(), vec![vec![RecordKind::HistoryEntry]; 7]);
}

#[tokio::test]
async fn every_saved_query_and_folder_write_tells_the_journal_its_kinds() {
    let root = tempfile::tempdir().expect("tempdir");
    let (history, journal) = journaled(&root).await;
    let connection = Uuid::new_v4();
    let queries = history.saved_queries();
    let folders = history.saved_query_folders();
    let query_kind = || vec![RecordKind::SavedQuery];
    let both = || vec![RecordKind::SavedQuery, RecordKind::SavedQueryFolder];

    let query = queries.save(saved("a", connection)).await.expect("save");
    queries.save_if_new(saved("b", connection)).await.expect("save if new");
    queries.rename(query.id, "c").await.expect("rename");
    queries.set_query(query.id, "SELECT 2").await.expect("set query");
    queries.set_keyword(query.id, Some("rev")).await.expect("keyword");
    let folder = folders.create(connection, "Reports", None).await.expect("folder");
    folders.rename(folder, "Monthly").await.expect("rename folder");
    queries
        .move_to_folder(query.id, Some(folder), None)
        .await
        .expect("file");
    folders.delete(folder).await.expect("delete folder");
    queries.delete(query.id).await.expect("delete");
    queries
        .delete_for_connection(connection)
        .await
        .expect("connection gone");

    assert_eq!(
        journal.take(),
        vec![
            query_kind(),
            query_kind(),
            query_kind(),
            query_kind(),
            query_kind(),
            vec![RecordKind::SavedQueryFolder],
            vec![RecordKind::SavedQueryFolder],
            query_kind(),
            both(),
            query_kind(),
            query_kind(),
        ]
    );
}

#[tokio::test]
async fn deleting_a_connections_data_names_each_kind_it_removed() {
    let root = tempfile::tempdir().expect("tempdir");
    let (history, journal) = journaled(&root).await;
    let connection = Uuid::new_v4();
    let favourites = history.favourites();
    favourites
        .add_table(&FavouriteTable {
            connection_id: connection,
            database: None,
            schema: None,
            name: "orders".to_owned(),
        })
        .await
        .expect("add");
    favourites
        .set_database(connection, "shop", DatabaseEnvironment::Production)
        .await
        .expect("set");
    journal.take();

    history
        .saved_queries()
        .delete_for_connection(connection)
        .await
        .expect("connection gone");

    assert_eq!(
        journal.take(),
        vec![vec![RecordKind::FavouriteTable, RecordKind::FavouriteDatabase]]
    );
}

#[tokio::test]
async fn every_favourite_and_table_folder_write_tells_the_journal_its_kind() {
    let root = tempfile::tempdir().expect("tempdir");
    let (history, journal) = journaled(&root).await;
    let connection = Uuid::new_v4();
    let favourites = history.favourites();
    let table = FavouriteTable {
        connection_id: connection,
        database: None,
        schema: None,
        name: "orders".to_owned(),
    };
    let scope = TableScope {
        connection_id: connection,
        database: String::new(),
        schema: String::new(),
    };
    let orders = TableRef {
        connection_id: connection,
        database: String::new(),
        schema: String::new(),
        name: "orders".to_owned(),
    };

    favourites.add_table(&table).await.expect("add");
    favourites.remove_table(&table).await.expect("remove");
    favourites
        .set_database(connection, "shop", DatabaseEnvironment::Testing)
        .await
        .expect("set");
    favourites.remove_database(connection, "shop").await.expect("remove");
    let folder = history.table_folders().create(scope, "Sales").await.expect("folder");
    history.table_folders().file(&[orders], folder.id).await.expect("file");

    assert_eq!(
        journal.take(),
        vec![
            vec![RecordKind::FavouriteTable],
            vec![RecordKind::FavouriteTable],
            vec![RecordKind::FavouriteDatabase],
            vec![RecordKind::FavouriteDatabase],
            vec![RecordKind::TableFolder],
            vec![RecordKind::TableFolderItem],
        ]
    );
}

#[tokio::test]
async fn each_history_db_write_names_the_rows_it_wrote_and_deleted() {
    let root = tempfile::tempdir().expect("tempdir");
    let (history, journal) = journaled(&root).await;
    let connection = Uuid::new_v4();
    let queries = history.saved_queries();
    let folders = history.saved_query_folders();
    let rows = |ids: &[i64]| ids.iter().copied().map(RecordRef::Row).collect::<Vec<_>>();

    let entry = history.record(run("SELECT 1", connection)).await.expect("record");
    let query = queries.save(saved("a", connection)).await.expect("save");
    let folder = folders.create(connection, "Reports", None).await.expect("folder");
    let inner = folders
        .create(connection, "Monthly", Some(folder))
        .await
        .expect("subfolder");
    queries.move_to_folder(query.id, Some(inner), None).await.expect("file");
    journal.take_entries();
    folders.delete(folder).await.expect("delete folder");
    history.delete_returning(&[entry]).await.expect("delete");

    let calls = journal.take_entries();
    assert_eq!(calls.len(), 2);
    assert_eq!(
        calls[0],
        vec![
            JournalEntry::new(RecordKind::SavedQuery).wrote(rows(&[query.id])),
            JournalEntry::new(RecordKind::SavedQueryFolder).deleted(rows(&[folder, inner])),
        ]
    );
    assert_eq!(
        calls[1],
        vec![JournalEntry::new(RecordKind::HistoryEntry).deleted(rows(&[entry]))]
    );
}

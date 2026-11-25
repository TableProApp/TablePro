use std::collections::HashSet;

use super::fixtures::{BETA_3, BETA_5, old_database};
use super::*;
use crate::unix_time::from_unix;

const RECORD_IDS: i64 = 20_261_126_000_000;

async fn beta_rows(pool: &SqlitePool, connection: Uuid) {
    for (id, name, parent) in [(1, "Reports", None), (2, "Monthly", Some(1))] {
        sqlx::query(
            "INSERT INTO saved_query_folders (id, connection_id, name, parent_id, sort_order, created_at, updated_at) \
             VALUES (?, ?, ?, ?, 0, 21, 22)",
        )
        .bind(id)
        .bind(connection.to_string())
        .bind(name)
        .bind(parent)
        .execute(pool)
        .await
        .expect("folder fixture");
    }
    for (id, name, folder, keyword) in [(9, "A", None, Some("daily")), (42, "z", Some(2), None)] {
        sqlx::query(
            "INSERT INTO saved_queries (id, name, query, connection_id, connection_name, keyword, folder_id, \
             created_at, updated_at) VALUES (?, ?, 'SELECT 42', ?, 'Original connection', ?, ?, 11, 12)",
        )
        .bind(id)
        .bind(name)
        .bind(connection.to_string())
        .bind(keyword)
        .bind(folder)
        .execute(pool)
        .await
        .expect("query fixture");
    }
    beta_history(pool, connection).await;
}

async fn beta_history(pool: &SqlitePool, connection: Uuid) {
    for (index, pinned) in [(0, 1), (1, 0), (2, 0)] {
        sqlx::query(
            "INSERT INTO history (query, query_folded, driver_id, connection_id, connection_name, executed_at, \
             success, pinned) VALUES (?, ?, 'postgres', ?, 'Original connection', ?, 1, ?)",
        )
        .bind(format!("SELECT widgets {index}"))
        .bind(format!("select widgets {index}"))
        .bind(connection.to_string())
        .bind(100 + index)
        .bind(pinned)
        .execute(pool)
        .await
        .expect("history fixture");
    }
    // The newest row goes, so the next id shows whether the rebuilt table kept the sequence.
    sqlx::query("DELETE FROM history WHERE executed_at = 102")
        .execute(pool)
        .await
        .expect("delete the newest entry");
}

async fn record_ids(history: &QueryHistory) -> Vec<String> {
    sqlx::query_scalar(
        "SELECT record_id FROM saved_queries UNION ALL SELECT record_id FROM saved_query_folders \
         UNION ALL SELECT record_id FROM history",
    )
    .fetch_all(&history.pool)
    .await
    .expect("record ids")
}

fn assert_random_v4(ids: &[String]) {
    let distinct: HashSet<&String> = ids.iter().collect();
    assert_eq!(distinct.len(), ids.len(), "two rows drew one id");
    for id in ids {
        let parsed = Uuid::parse_str(id).expect("a UUID");
        assert_eq!(parsed.get_version_num(), 4, "{id}");
        assert_eq!(parsed.get_variant(), uuid::Variant::RFC4122, "{id}");
        assert_eq!(*id, parsed.to_string(), "the store keeps lower-case text");
    }
}

#[tokio::test]
async fn a_beta_5_database_gets_random_record_ids_and_keeps_its_filing_times_pins_and_search() {
    let root = tempfile::tempdir().expect("tempdir");
    let (paths, pool) = old_database(&root, BETA_5).await;
    let connection = Uuid::new_v4();
    beta_rows(&pool, connection).await;
    let before: Vec<(i64, i64)> = sqlx::query_as("SELECT id, pinned FROM history ORDER BY id")
        .fetch_all(&pool)
        .await
        .expect("rows before");
    pool.close().await;

    let history = QueryHistory::open(&paths).await.expect("upgrade");

    let ids = record_ids(&history).await;
    assert_eq!(ids.len(), 2 + 2 + 2);
    assert_random_v4(&ids);
    let snapshot = history.saved_queries().snapshot(connection).await.expect("snapshot");
    let folder = |name: &str| {
        snapshot
            .folders
            .iter()
            .find(|folder| folder.name == name)
            .expect("folder")
            .clone()
    };
    let (reports, monthly) = (folder("Reports"), folder("Monthly"));
    assert_eq!((reports.parent_id, monthly.parent_id), (None, Some(reports.id)));
    assert_eq!(monthly.connection_id, Some(connection));
    let query = |name: &str| {
        snapshot
            .queries
            .iter()
            .find(|query| query.name == name)
            .expect("query")
            .clone()
    };
    assert_eq!(query("z").folder_id, Some(monthly.id));
    assert_eq!(
        (query("A").folder_id, query("A").keyword.as_deref()),
        (None, Some("daily"))
    );
    assert_eq!(
        (query("A").created_at, query("A").updated_at),
        (from_unix(11), from_unix(12))
    );
    assert_eq!((reports.created_at, reports.updated_at), (from_unix(21), from_unix(22)));
    let stored: i64 = sqlx::query_scalar("SELECT created_at FROM saved_queries WHERE name = 'A'")
        .fetch_one(&history.pool)
        .await
        .expect("stored time");
    assert_eq!(stored, 11_000, "saved queries keep milliseconds");

    let found = history
        .search_page(&HistoryQuery::from_input("widgets"), HistoryPageRequest::first(MAX_PAGE_SIZE))
        .await
        .expect("search")
        .entries;
    let mut after: Vec<(i64, i64)> = found
        .iter()
        .map(|entry| (entry.id, i64::from(entry.pinned)))
        .collect();
    after.sort();
    assert_eq!(after, before, "rowids or pins moved");
    let next = history
        .record(NewEntry {
            record_id: Uuid::new_v4(),
            query: "SELECT 1".to_owned(),
            driver_id: "postgres".to_owned(),
            connection_id: connection,
            connection_name: "Original connection".to_owned(),
            executed_at: SystemTime::now(),
            duration_ms: None,
            rows_affected: None,
            outcome: Outcome::Success,
        })
        .await
        .expect("record");
    assert_eq!(next, 4, "a deleted entry's id came back");

    let copies = crate::upgrade_copies::copies_blocking(&paths.history_database()).expect("copies");
    assert_eq!(copies.len(), 1, "no copy was kept before the upgrade");
    assert_eq!(copies[0].version, 20_261_109_000_000);
    let mut copy = SqliteConnectOptions::new()
        .filename(&copies[0].path)
        .read_only(true)
        .connect()
        .await
        .expect("open copy");
    let filed: Option<i64> = sqlx::query_scalar("SELECT folder_id FROM saved_queries WHERE id = 42")
        .fetch_one(&mut copy)
        .await
        .expect("the copy keeps the beta's format");
    assert_eq!(filed, Some(2));
    copy.close().await.expect("close copy");
}

#[tokio::test]
async fn a_beta_3_database_upgrades_through_every_migration() {
    let root = tempfile::tempdir().expect("tempdir");
    let (paths, pool) = old_database(&root, BETA_3).await;
    let connection = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO saved_queries (name, query, connection_id, connection_name, created_at, updated_at) \
         VALUES ('daily', 'SELECT 1', ?, 'local', 5, 6)",
    )
    .bind(connection.to_string())
    .execute(&pool)
    .await
    .expect("a saved query");
    beta_history(&pool, connection).await;
    pool.close().await;

    let history = QueryHistory::open(&paths).await.expect("upgrade");

    assert_random_v4(&record_ids(&history).await);
    let saved = history.saved_queries().list(Some(connection)).await.expect("list");
    assert_eq!(saved.len(), 1);
    assert_eq!((saved[0].name.as_str(), saved[0].created_at), ("daily", from_unix(5)));
    let applied: Vec<i64> = sqlx::query_scalar("SELECT version FROM _sqlx_migrations ORDER BY version")
        .fetch_all(&history.pool)
        .await
        .expect("applied");
    assert_eq!(applied.last(), Some(&RECORD_IDS));
    assert_eq!(
        history
            .search_page(&HistoryQuery::from_input("widgets"), HistoryPageRequest::first(10))
            .await
            .expect("search")
            .entries
            .len(),
        2
    );
}

#[tokio::test]
async fn folders_nested_past_the_sqlite_cascade_limit_upgrade_whole() {
    let root = tempfile::tempdir().expect("tempdir");
    let (paths, pool) = old_database(&root, BETA_5).await;
    let connection = Uuid::new_v4();
    let mut parent: Option<i64> = None;
    for _ in 0..1_100 {
        let id = sqlx::query(
            "INSERT INTO saved_query_folders (connection_id, name, parent_id, sort_order, created_at, updated_at) \
             VALUES (?, 'Nested', ?, 0, 1, 1)",
        )
        .bind(connection.to_string())
        .bind(parent)
        .execute(&pool)
        .await
        .expect("insert folder")
        .last_insert_rowid();
        parent = Some(id);
    }
    pool.close().await;

    let history = QueryHistory::open(&paths).await.expect("upgrade");

    let folders = history.saved_query_folders().list(connection).await.expect("list");
    assert_eq!(folders.len(), 1_100);
    let held: HashSet<Uuid> = folders.iter().map(|folder| folder.id).collect();
    assert_eq!(folders.iter().filter(|folder| folder.parent_id.is_none()).count(), 1);
    assert!(
        folders
            .iter()
            .filter_map(|folder| folder.parent_id)
            .all(|parent| held.contains(&parent))
    );
}

// 0052, Deletes: a cascade changes rows behind the change journal.
#[tokio::test]
async fn no_synced_table_has_a_referential_action_or_a_foreign_key() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
        .await
        .expect("open");

    for table in [
        "history",
        "saved_queries",
        "saved_query_folders",
        "favourite_tables",
        "favourite_databases",
    ] {
        let keys: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM pragma_foreign_key_list(?)")
            .bind(table)
            .fetch_one(&history.pool)
            .await
            .expect("foreign keys");
        assert_eq!(keys, 0, "{table}");
    }
    let actions: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE sql LIKE '%ON DELETE%'")
        .fetch_one(&history.pool)
        .await
        .expect("schema");
    assert_eq!(actions, 0);
}

#[tokio::test]
async fn an_entry_brought_again_under_its_id_keeps_the_row_it_has() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
        .await
        .expect("open");
    let record_id = Uuid::new_v4();
    let entry = |query: &str| NewEntry {
        record_id,
        query: query.to_owned(),
        driver_id: "postgres".to_owned(),
        connection_id: Uuid::nil(),
        connection_name: "local".to_owned(),
        executed_at: SystemTime::UNIX_EPOCH,
        duration_ms: None,
        rows_affected: None,
        outcome: Outcome::Success,
    };

    let first = history.record(entry("SELECT 1")).await.expect("record");
    let again = history.record(entry("SELECT 2")).await.expect("record again");

    assert_eq!(first, again);
    let found = history
        .search_page(&HistoryQuery::from_input(""), HistoryPageRequest::first(10))
        .await
        .expect("search")
        .entries;
    assert_eq!(found.len(), 1);
    assert_eq!((found[0].record_id, found[0].query.as_str()), (record_id, "SELECT 1"));
}

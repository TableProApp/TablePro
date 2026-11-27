// Saved queries, folders, favourites and table folders leaving `history.db` for `saved_queries.db`: from a populated
// older file, whichever store opens first, and after a crash at each point of the move.

use std::path::Path;
use std::time::Duration;

use sqlx::migrate::{MigrateError, Migrator};
use sqlx::sqlite::SqliteConnectOptions;
use sqlx::{AssertSqlSafe, ConnectOptions, Connection, SqlitePool};
use tokio::sync::oneshot;
use uuid::Uuid;

use super::fixtures::old_database;
use super::schema;
use super::split::{COMPACTION_OWED, MOVE_OUT, MOVED, MOVED_AWAY, history_before_move, partial_of};
use super::{HistoryPageRequest, HistoryQuery, QueryHistory};
use crate::SavedQueryDatabase;
use crate::paths::StoragePaths;

// The migrations a build before the move left: everything up to the history's tombstones.
const BEFORE_MOVE: usize = 7;
const GENERATION: &str = "5b0d3c1e-2f4a-4b6c-8d9e-0a1b2c3d4e5f";

struct Old {
    paths: StoragePaths,
    // Each moved table's rows as the older file held them.
    rows: Vec<Vec<String>>,
    connection: Uuid,
    entries: Vec<Uuid>,
}

async fn rows(pool: &SqlitePool) -> Vec<Vec<String>> {
    let mut all = Vec::new();
    for (table, columns) in MOVED {
        all.push(
            sqlx::query_scalar(AssertSqlSafe(format!(
                "SELECT json_array({columns}) FROM {table} ORDER BY json_array({columns})"
            )))
            .fetch_all(pool)
            .await
            .expect("rows"),
        );
    }
    all
}

async fn sequences(pool: &SqlitePool) -> Vec<(String, i64)> {
    sqlx::query_as(
        "SELECT name, seq FROM sqlite_sequence WHERE name IN ('saved_queries', 'saved_query_folders') ORDER BY name",
    )
    .fetch_all(pool)
    .await
    .expect("sequences")
}

// A `history.db` a build before the move wrote, with a row in every table and a deleted query, so its counter is past
// every rowid it holds.
async fn old_file(root: &tempfile::TempDir) -> Old {
    let (paths, pool) = old_database(root, BEFORE_MOVE).await;
    let connection = Uuid::new_v4();
    let (reports, monthly) = (Uuid::new_v4().to_string(), Uuid::new_v4().to_string());
    let shelf = Uuid::new_v4().to_string();
    let entries = vec![Uuid::new_v4(), Uuid::new_v4()];
    let statements = [
        format!(
            "INSERT INTO saved_query_folders (id, record_id, connection_id, name, parent_record_id, sort_order, \
             created_at, updated_at) VALUES (4, '{reports}', '{connection}', 'Reports', NULL, 0, 1000, 2000), \
             (7, '{monthly}', '{connection}', 'Monthly', '{reports}', 0, 1001, 2001)"
        ),
        format!(
            "INSERT INTO saved_queries (id, record_id, name, query, connection_id, connection_name, keyword, \
             folder_record_id, sort_order, created_at, updated_at) VALUES \
             (2, '{}', 'daily', 'SELECT 1', '{connection}', 'local', 'dly', '{monthly}', 0, 1500, 2500), \
             (5, '{}', 'everywhere', 'SELECT 2', NULL, 'any', NULL, NULL, 0, 1600, 2600), \
             (9, '{}', 'gone', 'SELECT 3', NULL, 'any', NULL, NULL, 1, 1700, 2700)",
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4()
        ),
        "DELETE FROM saved_queries WHERE id = 9".to_owned(),
        format!(
            "INSERT INTO favourite_tables (connection_id, database, schema, name, created_at) VALUES \
             ('{connection}', 'shop', 'public', 'orders', 10), ('{connection}', '', '', 'flat', 11)"
        ),
        format!(
            "INSERT INTO favourite_databases (connection_id, database, environment, created_at) VALUES \
             ('{connection}', 'shop', 'production', 12)"
        ),
        format!(
            "INSERT INTO table_folders (id, connection_id, database, schema, name, created_at, updated_at) VALUES \
             ('{shelf}', '{connection}', 'shop', 'public', 'Billing', 3000, 4000)"
        ),
        format!(
            "INSERT INTO table_folder_items (connection_id, database, schema, name, folder_id) VALUES \
             ('{connection}', 'shop', 'public', 'orders', '{shelf}')"
        ),
        format!(
            "INSERT INTO history (record_id, query, query_folded, driver_id, connection_id, connection_name, \
             executed_at, success) VALUES ('{}', 'SELECT kept', 'select kept', 'sqlite', '{connection}', 'local', \
             1800000000, 1), ('{}', 'SELECT also', 'select also', 'sqlite', '{connection}', 'local', 1800000001, 1)",
            entries[0], entries[1]
        ),
        format!(
            "INSERT INTO history_tombstones (record_id, connection_id) VALUES ('{}', '{connection}')",
            Uuid::new_v4()
        ),
        format!("INSERT INTO store_identity (id, generation, sequence) VALUES (1, '{GENERATION}', 5)"),
        "UPDATE store_identity SET sequence = 5".to_owned(),
    ];
    for statement in statements {
        sqlx::query(AssertSqlSafe(statement))
            .execute(&pool)
            .await
            .expect("an old row");
    }
    let rows = rows(&pool).await;
    pool.close().await;
    Old {
        paths,
        rows,
        connection,
        entries,
    }
}

async fn tables(path: &Path) -> Vec<String> {
    let mut database = SqliteConnectOptions::new()
        .filename(path)
        .read_only(true)
        .connect()
        .await
        .expect("open");
    let names = sqlx::query_scalar("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .fetch_all(&mut database)
        .await
        .expect("tables");
    database.close().await.expect("close");
    names
}

async fn assert_moved(old: &Old, saved: &SavedQueryDatabase) {
    assert_eq!(
        rows(saved.pool()).await,
        old.rows,
        "a moved row changed or went missing"
    );
    // Past every rowid the file ever gave, not only the ones it holds now.
    let counters = sequences(saved.pool()).await;
    assert!(
        matches!(
            counters.as_slice(),
            [(queries, at_queries), (folders, at_folders)]
                if queries == "saved_queries" && *at_queries >= 9 && folders == "saved_query_folders" && *at_folders >= 7
        ),
        "a deleted rowid can come back: {counters:?}"
    );
    let contents = saved.saved_queries().contents().await.expect("contents");
    assert_eq!(contents.queries.len(), 2);
    assert_eq!(contents.folders.len(), 2);
    let listed = saved.saved_queries().list(Some(old.connection)).await.expect("list");
    assert!(listed.iter().any(|query| query.keyword.as_deref() == Some("dly")));
    assert_eq!(saved.favourites().contents().await.expect("favourites").tables.len(), 2);
    assert_eq!(
        saved
            .table_folders()
            .contents()
            .await
            .expect("table folders")
            .items
            .len(),
        1
    );
    let history_tables = tables(&old.paths.history_database()).await;
    for (table, _) in MOVED {
        assert!(
            !history_tables.iter().any(|name| name == table),
            "{table} stayed in history.db"
        );
    }
}

async fn assert_history_kept(old: &Old, history: &QueryHistory) {
    let page = history
        .search_page(&HistoryQuery::default(), HistoryPageRequest::first(10))
        .await
        .expect("history");
    let mut ids: Vec<Uuid> = page.entries.iter().map(|entry| entry.record_id).collect();
    ids.sort();
    let mut expected = old.entries.clone();
    expected.sort();
    assert_eq!(ids, expected);
    assert_eq!(history.tombstones().await.expect("tombstones").len(), 1);
}

#[tokio::test]
async fn an_older_history_db_moves_every_saved_row_out_and_keeps_its_history() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;

    let history = QueryHistory::open(&old.paths).await.expect("history");
    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");

    assert_moved(&old, &saved).await;
    assert_history_kept(&old, &history).await;
    let identity = history.identity().await.expect("identity");
    assert_eq!(
        (identity.generation.to_string(), identity.sequence),
        (GENERATION.to_owned(), 5),
        "the move read as a write to the history"
    );
    assert_ne!(
        saved.identity().await.expect("identity").generation,
        identity.generation
    );
}

#[tokio::test]
async fn the_saved_queries_opening_first_move_out_of_history_db() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;

    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");
    let history = QueryHistory::open(&old.paths).await.expect("history");

    assert_moved(&old, &saved).await;
    assert_history_kept(&old, &history).await;
}

#[tokio::test]
async fn the_copy_kept_before_the_move_holds_the_saved_queries() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;

    QueryHistory::open(&old.paths).await.expect("history");

    let copies = crate::upgrade_copies::copies_blocking(&old.paths.history_database()).expect("copies");
    assert_eq!(copies.len(), 1);
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .connect_with(SqliteConnectOptions::new().filename(&copies[0].path).read_only(true))
        .await
        .expect("the copy");
    assert_eq!(rows(&pool).await, old.rows);
}

#[tokio::test]
async fn both_stores_opening_at_once_move_the_rows_once() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;

    let (history, saved) = tokio::join!(QueryHistory::open(&old.paths), SavedQueryDatabase::open(&old.paths));

    assert_moved(&old, &saved.expect("saved queries")).await;
    assert_history_kept(&old, &history.expect("history")).await;
}

#[tokio::test]
async fn a_build_cut_short_before_the_drop_is_made_again_from_history_db() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let partial = partial_of(&old.paths.saved_query_database());
    std::fs::write(&partial, b"what a crash left halfway").expect("a half-made build");

    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");

    assert_moved(&old, &saved).await;
    assert!(!partial.exists(), "the build stayed beside the store");
}

#[tokio::test]
async fn a_build_whose_rows_went_in_before_the_crash_holds_no_row_twice() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let scratch = tempfile::tempdir().expect("tempdir");
    let elsewhere = StoragePaths::under(scratch.path(), "tablepro", "app.tablepro.TablePro");
    std::fs::create_dir_all(&elsewhere.state).expect("state");
    std::fs::copy(history_before_move(&old.paths), history_before_move(&elsewhere)).expect("a second old file");
    let whole = SavedQueryDatabase::open(&elsewhere).await.expect("a whole build");
    whole.pool().close().await;
    let partial = partial_of(&old.paths.saved_query_database());
    std::fs::copy(elsewhere.saved_query_database(), &partial).expect("a build the crash left whole");

    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");

    assert_moved(&old, &saved).await;
}

#[tokio::test]
async fn a_crash_after_the_drop_finishes_the_move_from_its_build() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let saved_path = old.paths.saved_query_database();
    let built = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");
    let generation = built.identity().await.expect("identity").generation;
    built.pool().close().await;
    // The drop committed, then the rename never ran.
    std::fs::rename(&saved_path, partial_of(&saved_path)).expect("back to the build");

    let history = QueryHistory::open(&old.paths).await.expect("history");
    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");

    assert_moved(&old, &saved).await;
    assert_history_kept(&old, &history).await;
    assert_eq!(saved.identity().await.expect("identity").generation, generation);
}

#[tokio::test]
async fn the_saved_queries_finish_a_move_the_history_left_unrenamed() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let saved_path = old.paths.saved_query_database();
    let built = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");
    built.pool().close().await;
    std::fs::rename(&saved_path, partial_of(&saved_path)).expect("back to the build");

    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");

    assert_moved(&old, &saved).await;
}

#[tokio::test]
async fn opening_again_moves_nothing() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let first = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");
    let identity = first.identity().await.expect("identity");
    drop(first);
    drop(QueryHistory::open(&old.paths).await.expect("history"));

    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");

    assert_eq!(saved.identity().await.expect("identity"), identity);
    assert_moved(&old, &saved).await;
}

// The saved queries' store as the person used it after the move, and `history.db` put back from before it, as the
// copy an upgrade kept or a backup brings back. `changed` is what an older release wrote to it meanwhile.
async fn put_back(old: &Old, changed: Option<&str>) -> Uuid {
    let history_path = old.paths.history_database();
    let copy = old.paths.state.join("history.db.put-back");
    std::fs::copy(history_before_move(&old.paths), &copy).expect("a copy of the old file");
    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");
    let generation = saved.identity().await.expect("identity").generation;
    saved
        .saved_queries()
        .save(crate::saved_queries::NewSavedQuery {
            name: "after the move".to_owned(),
            query: "SELECT 4".to_owned(),
            connection_id: None,
            connection_name: "any".to_owned(),
        })
        .await
        .expect("a later query");
    saved.pool().close().await;
    for sidecar in ["-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{sidecar}", history_path.display()));
    }
    std::fs::copy(&copy, &history_path).expect("put back");
    if let Some(statement) = changed {
        let pool = super::connect(&history_path).await.expect("the put-back file");
        sqlx::query(AssertSqlSafe(statement.to_owned()))
            .execute(&pool)
            .await
            .expect("an older release's write");
        pool.close().await;
    }
    generation
}

async fn names(saved: &SavedQueryDatabase) -> Vec<String> {
    let mut names: Vec<String> = saved
        .saved_queries()
        .list(None)
        .await
        .expect("list")
        .into_iter()
        .map(|query| query.name)
        .collect();
    names.sort();
    names
}

// Putting back a `history.db` from before the move restores the history alone. The saved queries' store stays as the
// person last used it, and what an older release changed in the file put back stays in the copy the upgrade keeps.
#[tokio::test]
async fn a_history_db_put_back_keeps_the_saved_queries_store_and_its_tables_stay_in_the_copy() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let generation = put_back(
        &old,
        Some("UPDATE saved_queries SET name = 'renamed back then' WHERE name = 'daily'"),
    )
    .await;
    let copies_before = crate::upgrade_copies::copies_blocking(&old.paths.history_database())
        .expect("copies")
        .len();

    drop(QueryHistory::open(&old.paths).await.expect("history"));
    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");

    assert_eq!(names(&saved).await, ["after the move", "daily", "everywhere"]);
    assert_eq!(saved.identity().await.expect("identity").generation, generation);
    assert!(
        !tables(&old.paths.history_database())
            .await
            .iter()
            .any(|name| name == "saved_queries")
    );
    let copies = crate::upgrade_copies::copies_blocking(&old.paths.history_database()).expect("copies");
    assert_eq!(copies.len(), copies_before + 1, "no copy kept the file put back");
    let (kept, _) = copy_rows(&copies.last().expect("the newest copy").path).await;
    assert!(kept[1].iter().any(|row| row.contains("renamed back then")), "{kept:?}");
}

#[tokio::test]
async fn a_new_install_makes_both_stores_and_history_db_holds_no_saved_table() {
    let root = tempfile::tempdir().expect("tempdir");
    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");

    let history = QueryHistory::open(&paths).await.expect("history");
    let saved = SavedQueryDatabase::open(&paths).await.expect("saved queries");

    let applied: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM _sqlx_migrations WHERE version = ?")
        .bind(MOVE_OUT)
        .fetch_one(history.pool())
        .await
        .expect("migrations");
    assert_eq!(applied, 1);
    let history_tables = tables(&paths.history_database()).await;
    assert!(!history_tables.iter().any(|name| name == "saved_queries"));
    assert!(
        saved
            .saved_queries()
            .contents()
            .await
            .expect("contents")
            .queries
            .is_empty()
    );
    assert!(!partial_of(&paths.saved_query_database()).exists());
    assert_ne!(
        saved.identity().await.expect("identity").generation,
        history.identity().await.expect("identity").generation
    );
}

#[tokio::test]
async fn the_saved_queries_open_without_a_history_db() {
    let root = tempfile::tempdir().expect("tempdir");
    let paths = StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro");

    let saved = SavedQueryDatabase::open(&paths).await.expect("saved queries");

    assert!(
        saved
            .saved_queries()
            .contents()
            .await
            .expect("contents")
            .queries
            .is_empty()
    );
    assert!(!paths.history_database().exists(), "the saved queries made a history");
    assert!(
        !paths.history_folder().exists(),
        "the saved queries made the history's folder"
    );
}

async fn copy_rows(copy: &Path) -> (Vec<Vec<String>>, i64) {
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .connect_with(SqliteConnectOptions::new().filename(copy).read_only(true))
        .await
        .expect("the copy");
    let history: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM history")
        .fetch_one(&pool)
        .await
        .expect("history");
    let saved = rows(&pool).await;
    pool.close().await;
    (saved, history)
}

// The copy kept before the move holds both stores' tables, so each store's deletions reach it.
#[tokio::test]
async fn a_saved_query_deleted_after_the_move_leaves_the_copy_kept_before_it() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let history = QueryHistory::open(&old.paths).await.expect("history");
    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");
    let copy = crate::upgrade_copies::copies_blocking(&old.paths.history_database()).expect("copies")[0]
        .path
        .clone();
    let daily = saved
        .saved_queries()
        .list(Some(old.connection))
        .await
        .expect("list")
        .into_iter()
        .find(|query| query.name == "daily")
        .expect("daily")
        .id;

    saved.saved_queries().delete(daily).await.expect("delete");

    let (kept, entries) = copy_rows(&copy).await;
    assert_eq!(kept[1].len(), 1, "a deleted saved query stayed in the copy");
    assert!(kept[1][0].contains("everywhere"));
    assert_eq!(entries, 2, "a saved query's deletion took history out of the copy");
    drop(history);
}

#[tokio::test]
async fn a_history_entry_deleted_after_the_move_leaves_the_copy_and_its_saved_queries_stay() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let history = QueryHistory::open(&old.paths).await.expect("history");
    let copy = crate::upgrade_copies::copies_blocking(&old.paths.history_database()).expect("copies")[0]
        .path
        .clone();

    assert_eq!(history.delete_records(&[old.entries[0]]).await.expect("delete"), 1);

    let (kept, entries) = copy_rows(&copy).await;
    assert_eq!(entries, 1, "a deleted entry stayed in the copy");
    assert_eq!(kept, old.rows);
}

// On iOS the history stays locked while the saved queries sync: their deletions open neither the live history nor a
// copy of it made after the move, and so delete no healthy copy for failing to.
#[cfg(unix)]
#[tokio::test]
async fn a_saved_query_deleted_while_the_history_is_locked_away_trims_and_keeps_every_copy() {
    use std::os::unix::fs::PermissionsExt;

    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let history = QueryHistory::open(&old.paths).await.expect("history");
    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");
    let before_move = crate::upgrade_copies::copies_blocking(&old.paths.history_database()).expect("copies")[0]
        .path
        .clone();
    let after_move = crate::upgrade_copies::keep_database(history.pool(), history.path(), MOVE_OUT as u64 + 1)
        .await
        .expect("a later copy");
    history.pool().close().await;
    let locked = std::fs::Permissions::from_mode(0o000);
    for file in [old.paths.history_database(), after_move.clone()] {
        std::fs::set_permissions(&file, locked.clone()).expect("lock");
    }
    let daily = saved
        .saved_queries()
        .list(Some(old.connection))
        .await
        .expect("list")
        .into_iter()
        .find(|query| query.name == "daily")
        .expect("daily")
        .id;

    let deleted = saved.saved_queries().delete(daily).await;

    let open = std::fs::Permissions::from_mode(0o600);
    for file in [old.paths.history_database(), after_move.clone()] {
        std::fs::set_permissions(&file, open.clone()).expect("unlock");
    }
    deleted.expect("delete");
    assert!(
        after_move.exists(),
        "a copy of the history alone was opened and deleted"
    );
    let (kept, _) = copy_rows(&before_move).await;
    assert_eq!(
        kept[1].len(),
        1,
        "the copy from before the move kept a deleted saved query"
    );
}

// The history leaves the state folder for its own once, with its upgrade copies and the commits its WAL still held.
#[tokio::test]
async fn the_history_moves_into_its_folder_with_its_copies_and_its_last_commits() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let before = history_before_move(&old.paths);
    let kept_copy = old.paths.state.join("history.db.v20261126000000-1764000000");
    std::fs::copy(&before, &kept_copy).expect("a copy an earlier upgrade kept");
    // A connection still open keeps the last commit in the WAL; the files as they stand are what a crash leaves.
    let pool = super::connect(&before).await.expect("the old file");
    sqlx::query(
        "INSERT INTO history (record_id, query, query_folded, driver_id, connection_id, connection_name, \
         executed_at, success) VALUES (?, 'SELECT wal', 'select wal', 'sqlite', ?, 'local', 1800000002, 1)",
    )
    .bind(Uuid::new_v4().to_string())
    .bind(old.connection.to_string())
    .execute(&pool)
    .await
    .expect("a commit in the WAL");
    let crashed = tempfile::tempdir().expect("tempdir");
    let crashed_paths = StoragePaths::under(crashed.path(), "tablepro", "app.tablepro.TablePro");
    std::fs::create_dir_all(&crashed_paths.state).expect("state");
    for suffix in ["", "-wal", "-shm"] {
        let from = format!("{}{suffix}", before.display());
        let to = format!("{}{suffix}", history_before_move(&crashed_paths).display());
        std::fs::copy(&from, &to).expect("the file as a crash leaves it");
    }
    std::fs::copy(
        &kept_copy,
        crashed_paths.state.join("history.db.v20261126000000-1764000000"),
    )
    .expect("the copy");
    pool.close().await;

    let history = QueryHistory::open(&crashed_paths).await.expect("history");

    assert_left_marked(&crashed_paths).await;
    assert_eq!(history.path(), crashed_paths.history_database());
    let queries: Vec<String> = history
        .entries()
        .await
        .expect("entries")
        .into_iter()
        .map(|entry| entry.query)
        .collect();
    assert!(
        queries.iter().any(|query| query == "SELECT wal"),
        "the WAL's commit was lost: {queries:?}"
    );
    let copies = crate::upgrade_copies::copies_blocking(&crashed_paths.history_database()).expect("copies");
    assert!(
        copies
            .iter()
            .any(|copy| copy.path.ends_with("history/history.db.v20261126000000-1764000000")),
        "the earlier copy stayed behind: {copies:?}"
    );
    assert!(
        crate::upgrade_copies::copies_blocking(&history_before_move(&crashed_paths))
            .expect("copies")
            .is_empty()
    );
}

// A crash after the copies moved and before the database did: the next open moves the database.
#[tokio::test]
async fn a_move_into_the_folder_cut_short_after_the_copies_finishes() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    std::fs::create_dir_all(old.paths.history_folder()).expect("the folder");
    std::fs::copy(
        history_before_move(&old.paths),
        old.paths.history_folder().join("history.db.v20261126000000-1764000000"),
    )
    .expect("a copy that moved");

    let history = QueryHistory::open(&old.paths).await.expect("history");
    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");

    assert_left_marked(&old.paths).await;
    assert_moved(&old, &saved).await;
    assert_history_kept(&old, &history).await;
}

// Another process holding the old file keeps it where it is, whole: nothing moves until it lets go.
#[tokio::test]
async fn a_history_another_process_holds_open_stays_where_it_is() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let kept_copy = old.paths.state.join("history.db.v20261126000000-1764000000");
    std::fs::copy(history_before_move(&old.paths), &kept_copy).expect("a copy an earlier upgrade kept");
    let holder = super::connect(&history_before_move(&old.paths))
        .await
        .expect("another process");
    sqlx::query("SELECT COUNT(*) FROM history")
        .execute(&holder)
        .await
        .expect("a read");

    let refused = QueryHistory::open(&old.paths).await;

    assert!(refused.is_err(), "the history moved while another process held it");
    assert!(history_before_move(&old.paths).exists());
    assert!(!old.paths.history_database().exists());
    assert!(
        kept_copy.exists(),
        "a refused move took a copy away from an older build's cleanup"
    );
    let entries: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM history")
        .fetch_one(&holder)
        .await
        .expect("the holder still reads its file");
    assert_eq!(entries, 2);
    holder.close().await;
    let history = QueryHistory::open(&old.paths).await.expect("history");
    assert_history_kept(&old, &history).await;
    assert!(!kept_copy.exists());
    assert!(
        old.paths
            .history_folder()
            .join("history.db.v20261126000000-1764000000")
            .exists()
    );
}

// A file an older build made where the history used to be, once this build's history is in its folder, is not this
// build's to move or read.
#[tokio::test]
async fn a_history_already_in_its_folder_leaves_one_an_older_build_made_alone() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    drop(QueryHistory::open(&old.paths).await.expect("history"));
    std::fs::write(history_before_move(&old.paths), b"an older build's").expect("a file where the history was");

    let history = QueryHistory::open(&old.paths).await.expect("history");

    assert_history_kept(&old, &history).await;
    assert_eq!(
        std::fs::read(history_before_move(&old.paths)).expect("left"),
        b"an older build's"
    );
}

// The saved queries opening first move the history into its folder too, and a new install makes the folder.
#[tokio::test]
async fn the_saved_queries_opening_first_move_the_history_into_its_folder() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;

    let saved = SavedQueryDatabase::open(&old.paths).await.expect("saved queries");

    assert_left_marked(&old.paths).await;
    assert!(old.paths.history_database().is_file());
    assert_moved(&old, &saved).await;
}

fn holds(path: &Path, text: &str) -> bool {
    let needle = text.as_bytes();
    ["", "-wal", "-journal"].iter().any(|suffix| {
        std::fs::read(format!("{}{suffix}", path.display()))
            .is_ok_and(|bytes| bytes.windows(needle.len()).any(|window| window == needle))
    })
}

// What stays where the history was: no table but the migrations, one whose version no build has, so an older build
// refuses the file, and none of the history's text.
async fn assert_left_marked(paths: &StoragePaths) {
    let before = history_before_move(paths);
    let left: Vec<String> = tables(&before)
        .await
        .into_iter()
        .filter(|name| !name.starts_with("sqlite_"))
        .collect();
    assert_eq!(left, ["_sqlx_migrations"]);
    assert!(
        !holds(&before, "select kept"),
        "the history's text stayed in the old file"
    );
    let older = super::connect(&before).await.expect("the old file");
    let refused = Migrator::with_migrations(schema::MIGRATOR.iter().take(BEFORE_MOVE).cloned().collect())
        .run(&older)
        .await;
    older.close().await;
    assert!(
        matches!(refused, Err(MigrateError::VersionMissing(version)) if version == MOVED_AWAY),
        "an older build opened the file the history left: {refused:?}"
    );
}

fn is_busy(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|error| error.code())
        .and_then(|code| code.parse::<i32>().ok())
        .is_some_and(|code| code & 0xff == 5)
}

// An older build's process that writes while the history moves waits on the move's lock, and once the move is done the
// file refuses it, so no write lands where this build no longer reads.
#[tokio::test]
async fn a_write_while_the_history_moves_waits_and_the_file_it_left_then_refuses_an_older_build() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let before = history_before_move(&old.paths);
    let (held, on_hold) = oneshot::channel();
    let (resume, resumed) = oneshot::channel();
    super::split::PAUSES.lock().expect("pauses").push(super::split::Pause {
        path: before.clone(),
        held,
        resume: resumed,
    });
    let paths = old.paths.clone();
    let opening = tokio::spawn(async move { QueryHistory::open(&paths).await });
    on_hold.await.expect("the move took its lock");

    let written: Result<(), sqlx::Error> = async {
        let mut other = SqliteConnectOptions::new()
            .filename(&before)
            .busy_timeout(Duration::ZERO)
            .connect()
            .await?;
        sqlx::query(
            "INSERT INTO history (record_id, query, query_folded, driver_id, connection_id, connection_name, \
             executed_at, success) VALUES (?, 'SELECT late', 'select late', 'sqlite', ?, 'local', 1800000003, 1)",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(old.connection.to_string())
        .execute(&mut other)
        .await?;
        other.close().await
    }
    .await;
    assert!(
        written.as_ref().is_err_and(is_busy),
        "a write landed while the history moved: {written:?}"
    );
    resume.send(()).expect("resume");
    let history = opening.await.expect("the open").expect("history");

    assert_history_kept(&old, &history).await;
    assert_left_marked(&old.paths).await;
}

// A crash after the file was marked and before its copy took its place: the next open renames the copy, which holds
// the history, and moves the upgrade copies still waiting.
#[tokio::test]
async fn a_move_cut_short_after_the_mark_finishes_from_its_copy() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    // Closed, so its WAL is folded in before the file is renamed back.
    QueryHistory::open(&old.paths)
        .await
        .expect("history")
        .pool()
        .close()
        .await;
    let moved = old.paths.history_database();
    std::fs::rename(&moved, partial_of(&moved)).expect("back to the copy");
    let copy = crate::upgrade_copies::copies_blocking(&moved)
        .expect("copies")
        .remove(0)
        .path;
    let name = copy.file_name().expect("a name").to_owned();
    std::fs::rename(&copy, old.paths.state.join(&name)).expect("a copy still waiting");

    let history = QueryHistory::open(&old.paths).await.expect("history");

    assert_history_kept(&old, &history).await;
    assert!(!partial_of(&moved).exists());
    assert!(old.paths.history_folder().join(&name).exists());
    assert!(!old.paths.state.join(&name).exists());
    assert_left_marked(&old.paths).await;
}

// A copy a trim was cut short in keeps its journal beside it in the folder, whichever of the two moved first.
#[tokio::test]
async fn an_upgrade_copy_moves_with_its_journal() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file(&root).await;
    let state = old.paths.state.clone();
    let folder = old.paths.history_folder();
    std::fs::create_dir_all(&folder).expect("the folder");
    for (copy, journal_at) in [
        ("history.db.v20261126000000-1764000000", &state),
        ("history.db.v20261126000000-1764000001", &folder),
    ] {
        std::fs::copy(history_before_move(&old.paths), state.join(copy)).expect("a copy");
        std::fs::write(journal_at.join(format!("{copy}-journal")), b"the pages a trim replaced").expect("a journal");
    }

    drop(QueryHistory::open(&old.paths).await.expect("history"));

    for copy in [
        "history.db.v20261126000000-1764000000",
        "history.db.v20261126000000-1764000001",
    ] {
        assert!(folder.join(copy).exists(), "{copy} stayed behind");
        assert!(
            folder.join(format!("{copy}-journal")).exists(),
            "{copy} lost its journal"
        );
        assert!(!state.join(copy).exists());
        assert!(!state.join(format!("{copy}-journal")).exists());
    }
}

const SAVED_TEXT: &str = "only a saved query held this";

async fn old_file_with_saved_text(root: &tempfile::TempDir) -> Old {
    let old = old_file(root).await;
    let pool = super::connect(&history_before_move(&old.paths))
        .await
        .expect("the old file");
    // Over several pages, so some page the drop frees keeps it whole.
    sqlx::query("UPDATE saved_queries SET query = ? WHERE id = 2")
        .bind(format!("SELECT '{}'", SAVED_TEXT.repeat(400)))
        .execute(&pool)
        .await
        .expect("a saved query");
    pool.close().await;
    old
}

// The saved queries leave the history's file with their text: the pages the drop freed are rewritten.
#[tokio::test]
async fn the_saved_queries_leave_no_text_in_the_history_file() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file_with_saved_text(&root).await;

    let history = QueryHistory::open(&old.paths).await.expect("history");

    assert!(
        !holds(&old.paths.history_database(), SAVED_TEXT),
        "a saved query's text stayed in history.db"
    );
    assert!(!holds(&history_before_move(&old.paths), SAVED_TEXT));
    assert!(
        !tables(&old.paths.history_database())
            .await
            .iter()
            .any(|name| name == COMPACTION_OWED)
    );
    assert_history_kept(&old, &history).await;
}

// A crash after the drop committed and before the file was compacted: the next open compacts it.
#[tokio::test]
async fn a_compaction_a_crash_cut_off_runs_at_the_next_open() {
    let root = tempfile::tempdir().expect("tempdir");
    let old = old_file_with_saved_text(&root).await;
    {
        let _moving = super::split::MOVING.lock().await;
        super::split::relocate(&old.paths).await.expect("the folder");
    }
    let pool = super::connect(&old.paths.history_database()).await.expect("history");
    sqlx::query("PRAGMA secure_delete = OFF")
        .execute(&pool)
        .await
        .expect("no zeroing");
    super::split::take_out(&pool, &old.paths).await.expect("the drop");
    pool.close().await;
    assert!(
        holds(&old.paths.history_database(), SAVED_TEXT),
        "the drop alone already cleared the text, so this tests nothing"
    );
    assert!(
        tables(&old.paths.history_database())
            .await
            .iter()
            .any(|name| name == COMPACTION_OWED)
    );

    let history = QueryHistory::open(&old.paths).await.expect("history");

    assert!(!holds(&old.paths.history_database(), SAVED_TEXT));
    assert!(
        !tables(&old.paths.history_database())
            .await
            .iter()
            .any(|name| name == COMPACTION_OWED)
    );
    assert_history_kept(&old, &history).await;
}

#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    Core, DatabaseEnvironmentTag, FavouriteTableInfo, FileOpenRequest, HistoryExportFormat, HistoryOutcomeTag,
    HistoryRun, HostConfig, HostSecretError, HostSecrets, SavedQueryDraft, SecretItemTag, SecretKindTag,
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

const SHOP: &str = "6f0b6a4e-3a52-4c2f-9d1e-0c6a2b7f9e11";
const OTHER: &str = "1c2d3e4f-5a6b-4c7d-8e9f-a0b1c2d3e4f5";

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

fn draft(connection: &str, name: &str, sql: &str) -> SavedQueryDraft {
    SavedQueryDraft {
        connection_id: connection.to_owned(),
        connection_name: "shop".to_owned(),
        name: name.to_owned(),
        sql: sql.to_owned(),
    }
}

#[tokio::test]
async fn a_saved_query_comes_back_for_its_connection_only() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let queries = core.history().await.unwrap().saved_queries();

    let id = queries
        .save(draft(SHOP, "Orders today", "SELECT * FROM orders"), false)
        .await
        .unwrap()
        .unwrap();
    queries
        .save(draft(OTHER, "Elsewhere", "SELECT 1"), false)
        .await
        .unwrap();
    let shop = queries.snapshot(SHOP.to_owned()).await.unwrap();

    let [query] = shop.queries.as_slice() else {
        panic!("{:?}", shop.queries)
    };
    assert_eq!(query.id, id);
    assert_eq!(query.name, "Orders today");
    assert_eq!(query.sql, "SELECT * FROM orders");
    assert_eq!(
        (query.folder_id, query.keyword.as_deref(), query.order),
        (None, None, 0)
    );
    assert!(query.updated_at_ms > 0);
    assert!(shop.folders.is_empty());
}

#[tokio::test]
async fn a_taken_name_is_replaced_only_when_asked_and_keeps_its_id() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let queries = core.history().await.unwrap().saved_queries();
    let first = queries
        .save(draft(SHOP, "Daily", "SELECT 1"), false)
        .await
        .unwrap()
        .unwrap();

    let kept = queries.save(draft(SHOP, "Daily", "SELECT 2"), false).await.unwrap();
    let before = queries.snapshot(SHOP.to_owned()).await.unwrap();
    let replaced = queries.save(draft(SHOP, "Daily", "SELECT 2"), true).await.unwrap();
    let after = queries.snapshot(SHOP.to_owned()).await.unwrap();

    assert_eq!(kept, None);
    assert_eq!(before.queries[0].sql, "SELECT 1");
    assert_eq!(replaced, Some(first));
    assert_eq!(after.queries.len(), 1);
    assert_eq!(after.queries[0].sql, "SELECT 2");
}

#[tokio::test]
async fn folders_nest_hold_queries_in_order_and_give_them_back_to_the_top_when_deleted() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let queries = core.history().await.unwrap().saved_queries();
    let reports = queries
        .create_folder(SHOP.to_owned(), "Reports".to_owned(), None)
        .await
        .unwrap();
    let monthly = queries
        .create_folder(SHOP.to_owned(), "Monthly".to_owned(), Some(reports))
        .await
        .unwrap();
    let a = queries
        .save(draft(SHOP, "A", "SELECT 'a'"), false)
        .await
        .unwrap()
        .unwrap();
    let b = queries
        .save(draft(SHOP, "B", "SELECT 'b'"), false)
        .await
        .unwrap()
        .unwrap();

    queries.move_query(a, Some(monthly), None).await.unwrap();
    queries.move_query(b, Some(monthly), Some(a)).await.unwrap();
    let filed = queries.snapshot(SHOP.to_owned()).await.unwrap();
    queries.delete_folder(reports).await.unwrap();
    let after = queries.snapshot(SHOP.to_owned()).await.unwrap();

    assert_eq!(filed.folders.len(), 2);
    let inner = filed.folders.iter().find(|folder| folder.id == monthly).unwrap();
    assert_eq!(inner.parent_id, Some(reports));
    let order: Vec<(i64, Option<i64>, i64)> = filed
        .queries
        .iter()
        .map(|query| (query.id, query.folder_id, query.order))
        .collect();
    assert_eq!(order, [(b, Some(monthly), 0), (a, Some(monthly), 1)]);
    assert!(after.folders.is_empty());
    assert!(after.queries.iter().all(|query| query.folder_id.is_none()));
    assert_eq!(after.queries.len(), 2);
}

#[tokio::test]
async fn a_rename_a_keyword_or_a_folder_name_already_taken_is_refused_by_code() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let queries = core.history().await.unwrap().saved_queries();
    let one = queries
        .save(draft(SHOP, "One", "SELECT 1"), false)
        .await
        .unwrap()
        .unwrap();
    let two = queries
        .save(draft(SHOP, "Two", "SELECT 2"), false)
        .await
        .unwrap()
        .unwrap();
    queries.set_keyword(one, Some("sel".to_owned())).await.unwrap();
    queries
        .create_folder(SHOP.to_owned(), "Reports".to_owned(), None)
        .await
        .unwrap();

    let name = queries.rename(two, "One".to_owned()).await.unwrap_err();
    let keyword = queries.set_keyword(two, Some("SEL".to_owned())).await.unwrap_err();
    let spaced = queries
        .set_keyword(two, Some("two words".to_owned()))
        .await
        .unwrap_err();
    let folder = queries
        .create_folder(SHOP.to_owned(), "reports".to_owned(), None)
        .await
        .unwrap_err();
    let empty = queries.save(draft(SHOP, "  ", "SELECT 3"), false).await.unwrap_err();
    let unknown = queries.delete(9_999).await.unwrap_err();

    assert_eq!(name.code(), "storage.name_taken");
    assert_eq!(keyword.code(), "storage.keyword_taken");
    assert_eq!(spaced.code(), "storage.keyword_invalid");
    assert_eq!(folder.code(), "storage.folder_name_taken");
    assert_eq!(empty.code(), "storage.empty_name");
    assert_eq!(unknown.code(), "storage.not_found");
    let snapshot = queries.snapshot(SHOP.to_owned()).await.unwrap();
    let keywords: Vec<Option<&str>> = snapshot.queries.iter().map(|query| query.keyword.as_deref()).collect();
    assert_eq!(keywords, [Some("sel"), None]);
}

#[tokio::test]
async fn deleting_a_connections_data_takes_its_queries_folders_and_favourites_only() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let history = core.history().await.unwrap();
    let queries = history.saved_queries();
    let favourites = history.favourites();
    queries.save(draft(SHOP, "Mine", "SELECT 1"), false).await.unwrap();
    queries
        .create_folder(SHOP.to_owned(), "Reports".to_owned(), None)
        .await
        .unwrap();
    queries.save(draft(OTHER, "Theirs", "SELECT 2"), false).await.unwrap();
    let table = FavouriteTableInfo {
        database: None,
        schema: Some("main".to_owned()),
        name: "orders".to_owned(),
    };
    favourites.add_table(SHOP.to_owned(), table.clone()).await.unwrap();
    favourites.add_table(OTHER.to_owned(), table).await.unwrap();

    let removed = queries.delete_for_connection(SHOP.to_owned()).await.unwrap();

    assert_eq!(removed, 1);
    let mine = queries.snapshot(SHOP.to_owned()).await.unwrap();
    assert!(mine.queries.is_empty() && mine.folders.is_empty());
    assert!(favourites.tables(SHOP.to_owned()).await.unwrap().is_empty());
    assert_eq!(queries.snapshot(OTHER.to_owned()).await.unwrap().queries.len(), 1);
    assert_eq!(favourites.tables(OTHER.to_owned()).await.unwrap().len(), 1);
}

#[tokio::test]
async fn favourite_tables_and_databases_are_kept_per_connection() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let favourites = core.history().await.unwrap().favourites();
    let orders = FavouriteTableInfo {
        database: Some("shop".to_owned()),
        schema: Some(String::new()),
        name: "orders".to_owned(),
    };

    favourites.add_table(SHOP.to_owned(), orders.clone()).await.unwrap();
    favourites.add_table(SHOP.to_owned(), orders.clone()).await.unwrap();
    favourites
        .set_database(SHOP.to_owned(), "shop".to_owned(), DatabaseEnvironmentTag::Testing)
        .await
        .unwrap();
    favourites
        .set_database(SHOP.to_owned(), "shop".to_owned(), DatabaseEnvironmentTag::Production)
        .await
        .unwrap();
    let tables = favourites.tables(SHOP.to_owned()).await.unwrap();
    let databases = favourites.databases(SHOP.to_owned()).await.unwrap();
    favourites.remove_table(SHOP.to_owned(), orders).await.unwrap();
    favourites
        .remove_database(SHOP.to_owned(), "shop".to_owned())
        .await
        .unwrap();

    let [table] = tables.as_slice() else {
        panic!("{tables:?}")
    };
    assert_eq!(table.database.as_deref(), Some("shop"));
    assert_eq!(table.schema, None, "an empty schema is none");
    assert_eq!(table.name, "orders");
    assert_eq!(databases.len(), 1);
    assert_eq!(databases[0].environment, DatabaseEnvironmentTag::Production);
    assert!(favourites.tables(SHOP.to_owned()).await.unwrap().is_empty());
    assert!(favourites.databases(SHOP.to_owned()).await.unwrap().is_empty());
    assert!(favourites.tables("not-an-id".to_owned()).await.is_err());
}

#[tokio::test]
async fn a_pinned_run_comes_first_and_an_export_writes_the_runs_asked_for() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(dir.path());
    let session = core
        .open_file(
            FileOpenRequest {
                path: dir.path().join("app.sqlite").display().to_string(),
                driver_id: None,
                read_only: false,
                create: true,
            },
            None,
        )
        .await
        .unwrap();
    let history = core.history().await.unwrap();
    let ran = |sql: &str, at_secs: i64| HistoryRun {
        sql: sql.to_owned(),
        executed_at_ms: at_secs * 1_000,
        duration_ms: None,
        rows_affected: None,
        outcome: HistoryOutcomeTag::Succeeded,
    };
    let old = history
        .record(session.clone(), ran("SELECT 'old'", 1_700_000_000))
        .await
        .unwrap()
        .unwrap();
    let new = history
        .record(session.clone(), ran("SELECT 'new'", 1_700_000_100))
        .await
        .unwrap()
        .unwrap();

    history.set_pinned(old, true).await.unwrap();
    let pinned = history.search(String::new(), None, None, 50).await.unwrap();
    history.set_pinned(old, false).await.unwrap();
    let unpinned = history.search(String::new(), None, None, 50).await.unwrap();
    let sql_file = dir.path().join("history.sql");
    let csv_file = dir.path().join("history.csv");
    history
        .export(vec![old], HistoryExportFormat::Sql, sql_file.display().to_string())
        .await
        .unwrap();
    history
        .export(vec![old, new], HistoryExportFormat::Csv, csv_file.display().to_string())
        .await
        .unwrap();
    let relative = history
        .export(vec![old], HistoryExportFormat::Sql, "history.sql".to_owned())
        .await
        .unwrap_err();

    let order: Vec<(i64, bool)> = pinned.entries.iter().map(|entry| (entry.id, entry.pinned)).collect();
    assert_eq!(order, [(old, true), (new, false)]);
    let order: Vec<i64> = unpinned.entries.iter().map(|entry| entry.id).collect();
    assert_eq!(order, [new, old]);
    let script = std::fs::read_to_string(&sql_file).unwrap();
    assert!(
        script.contains("SELECT 'old'") && !script.contains("SELECT 'new'"),
        "{script}"
    );
    let csv = std::fs::read_to_string(&csv_file).unwrap();
    assert!(csv.starts_with("\"executed_at\","), "{csv}");
    assert_eq!(csv.lines().count(), 3, "{csv}");
    assert_eq!(relative.code(), "ffi.export_bad_path");
    session.close().await.unwrap();
}

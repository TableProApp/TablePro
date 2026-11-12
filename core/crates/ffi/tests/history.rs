#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    Core, DatabaseSession, FileOpenRequest, HistoryOutcomeTag, HistoryRun, HostConfig, HostSecretError, HostSecrets,
    SecretItemTag, SecretKindTag,
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

fn started(storage: Option<&Path>) -> Arc<Core> {
    Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: storage.map(|dir| dir.display().to_string()),
        },
        Box::new(NoSecrets),
    )
    .unwrap()
}

async fn open(core: &Core, path: &Path) -> Arc<DatabaseSession> {
    let request = FileOpenRequest {
        path: path.display().to_string(),
        driver_id: None,
        read_only: false,
        create: true,
    };
    core.open_file(request, None).await.unwrap()
}

// Whole seconds, which is what the store keeps.
fn ran(sql: &str, at_secs: i64) -> HistoryRun {
    HistoryRun {
        sql: sql.to_owned(),
        executed_at_ms: at_secs * 1_000,
        duration_ms: Some(12),
        rows_affected: Some(3),
        outcome: HistoryOutcomeTag::Succeeded,
    }
}

#[tokio::test]
async fn a_recorded_run_is_found_by_its_words() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(Some(dir.path()));
    let session = open(&core, &dir.path().join("app.sqlite")).await;
    let history = core.history().await.unwrap();

    let kept = history
        .record(session.clone(), ran("SELECT name FROM people", 1_700_000_000))
        .await
        .unwrap()
        .unwrap();
    let failed = HistoryRun {
        outcome: HistoryOutcomeTag::Failed {
            message: "no such column: nope".to_owned(),
        },
        ..ran("SELECT nope FROM people", 1_700_000_001)
    };
    let refused = history.record(session.clone(), failed).await.unwrap().unwrap();
    let named = history.search("name people".to_owned(), None, None, 50).await.unwrap();
    let both = history.search("PEOPLE".to_owned(), None, None, 50).await.unwrap();

    let [entry] = named.entries.as_slice() else {
        panic!("{:?}", named.entries)
    };
    assert_eq!(entry.id, kept);
    assert_eq!(entry.sql, "SELECT name FROM people");
    assert_eq!(entry.connection_id, Some(session.id()));
    assert_eq!(entry.connection_name, session.name());
    assert_eq!(entry.driver_id, "sqlite");
    assert_eq!(entry.executed_at_ms, 1_700_000_000_000);
    assert_eq!((entry.duration_ms, entry.rows_affected), (Some(12), Some(3)));
    assert_eq!(entry.outcome, HistoryOutcomeTag::Succeeded);
    assert!(!entry.pinned);
    assert_eq!(named.next, None);
    let ids: Vec<i64> = both.entries.iter().map(|entry| entry.id).collect();
    assert_eq!(ids, [refused, kept], "newest first");
    assert_eq!(
        both.entries[0].outcome,
        HistoryOutcomeTag::Failed {
            message: "no such column: nope".to_owned()
        }
    );
}

#[tokio::test]
async fn a_search_keeps_to_the_connection_it_names() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(Some(dir.path()));
    let first = open(&core, &dir.path().join("first.sqlite")).await;
    let second = open(&core, &dir.path().join("second.sqlite")).await;
    let history = core.history().await.unwrap();

    let mine = history
        .record(first.clone(), ran("SELECT 1", 1_700_000_000))
        .await
        .unwrap()
        .unwrap();
    history
        .record(second.clone(), ran("SELECT 2", 1_700_000_001))
        .await
        .unwrap()
        .unwrap();
    let only_first = history.search(String::new(), Some(first.id()), None, 50).await.unwrap();
    let every = history.search(String::new(), None, None, 50).await.unwrap();

    let ids: Vec<i64> = only_first.entries.iter().map(|entry| entry.id).collect();
    assert_eq!(ids, [mine]);
    assert_eq!(every.entries.len(), 2);
}

#[tokio::test]
async fn pages_follow_the_cursor_and_show_no_run_twice() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(Some(dir.path()));
    let session = open(&core, &dir.path().join("app.sqlite")).await;
    let history = core.history().await.unwrap();
    let mut ids = Vec::new();
    for (index, at) in [1_700_000_001, 1_700_000_002, 1_700_000_003].into_iter().enumerate() {
        let sql = format!("SELECT {index}");
        ids.push(history.record(session.clone(), ran(&sql, at)).await.unwrap().unwrap());
    }

    let first = history.search(String::new(), None, None, 2).await.unwrap();
    let second = history.search(String::new(), None, first.next, 2).await.unwrap();

    let shown: Vec<i64> = first.entries.iter().map(|entry| entry.id).collect();
    let rest: Vec<i64> = second.entries.iter().map(|entry| entry.id).collect();
    assert_eq!(shown, [ids[2], ids[1]]);
    assert!(first.next.is_some());
    assert_eq!(rest, [ids[0]]);
    assert_eq!(second.next, None);
}

#[tokio::test]
async fn a_deleted_run_is_gone_and_clear_removes_the_rest() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(Some(dir.path()));
    let session = open(&core, &dir.path().join("app.sqlite")).await;
    let history = core.history().await.unwrap();
    let gone = history
        .record(session.clone(), ran("SELECT 1", 1_700_000_000))
        .await
        .unwrap()
        .unwrap();
    let left = history
        .record(session.clone(), ran("SELECT 2", 1_700_000_001))
        .await
        .unwrap()
        .unwrap();

    history.delete(vec![gone]).await.unwrap();
    let after_delete = history.search(String::new(), None, None, 50).await.unwrap();
    history.clear().await.unwrap();
    let after_clear = history.search(String::new(), None, None, 50).await.unwrap();

    let ids: Vec<i64> = after_delete.entries.iter().map(|entry| entry.id).collect();
    assert_eq!(ids, [left]);
    assert!(after_clear.entries.is_empty());
}

// SQLite withholds a statement that sets an encryption key, and text whose quote never closes.
#[tokio::test]
async fn a_statement_the_engine_withholds_is_not_stored() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(Some(dir.path()));
    let session = open(&core, &dir.path().join("app.sqlite")).await;
    let history = core.history().await.unwrap();

    let key = history
        .record(session.clone(), ran("PRAGMA key = 'hunter2'", 1_700_000_000))
        .await
        .unwrap();
    let unclosed = history
        .record(session.clone(), ran("SELECT 'hunter2", 1_700_000_001))
        .await
        .unwrap();
    let stored = history.search(String::new(), None, None, 50).await.unwrap();

    assert_eq!((key, unclosed), (None, None));
    assert!(stored.entries.is_empty(), "{:?}", stored.entries);
}

#[tokio::test]
async fn every_caller_shares_one_store_and_a_core_without_storage_has_none() {
    let dir = tempfile::tempdir().unwrap();
    let core = started(Some(dir.path()));

    let first = core.history().await.unwrap();
    let again = core.history().await.unwrap();
    let error = started(None).history().await.unwrap_err();

    assert!(Arc::ptr_eq(&first, &again));
    assert_eq!(error.code(), "ffi.no_storage");
}

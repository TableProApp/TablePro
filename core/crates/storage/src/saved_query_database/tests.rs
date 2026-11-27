use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;

use super::*;
use crate::journal::RecordKind;
use crate::journal::recording::Recording;
use crate::saved_queries::NewSavedQuery;

fn paths(root: &tempfile::TempDir) -> StoragePaths {
    StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro")
}

fn named(name: &str) -> NewSavedQuery {
    NewSavedQuery {
        name: name.to_owned(),
        query: "SELECT 1".to_owned(),
        connection_id: None,
        connection_name: "any".to_owned(),
    }
}

#[tokio::test]
async fn the_store_and_its_wal_are_private() {
    let root = tempfile::tempdir().expect("tempdir");
    let paths = paths(&root);

    let saved = SavedQueryDatabase::open(&paths).await.expect("open");
    saved.saved_queries().save(named("one")).await.expect("save");

    let mode = |path: &Path| std::fs::metadata(path).expect("metadata").permissions().mode() & 0o777;
    assert_eq!(mode(&paths.saved_query_database()), 0o600);
    assert_eq!(mode(&paths.saved_query_database().with_extension("db-wal")), 0o600);
}

#[tokio::test]
async fn a_store_a_newer_build_wrote_is_refused() {
    let root = tempfile::tempdir().expect("tempdir");
    let paths = paths(&root);
    let saved = SavedQueryDatabase::open(&paths).await.expect("open");
    sqlx::query(
        "INSERT INTO _sqlx_migrations (version, description, installed_on, success, checksum, execution_time) \
         VALUES (99999999999999, 'from the future', CURRENT_TIMESTAMP, 1, X'00', 0)",
    )
    .execute(saved.pool())
    .await
    .expect("a future migration");
    saved.pool().close().await;

    let refused = SavedQueryDatabase::open(&paths).await;

    assert!(
        matches!(refused, Err(StorageError::SavedQueriesNewerThanApp { .. })),
        "{:?}",
        refused.err()
    );
}

// Bump this with each new migration file: an applied migration is never edited.
#[test]
fn the_migrator_embeds_every_migration() {
    assert_eq!(schema::MIGRATOR.iter().count(), 1);
}

#[tokio::test]
async fn a_new_generation_starts_on_a_restore_and_a_write_raises_the_sequence() {
    let root = tempfile::tempdir().expect("tempdir");
    let saved = SavedQueryDatabase::open(&paths(&root)).await.expect("open");
    let first = saved.identity().await.expect("identity");

    saved.saved_queries().save(named("one")).await.expect("save");
    let written = saved.identity().await.expect("identity");
    let restored = saved.start_new_generation().await.expect("restore");

    assert_eq!(written.generation, first.generation);
    assert!(written.sequence > first.sequence);
    assert_ne!(restored.generation, first.generation);
}

#[tokio::test]
async fn its_writes_tell_its_own_journal_and_not_the_historys() {
    let root = tempfile::tempdir().expect("tempdir");
    let paths = paths(&root);
    let history = crate::QueryHistory::open(&paths).await.expect("history");
    let saved = SavedQueryDatabase::open(&paths).await.expect("saved queries");
    let (history_journal, saved_journal) = (Arc::new(Recording::default()), Arc::new(Recording::default()));
    history.set_journal(Some(history_journal.clone()));
    saved.set_journal(Some(saved_journal.clone()));

    saved.saved_queries().save(named("one")).await.expect("save");

    assert_eq!(saved_journal.calls(), [vec![RecordKind::SavedQuery]]);
    assert!(history_journal.calls().is_empty());
}

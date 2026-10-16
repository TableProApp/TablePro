use tempfile::TempDir;

use super::tests::sample_connection;
use super::{load_from, save_to, update_connection_in};

#[tokio::test]
async fn concurrent_updates_of_one_connection_keep_every_change() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connections.json");
    let saved = sample_connection();
    save_to(&path, std::slice::from_ref(&saved)).await.unwrap();

    let (database, name) = tokio::join!(
        update_connection_in(&path, saved.id, |connection| connection.database = "switched".into()),
        update_connection_in(&path, saved.id, |connection| connection.name = "Renamed".into()),
    );
    database.unwrap().expect("the connection exists");
    name.unwrap().expect("the connection exists");

    let loaded = load_from(&path).await.unwrap();
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].database, "switched");
    assert_eq!(loaded[0].name, "Renamed");
}

#[tokio::test]
async fn updating_a_missing_connection_changes_nothing() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("connections.json");
    let saved = sample_connection();
    save_to(&path, std::slice::from_ref(&saved)).await.unwrap();

    let missing = update_connection_in(&path, uuid::Uuid::new_v4(), |connection| connection.name = "x".into())
        .await
        .unwrap();

    assert!(missing.is_none());
    assert_eq!(load_from(&path).await.unwrap(), vec![saved]);
}

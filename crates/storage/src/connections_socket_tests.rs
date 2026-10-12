use std::path::PathBuf;

use super::tests::sample_connection;
use super::{load_from, save_to};

#[tokio::test]
async fn postgres_socket_directory_round_trips_in_the_current_file_version() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("connections.json");
    let mut connection = sample_connection();
    connection.socket_dir = Some(PathBuf::from("/run/postgresql"));
    save_to(&path, std::slice::from_ref(&connection)).await.unwrap();

    let raw = std::fs::read_to_string(&path).unwrap();
    assert!(raw.contains("\"version\": 2"));
    assert_eq!(load_from(&path).await.unwrap(), vec![connection]);
}

#[tokio::test]
async fn mysql_socket_file_round_trips_and_legacy_records_default_to_none() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("connections.json");
    let mut connection = sample_connection();
    connection.driver_id = "mysql".into();
    connection.socket_path = Some(PathBuf::from("/run/mysqld/mysqld.sock"));
    save_to(&path, std::slice::from_ref(&connection)).await.unwrap();

    assert_eq!(load_from(&path).await.unwrap(), vec![connection]);
    let legacy = br#"{"version":2,"connections":[{"id":"00000000-0000-0000-0000-000000000001","name":"legacy","driver_id":"mysql","host":"localhost","port":3306,"database":"mysql","username":"root"}]}"#;
    let legacy_path = dir.path().join("legacy.json");
    std::fs::write(&legacy_path, legacy).unwrap();
    let loaded = load_from(&legacy_path).await.unwrap();
    assert_eq!(loaded[0].socket_path, None);
}

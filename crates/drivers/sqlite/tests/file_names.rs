#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use drivers_sqlite::SqliteDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver};
use tempfile::TempDir;

#[tokio::test]
async fn a_file_name_with_url_characters_opens_that_exact_file() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("q?a%20b.db");
    let options = || ConnectOptions {
        database: path.to_string_lossy().to_string(),
        ..Default::default()
    };
    let writer = SqliteDriver.connect(options()).await.unwrap();
    writer.execute("CREATE TABLE kept (id INTEGER)").await.unwrap();
    drop(writer);

    let names: Vec<_> = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(names, vec!["q?a%20b.db".to_string()]);
    let reader = SqliteDriver.connect(options()).await.unwrap();
    assert_eq!(reader.list_tables().await.unwrap().len(), 1);
}

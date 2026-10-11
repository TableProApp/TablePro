#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use drivers_duckdb::DuckdbDriver;
use tablepro_core::{ConnectOptions, DatabaseDriver, Value};

fn quote_ident(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn escape_duckdb_literal(value: &str) -> String {
    value.replace('\'', "''")
}

fn derive_view_name(path: &str) -> String {
    std::path::Path::new(path)
        .file_stem()
        .and_then(std::ffi::OsStr::to_str)
        .map(|stem| {
            let mut name: String = stem
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' })
                .collect();
            if name.chars().next().is_some_and(|c| c.is_ascii_digit()) {
                name.insert(0, '_');
            }
            name
        })
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "data".to_string())
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_read_only_flat_file_connection_reads_only_the_selected_file() {
    let dir = tempfile::tempdir().unwrap();
    let selected = dir.path().join("quoted-'日本語'.csv");
    let sibling_text = dir.path().join("private.txt");
    let sibling_csv = dir.path().join("private.csv");
    let sibling_json = dir.path().join("private.json");
    let sibling_parquet = dir.path().join("private.parquet");
    let unrelated_dir = tempfile::tempdir().unwrap();
    let unrelated_text = unrelated_dir.path().join("unrelated.txt");
    std::fs::write(&selected, "id,label\n7,selected\n").unwrap();
    std::fs::write(&sibling_text, "sibling secret").unwrap();
    std::fs::write(&sibling_csv, "id\n99\n").unwrap();
    std::fs::write(&sibling_json, "[{\"id\":99}]").unwrap();
    std::fs::write(&unrelated_text, "unrelated secret").unwrap();
    let fixture = duckdb::Connection::open_in_memory().unwrap();
    fixture
        .execute(
            &format!(
                "COPY (SELECT 99 AS id) TO '{}' (FORMAT PARQUET)",
                escape_duckdb_literal(sibling_parquet.to_str().unwrap())
            ),
            [],
        )
        .unwrap();

    let connection = DuckdbDriver
        .connect(ConnectOptions {
            database: selected.to_string_lossy().into_owned(),
            read_only: true,
            ..ConnectOptions::default()
        })
        .await
        .unwrap();
    let view = quote_ident(&derive_view_name(selected.to_str().unwrap()));
    assert_eq!(
        connection
            .query(&format!("SELECT id, label FROM {view}"))
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(7), Value::Text("selected".into())]]
    );

    let selected_path = escape_duckdb_literal(selected.to_str().unwrap());
    assert!(
        connection
            .query(&format!("SELECT id FROM read_csv('{selected_path}')"))
            .await
            .is_err()
    );

    for path in [
        &sibling_text,
        &sibling_csv,
        &sibling_json,
        &sibling_parquet,
        &unrelated_text,
    ] {
        let path = escape_duckdb_literal(path.to_str().unwrap());
        let sql = if path.ends_with(".txt") {
            format!("SELECT * FROM read_text('{path}')")
        } else if path.ends_with(".csv") {
            format!("SELECT * FROM read_csv('{path}')")
        } else if path.ends_with(".json") {
            format!("SELECT * FROM read_json('{path}')")
        } else {
            format!("SELECT * FROM read_parquet('{path}')")
        };
        assert!(connection.query(&sql).await.is_err(), "{sql}");
    }

    let sibling_path = escape_duckdb_literal(sibling_text.to_str().unwrap());
    assert!(
        connection
            .execute(&format!("ATTACH '{sibling_path}' AS sibling_db"))
            .await
            .is_err()
    );
    assert!(
        connection
            .execute(&format!("COPY (SELECT 1) TO '{sibling_path}'"))
            .await
            .is_err()
    );
    assert!(connection.execute("SET enable_external_access = true").await.is_err());
    assert!(
        connection
            .execute(&format!("SET allowed_paths = ['{sibling_path}']"))
            .await
            .is_err()
    );
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_read_only_flat_file_connection_stays_on_the_selected_inode_after_path_replacement() {
    let dir = tempfile::tempdir().unwrap();
    let selected = dir.path().join("selected.csv");
    let moved = dir.path().join("moved.csv");
    std::fs::write(&selected, "id\n7\n").unwrap();
    let connection = DuckdbDriver
        .connect(ConnectOptions {
            database: selected.to_string_lossy().into_owned(),
            read_only: true,
            ..ConnectOptions::default()
        })
        .await
        .unwrap();
    let view = quote_ident(&derive_view_name(selected.to_str().unwrap()));
    assert_eq!(
        connection.query(&format!("SELECT id FROM {view}")).await.unwrap().rows,
        vec![vec![Value::Int(7)]]
    );

    std::fs::rename(&selected, &moved).unwrap();
    std::fs::write(&selected, "id\n99\n").unwrap();
    assert_eq!(
        connection.query(&format!("SELECT id FROM {view}")).await.unwrap().rows,
        vec![vec![Value::Int(7)]]
    );

    let replaced_path = escape_duckdb_literal(selected.to_str().unwrap());
    assert!(
        connection
            .query(&format!("SELECT id FROM read_csv('{replaced_path}')"))
            .await
            .is_err()
    );
}

#[cfg(target_os = "linux")]
#[test]
fn a_read_only_flat_file_connection_refuses_a_fifo_without_blocking() {
    use std::{process::Command, sync::mpsc, time::Duration};

    let dir = tempfile::tempdir().unwrap();
    let fifo = dir.path().join("pipe.csv");
    let status = Command::new("mkfifo").arg(&fifo).status().unwrap();
    assert!(status.success());

    let path = fifo.to_string_lossy().into_owned();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let result = runtime.block_on(DuckdbDriver.connect(ConnectOptions {
            database: path,
            read_only: true,
            ..ConnectOptions::default()
        }));
        let _ = sender.send(result.is_err());
    });

    let refused = receiver
        .recv_timeout(Duration::from_secs(2))
        .expect("FIFO detection must finish without waiting for a writer");
    assert!(refused, "a FIFO is not a regular data file");
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_read_only_flat_file_connection_accepts_a_symlink_to_the_selected_file() {
    use std::os::unix::fs::symlink;

    let dir = tempfile::tempdir().unwrap();
    let selected = dir.path().join("selected.csv");
    let alias = dir.path().join("alias.csv");
    std::fs::write(&selected, "id\n7\n").unwrap();
    symlink(&selected, &alias).unwrap();
    let connection = DuckdbDriver
        .connect(ConnectOptions {
            database: alias.to_string_lossy().into_owned(),
            read_only: true,
            ..ConnectOptions::default()
        })
        .await
        .unwrap();
    let view = quote_ident(&derive_view_name(alias.to_str().unwrap()));
    assert_eq!(
        connection.query(&format!("SELECT id FROM {view}")).await.unwrap().rows,
        vec![vec![Value::Int(7)]]
    );
}

#[tokio::test]
async fn a_read_only_duckdb_database_disables_external_access_and_mutations() {
    let dir = tempfile::tempdir().unwrap();
    let database = dir.path().join("data.duckdb");
    let private = dir.path().join("private.txt");
    std::fs::write(&private, "sibling secret").unwrap();
    let writer = DuckdbDriver
        .connect(ConnectOptions {
            database: database.to_string_lossy().into_owned(),
            ..ConnectOptions::default()
        })
        .await
        .unwrap();
    writer.execute("CREATE TABLE items(id INTEGER)").await.unwrap();
    writer.execute("INSERT INTO items VALUES (7)").await.unwrap();
    drop(writer);

    let reader = DuckdbDriver
        .connect(ConnectOptions {
            database: database.to_string_lossy().into_owned(),
            read_only: true,
            ..ConnectOptions::default()
        })
        .await
        .unwrap();
    assert_eq!(
        reader.query("SELECT id FROM items").await.unwrap().rows,
        vec![vec![Value::Int(7)]]
    );
    assert!(reader.execute("CREATE TABLE denied(id INTEGER)").await.is_err());
    assert!(
        reader
            .query(&format!(
                "SELECT * FROM read_text('{}')",
                escape_duckdb_literal(private.to_str().unwrap())
            ))
            .await
            .is_err()
    );
    assert!(reader.execute("SET enable_external_access = true").await.is_err());
}

#[tokio::test]
async fn a_read_only_in_memory_duckdb_connection_is_refused() {
    let connection = DuckdbDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            read_only: true,
            ..ConnectOptions::default()
        })
        .await;

    assert!(connection.is_err());
}

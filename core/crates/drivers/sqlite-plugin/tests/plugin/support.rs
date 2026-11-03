use std::path::{Path, PathBuf};
use std::time::Duration;

use sqlx::Connection;
use tablepro_driver_abi::proto::{self, Request, Response, request, response};
use tablepro_driver_host::{DriverHandle, DriverLibrary, Reply};

pub const WAIT: Duration = Duration::from_secs(30);

// Cargo builds the cdylib beside the test binaries, in target/<profile>/deps.
pub fn plugin_path() -> PathBuf {
    let exe = std::env::current_exe().unwrap();
    let deps = exe.parent().unwrap();
    let name = format!(
        "{}tablepro_driver_sqlite_plugin{}",
        std::env::consts::DLL_PREFIX,
        std::env::consts::DLL_SUFFIX
    );
    [deps.join(&name), deps.parent().unwrap().join(&name)]
        .into_iter()
        .find(|path| path.exists())
        .unwrap_or_else(|| panic!("{name} was not built beside {}", deps.display()))
}

pub fn load_dynamic() -> DriverHandle {
    let library = DriverLibrary::load(&plugin_path()).unwrap();
    assert_eq!(library.identity().id, "sqlite");
    assert_eq!(library.identity().version, env!("CARGO_PKG_VERSION"));
    library.open().unwrap()
}

pub fn load_static() -> DriverHandle {
    tablepro_driver_host::open_static::<tablepro_driver_sqlite_plugin::Driver>("sqlite").unwrap()
}

pub async fn people_database(folder: &Path) -> PathBuf {
    let path = folder.join("people.sqlite");
    let url = format!("sqlite://{}?mode=rwc", path.display());
    let mut connection = sqlx::SqliteConnection::connect(&url).await.unwrap();
    for statement in [
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, badge BLOB)",
        "INSERT INTO people VALUES (1, 'Ada', 9.5, x'0102'), (2, 'Linus', 7.25, NULL), (3, 'Grace', NULL, NULL)",
        "CREATE VIEW top_people AS SELECT name FROM people WHERE score > 8",
    ] {
        sqlx::query(statement).execute(&mut connection).await.unwrap();
    }
    connection.close().await.unwrap();
    path
}

pub async fn call(handle: &DriverHandle, kind: request::Kind) -> Reply {
    tokio::time::timeout(WAIT, handle.call(&Request::of(kind)))
        .await
        .expect("the driver answered in time")
        .expect("the driver took the call")
}

pub fn error_code(response: &Response) -> &str {
    match &response.kind {
        Some(response::Kind::Error(error)) => error.codes.first().map_or("", String::as_str),
        _ => "",
    }
}

pub async fn open(handle: &DriverHandle, path: &Path) -> u64 {
    let reply = call(
        handle,
        request::Kind::OpenFile(proto::OpenFile {
            path: path.display().to_string(),
            create: false,
            read_only: false,
            client_version: "test".to_owned(),
        }),
    )
    .await;
    assert_eq!(reply.status, 0, "{:?}", reply.response);
    match reply.response.kind {
        Some(response::Kind::Opened(opened)) => {
            assert!(!opened.server_version.is_empty());
            opened.connection
        }
        other => panic!("open answered {other:?}"),
    }
}

pub fn read(connection: u64, sql: &str, row_limit: u64) -> request::Kind {
    request::Kind::Read(proto::Read {
        connection,
        sql: sql.to_owned(),
        row_limit,
        timeout_ms: 0,
    })
}

// Never ends on its own: only a cancel stops it.
pub const ENDLESS: &str = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c";

// Off the runtime's workers: a driver linked in shares tokio with the test, and its shutdown blocks.
pub async fn shut_down(handle: std::sync::Arc<DriverHandle>) -> bool {
    tokio::task::spawn_blocking(move || handle.shutdown(Duration::from_secs(10)))
        .await
        .unwrap()
}

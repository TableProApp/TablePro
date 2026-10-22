use std::io::Read;
use std::path::{Path, PathBuf};

use tablepro_storage::SavedConnection;

#[derive(Debug, PartialEq, Eq)]
pub enum LaunchArgument {
    Path(PathBuf),
    Uri(String),
}

#[derive(Debug, PartialEq, Eq)]
pub struct DatabaseFile {
    pub driver_id: &'static str,
    pub path: PathBuf,
}

#[derive(Debug, PartialEq, Eq)]
pub enum OpenRejection {
    Missing(PathBuf),
    NotADatabase(PathBuf),
}

const SQLITE_MAGIC: &[u8] = b"SQLite format 3\0";
const SQLITE_EXTENSIONS: &[&str] = &["sqlite", "sqlite3", "db", "db3", "s3db"];
const DUCKDB_EXTENSIONS: &[&str] = &["duckdb", "ddb"];

pub fn classify_file(path: &Path) -> Result<DatabaseFile, OpenRejection> {
    if !path.is_file() {
        return Err(OpenRejection::Missing(path.to_path_buf()));
    }
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase)
        .unwrap_or_default();
    let mut header = [0u8; 16];
    let read = std::fs::File::open(path)
        .and_then(|mut file| file.read(&mut header))
        .map_err(|_| OpenRejection::NotADatabase(path.to_path_buf()))?;
    let header = &header[..read];
    let driver_id = if SQLITE_EXTENSIONS.contains(&extension.as_str()) && header.starts_with(SQLITE_MAGIC) {
        "sqlite"
    } else if DUCKDB_EXTENSIONS.contains(&extension.as_str()) && header.get(8..12) == Some(b"DUCK") {
        "duckdb"
    } else {
        return Err(OpenRejection::NotADatabase(path.to_path_buf()));
    };
    Ok(DatabaseFile {
        driver_id,
        path: path.to_path_buf(),
    })
}

pub fn file_connection(driver_id: &str, path: &Path) -> SavedConnection {
    let name = path.file_name().map_or_else(
        || path.display().to_string(),
        |name| name.to_string_lossy().into_owned(),
    );
    SavedConnection {
        auth_source: None,
        id: uuid::Uuid::new_v4(),
        name,
        driver_id: driver_id.to_owned(),
        host: String::new(),
        port: 0,
        socket_dir: None,
        socket_path: None,
        database: path.display().to_string(),
        username: String::new(),
        use_tls: false,
        tls_mode: Some(tablepro_core::TlsMode::Disabled),
        tls_root_cert: None,
        tls_client_cert: None,
        tls_client_key: None,
        read_only: false,
        auth_mode: tablepro_core::AuthMode::Password,
        environment: tablepro_core::Environment::Local,
        ssh: None,
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, name: &str, bytes: &[u8]) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn a_sqlite_file_is_recognised_by_extension_and_header() {
        let dir = tempfile::tempdir().unwrap();
        let mut bytes = SQLITE_MAGIC.to_vec();
        bytes.extend_from_slice(&[0; 84]);
        let path = write(dir.path(), "books.SQLite3", &bytes);
        assert_eq!(
            classify_file(&path),
            Ok(DatabaseFile {
                driver_id: "sqlite",
                path
            })
        );
    }

    #[test]
    fn a_duckdb_file_is_recognised_by_its_magic_at_offset_eight() {
        let dir = tempfile::tempdir().unwrap();
        let mut bytes = vec![0u8; 8];
        bytes.extend_from_slice(b"DUCK");
        bytes.extend_from_slice(&[0; 32]);
        let path = write(dir.path(), "shop.duckdb", &bytes);
        assert!(matches!(
            classify_file(&path),
            Ok(DatabaseFile {
                driver_id: "duckdb",
                ..
            })
        ));
    }

    #[test]
    fn a_missing_path_is_refused_not_created() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("typo.db");
        assert_eq!(classify_file(&path), Err(OpenRejection::Missing(path.clone())));
        assert!(!path.exists());
    }

    #[test]
    fn a_renamed_text_file_or_wrong_extension_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let text = write(dir.path(), "notes.db", b"just some notes, not a database");
        assert_eq!(classify_file(&text), Err(OpenRejection::NotADatabase(text.clone())));
        let mut sqlite = SQLITE_MAGIC.to_vec();
        sqlite.extend_from_slice(&[0; 84]);
        let wrong = write(dir.path(), "books.txt", &sqlite);
        assert_eq!(classify_file(&wrong), Err(OpenRejection::NotADatabase(wrong.clone())));
        let empty = write(dir.path(), "empty.db", b"");
        assert_eq!(classify_file(&empty), Err(OpenRejection::NotADatabase(empty.clone())));
    }

    #[test]
    fn the_file_record_keeps_the_path_in_database() {
        let saved = file_connection("sqlite", Path::new("/data/books.db"));
        assert_eq!(
            (saved.name.as_str(), saved.database.as_str()),
            ("books.db", "/data/books.db")
        );
        assert!(saved.host.is_empty() && saved.username.is_empty());
    }
}

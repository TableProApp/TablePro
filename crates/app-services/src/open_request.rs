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
    driver_id: &'static str,
    path: PathBuf,
    database: String,
}

impl DatabaseFile {
    pub fn driver_id(&self) -> &'static str {
        self.driver_id
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn database_path(&self) -> &str {
        &self.database
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum OpenRejection {
    Missing(PathBuf),
    NotADatabase(PathBuf),
    NonUtf8Path(PathBuf),
}

const SQLITE_MAGIC: &[u8] = b"SQLite format 3\0";
const SQLITE_EXTENSIONS: &[&str] = &["sqlite", "sqlite3", "db", "db3", "s3db"];
const DUCKDB_EXTENSIONS: &[&str] = &["duckdb", "ddb"];

pub fn classify_file(path: &Path) -> Result<DatabaseFile, OpenRejection> {
    if !path.is_file() {
        return Err(OpenRejection::Missing(path.to_path_buf()));
    }
    let database = path
        .to_str()
        .map(str::to_owned)
        .ok_or_else(|| OpenRejection::NonUtf8Path(path.to_path_buf()))?;
    let extension = path
        .extension()
        .and_then(std::ffi::OsStr::to_str)
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
        database,
    })
}

pub fn file_connection(file: &DatabaseFile) -> SavedConnection {
    let name = file
        .path
        .file_name()
        .and_then(std::ffi::OsStr::to_str)
        .map(str::to_owned)
        .unwrap_or_else(|| file.database.clone());
    SavedConnection {
        auth_source: None,
        id: uuid::Uuid::new_v4(),
        name,
        driver_id: file.driver_id.to_owned(),
        host: String::new(),
        port: 0,
        socket_dir: None,
        socket_path: None,
        database: file.database.clone(),
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
    use std::path::{Path, PathBuf};

    use super::{DatabaseFile, OpenRejection, classify_file, file_connection};

    const SQLITE_MAGIC: &[u8] = b"SQLite format 3\0";

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
                database: path.to_str().expect("UTF-8 path").to_owned(),
                path
            })
        );
    }

    #[test]
    fn a_duckdb_file_is_recognised_by_extension_and_header() {
        let dir = tempfile::tempdir().unwrap();
        let mut bytes = vec![0u8; 8];
        bytes.extend_from_slice(b"DUCK");
        bytes.extend_from_slice(&[0; 32]);
        let path = write(dir.path(), "shop.duckdb", &bytes);
        let file = classify_file(&path).expect("database file");

        assert_eq!(file.driver_id(), "duckdb");
        assert_eq!(file.path(), path);
        assert_eq!(file.database_path(), path.to_str().expect("UTF-8 path"));
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

    #[cfg(unix)]
    #[test]
    fn a_non_utf8_database_path_is_refused_instead_of_being_lossily_saved() {
        use std::ffi::OsString;
        use std::os::unix::ffi::OsStringExt;

        let dir = tempfile::tempdir().unwrap();
        let name = OsString::from_vec(vec![b'b', 0xff, b'o', b'o', b'k', b'.', b'd', b'b']);
        let path = dir.path().join(name);
        let mut bytes = SQLITE_MAGIC.to_vec();
        bytes.extend_from_slice(&[0; 84]);
        std::fs::write(&path, bytes).unwrap();

        assert_eq!(classify_file(&path), Err(OpenRejection::NonUtf8Path(path.clone())));
        assert!(path.is_file());
    }

    #[test]
    fn a_saved_file_record_keeps_its_path_and_omits_network_authentication() {
        let dir = tempfile::tempdir().unwrap();
        let mut bytes = SQLITE_MAGIC.to_vec();
        bytes.extend_from_slice(&[0; 84]);
        let path = write(dir.path(), "books.db", &bytes);
        let file = classify_file(&path).unwrap();
        let saved = file_connection(&file);

        assert_eq!(saved.name, "books.db");
        assert_eq!(saved.database, path.to_str().unwrap());
        assert!(saved.host.is_empty() && saved.username.is_empty());
        assert!(saved.ssh.is_none());
        assert!(saved.tls_root_cert.is_none() && saved.tls_client_cert.is_none() && saved.tls_client_key.is_none());
    }
}

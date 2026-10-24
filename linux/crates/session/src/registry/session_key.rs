use std::path::Path;

use tablepro_storage::SavedConnection;
use uuid::Uuid;

use super::FileIdentity;

/// What a session is keyed by, so the same database opens one window.
///
/// A file the user has also saved is keyed by the saved entry, not by
/// its path, so opening it from the file manager and from the
/// connection list land on the same session.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SessionKey {
    Saved(Uuid),
    /// The canonical file URI when there is one, else the URI the file
    /// arrived as.
    File(String),
}

impl SessionKey {
    /// Only a saved connection whose driver `is_file_driver` says opens
    /// a file can be the file: any other would log in to its server with
    /// its stored credentials.
    pub fn for_file(identity: &FileIdentity, saved: &[SavedConnection], is_file_driver: impl Fn(&str) -> bool) -> Self {
        if let Some(canonical) = identity.canonical_path.as_deref() {
            let matched = saved.iter().find(|connection| {
                is_file_driver(&connection.driver_id) && resolves_to(&connection.database, canonical)
            });
            if let Some(connection) = matched {
                return Self::Saved(connection.id);
            }
        }
        Self::File(identity.uri.clone())
    }
}

/// A saved entry names its file however the user typed it, so both
/// sides are resolved before they are compared. A relative name would
/// resolve against the directory TablePro was started in, so only an
/// absolute one names a file.
fn resolves_to(database: &str, canonical: &Path) -> bool {
    let database = Path::new(database);
    if !database.is_absolute() {
        return false;
    }
    match std::fs::canonicalize(database) {
        Ok(resolved) => resolved == canonical,
        Err(_) => database == canonical,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file_driver(id: &str) -> bool {
        id == "sqlite"
    }

    fn saved_file(database: &str) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "local".to_owned(),
            driver_id: "sqlite".to_owned(),
            host: String::new(),
            port: 0,
            database: database.to_owned(),
            username: String::new(),
            tls: tablepro_core::TlsConfig::disabled(),
            safe_mode: tablepro_core::SafeModeLevel::Off,
            external_access: tablepro_core::ExternalAccess::ReadOnly,
            ai_policy: tablepro_core::AiPolicy::Ask,
            auth_mode: tablepro_core::AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group: None,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    #[test]
    fn file_key_matches_saved_file_connection_by_canonical_path() {
        let root = tempfile::tempdir().expect("tempdir");
        let database = root.path().join("app.db");
        std::fs::write(&database, b"").expect("seed");
        let link = root.path().join("app-link.db");
        std::os::unix::fs::symlink(&database, &link).expect("symlink");
        // The saved entry names the symlink, the file manager opened the
        // target. Both have to reach the same session.
        let saved = [saved_file(&link.to_string_lossy())];
        let identity = FileIdentity::new(
            Some(std::fs::canonicalize(&database).expect("canonical")),
            format!("file://{}", database.display()),
        );

        let key = SessionKey::for_file(&identity, &saved, file_driver);

        assert_eq!(key, SessionKey::Saved(saved[0].id));
    }

    #[test]
    fn file_key_uses_canonical_uri() {
        let root = tempfile::tempdir().expect("tempdir");
        let database = root.path().join("unsaved.db");
        std::fs::write(&database, b"").expect("seed");
        let uri = format!("file://{}", database.display());
        let identity = FileIdentity::new(Some(database.clone()), uri.clone());

        let key = SessionKey::for_file(&identity, &[], file_driver);

        assert_eq!(key, SessionKey::File(uri));
    }

    #[test]
    fn a_file_that_no_longer_resolves_still_gets_a_key() {
        let identity = FileIdentity::new(None, "file:///gone/app.db".to_owned());

        let key = SessionKey::for_file(&identity, &[saved_file("/gone/app.db")], file_driver);

        assert_eq!(
            key,
            SessionKey::File("file:///gone/app.db".to_owned()),
            "an unresolvable file was matched against a saved entry by name alone"
        );
    }

    /// `tablepro shop` must not log in to a saved server whose database
    /// is named like the file, with that server's stored password.
    #[test]
    fn a_network_connection_never_matches_a_file() {
        let root = tempfile::tempdir().expect("tempdir");
        let database = std::fs::canonicalize(root.path()).expect("canonical").join("shop");
        std::fs::write(&database, b"").expect("seed");
        let mut network = saved_file(&database.to_string_lossy());
        network.driver_id = "postgres".to_owned();
        let identity = FileIdentity::new(Some(database.clone()), format!("file://{}", database.display()));

        let key = SessionKey::for_file(&identity, &[network], file_driver);

        assert!(matches!(key, SessionKey::File(_)), "{key:?}");
    }

    /// A relative name resolves against whatever directory TablePro was
    /// started in, here the crate's own, so it never names the file.
    #[test]
    fn a_relative_database_never_matches_a_file() {
        let manifest = std::fs::canonicalize(concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml")).expect("canonical");
        let identity = FileIdentity::new(Some(manifest.clone()), format!("file://{}", manifest.display()));
        let mut network = saved_file("Cargo.toml");
        network.driver_id = "postgres".to_owned();

        let key = SessionKey::for_file(&identity, &[saved_file("Cargo.toml"), network], file_driver);

        assert!(matches!(key, SessionKey::File(_)), "{key:?}");
    }
}

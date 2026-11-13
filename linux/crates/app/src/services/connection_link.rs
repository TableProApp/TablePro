use gio::prelude::*;
use tablepro_core::connection_url::ConnectionUrl;
use tablepro_core::{DriverCapabilities, is_local_socket_host};
use tablepro_storage::{ConnectionStore, SavedConnection};

use super::share_link::{SHARE_LINK_SCHEME, is_share_link};

// The schemes tablepro_core::connection_url::parse reads; the desktop entry claims each one.
pub const LINK_SCHEMES: [&str; 22] = [
    "cassandra",
    "ch",
    "clickhouse",
    "cql",
    "duckdb",
    "mariadb",
    "mongodb",
    "mongodb+srv",
    "mssql",
    "mysql",
    "mysqlx",
    "postgres",
    "postgresql",
    "redis",
    "rediss",
    "scylla",
    "scylladb",
    "sqlite",
    "sqlite3",
    "sqlserver",
    "valkey",
    "valkeys",
];

// A JDBC URL wraps one of those schemes. It comes from a command line, never from a desktop link.
const JDBC_SCHEME: &str = "jdbc";

// Read from the text: a GFile a VFS rewrote can report no scheme at all.
pub fn is_link(uri: &str) -> bool {
    glib::Uri::peek_scheme(uri).is_some_and(|scheme| scheme == JDBC_SCHEME || LINK_SCHEMES.contains(&scheme.as_str()))
}

pub fn link_text(file: &gio::File) -> Option<String> {
    let uri = file.uri();
    is_link(&uri).then(|| uri.to_string())
}

// A failed gvfs daemon probe can release the local singleton, so the link callbacks own their backend.
fn link_vfs() -> Result<gio::Vfs, glib::BoolError> {
    let _default = gio::Vfs::default();
    let extension = gio::IOExtensionPoint::lookup(gio::VFS_EXTENSION_POINT_NAME)
        .and_then(|point| point.extension_by_name("local"))
        .ok_or_else(|| glib::bool_error!("GIO has no local VFS implementation"))?;
    glib::Object::with_type(extension.type_())
        .downcast::<gio::Vfs>()
        .map_err(|_| glib::bool_error!("GIO's local implementation is not a VFS"))
}

// gvfs reads these into a mount spec that drops the password and all but one MongoDB host. A share link
// keeps its text the same way, so its token reaches the app as the viewer page wrote it.
pub fn register_link_schemes() -> Result<(), glib::BoolError> {
    static REGISTERED: std::sync::OnceLock<Result<(), glib::BoolError>> = std::sync::OnceLock::new();
    REGISTERED
        .get_or_init(|| {
            let vfs = gio::Vfs::default();
            // Backend construction registers a scheme and cannot run under a lookup callback's scheme lock.
            let local = link_vfs()?;
            for scheme in LINK_SCHEMES.into_iter().chain([JDBC_SCHEME, SHARE_LINK_SCHEME]) {
                let uri_vfs = local.clone();
                let parse_vfs = local.clone();
                let registered = vfs.register_uri_scheme(
                    scheme,
                    Some(Box::new(move |_, uri| Some(uri_vfs.file_for_uri(uri)))),
                    Some(Box::new(move |_, name| {
                        (is_link(name) || is_share_link(name)).then(|| parse_vfs.file_for_uri(name))
                    })),
                );
                if !registered {
                    return Err(glib::bool_error!(
                        "GIO already has a handler for a connection link scheme"
                    ));
                }
            }
            Ok(())
        })
        .clone()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkTarget {
    pub driver_id: String,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
}

impl LinkTarget {
    // Filled as the connect dialog fills its form, so a link matches the connection that dialog saves.
    pub fn new(url: &ConnectionUrl, caps: &DriverCapabilities, desktop_user: &str) -> Self {
        if caps.is_file_based() {
            return Self {
                driver_id: url.driver_id.to_owned(),
                host: String::new(),
                port: 0,
                database: url.database.clone(),
                username: String::new(),
            };
        }
        let host = match url.host.as_str() {
            "" => caps
                .local_socket()
                .and_then(|socket| socket.defaults().first())
                .map(|path| (*path).to_owned())
                .unwrap_or_default(),
            host => host.to_owned(),
        };
        let username = match url.username.is_empty() && is_local_socket_host(&host) {
            true => desktop_user.to_owned(),
            false => url.username.clone(),
        };
        Self {
            driver_id: url.driver_id.to_owned(),
            port: url.port.or(caps.default_port()).unwrap_or(0),
            database: url.database.clone(),
            host,
            username,
        }
    }

    pub fn matches(&self, saved: &SavedConnection) -> bool {
        saved.driver_id == self.driver_id
            && same_host(&saved.host, &self.host)
            && saved.port == self.port
            && saved.database == self.database
            && saved.username == self.username
    }
}

// A host name has no case; a socket path does.
fn same_host(saved: &str, wanted: &str) -> bool {
    match is_local_socket_host(wanted) {
        true => saved == wanted,
        false => saved.eq_ignore_ascii_case(wanted),
    }
}

pub fn saved_for_link<'a>(target: &LinkTarget, saved: &'a [SavedConnection]) -> Option<&'a SavedConnection> {
    saved.iter().find(|connection| target.matches(connection))
}

// The store, not the picker's list, which may still be loading when a launch for the link gets here.
pub fn saved_for_link_blocking(target: &LinkTarget, connections: &ConnectionStore) -> Option<SavedConnection> {
    match connections.load_blocking() {
        Ok(saved) => saved_for_link(target, &saved).cloned(),
        Err(error) => {
            tracing::warn!(%error, "the saved connections could not be read to match a link against");
            None
        }
    }
}

pub fn without_password(uri: &str) -> String {
    let Some((scheme, rest)) = uri.split_once("://") else {
        return uri.to_owned();
    };
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (authority, tail) = rest.split_at(end);
    let Some((userinfo, host)) = authority.rsplit_once('@') else {
        return uri.to_owned();
    };
    let user = userinfo.split_once(':').map_or(userinfo, |(user, _)| user);
    format!("{scheme}://{user}@{host}{tail}")
}

#[cfg(test)]
mod tests {
    use tablepro_core::connection_url::{ConnectionUrlError, parse};
    use tablepro_core::{AiPolicy, AuthMode, ExternalAccess, SafeModeLevel, TlsConfig};
    use tablepro_test_support::FakeDriver;
    use uuid::Uuid;

    use super::*;

    fn saved(driver_id: &str, host: &str, port: u16, database: &str, username: &str) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "Shop".to_owned(),
            driver_id: driver_id.to_owned(),
            host: host.to_owned(),
            port,
            database: database.to_owned(),
            username: username.to_owned(),
            tls: TlsConfig::disabled(),
            safe_mode: SafeModeLevel::Off,
            external_access: ExternalAccess::default(),
            ai_policy: AiPolicy::default(),
            query_timeout_secs: None,
            masking_rules: Vec::new(),
            auth_mode: AuthMode::Password,
            ssh: None,
            last_opened_at: None,
            color: None,
            group_id: None,
            order: 0,
            tags: Vec::new(),
            icon: None,
            options: Default::default(),
        }
    }

    fn target(url: &str, caps: &DriverCapabilities) -> LinkTarget {
        LinkTarget::new(&parse(url).expect("a connection URL"), caps, "ada")
    }

    #[test]
    fn every_link_scheme_is_one_the_parser_reads() {
        for scheme in LINK_SCHEMES {
            let parsed = parse(&format!("{scheme}://db.example.com/0"));
            assert!(
                !matches!(parsed, Err(ConnectionUrlError::UnknownScheme { .. })),
                "{scheme}: {parsed:?}"
            );
        }
    }

    #[test]
    fn a_scheme_the_parser_does_not_read_is_no_link() {
        assert!(matches!(
            parse("ftp://db.example.com/shop"),
            Err(ConnectionUrlError::UnknownScheme { .. })
        ));
        assert!(!is_link("ftp://db.example.com/shop"));
        assert!(!is_link("file:///home/ada/shop.db"));
        assert!(!is_link("/home/ada/shop.db"));
    }

    #[test]
    fn links_are_told_by_their_scheme_whatever_its_case() {
        assert!(is_link("postgresql://ada@db.example.com/shop"));
        assert!(is_link("PostgreSQL://ada@db.example.com/shop"));
        assert!(is_link("mongodb+srv://ada@cluster.example.com/shop"));
        assert!(is_link("sqlite:/home/ada/shop.db"));
        assert!(is_link("jdbc:sqlserver://db.example.com;databaseName=shop"));
    }

    #[test]
    fn a_link_matches_the_saved_connection_that_goes_where_it_goes() {
        let caps = &FakeDriver::NETWORK_CAPABILITIES;
        let shop = saved("postgres", "db.example.com", 5432, "shop", "ada");
        let list = [
            saved("postgres", "db.example.com", 5432, "stock", "ada"),
            saved("postgres", "db.example.com", 5432, "shop", "bob"),
            saved("postgres", "db.example.com", 6543, "shop", "ada"),
            shop.clone(),
        ];

        let found = saved_for_link(&target("postgresql://ada:secret@DB.example.com:5432/shop", caps), &list);

        assert_eq!(found.map(|connection| connection.id), Some(shop.id));
    }

    #[test]
    fn a_link_without_a_port_takes_the_engine_default() {
        let caps = &FakeDriver::NETWORK_CAPABILITIES;
        let list = [saved("postgres", "db.example.com", 1, "shop", "ada")];

        assert!(saved_for_link(&target("postgresql://ada@db.example.com/shop", caps), &list).is_some());
    }

    #[test]
    fn another_engine_never_matches() {
        let caps = &FakeDriver::NETWORK_CAPABILITIES;
        let list = [saved("mysql", "db.example.com", 5432, "shop", "ada")];

        let link = target("postgresql://ada@db.example.com:5432/shop", caps);

        assert_eq!(link.driver_id, "postgres");
        assert!(saved_for_link(&link, &list).is_none());
    }

    #[test]
    fn a_file_link_matches_the_saved_file() {
        let caps = &FakeDriver::FILE_CAPABILITIES;
        let list = [saved("sqlite", "", 0, "/home/ada/shop.db", "")];

        assert!(saved_for_link(&target("sqlite:///home/ada/shop.db", caps), &list).is_some());
        assert!(saved_for_link(&target("sqlite:///home/ada/stock.db", caps), &list).is_none());
    }

    #[test]
    fn the_password_is_taken_out_of_a_uri() {
        assert_eq!(
            without_password("sftp://ada:s3cret@files.example.com/shop.db"),
            "sftp://ada@files.example.com/shop.db"
        );
        assert_eq!(
            without_password("postgresql://ada:p@ss@db.example.com:5432/shop?sslmode=require"),
            "postgresql://ada@db.example.com:5432/shop?sslmode=require"
        );
        assert_eq!(
            without_password("redis://:pw@localhost:6379/0"),
            "redis://@localhost:6379/0"
        );
        assert_eq!(without_password("file:///home/ada/shop.db"), "file:///home/ada/shop.db");
        assert_eq!(without_password("https://example.com/a@b"), "https://example.com/a@b");
    }

    #[test]
    fn a_registered_link_keeps_its_password_and_every_host() {
        register_link_schemes().expect("register the connection links");

        for link in [
            "postgresql://ada:s3cr%40t@db.example.com:5432/app?sslmode=require",
            "mongodb://u:p@h1:27017,h2:27017,h3:27017/db?replicaSet=rs0",
            "redis://:pw@localhost:6379/0",
        ] {
            assert_eq!(gio::File::for_uri(link).uri().as_str(), link);
            assert_eq!(gio::File::for_commandline_arg(link).uri().as_str(), link);
        }
    }

    #[test]
    fn registered_links_keep_their_text_on_other_threads() {
        register_link_schemes().expect("register the connection links");
        let workers: Vec<_> = (0..4)
            .map(|_| {
                std::thread::spawn(|| {
                    register_link_schemes().expect("reuse the connection links");
                    for scheme in LINK_SCHEMES.into_iter().chain([JDBC_SCHEME]) {
                        let link = format!("{scheme}://ada:p%40ss@first:1234,second:5678/shop?key=value");
                        assert_eq!(gio::File::for_uri(&link).uri().as_str(), link);
                        assert_eq!(gio::File::for_parse_name(&link).uri().as_str(), link);
                    }
                })
            })
            .collect();
        for worker in workers {
            worker.join().expect("link lookups on a worker");
        }
    }

    #[test]
    fn parse_names_still_work_once_the_links_are_registered() {
        register_link_schemes().expect("register the connection links");

        let file = gio::File::for_parse_name("/home/ada/shop.db");

        assert_eq!(file.path().as_deref(), Some(std::path::Path::new("/home/ada/shop.db")));
        assert_eq!(
            gio::File::for_parse_name("postgresql://ada@h/db").uri().as_str(),
            "postgresql://ada@h/db"
        );
    }
}

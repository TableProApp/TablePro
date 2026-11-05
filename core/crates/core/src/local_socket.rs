use std::path::{Path, PathBuf};

// A host that is an absolute path names a server's Unix-domain socket, as libpq reads one.
pub fn is_local_socket_host(host: &str) -> bool {
    host.starts_with('/')
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LocalSocket {
    // libpq: the host is the folder, and the port picks `<folder>/<file_prefix><port>` in it.
    Folder {
        file_prefix: &'static str,
        defaults: &'static [&'static str],
    },
    // The mysql client's `--socket`: the host is the socket file, and the port is not read.
    File {
        defaults: &'static [&'static str],
    },
}

impl LocalSocket {
    pub fn socket_file(&self, host: &Path, port: u16) -> PathBuf {
        match self {
            Self::Folder { file_prefix, .. } => host.join(format!("{file_prefix}{port}")),
            Self::File { .. } => host.to_path_buf(),
        }
    }

    pub fn reads_port(&self) -> bool {
        matches!(self, Self::Folder { .. })
    }

    // libpq ignores sslmode on a socket and the server answers N; MySQL speaks TLS there as over TCP.
    pub fn takes_tls(&self) -> bool {
        matches!(self, Self::File { .. })
    }

    pub fn defaults(&self) -> &'static [&'static str] {
        match self {
            Self::Folder { defaults, .. } | Self::File { defaults } => defaults,
        }
    }

    // Stats the disk: call it off the UI thread.
    pub fn find_default(&self, port: u16) -> Option<PathBuf> {
        self.first_listening(self.defaults().iter().map(Path::new), port)
    }

    fn first_listening<'a>(&self, hosts: impl IntoIterator<Item = &'a Path>, port: u16) -> Option<PathBuf> {
        hosts
            .into_iter()
            .find(|host| is_socket(&self.socket_file(host, port)))
            .map(Path::to_path_buf)
    }
}

#[cfg(unix)]
fn is_socket(path: &Path) -> bool {
    use std::os::unix::fs::FileTypeExt;
    std::fs::metadata(path).is_ok_and(|metadata| metadata.file_type().is_socket())
}

// No engine here listens on a Unix-domain socket on Windows.
#[cfg(not(unix))]
fn is_socket(_path: &Path) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    const POSTGRES: LocalSocket = LocalSocket::Folder {
        file_prefix: ".s.PGSQL.",
        defaults: &["/run/postgresql", "/tmp"],
    };
    const MYSQL: LocalSocket = LocalSocket::File {
        defaults: &["/run/mysqld/mysqld.sock"],
    };

    #[test]
    fn a_folder_names_the_file_after_the_port_and_a_file_is_itself() {
        assert_eq!(
            POSTGRES.socket_file(Path::new("/run/postgresql"), 5433),
            PathBuf::from("/run/postgresql/.s.PGSQL.5433")
        );
        assert_eq!(
            MYSQL.socket_file(Path::new("/run/mysqld/mysqld.sock"), 3306),
            PathBuf::from("/run/mysqld/mysqld.sock")
        );
        assert!(POSTGRES.reads_port());
        assert!(!MYSQL.reads_port());
        assert!(!POSTGRES.takes_tls());
        assert!(MYSQL.takes_tls());
    }

    #[test]
    fn only_an_absolute_path_is_a_socket_host() {
        assert!(is_local_socket_host("/var/run/postgresql"));
        assert!(!is_local_socket_host("localhost"));
        assert!(!is_local_socket_host("relative/dir"));
        assert!(!is_local_socket_host(""));
    }

    #[cfg(unix)]
    #[test]
    fn the_default_is_the_first_place_a_socket_listens() {
        let dir = std::env::temp_dir().join(format!("tablepro-local-socket-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join(".s.PGSQL.6000");
        let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let places = [Path::new("/nonexistent/tablepro"), dir.as_path()];

        assert_eq!(POSTGRES.first_listening(places, 6000), Some(dir.clone()));
        assert_eq!(POSTGRES.first_listening(places, 6001), None);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

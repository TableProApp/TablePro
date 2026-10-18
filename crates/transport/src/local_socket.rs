use std::os::unix::fs::FileTypeExt;

use tablepro_core::{ConnectOptions, DatabaseDriver, TlsMode};

use crate::TransportError;

pub(super) fn validate_local_socket(
    opts: &ConnectOptions,
    driver: &dyn DatabaseDriver,
    has_ssh: bool,
) -> Result<(), TransportError> {
    if opts.forwarded_socket_dir.is_some() && (opts.local_socket_dir.is_some() || opts.local_socket_path.is_some()) {
        return invalid("a local endpoint cannot be combined with an SSH-forwarded socket");
    }
    if let Some(path) = opts.local_socket_path.as_deref() {
        return validate_socket_file(path, driver, has_ssh, opts.tls.mode);
    }
    let Some(directory) = opts.local_socket_dir.as_deref() else {
        return Ok(());
    };
    validate_postgres_socket_directory(directory, opts, driver, has_ssh)
}

fn validate_socket_file(
    path: &std::path::Path,
    driver: &dyn DatabaseDriver,
    has_ssh: bool,
    tls_mode: TlsMode,
) -> Result<(), TransportError> {
    check_local_endpoint(driver.supports_local_socket_file(), driver, has_ssh, tls_mode)?;
    if !path.is_absolute() {
        return invalid(format!("socket path must be absolute: {}", path.display()));
    }
    let metadata = std::fs::metadata(path).map_err(|error| {
        TransportError::InvalidLocalSocket(format!("cannot access socket path {}: {error}", path.display()))
    })?;
    if !metadata.file_type().is_socket() {
        return invalid(format!("socket path is not a Unix socket: {}", path.display()));
    }
    Ok(())
}

fn validate_postgres_socket_directory(
    directory: &std::path::Path,
    opts: &ConnectOptions,
    driver: &dyn DatabaseDriver,
    has_ssh: bool,
) -> Result<(), TransportError> {
    check_local_endpoint(driver.supports_local_socket_directory(), driver, has_ssh, opts.tls.mode)?;
    if opts.port == 0 {
        return invalid("PostgreSQL socket port must be greater than zero");
    }
    if !directory.is_absolute() {
        return invalid(format!("socket directory must be absolute: {}", directory.display()));
    }
    let metadata = std::fs::metadata(directory).map_err(|error| {
        TransportError::InvalidLocalSocket(format!(
            "cannot access socket directory {}: {error}",
            directory.display()
        ))
    })?;
    if !metadata.is_dir() {
        return invalid(format!("socket path is not a directory: {}", directory.display()));
    }
    validate_postgres_socket_file(&directory.join(format!(".s.PGSQL.{}", opts.port)))
}

fn validate_postgres_socket_file(path: &std::path::Path) -> Result<(), TransportError> {
    let metadata = std::fs::metadata(path).map_err(|error| {
        TransportError::InvalidLocalSocket(format!("cannot access PostgreSQL socket {}: {error}", path.display()))
    })?;
    if !metadata.file_type().is_socket() {
        return invalid(format!("PostgreSQL socket path is not a socket: {}", path.display()));
    }
    Ok(())
}

fn check_local_endpoint(
    supported: bool,
    driver: &dyn DatabaseDriver,
    has_ssh: bool,
    tls_mode: TlsMode,
) -> Result<(), TransportError> {
    if !supported {
        return Err(TransportError::LocalSocketUnsupported(
            driver.display_name().to_string(),
        ));
    }
    if has_ssh {
        return Err(TransportError::LocalSocketWithSsh);
    }
    if tls_mode != TlsMode::Disabled {
        return Err(TransportError::LocalSocketWithTls);
    }
    Ok(())
}

fn invalid(message: impl Into<String>) -> Result<(), TransportError> {
    Err(TransportError::InvalidLocalSocket(message.into()))
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixListener;

    use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, DriverError, TlsConfig, TlsMode};

    use super::validate_local_socket;
    use crate::TransportError;

    struct FileSocketOnlyDriver;

    #[async_trait::async_trait]
    impl DatabaseDriver for FileSocketOnlyDriver {
        fn id(&self) -> &'static str {
            "file-socket"
        }
        fn display_name(&self) -> &'static str {
            "File socket"
        }
        fn default_port(&self) -> u16 {
            3306
        }
        fn supports_local_socket(&self) -> bool {
            true
        }
        fn supports_local_socket_file(&self) -> bool {
            true
        }
        async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            Err(DriverError::Unsupported("test driver".into()))
        }
    }

    #[test]
    fn a_driver_that_only_supports_a_socket_file_refuses_a_socket_directory() {
        let directory = tempfile::tempdir().unwrap();
        let _listener = UnixListener::bind(directory.path().join(".s.PGSQL.3306")).unwrap();
        let opts = ConnectOptions {
            host: "localhost".into(),
            port: 3306,
            local_socket_dir: Some(directory.path().to_path_buf()),
            ..Default::default()
        };

        assert!(matches!(
            validate_local_socket(&opts, &FileSocketOnlyDriver, false),
            Err(TransportError::LocalSocketUnsupported(_))
        ));
    }

    struct SocketDriver;

    #[async_trait::async_trait]
    impl DatabaseDriver for SocketDriver {
        fn id(&self) -> &'static str {
            "socket"
        }
        fn display_name(&self) -> &'static str {
            "Socket"
        }
        fn default_port(&self) -> u16 {
            5432
        }
        fn supports_local_socket(&self) -> bool {
            true
        }
        fn supports_local_socket_file(&self) -> bool {
            true
        }
        fn supports_local_socket_directory(&self) -> bool {
            true
        }
        async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            Err(DriverError::Unsupported("test driver".into()))
        }
    }

    fn directory_opts(directory: &std::path::Path, port: u16) -> ConnectOptions {
        ConnectOptions {
            host: "localhost".into(),
            port,
            local_socket_dir: Some(directory.to_path_buf()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        }
    }

    #[test]
    fn a_postgres_socket_in_the_directory_is_accepted() {
        let directory = tempfile::tempdir().unwrap();
        let _listener = UnixListener::bind(directory.path().join(".s.PGSQL.5432")).unwrap();
        assert!(validate_local_socket(&directory_opts(directory.path(), 5432), &SocketDriver, false).is_ok());
    }

    #[test]
    fn a_directory_without_the_postgres_socket_for_that_port_is_refused() {
        let directory = tempfile::tempdir().unwrap();
        let _listener = UnixListener::bind(directory.path().join(".s.PGSQL.5432")).unwrap();
        assert!(matches!(
            validate_local_socket(&directory_opts(directory.path(), 5433), &SocketDriver, false),
            Err(TransportError::InvalidLocalSocket(_))
        ));
    }

    #[test]
    fn a_zero_port_is_refused_before_the_socket_is_looked_up() {
        let directory = tempfile::tempdir().unwrap();
        let error = validate_local_socket(&directory_opts(directory.path(), 0), &SocketDriver, false)
            .expect_err("port zero is never a socket");
        assert!(error.to_string().contains("greater than zero"), "{error}");
    }

    #[test]
    fn a_relative_socket_directory_is_refused() {
        let error = validate_local_socket(
            &directory_opts(std::path::Path::new("relative"), 5432),
            &SocketDriver,
            false,
        )
        .expect_err("relative directories are refused");
        assert!(error.to_string().contains("must be absolute"), "{error}");
    }

    #[test]
    fn a_missing_socket_directory_is_reported_as_inaccessible() {
        let directory = tempfile::tempdir().unwrap();
        let missing = directory.path().join("missing");
        let error = validate_local_socket(&directory_opts(&missing, 5432), &SocketDriver, false)
            .expect_err("a missing directory cannot hold a socket");
        assert!(error.to_string().contains("cannot access socket directory"), "{error}");
    }

    #[test]
    fn a_regular_file_in_place_of_the_directory_is_refused() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("not-a-directory");
        std::fs::write(&file, b"").unwrap();
        let error = validate_local_socket(&directory_opts(&file, 5432), &SocketDriver, false)
            .expect_err("a file is not a socket directory");
        assert!(error.to_string().contains("is not a directory"), "{error}");
    }

    #[test]
    fn a_regular_file_where_the_postgres_socket_belongs_is_refused() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join(".s.PGSQL.5432"), b"").unwrap();
        let error = validate_local_socket(&directory_opts(directory.path(), 5432), &SocketDriver, false)
            .expect_err("a regular file is not a socket");
        assert!(error.to_string().contains("is not a socket"), "{error}");
    }

    #[test]
    fn a_socket_over_ssh_or_with_tls_is_refused() {
        let directory = tempfile::tempdir().unwrap();
        let _listener = UnixListener::bind(directory.path().join(".s.PGSQL.5432")).unwrap();
        let opts = directory_opts(directory.path(), 5432);
        assert!(matches!(
            validate_local_socket(&opts, &SocketDriver, true),
            Err(TransportError::LocalSocketWithSsh)
        ));
        let mut with_tls = directory_opts(directory.path(), 5432);
        with_tls.tls = TlsConfig {
            mode: TlsMode::VerifyFull,
            ..TlsConfig::disabled()
        };
        assert!(matches!(
            validate_local_socket(&with_tls, &SocketDriver, false),
            Err(TransportError::LocalSocketWithTls)
        ));
    }

    #[test]
    fn a_forwarded_socket_cannot_be_combined_with_a_local_directory_or_path() {
        let directory = tempfile::tempdir().unwrap();
        let mut both = directory_opts(directory.path(), 5432);
        both.forwarded_socket_dir = Some(directory.path().to_path_buf());
        assert!(matches!(
            validate_local_socket(&both, &SocketDriver, false),
            Err(TransportError::InvalidLocalSocket(_))
        ));
        let with_path = ConnectOptions {
            local_socket_path: Some(directory.path().join("socket")),
            forwarded_socket_dir: Some(directory.path().to_path_buf()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        };
        let combined = validate_local_socket(&with_path, &SocketDriver, false)
            .expect_err("a forwarded socket cannot be combined with a local path");
        assert!(combined.to_string().contains("cannot be combined"), "{combined}");
    }

    #[test]
    fn a_socket_file_path_is_accepted_only_when_it_is_an_absolute_socket() {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("app.sock");
        let _listener = UnixListener::bind(&socket).unwrap();
        let opts = |path: std::path::PathBuf| ConnectOptions {
            host: "localhost".into(),
            port: 5432,
            local_socket_path: Some(path),
            tls: TlsConfig::disabled(),
            ..Default::default()
        };
        assert!(validate_local_socket(&opts(socket.clone()), &SocketDriver, false).is_ok());
        let relative = validate_local_socket(&opts(std::path::PathBuf::from("app.sock")), &SocketDriver, false)
            .expect_err("a relative socket file is refused");
        assert!(relative.to_string().contains("must be absolute"), "{relative}");
        let file = directory.path().join("plain");
        std::fs::write(&file, b"").unwrap();
        let not_socket =
            validate_local_socket(&opts(file), &SocketDriver, false).expect_err("a regular file is not a socket");
        assert!(not_socket.to_string().contains("is not a Unix socket"), "{not_socket}");
    }
}

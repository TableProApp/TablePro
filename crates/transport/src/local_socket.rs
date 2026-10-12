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
    check_local_endpoint(driver.supports_local_socket(), driver, has_ssh, opts.tls.mode)?;
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

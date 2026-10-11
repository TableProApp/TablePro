use secrecy::SecretString;
use std::os::unix::fs::FileTypeExt;
use std::sync::Arc;
use std::time::Duration;
use tablepro_core::Environment;
use tablepro_core::{AuthMode, ConnectOptions, Connection, DatabaseDriver, DriverError, TlsConfig, TlsMode};
use tablepro_policy::{
    AuditErrorCategory, AuditEvent, AuditSink, AuditState, AuditTerminalStatus, AuditTransportClient,
    AuditTransportOutcome, Principal,
};
use tablepro_ssh::{SshAuth, SshConfig, SshTunnel};
use tablepro_storage::{
    SavedConnection, SavedSshAuth, SavedSshConfig, SshClient, load_password, load_ssh_passphrase, load_ssh_password,
};
use uuid::Uuid;

mod route;
mod session_material;

pub use route::{OpenSshEnvironment, SshEnvironment, SshRoute, Tunnel, openssh_config_for, system_openssh};
pub use session_material::session_material_digest;

const DATABASE_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone)]
pub struct TransportAuditContext {
    pub sink: Arc<dyn AuditSink>,
    pub state: Arc<AuditState>,
    pub principal: Principal,
    pub connection_id: Uuid,
    pub connection_name: String,
    pub environment: Environment,
    pub driver_id: String,
}

#[derive(Clone)]
pub struct TransportAuditFactory {
    sink: Arc<dyn AuditSink>,
    state: Arc<AuditState>,
}

impl TransportAuditFactory {
    pub fn new(sink: Arc<dyn AuditSink>, state: Arc<AuditState>) -> Self {
        Self { sink, state }
    }

    pub fn context(
        &self,
        principal: Principal,
        connection_id: Uuid,
        connection_name: impl Into<String>,
        environment: Environment,
        driver_id: impl Into<String>,
    ) -> TransportAuditContext {
        TransportAuditContext::new(
            self.sink.clone(),
            self.state.clone(),
            principal,
            connection_id,
            connection_name,
            environment,
            driver_id,
        )
    }
}

impl TransportAuditContext {
    pub fn new(
        sink: Arc<dyn AuditSink>,
        state: Arc<AuditState>,
        principal: Principal,
        connection_id: Uuid,
        connection_name: impl Into<String>,
        environment: Environment,
        driver_id: impl Into<String>,
    ) -> Self {
        Self {
            sink,
            state,
            principal,
            connection_id,
            connection_name: connection_name.into(),
            environment,
            driver_id: driver_id.into(),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("ssh: {0}")]
    Ssh(String),
    #[error("ssh host-key trust was refused: {0}")]
    HostKeyRefused(String),
    #[error("ssh host key changed: {0}")]
    HostKeyChanged(String),
    #[error("ssh host key is revoked: {0}")]
    HostKeyRevoked(String),
    #[error("ssh operation timed out: {0}")]
    SshTimeout(String),
    #[error("ssh operation was cancelled")]
    Cancelled,
    #[error("transport audit could not be persisted: {0}")]
    AuditWriteFailed(String),
    #[error(
        "the system OpenSSH client is not available inside the Flatpak sandbox; switch this connection to the built-in SSH client"
    )]
    SystemSshUnavailableInSandbox,
    #[error("{0}")]
    Secret(String),
    #[error("{0}")]
    Keyring(tablepro_storage::KeyringFailure),
    #[error("integrated authentication is not supported by the {0} driver")]
    IntegratedAuthUnsupported(String),
    #[error("local Unix sockets are not supported by the {0} driver")]
    LocalSocketUnsupported(String),
    #[error("a local Unix socket cannot be combined with SSH tunnelling")]
    LocalSocketWithSsh,
    #[error("TLS must be disabled for a local Unix socket")]
    LocalSocketWithTls,
    #[error("invalid local Unix socket: {0}")]
    InvalidLocalSocket(String),
    #[error("database connection timed out after {seconds} seconds")]
    DatabaseTimeout { seconds: u64 },
    #[error(transparent)]
    Driver(#[from] DriverError),
}

/// Choose the process-wide rustls crypto provider.
///
/// The static drivers pull in both `ring` (MySQL, SQL Server, MongoDB) and
/// `aws-lc-rs` (ClickHouse), which leaves rustls unable to pick a default on
/// its own. Any library that builds a `ClientConfig` without naming a provider
/// then panics at connect time. Every composition root, including test
/// binaries that link more than one driver, must call this before connecting.
/// Calling it more than once is harmless: the first call wins.
pub fn install_crypto_provider() {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
}

pub fn tls_config(mode: TlsMode) -> TlsConfig {
    TlsConfig {
        mode,
        ..Default::default()
    }
}

pub async fn connect_options_for(saved: &SavedConnection) -> Result<ConnectOptions, TransportError> {
    let password = if loads_database_password(saved) {
        load_password(saved.id)
            .await
            .map_err(|error| secret_error("load database password", error))?
            .unwrap_or_else(|| SecretString::new(String::new().into()))
    } else {
        SecretString::new(String::new().into())
    };
    Ok(ConnectOptions {
        host: saved.host.clone(),
        port: saved.port,
        database: saved.database.clone(),
        username: saved.username.clone(),
        password,
        tls: TlsConfig {
            mode: saved.effective_tls_mode(),
            root_cert: saved.tls_root_cert.clone(),
            client_cert: saved.tls_client_cert.clone(),
            client_key: saved.tls_client_key.clone(),
            ..Default::default()
        },
        auth_mode: saved.auth_mode,
        service_endpoint: None,
        local_socket_dir: saved.socket_dir.clone(),
        forwarded_socket_dir: None,
        application_name: None,
        connect_timeout_secs: saved.connect_timeout_secs,
        read_only: saved.read_only,
    })
}

pub async fn saved_ssh_route(saved: &SavedConnection) -> Result<Option<SshRoute>, TransportError> {
    saved_ssh_route_with_sandbox_override(saved, None).await
}

async fn saved_ssh_route_with_sandbox_override(
    saved: &SavedConnection,
    sandboxed: Option<bool>,
) -> Result<Option<SshRoute>, TransportError> {
    let Some(ssh) = &saved.ssh else {
        return Ok(None);
    };
    match ssh.client {
        SshClient::Builtin => resolve_saved_ssh_chain(saved.id, ssh)
            .await
            .map(|hops| Some(SshRoute::Builtin(hops))),
        SshClient::OpenSsh => {
            let config = match sandboxed {
                Some(sandboxed) => route::openssh_config_in_sandbox(saved.id, ssh, sandboxed).await,
                None => route::openssh_config(saved.id, ssh).await,
            }?;
            Ok(Some(SshRoute::OpenSsh(config)))
        }
    }
}

pub async fn establish(
    driver: &dyn DatabaseDriver,
    opts: ConnectOptions,
    ssh: Option<SshRoute>,
    environment: &SshEnvironment,
) -> Result<(Box<dyn Connection>, Option<Tunnel>), TransportError> {
    establish_with_cancellation(
        driver,
        opts,
        ssh,
        environment,
        tokio_util::sync::CancellationToken::new(),
    )
    .await
}

pub async fn establish_with_cancellation(
    driver: &dyn DatabaseDriver,
    opts: ConnectOptions,
    ssh: Option<SshRoute>,
    environment: &SshEnvironment,
    cancellation: tokio_util::sync::CancellationToken,
) -> Result<(Box<dyn Connection>, Option<Tunnel>), TransportError> {
    let client = match ssh.as_ref() {
        Some(SshRoute::Builtin(_)) => Some(AuditTransportClient::BuiltinSsh),
        Some(SshRoute::OpenSsh(_)) => Some(AuditTransportClient::SystemOpenSsh),
        None => None,
    };
    let started = std::time::Instant::now();
    let result = tokio::select! {
        biased;
        () = cancellation.cancelled() => Err(TransportError::Cancelled),
        result = establish_inner(driver, opts, ssh, environment, cancellation.clone()) => result,
    };
    if let (Some(client), Some(context)) = (client, environment.audit.as_ref()) {
        let (outcome, status, category) = classify_transport_result(&result);
        let event = AuditEvent::transport_attempt(
            Uuid::new_v4(),
            context.principal.clone(),
            context.connection_id,
            context.connection_name.clone(),
            context.environment,
            context.driver_id.clone(),
            client,
            outcome,
            status,
            category,
            started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64,
        );
        if let Err(error) = context.sink.record(event).await {
            context.state.disable_after_audit_failure();
            drop(result);
            return Err(TransportError::AuditWriteFailed(error.to_string()));
        }
    }
    result
}

fn classify_transport_result(
    result: &Result<(Box<dyn Connection>, Option<Tunnel>), TransportError>,
) -> (AuditTransportOutcome, AuditTerminalStatus, Option<AuditErrorCategory>) {
    use AuditTerminalStatus as Status;
    use AuditTransportOutcome as Outcome;
    match result {
        Ok(_) => (Outcome::Connected, Status::Succeeded, None),
        Err(TransportError::HostKeyRefused(_)) => (
            Outcome::HostKeyRefused,
            Status::Denied,
            Some(AuditErrorCategory::Authentication),
        ),
        Err(TransportError::HostKeyChanged(_)) => (
            Outcome::HostKeyChanged,
            Status::Denied,
            Some(AuditErrorCategory::Authentication),
        ),
        Err(TransportError::HostKeyRevoked(_)) => (
            Outcome::HostKeyRevoked,
            Status::Denied,
            Some(AuditErrorCategory::Authentication),
        ),
        Err(TransportError::Cancelled) => (
            Outcome::Cancelled,
            Status::Cancelled,
            Some(AuditErrorCategory::Cancelled),
        ),
        Err(TransportError::SshTimeout(_) | TransportError::DatabaseTimeout { .. }) => {
            (Outcome::TimedOut, Status::TimedOut, Some(AuditErrorCategory::Timeout))
        }
        Err(TransportError::Driver(DriverError::Tls(_))) => {
            (Outcome::TlsFailed, Status::Failed, Some(AuditErrorCategory::Tls))
        }
        Err(TransportError::Driver(DriverError::AuthFailed)) => (
            Outcome::AuthenticationFailed,
            Status::Failed,
            Some(AuditErrorCategory::Authentication),
        ),
        Err(_) => (
            Outcome::ConnectionFailed,
            Status::Failed,
            Some(AuditErrorCategory::Connection),
        ),
    }
}

async fn establish_inner(
    driver: &dyn DatabaseDriver,
    mut opts: ConnectOptions,
    ssh: Option<SshRoute>,
    environment: &SshEnvironment,
    cancellation: tokio_util::sync::CancellationToken,
) -> Result<(Box<dyn Connection>, Option<Tunnel>), TransportError> {
    check_auth_mode(opts.auth_mode, driver.supports_integrated_auth(), driver.display_name())?;
    validate_client_tls_auth(driver, &opts)?;
    validate_local_socket(&opts, driver, ssh.is_some())?;
    opts.forwarded_socket_dir = None;
    let tunnel = match ssh {
        Some(route) => Some(open_tunnel(driver, &mut opts, route, environment, cancellation).await?),
        None => None,
    };
    let timeout = connect_timeout(&opts);
    let raw = connect_with_timeout(driver, opts, timeout).await?;
    Ok((raw, tunnel))
}

fn validate_client_tls_auth(driver: &dyn DatabaseDriver, opts: &ConnectOptions) -> Result<(), TransportError> {
    let (Some(cert), Some(key)) = (&opts.tls.client_cert, &opts.tls.client_key) else {
        if opts.tls.client_cert.is_none() && opts.tls.client_key.is_none() {
            return Ok(());
        }
        return Err(DriverError::Unsupported(
            "TLS client authentication requires both a certificate and a private key".into(),
        )
        .into());
    };
    if !driver.supports_client_tls_auth() {
        return Err(DriverError::Unsupported(format!(
            "{} does not support TLS client authentication",
            driver.display_name()
        ))
        .into());
    }
    if matches!(opts.tls.mode, TlsMode::Disabled | TlsMode::Prefer) {
        return Err(DriverError::Unsupported(
            "TLS client authentication requires a TLS mode that cannot fall back to plaintext".into(),
        )
        .into());
    }
    for path in [cert, key] {
        let file = std::fs::File::open(path)
            .map_err(|_| DriverError::Unsupported("TLS client certificate or key file cannot be opened".into()))?;
        let metadata = file
            .metadata()
            .map_err(|_| DriverError::Unsupported("TLS client certificate or key file cannot be inspected".into()))?;
        if !metadata.is_file() || metadata.len() > 1024 * 1024 {
            return Err(DriverError::Unsupported(
                "TLS client certificate and key must be regular files no larger than 1 MiB".into(),
            )
            .into());
        }
    }
    Ok(())
}

fn connect_timeout(opts: &ConnectOptions) -> Duration {
    opts.connect_timeout_secs
        .filter(|seconds| *seconds > 0)
        .map_or(DATABASE_CONNECT_TIMEOUT, |seconds| {
            Duration::from_secs(u64::from(seconds))
        })
}

async fn open_tunnel(
    driver: &dyn DatabaseDriver,
    opts: &mut ConnectOptions,
    route: SshRoute,
    environment: &SshEnvironment,
    cancellation: tokio_util::sync::CancellationToken,
) -> Result<Tunnel, TransportError> {
    let remote = (std::mem::take(&mut opts.host), opts.port);
    let socket_name = forwarded_socket_name(driver, opts.tls.mode, remote.1);
    let tunnel = match route {
        SshRoute::Builtin(hops) => Tunnel::Builtin(open_builtin(&hops, &remote, socket_name, environment).await?),
        SshRoute::OpenSsh(config) => Tunnel::OpenSsh(
            route::open_openssh(&config, environment, (&remote.0, remote.1), socket_name, cancellation).await?,
        ),
    };
    match (&tunnel, tunnel.socket_dir()) {
        (_, Some(directory)) => forward_through_socket(opts, remote, directory.to_path_buf()),
        (Tunnel::Builtin(tun), None) => {
            redirect_through_tunnel(opts, remote, (tun.local_host().to_string(), tun.local_port()))
        }
        (Tunnel::OpenSsh(forward), None) => match forward.local_endpoint() {
            tablepro_ssh::openssh::LocalEndpoint::Tcp(address) => {
                redirect_through_tunnel(opts, remote, (address.ip().to_string(), address.port()))
            }
            tablepro_ssh::openssh::LocalEndpoint::Unix(_) => {
                return Err(TransportError::Ssh("the forwarded socket has no directory".into()));
            }
        },
    }
    Ok(tunnel)
}

async fn open_builtin(
    hops: &[SshConfig],
    remote: &(String, u16),
    socket_name: Option<String>,
    environment: &SshEnvironment,
) -> Result<SshTunnel, TransportError> {
    if hops.is_empty() {
        return Err(TransportError::Ssh("jump chain is empty".into()));
    }
    let unknown = environment.unknown_host_key;
    match (&socket_name, &environment.builtin_prompter) {
        (Some(name), Some(prompter)) => {
            SshTunnel::open_chain_socket_prompted(hops, remote.0.clone(), remote.1, name, unknown, prompter.clone())
                .await
        }
        (None, Some(prompter)) => {
            SshTunnel::open_chain_prompted(hops, remote.0.clone(), remote.1, unknown, prompter.clone()).await
        }
        (Some(name), None) => SshTunnel::open_chain_socket(hops, remote.0.clone(), remote.1, name, unknown).await,
        (None, None) => SshTunnel::open_chain(hops, remote.0.clone(), remote.1, unknown).await,
    }
    .map_err(|error| match error {
        error @ tablepro_ssh::SshError::UnknownHostKey { .. } => TransportError::HostKeyRefused(error.to_string()),
        error @ tablepro_ssh::SshError::HostKeyMismatch { .. } => TransportError::HostKeyChanged(error.to_string()),
        error @ tablepro_ssh::SshError::Timeout { .. } => TransportError::SshTimeout(error.to_string()),
        error => TransportError::Ssh(error.to_string()),
    })
}

async fn connect_with_timeout(
    driver: &dyn DatabaseDriver,
    opts: ConnectOptions,
    timeout: Duration,
) -> Result<Box<dyn Connection>, TransportError> {
    tokio::time::timeout(timeout, driver.connect(opts))
        .await
        .map_err(|_| TransportError::DatabaseTimeout {
            seconds: timeout.as_secs(),
        })?
        .map_err(TransportError::Driver)
}

fn validate_local_socket(
    opts: &ConnectOptions,
    driver: &dyn DatabaseDriver,
    has_ssh: bool,
) -> Result<(), TransportError> {
    let Some(directory) = opts.local_socket_dir.as_deref() else {
        return Ok(());
    };
    if !driver.supports_local_socket() {
        return Err(TransportError::LocalSocketUnsupported(
            driver.display_name().to_string(),
        ));
    }
    if has_ssh {
        return Err(TransportError::LocalSocketWithSsh);
    }
    if opts.tls.mode != TlsMode::Disabled {
        return Err(TransportError::LocalSocketWithTls);
    }
    if opts.port == 0 {
        return Err(TransportError::InvalidLocalSocket(
            "PostgreSQL socket port must be greater than zero".into(),
        ));
    }
    if !directory.is_absolute() {
        return Err(TransportError::InvalidLocalSocket(format!(
            "socket directory must be absolute: {}",
            directory.display()
        )));
    }
    let metadata = std::fs::metadata(directory).map_err(|error| {
        TransportError::InvalidLocalSocket(format!(
            "cannot access socket directory {}: {error}",
            directory.display()
        ))
    })?;
    if !metadata.is_dir() {
        return Err(TransportError::InvalidLocalSocket(format!(
            "socket path is not a directory: {}",
            directory.display()
        )));
    }
    let socket = directory.join(format!(".s.PGSQL.{}", opts.port));
    match std::fs::metadata(&socket) {
        Ok(metadata) if metadata.file_type().is_socket() => {}
        Ok(_) => {
            return Err(TransportError::InvalidLocalSocket(format!(
                "PostgreSQL socket path is not a socket: {}",
                socket.display()
            )));
        }
        Err(error) => {
            return Err(TransportError::InvalidLocalSocket(format!(
                "cannot access PostgreSQL socket {}: {error}",
                socket.display()
            )));
        }
    }
    Ok(())
}

fn redirect_through_tunnel(opts: &mut ConnectOptions, service_endpoint: (String, u16), dial_endpoint: (String, u16)) {
    opts.service_endpoint = Some(service_endpoint);
    opts.host = dial_endpoint.0;
    opts.port = dial_endpoint.1;
    opts.forwarded_socket_dir = None;
}

fn forward_through_socket(opts: &mut ConnectOptions, service_endpoint: (String, u16), directory: std::path::PathBuf) {
    opts.host = service_endpoint.0.clone();
    opts.port = service_endpoint.1;
    opts.service_endpoint = Some(service_endpoint);
    opts.forwarded_socket_dir = Some(directory);
}

fn forwarded_socket_name(driver: &dyn DatabaseDriver, tls_mode: TlsMode, service_port: u16) -> Option<String> {
    if !tls_mode.verifies_cert() {
        return None;
    }
    driver.forwarded_socket_name(service_port)
}

fn check_auth_mode(mode: AuthMode, supports_integrated_auth: bool, driver_name: &str) -> Result<(), TransportError> {
    if mode == AuthMode::Kerberos && !supports_integrated_auth {
        return Err(TransportError::IntegratedAuthUnsupported(driver_name.to_string()));
    }
    Ok(())
}

fn jump_hop_password_refused(hop_index: usize) -> TransportError {
    TransportError::Secret(format!(
        "jump hop {hop_index} uses password auth, but only hop 0 can \
         (edit connections.json jump auth to use a private key for this hop)"
    ))
}

fn loads_database_password(saved: &SavedConnection) -> bool {
    saved.auth_mode == AuthMode::Password && !matches!(saved.driver_id.as_str(), "sqlite" | "duckdb")
}

async fn resolve_saved_ssh_chain(id: Uuid, saved: &SavedSshConfig) -> Result<Vec<SshConfig>, TransportError> {
    let hops = saved.flatten_hops();
    let mut out = Vec::with_capacity(hops.len());
    for (index, hop) in hops.into_iter().enumerate() {
        out.push(resolve_saved_ssh_hop(id, hop, index).await?);
    }
    Ok(out)
}

pub(crate) async fn resolve_saved_ssh_hop(
    id: Uuid,
    saved: &SavedSshConfig,
    hop_index: usize,
) -> Result<SshConfig, TransportError> {
    let auth = match &saved.auth {
        _ if saved.agent => SshAuth::Agent,
        SavedSshAuth::Password if saved.credential_revision == 0 && hop_index > 0 => {
            return Err(jump_hop_password_refused(hop_index));
        }
        SavedSshAuth::Password => SshAuth::Password {
            password: saved_ssh_password(id, saved, hop_index).await?,
        },
        SavedSshAuth::PrivateKey { path, has_passphrase } => SshAuth::PrivateKey {
            path: path.clone(),
            passphrase: saved_ssh_passphrase(id, saved, hop_index, *has_passphrase).await?,
        },
    };
    Ok(SshConfig {
        host: saved.host.clone(),
        port: saved.port,
        username: saved.username.clone(),
        auth,
    })
}

pub(crate) fn secret_error(context: &str, error: tablepro_storage::StorageError) -> TransportError {
    match error {
        tablepro_storage::StorageError::Keyring(failure) => TransportError::Keyring(failure),
        other => TransportError::Secret(format!("{context}: {other}")),
    }
}

async fn saved_ssh_password(id: Uuid, hop: &SavedSshConfig, hop_index: usize) -> Result<SecretString, TransportError> {
    let password = if hop.credential_revision == 0 {
        load_ssh_password(id)
            .await
            .map_err(|e| secret_error("load ssh password", e))?
    } else {
        tablepro_storage::load_ssh_hop_password(id, hop.hop_id, hop.credential_revision)
            .await
            .map_err(|e| secret_error("load ssh hop password", e))?
    };
    password.ok_or_else(|| TransportError::Secret(format!("ssh password for hop {hop_index} not in keyring")))
}

async fn saved_ssh_passphrase(
    id: Uuid,
    hop: &SavedSshConfig,
    hop_index: usize,
    has_passphrase: bool,
) -> Result<Option<SecretString>, TransportError> {
    if !has_passphrase {
        return Ok(None);
    }
    if hop.credential_revision == 0 {
        if hop_index > 0 {
            return Err(TransportError::Secret(format!(
                "legacy SSH passphrase cannot be assigned to jump hop {hop_index}"
            )));
        }
        return load_ssh_passphrase(id)
            .await
            .map_err(|e| secret_error("load ssh passphrase", e));
    }
    tablepro_storage::load_ssh_hop_passphrase(id, hop.hop_id, hop.credential_revision)
        .await
        .map_err(|e| secret_error("load ssh hop passphrase", e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct RecordingAudit(std::sync::Mutex<Vec<AuditEvent>>);

    #[async_trait::async_trait]
    impl AuditSink for RecordingAudit {
        async fn record(&self, event: AuditEvent) -> Result<(), tablepro_policy::AuditError> {
            self.0.lock().expect("audit events").push(event);
            Ok(())
        }
    }

    struct FailingAudit;

    #[async_trait::async_trait]
    impl AuditSink for FailingAudit {
        async fn record(&self, _event: AuditEvent) -> Result<(), tablepro_policy::AuditError> {
            Err(tablepro_policy::AuditError::Persistence("disk full".into()))
        }
    }

    fn audit_environment(sink: Arc<dyn AuditSink>, state: Arc<AuditState>) -> SshEnvironment {
        SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Refuse).with_audit(TransportAuditContext::new(
            sink,
            state,
            Principal::Agent {
                token: "secret-agent-token".into(),
                client: None,
                model: None,
            },
            Uuid::new_v4(),
            "test connection",
            Environment::Local,
            "postgres",
        ))
    }

    fn saved_ssh_connection(client: SshClient) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: "sandbox routing test".into(),
            driver_id: "postgres".into(),
            host: "db.example".into(),
            port: 5432,
            socket_dir: None,
            database: "db".into(),
            username: "user".into(),
            use_tls: false,
            tls_mode: None,
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            auth_mode: AuthMode::Password,
            read_only: false,
            environment: Environment::Local,
            ssh: Some(SavedSshConfig {
                hop_id: Uuid::new_v4(),
                credential_revision: 0,
                host: "bastion.example".into(),
                port: 22,
                username: "user".into(),
                auth: SavedSshAuth::Password,
                jump: None,
                client,
                agent: false,
            }),
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }

    #[tokio::test]
    async fn saved_system_openssh_refuses_deterministically_in_flatpak_without_fallback() {
        let saved = saved_ssh_connection(SshClient::OpenSsh);
        assert!(matches!(
            saved_ssh_route_with_sandbox_override(&saved, Some(true)).await,
            Err(TransportError::SystemSshUnavailableInSandbox)
        ));

        let mut builtin = saved.clone();
        let builtin_ssh = builtin.ssh.as_mut().expect("ssh config");
        builtin_ssh.client = SshClient::Builtin;
        builtin_ssh.agent = true;
        assert!(matches!(
            saved_ssh_route_with_sandbox_override(&builtin, Some(true)).await,
            Ok(Some(SshRoute::Builtin(_)))
        ));

        let mut native = builtin;
        native.ssh.as_mut().expect("ssh config").client = SshClient::OpenSsh;
        assert!(matches!(
            saved_ssh_route_with_sandbox_override(&native, Some(false)).await,
            Ok(Some(SshRoute::OpenSsh(_)))
        ));
    }

    #[tokio::test]
    async fn cancelled_ssh_attempt_writes_one_terminal_redacted_record() {
        let sink = Arc::new(RecordingAudit::default());
        let state = Arc::new(AuditState::new());
        let environment = audit_environment(sink.clone(), state);
        let cancellation = tokio_util::sync::CancellationToken::new();
        cancellation.cancel();
        let result = establish_with_cancellation(
            &HangingDriver,
            ConnectOptions::default(),
            Some(SshRoute::Builtin(Vec::new())),
            &environment,
            cancellation,
        )
        .await;
        assert!(matches!(result, Err(TransportError::Cancelled)));
        let events = sink.0.lock().expect("audit events");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].phase, tablepro_policy::AuditRecordPhase::Outcome);
        assert_eq!(events[0].terminal_status, AuditTerminalStatus::Cancelled);
        assert_eq!(
            events[0].transport_attempt.unwrap().client,
            AuditTransportClient::BuiltinSsh
        );
        match &events[0].principal {
            Principal::Agent { token, .. } => assert!(!token.contains("secret-agent-token")),
            Principal::Human { .. } => panic!("agent principal expected"),
        }
    }

    #[tokio::test]
    async fn audit_persistence_failure_fails_closed_and_returns_no_connection() {
        let state = Arc::new(AuditState::new());
        let environment = audit_environment(Arc::new(FailingAudit), state.clone());
        let cancellation = tokio_util::sync::CancellationToken::new();
        cancellation.cancel();
        let result = establish_with_cancellation(
            &HangingDriver,
            ConnectOptions::default(),
            Some(SshRoute::Builtin(Vec::new())),
            &environment,
            cancellation,
        )
        .await;
        assert!(matches!(result, Err(TransportError::AuditWriteFailed(_))));
        assert!(state.governed_writes_disabled());
    }

    #[test]
    fn a_saved_connect_timeout_replaces_the_default_and_zero_keeps_it() {
        let mut opts = ConnectOptions::default();
        assert_eq!(connect_timeout(&opts), DATABASE_CONNECT_TIMEOUT);
        opts.connect_timeout_secs = Some(0);
        assert_eq!(connect_timeout(&opts), DATABASE_CONNECT_TIMEOUT);
        opts.connect_timeout_secs = Some(5);
        assert_eq!(connect_timeout(&opts), Duration::from_secs(5));
    }

    struct HangingDriver;

    #[async_trait::async_trait]
    impl DatabaseDriver for HangingDriver {
        fn id(&self) -> &'static str {
            "hanging"
        }

        fn display_name(&self) -> &'static str {
            "Hanging"
        }

        fn default_port(&self) -> u16 {
            1
        }

        async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            std::future::pending().await
        }
    }

    #[test]
    fn tunnel_uses_local_dial_endpoint_and_keeps_service_identity() {
        let mut opts = ConnectOptions {
            host: "sql.corp.example".into(),
            port: 1433,
            ..Default::default()
        };

        redirect_through_tunnel(
            &mut opts,
            ("sql.corp.example".into(), 1433),
            ("127.0.0.1".into(), 54321),
        );

        assert_eq!(opts.host, "127.0.0.1");
        assert_eq!(opts.port, 54321);
        assert_eq!(opts.service_address(), ("sql.corp.example", 1433));
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
        fn forwarded_socket_name(&self, service_port: u16) -> Option<String> {
            Some(format!(".s.PGSQL.{service_port}"))
        }
        fn supports_local_socket(&self) -> bool {
            true
        }
        async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            Err(DriverError::Unsupported("test driver".into()))
        }
    }

    struct TcpOnlyDriver;

    #[async_trait::async_trait]
    impl DatabaseDriver for TcpOnlyDriver {
        fn id(&self) -> &'static str {
            "tcp-only"
        }
        fn display_name(&self) -> &'static str {
            "TCP only"
        }
        fn default_port(&self) -> u16 {
            3306
        }
        async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
            Err(DriverError::Unsupported("test driver".into()))
        }
    }

    #[test]
    fn socket_forwarding_applies_only_when_the_mode_verifies_certificates() {
        assert_eq!(
            forwarded_socket_name(&SocketDriver, TlsMode::VerifyFull, 5432).as_deref(),
            Some(".s.PGSQL.5432")
        );
        assert_eq!(
            forwarded_socket_name(&SocketDriver, TlsMode::VerifyCa, 5432).as_deref(),
            Some(".s.PGSQL.5432")
        );
        assert!(forwarded_socket_name(&SocketDriver, TlsMode::Require, 5432).is_none());
        assert!(forwarded_socket_name(&SocketDriver, TlsMode::Disabled, 5432).is_none());
        assert!(forwarded_socket_name(&TcpOnlyDriver, TlsMode::VerifyFull, 3306).is_none());
    }

    #[test]
    fn local_socket_validation_is_fail_closed() {
        let dir = tempfile::tempdir().unwrap();
        let mut opts = ConnectOptions {
            host: "localhost".into(),
            port: 5432,
            local_socket_dir: Some(dir.path().to_path_buf()),
            ..Default::default()
        };

        assert!(matches!(
            validate_local_socket(&opts, &TcpOnlyDriver, false),
            Err(TransportError::LocalSocketUnsupported(_))
        ));
        assert!(matches!(
            validate_local_socket(&opts, &SocketDriver, true),
            Err(TransportError::LocalSocketWithSsh)
        ));

        opts.tls = tls_config(TlsMode::VerifyFull);
        assert!(matches!(
            validate_local_socket(&opts, &SocketDriver, false),
            Err(TransportError::LocalSocketWithTls)
        ));
        opts.tls = tls_config(TlsMode::Disabled);
        assert!(matches!(
            validate_local_socket(&opts, &SocketDriver, false),
            Err(TransportError::InvalidLocalSocket(_))
        ));
        opts.port = 0;
        assert!(matches!(
            validate_local_socket(&opts, &SocketDriver, false),
            Err(TransportError::InvalidLocalSocket(_))
        ));
        opts.port = 5432;
        opts.local_socket_dir = Some(std::path::PathBuf::from("relative"));
        assert!(matches!(
            validate_local_socket(&opts, &SocketDriver, false),
            Err(TransportError::InvalidLocalSocket(_))
        ));
    }

    #[test]
    fn socket_forwarding_keeps_the_service_hostname_for_tls() {
        let mut opts = ConnectOptions {
            host: String::new(),
            port: 5432,
            tls: tls_config(TlsMode::VerifyFull),
            ..Default::default()
        };

        forward_through_socket(
            &mut opts,
            ("db.corp.example".into(), 5432),
            std::path::PathBuf::from("/run/user/1000/tablepro-ssh-abc"),
        );

        assert_eq!(opts.service_address(), ("db.corp.example", 5432));
        assert_eq!(
            opts.transport(),
            tablepro_core::Transport::Socket {
                directory: std::path::Path::new("/run/user/1000/tablepro-ssh-abc"),
                identity_host: "db.corp.example",
                identity_port: 5432,
                origin: tablepro_core::SocketOrigin::Forwarded,
            }
        );
    }

    #[test]
    fn tcp_forwarding_clears_any_earlier_socket_directory() {
        let mut opts = ConnectOptions {
            host: "db.corp.example".into(),
            port: 5432,
            forwarded_socket_dir: Some(std::path::PathBuf::from("/run/user/1000/stale")),
            ..Default::default()
        };

        redirect_through_tunnel(&mut opts, ("db.corp.example".into(), 5432), ("127.0.0.1".into(), 54321));

        assert!(opts.forwarded_socket_dir.is_none());
        assert_eq!(
            opts.transport(),
            tablepro_core::Transport::Tcp {
                host: "127.0.0.1",
                port: 54321
            }
        );
    }

    #[tokio::test]
    async fn establish_never_reuses_a_socket_directory_from_an_earlier_attempt() {
        let opts = ConnectOptions {
            host: "db.corp.example".into(),
            port: 5432,
            forwarded_socket_dir: Some(std::path::PathBuf::from("/run/user/1000/removed")),
            ..Default::default()
        };

        let error = establish(
            &SocketDriver,
            opts,
            None,
            &SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
        )
        .await
        .err()
        .expect("test driver refuses to connect");

        assert!(error.to_string().contains("test driver"), "unexpected error: {error}");
    }

    #[tokio::test]
    async fn database_connection_attempt_is_bounded() {
        let error = connect_with_timeout(&HangingDriver, ConnectOptions::default(), Duration::from_millis(1))
            .await
            .err()
            .expect("hanging connection must time out");

        assert!(matches!(error, TransportError::DatabaseTimeout { .. }));
    }

    #[test]
    fn kerberos_requires_driver_support() {
        assert!(check_auth_mode(AuthMode::Kerberos, false, "PostgreSQL").is_err());
        assert!(check_auth_mode(AuthMode::Kerberos, true, "SQL Server").is_ok());
        assert!(check_auth_mode(AuthMode::Password, false, "PostgreSQL").is_ok());
    }

    fn key_hop(host: &str) -> SavedSshConfig {
        SavedSshConfig {
            hop_id: Uuid::new_v4(),
            credential_revision: 0,
            host: host.into(),
            port: 22,
            username: "svc".into(),
            auth: SavedSshAuth::PrivateKey {
                path: "/home/svc/.ssh/id_ed25519".into(),
                has_passphrase: false,
            },
            jump: None,
            client: Default::default(),
            agent: false,
        }
    }

    #[tokio::test]
    async fn a_jump_hop_cannot_use_password_auth() {
        let bastion = SavedSshConfig {
            jump: Some(Box::new(SavedSshConfig {
                auth: SavedSshAuth::Password,
                ..key_hop("jump2.partner")
            })),
            ..key_hop("bastion.corp")
        };

        let error = resolve_saved_ssh_chain(Uuid::new_v4(), &bastion)
            .await
            .expect_err("a jump hop with password auth must be refused");

        let message = error.to_string();
        assert!(message.contains("hop 1"), "unexpected error: {message}");
        assert!(
            !message.contains("not in keyring"),
            "must fail before ever touching the keyring: {message}"
        );
    }

    #[tokio::test]
    async fn a_multi_hop_key_only_chain_still_resolves() {
        let bastion = SavedSshConfig {
            jump: Some(Box::new(key_hop("jump2.partner"))),
            ..key_hop("bastion.corp")
        };

        let chain = resolve_saved_ssh_chain(Uuid::new_v4(), &bastion)
            .await
            .expect("a chain with only key-based hops must resolve");

        assert_eq!(chain.len(), 2);
        assert_eq!(chain[0].host, "bastion.corp");
        assert_eq!(chain[1].host, "jump2.partner");
    }

    #[tokio::test]
    #[ignore = "requires a running Secret Service; scripts/test-secret-service.sh provides one"]
    async fn hop_zero_password_auth_still_works() {
        let bastion = SavedSshConfig {
            auth: SavedSshAuth::Password,
            jump: Some(Box::new(key_hop("jump2.partner"))),
            ..key_hop("bastion.corp")
        };

        let error = resolve_saved_ssh_chain(Uuid::new_v4(), &bastion).await.unwrap_err();
        assert!(
            error.to_string().contains("not in keyring"),
            "hop 0 password auth must still reach the keyring lookup: {error}"
        );
    }

    #[tokio::test]
    #[ignore = "requires a running Secret Service; scripts/test-secret-service.sh provides one"]
    async fn password_auth_uses_the_secret_bound_to_each_hop() {
        let connection_id = Uuid::new_v4();
        let root_secret = Uuid::new_v4().to_string();
        let jump_secret = Uuid::new_v4().to_string();
        let root = SavedSshConfig {
            hop_id: Uuid::new_v4(),
            credential_revision: 1,
            auth: SavedSshAuth::Password,
            jump: Some(Box::new(SavedSshConfig {
                hop_id: Uuid::new_v4(),
                credential_revision: 1,
                auth: SavedSshAuth::Password,
                ..key_hop("jump.example")
            })),
            ..key_hop("root.example")
        };
        let hops = root.flatten_hops();
        tablepro_storage::store_ssh_hop_password(
            connection_id,
            hops[0].hop_id,
            hops[0].credential_revision,
            &root_secret,
            "BookiE test root SSH password",
        )
        .await
        .unwrap();
        tablepro_storage::store_ssh_hop_password(
            connection_id,
            hops[1].hop_id,
            hops[1].credential_revision,
            &jump_secret,
            "BookiE test jump SSH password",
        )
        .await
        .unwrap();

        let resolved = resolve_saved_ssh_chain(connection_id, &root).await.unwrap();
        let secrets = resolved
            .iter()
            .map(|hop| match &hop.auth {
                SshAuth::Password { password } => secrecy::ExposeSecret::expose_secret(password).to_owned(),
                _ => panic!("expected password auth"),
            })
            .collect::<Vec<_>>();

        for hop in hops {
            tablepro_storage::delete_ssh_hop_password(connection_id, hop.hop_id, hop.credential_revision)
                .await
                .unwrap();
        }
        assert_eq!(secrets, [root_secret, jump_secret]);
    }

    #[path = "ssh_passphrase_tests.rs"]
    mod ssh_passphrase_tests;

    #[tokio::test]
    #[ignore = "requires a running Secret Service; scripts/test-secret-service.sh provides one"]
    async fn legacy_jump_key_passphrase_is_refused_before_keyring_access() {
        let connection_id = Uuid::new_v4();
        tablepro_storage::store_ssh_passphrase(connection_id, "root-passphrase", "BookiE test legacy SSH passphrase")
            .await
            .unwrap();
        let bastion = SavedSshConfig {
            jump: Some(Box::new(SavedSshConfig {
                auth: SavedSshAuth::PrivateKey {
                    path: "/unused/jump-key".into(),
                    has_passphrase: true,
                },
                ..key_hop("jump.example")
            })),
            ..key_hop("root.example")
        };

        let error = resolve_saved_ssh_chain(connection_id, &bastion)
            .await
            .expect_err("legacy root passphrase must not be reused for a jump key");
        tablepro_storage::delete_ssh_passphrase(connection_id).await.unwrap();

        let message = error.to_string();
        assert!(message.contains("hop 1"), "unexpected error: {message}");
        assert!(
            !message.contains("keyring"),
            "must refuse before keyring access: {message}"
        );
    }
}

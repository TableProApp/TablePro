use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use secrecy::{ExposeSecret, SecretString};
use tablepro_core::{
    APPLICATION_NAME, Credentials, DriverError, LivenessPolicy, LossPhase, NetworkEndpoint, NetworkTarget,
    TimeoutPhase, TlsMode, Transport, TransportError,
};
use tiberius::error::Error;
use tiberius::{AuthMethod, Client, Config};
use tokio_util::compat::TokioAsyncWriteCompatExt;
use tokio_util::sync::CancellationToken;

use crate::physical::{MssqlClient, MssqlLink, MssqlStream};
use crate::probe;
use crate::tls_config::{TlsPlan, hung_up};
use crate::transport_io::{ReadTally, TransportIo};

/// Who the login says it is.
#[derive(Debug, Clone)]
enum LoginCredentials {
    Password {
        username: String,
        password: SecretString,
    },
    /// The Kerberos ticket the user already holds, or on Windows the
    /// account they signed in with.
    #[cfg(any(all(unix, feature = "kerberos"), windows))]
    Integrated,
}

/// Everything one target's logins share.
#[derive(Debug, Clone)]
pub(crate) struct LoginPlan {
    service: NetworkEndpoint,
    database: Option<String>,
    credentials: LoginCredentials,
    tls: TlsPlan,
    connect_timeout: Duration,
    login_timeout: Duration,
}

/// How one login attempt ended.
#[derive(Debug)]
pub(crate) enum Attempted {
    /// The server sent the login elsewhere, as an Azure gateway or an
    /// availability group listener does.
    Routed {
        host: String,
        port: u16,
    },
    Failed(DriverError),
}

impl LoginPlan {
    pub(crate) fn new(target: &NetworkTarget, liveness: &LivenessPolicy) -> Result<Self, DriverError> {
        let credentials = match &target.credentials {
            Credentials::Password { username, password } => LoginCredentials::Password {
                username: username.clone(),
                password: password.clone(),
            },
            #[cfg(any(all(unix, feature = "kerberos"), windows))]
            Credentials::Integrated => LoginCredentials::Integrated,
            #[cfg(not(any(all(unix, feature = "kerberos"), windows)))]
            Credentials::Integrated => {
                return Err(DriverError::Config(tablepro_core::ConfigError::AuthModeUnsupported));
            }
        };
        Ok(Self {
            service: target.transport.service_endpoint().clone(),
            database: target.database.clone().filter(|name| !name.is_empty()),
            credentials,
            tls: TlsPlan::new(&target.tls)?,
            connect_timeout: liveness.connect_timeout,
            login_timeout: liveness.login_timeout,
        })
    }

    /// The configuration of a login to `host`, which names the server for
    /// the certificate check and the Kerberos SPN; the socket itself
    /// comes from the transport.
    pub(crate) fn config(&self, host: &str, port: u16) -> Config {
        let mut config = Config::new();
        config.host(server_host(host));
        config.port(port);
        if let Some(database) = &self.database {
            config.database(database);
        }
        config.application_name(APPLICATION_NAME);
        config.authentication(self.auth_method());
        // The default bounds every response by 30 seconds and abandons
        // the connection when one takes longer, which an editor query
        // may well do. Calls are bounded by their own deadlines instead.
        config.command_timeout(None);
        // Ends a Kerberos login still running on a blocking thread after
        // the caller has given up on it.
        config.handshake_timeout(Some(self.login_timeout));
        self.tls.apply(&mut config);
        config
    }

    fn auth_method(&self) -> AuthMethod {
        match &self.credentials {
            LoginCredentials::Password { username, password } => {
                AuthMethod::sql_server(username, password.expose_secret())
            }
            #[cfg(any(all(unix, feature = "kerberos"), windows))]
            LoginCredentials::Integrated => AuthMethod::Integrated,
        }
    }

    fn login_error(&self, error: Error) -> DriverError {
        #[cfg(windows)]
        if self.integrated()
            && let Some(detail) = sspi_failure(&error)
        {
            return DriverError::IntegratedAuth(detail);
        }
        self.tls.login_error(error)
    }

    /// Whether a server that hung up on the login without a byte answers
    /// the other way to begin one, asked on a stream of its own with no
    /// credential sent. A transient drop answers neither.
    async fn takes_the_other_opening(&self, transport: &dyn Transport) -> bool {
        match self.tls.mode() {
            TlsMode::Strict => probe::answers_prelogin(transport, self.login_timeout).await,
            TlsMode::Disable | TlsMode::Require | TlsMode::VerifyFull => {
                let host = server_host(transport.service_endpoint().host());
                probe::answers_strict_hello(transport, self.tls.server_name(host), self.login_timeout).await
            }
        }
    }

    fn integrated(&self) -> bool {
        match &self.credentials {
            LoginCredentials::Password { .. } => false,
            #[cfg(any(all(unix, feature = "kerberos"), windows))]
            LoginCredentials::Integrated => true,
        }
    }
}

/// winauth hands SSPI's failures to tiberius as I/O errors: its own as
/// `Other`, and SSPI's `SECURITY_STATUS`, a negative HRESULT, as a raw OS
/// error. Windows' own error codes are positive.
#[cfg(windows)]
fn sspi_failure(error: &Error) -> Option<String> {
    use tiberius::error::IoErrorKind;

    match error {
        Error::Io { kind, message } if *kind == IoErrorKind::Other || message.contains("(os error -") => {
            Some(message.clone())
        }
        Error::Protocol(text) if text.contains("NTLM") => Some(text.to_string()),
        _ => None,
    }
}

/// `.` is SQL Server shorthand for the local machine, and it means
/// nothing to a certificate or a resolver.
fn server_host(host: &str) -> &str {
    if host == "." { "localhost" } else { host }
}

/// Log in over a stream from the transport, following one reroute.
/// `cancel` abandons the login wherever it is.
pub(crate) async fn login(
    plan: &LoginPlan,
    transport: Arc<dyn Transport>,
    cancel: &CancellationToken,
) -> Result<MssqlLink, DriverError> {
    let logging_in = follow_routing(plan, transport, |config, transport| attempt(plan, config, transport));
    tokio::select! {
        biased;
        () = cancel.cancelled() => Err(DriverError::Cancelled),
        done = logging_in => done,
    }
}

/// Run `attempt` against the service, and once more against wherever
/// the server routes it. A second routing answer is refused: a gateway
/// that keeps redirecting would otherwise loop forever.
pub(crate) async fn follow_routing<T, F, Fut>(
    plan: &LoginPlan,
    transport: Arc<dyn Transport>,
    mut attempt: F,
) -> Result<T, DriverError>
where
    F: FnMut(Config, Arc<dyn Transport>) -> Fut,
    Fut: Future<Output = Result<T, Attempted>>,
{
    let mut transport = transport;
    let mut host = plan.service.host().to_owned();
    let mut port = plan.service.port();
    let mut rerouted = false;
    loop {
        match attempt(plan.config(&host, port), transport.clone()).await {
            Ok(connected) => return Ok(connected),
            Err(Attempted::Failed(error)) => return Err(error),
            Err(Attempted::Routed {
                host: routed_host,
                port: routed_port,
            }) => {
                if rerouted {
                    return Err(DriverError::Protocol(format!(
                        "the server routed the login a second time, to {routed_host}:{routed_port}"
                    )));
                }
                rerouted = true;
                let endpoint = NetworkEndpoint::new(&routed_host, routed_port)?;
                transport = transport.reroute(endpoint).await?;
                host = routed_host;
                port = routed_port;
            }
        }
    }
}

/// One login: a stream under the connect timeout, then the TDS handshake
/// under the login timeout.
async fn attempt(plan: &LoginPlan, config: Config, transport: Arc<dyn Transport>) -> Result<MssqlLink, Attempted> {
    let stream = match tokio::time::timeout(plan.connect_timeout, transport.open()).await {
        Ok(Ok(stream)) => stream,
        Ok(Err(error)) => return Err(Attempted::Failed(DriverError::Transport(error))),
        Err(_) => {
            return Err(Attempted::Failed(DriverError::Transport(TransportError::Timeout {
                phase: TimeoutPhase::Connect,
            })));
        }
    };
    let tally = ReadTally::new();
    let io = TransportIo::new(stream, tally.clone()).compat_write();
    let connecting = connect(plan.integrated(), config, io);
    match tokio::time::timeout(plan.login_timeout, connecting).await {
        Ok(Ok(client)) => Ok(MssqlLink::new(client, tally)),
        Ok(Err(Error::Routing { host, port })) => Err(Attempted::Routed { host, port }),
        Ok(Err(error)) => match hung_up(&error).filter(|_| tally.bytes() == 0) {
            Some(detail) if plan.takes_the_other_opening(transport.as_ref()).await => {
                Err(Attempted::Failed(plan.tls.opening_refused(detail.to_owned())))
            }
            Some(_) => Err(Attempted::Failed(DriverError::ConnectionLost {
                during: LossPhase::Connect,
            })),
            None => Err(Attempted::Failed(plan.login_error(error))),
        },
        Err(_) => Err(Attempted::Failed(DriverError::Timeout {
            phase: TimeoutPhase::Login,
            server_cancelled: false,
        })),
    }
}

async fn connect(integrated: bool, config: Config, io: MssqlStream) -> Result<MssqlClient, Error> {
    #[cfg(any(all(unix, feature = "kerberos"), windows))]
    if integrated {
        return connect_off_worker(config, io).await;
    }
    #[cfg(not(any(all(unix, feature = "kerberos"), windows)))]
    let _ = integrated;
    // On the heap: the TLS handshake inside makes this future tens of
    // kilobytes, and every caller up to the pool would hold a copy in its
    // own state, which overflows a 2 MiB thread stack in a debug build.
    Box::pin(Client::connect(config, io)).await
}

/// MIT Kerberos and SSPI run as blocking FFI inside the login, which would hold
/// an async worker between polls and starve every other task on it, the
/// timers that bound this login included. The blocking pool is where a
/// blocking poll belongs.
#[cfg(any(all(unix, feature = "kerberos"), windows))]
async fn connect_off_worker(config: Config, io: MssqlStream) -> Result<MssqlClient, Error> {
    let handle = tokio::runtime::Handle::current();
    match tokio::task::spawn_blocking(move || handle.block_on(Client::connect(config, io))).await {
        Ok(connected) => connected,
        Err(ended) => Err(Error::Protocol(format!("the integrated login stopped: {ended}").into())),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use async_trait::async_trait;
    use tablepro_core::{TlsConfig, TransportKind, TransportRoute, TransportStream};

    use super::*;

    #[derive(Debug)]
    struct Recorded {
        service: NetworkEndpoint,
        reroutes: Arc<Mutex<Vec<NetworkEndpoint>>>,
    }

    #[async_trait]
    impl Transport for Recorded {
        fn service_endpoint(&self) -> &NetworkEndpoint {
            &self.service
        }

        fn kind(&self) -> TransportKind {
            TransportKind::DirectTcp
        }

        fn route(&self) -> TransportRoute {
            TransportRoute::Tcp(self.service.clone())
        }

        async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
            let (client, _server) = tokio::io::duplex(64);
            Ok(Box::new(client))
        }

        async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
            self.reroutes.lock().unwrap().push(endpoint.clone());
            Ok(Arc::new(Self {
                service: endpoint,
                reroutes: self.reroutes.clone(),
            }))
        }

        async fn explain_closed_stream(&self) -> Option<TransportError> {
            None
        }
    }

    fn target(host: &str) -> (NetworkTarget, Arc<Mutex<Vec<NetworkEndpoint>>>) {
        let reroutes = Arc::new(Mutex::new(Vec::new()));
        let transport = Recorded {
            service: NetworkEndpoint::new(host, 1433).unwrap(),
            reroutes: reroutes.clone(),
        };
        let target = NetworkTarget {
            transport: Arc::new(transport),
            credentials: Credentials::Password {
                username: "sa".to_owned(),
                password: SecretString::from("secret"),
            },
            database: Some("sales".to_owned()),
            tls: TlsConfig::verify_full(),
            options: Default::default(),
        };
        (target, reroutes)
    }

    fn plan(host: &str) -> (LoginPlan, Arc<dyn Transport>, Arc<Mutex<Vec<NetworkEndpoint>>>) {
        let (target, reroutes) = target(host);
        let plan = LoginPlan::new(&target, &LivenessPolicy::DESKTOP).unwrap();
        (plan, target.transport, reroutes)
    }

    #[tokio::test]
    async fn routing_followed_once_then_protocol_error() {
        let (plan, transport, reroutes) = plan("listener.example");
        let configs = Mutex::new(Vec::new());

        let outcome: Result<(), DriverError> = follow_routing(&plan, transport, |config, transport| {
            configs
                .lock()
                .unwrap()
                .push((config.get_addr(), transport.service_endpoint().clone()));
            async {
                Err(Attempted::Routed {
                    host: "replica.example".to_owned(),
                    port: 11000,
                })
            }
        })
        .await;

        assert!(matches!(outcome, Err(DriverError::Protocol(_))), "{outcome:?}");
        let configs = configs.into_inner().unwrap();
        assert_eq!(configs.len(), 2, "one reroute, then a refusal");
        assert_eq!(configs[0].0, "listener.example:1433");
        assert_eq!(configs[1].0, "replica.example:11000");
        assert_eq!(configs[1].1.host(), "replica.example");
        assert_eq!(reroutes.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn config_never_sets_readonly_and_uses_routed_host() {
        let (plan, transport, _) = plan("listener.example");
        let configs = Mutex::new(Vec::new());
        let mut answers = vec![
            Ok(()),
            Err(Attempted::Routed {
                host: "replica.example".to_owned(),
                port: 11000,
            }),
        ];

        let outcome = follow_routing(&plan, transport, |config, _| {
            configs.lock().unwrap().push(config);
            let answer = answers.pop().unwrap_or(Ok(()));
            async move { answer }
        })
        .await;

        assert!(outcome.is_ok());
        let configs = configs.into_inner().unwrap();
        let routed = configs.last().unwrap();
        assert_eq!(routed.get_addr(), "replica.example:11000");
        for config in &configs {
            let described = format!("{config:?}");
            assert!(described.contains("readonly: false"), "{described}");
            assert!(
                described.contains("application_name: Some(\"TablePro\")"),
                "{described}"
            );
            assert!(described.contains("database: Some(\"sales\")"), "{described}");
        }
    }

    #[test]
    fn command_timeout_disabled() {
        let (plan, _, _) = plan("db.example");
        let config = plan.config("db.example", 1433);

        assert_eq!(config.get_command_timeout(), None);
        assert_eq!(
            config.get_handshake_timeout(),
            Some(LivenessPolicy::DESKTOP.login_timeout)
        );
    }

    #[test]
    fn the_local_shorthand_names_localhost() {
        let (plan, _, _) = plan("db.example");

        assert_eq!(plan.config(".", 1433).get_addr(), "localhost:1433");
    }

    #[test]
    fn an_empty_database_name_selects_the_logins_default() {
        let (mut target, _) = target("db.example");
        target.database = Some(String::new());
        let plan = LoginPlan::new(&target, &LivenessPolicy::DESKTOP).unwrap();

        assert!(format!("{:?}", plan.config("db.example", 1433)).contains("database: None"));
    }

    #[cfg(not(any(all(unix, feature = "kerberos"), windows)))]
    #[test]
    fn kerberos_is_refused_when_built_without_the_feature() {
        let (mut target, _) = target("db.example");
        target.credentials = Credentials::Integrated;

        assert!(matches!(
            LoginPlan::new(&target, &LivenessPolicy::DESKTOP),
            Err(DriverError::Config(tablepro_core::ConfigError::AuthModeUnsupported))
        ));
    }

    #[cfg(any(all(unix, feature = "kerberos"), windows))]
    #[test]
    fn kerberos_authenticates_from_the_ticket_cache() {
        let (mut target, _) = target("db.example");
        target.credentials = Credentials::Integrated;
        let plan = LoginPlan::new(&target, &LivenessPolicy::DESKTOP).unwrap();

        assert!(plan.integrated());
        assert!(format!("{:?}", plan.config("db.example", 1433)).contains("auth: Integrated"));
    }

    #[cfg(windows)]
    #[test]
    fn an_sspi_status_fails_the_integrated_login_not_the_connection() {
        use tiberius::error::IoErrorKind;

        let (password_target, _) = target("db.example");
        let mut integrated_target = password_target.clone();
        integrated_target.credentials = Credentials::Integrated;
        let plan = LoginPlan::new(&integrated_target, &LivenessPolicy::DESKTOP).unwrap();
        let io = |kind| Error::Io {
            kind,
            message: "The logon attempt failed (os error -2146893044)".to_owned(),
        };

        assert!(matches!(
            plan.login_error(io(IoErrorKind::Other)),
            DriverError::IntegratedAuth(_)
        ));
        // SEC_E_LOGON_DENIED, as winauth returns it.
        let status = Error::from(std::io::Error::from_raw_os_error(-2146893044));
        assert!(matches!(plan.login_error(status), DriverError::IntegratedAuth(_)));
        let store = Error::Io {
            kind: IoErrorKind::NotFound,
            message: "no platform certificates and no extra CA".to_owned(),
        };
        assert!(!matches!(plan.login_error(store), DriverError::IntegratedAuth(_)));
        let reset = Error::Io {
            kind: IoErrorKind::ConnectionReset,
            message: "An existing connection was forcibly closed by the remote host. (os error 10054)".to_owned(),
        };
        assert!(matches!(plan.login_error(reset), DriverError::ConnectionLost { .. }));
        let password_plan = LoginPlan::new(&password_target, &LivenessPolicy::DESKTOP).unwrap();
        assert!(!matches!(
            password_plan.login_error(io(IoErrorKind::Other)),
            DriverError::IntegratedAuth(_)
        ));
    }
}

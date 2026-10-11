use std::borrow::Cow;
use std::collections::VecDeque;
use std::fmt;
use std::io::{self, Write};
use std::net::{self, SocketAddr, TcpStream, ToSocketAddrs};
use std::ops::DerefMut;
use std::path::PathBuf;
use std::str::{FromStr, from_utf8};
use std::time::{Duration, Instant};

use crate::cmd::{Cmd, cmd, pipe};
use crate::errors::{ErrorKind, RedisError, ServerError, ServerErrorKind};
use crate::io::tcp::{TcpSettings, stream_with_settings};
use crate::parser::Parser;
use crate::pipeline::Pipeline;
use crate::types::{
    FromRedisValue, HashMap, PushKind, RedisResult, SyncPushSender, ToRedisArgs, Value,
    from_redis_value_ref,
};
use crate::{ProtocolVersion, check_resp3, from_redis_value};

#[cfg(unix)]
use std::os::unix::net::UnixStream;

use crate::commands::resp3_hello;
use arcstr::ArcStr;
#[cfg(all(feature = "tls-native-tls", not(feature = "tls-rustls")))]
use native_tls::{TlsConnector, TlsStream};

#[cfg(feature = "tls-rustls")]
use rustls::{RootCertStore, StreamOwned};
#[cfg(feature = "tls-rustls")]
use std::sync::Arc;

use crate::PushInfo;

#[cfg(all(
    feature = "tls-rustls",
    not(feature = "tls-native-tls"),
    not(feature = "tls-rustls-webpki-roots")
))]
use rustls_native_certs::load_native_certs;

#[cfg(feature = "tls-rustls")]
use crate::tls::ClientTlsParams;

// Non-exhaustive to prevent construction outside this crate
#[derive(Clone, Debug)]
pub struct TlsConnParams {
    #[cfg(feature = "tls-rustls")]
    pub(crate) client_tls_params: Option<ClientTlsParams>,
    #[cfg(feature = "tls-rustls")]
    pub(crate) root_cert_store: Option<RootCertStore>,
    #[cfg(any(feature = "tls-rustls-insecure", feature = "tls-native-tls"))]
    pub(crate) danger_accept_invalid_hostnames: bool,
    /// Overrides the hostname used for certificate verification without
    /// changing which address the driver dials. Set when the dial address
    /// is a local forwarding endpoint, such as an SSH tunnel, but the
    /// certificate was issued for the server's real hostname.
    pub(crate) verify_host: Option<String>,
}

static DEFAULT_PORT: u16 = 6379;

/// Default library name to connect with
const DEFAULT_CLIENT_SETINFO_LIB_NAME: &str = "redis-rs";
/// Default library version to connect with
const DEFAULT_CLIENT_SETINFO_LIB_VER: &str = env!("CARGO_PKG_VERSION");

#[inline(always)]
fn connect_tcp(addr: (&str, u16), tcp_settings: &TcpSettings) -> io::Result<TcpStream> {
    let socket = TcpStream::connect(addr)?;
    stream_with_settings(socket, tcp_settings)
}

#[inline(always)]
fn connect_tcp_timeout(
    addr: &SocketAddr,
    timeout: Duration,
    tcp_settings: &TcpSettings,
) -> io::Result<TcpStream> {
    let socket = TcpStream::connect_timeout(addr, timeout)?;
    stream_with_settings(socket, tcp_settings)
}

/// This function takes a redis URL string and parses it into a URL
/// as used by rust-url.
///
/// This is necessary as the default parser does not understand how redis URLs function.
pub fn parse_redis_url(input: &str) -> Option<url::Url> {
    match url::Url::parse(input) {
        Ok(result) => match result.scheme() {
            "redis" | "rediss" | "valkey" | "valkeys" | "redis+unix" | "valkey+unix" | "unix" => {
                Some(result)
            }
            _ => None,
        },
        Err(_) => None,
    }
}

/// TlsMode indicates use or do not use verification of certification.
///
/// Check [ConnectionAddr](ConnectionAddr::TcpTls::insecure) for more.
#[derive(Clone, Copy, PartialEq)]
#[non_exhaustive]
pub enum TlsMode {
    /// Secure verify certification.
    Secure,
    /// Insecure do not verify certification.
    Insecure,
}

/// Defines the connection address.
///
/// Not all connection addresses are supported on all platforms.  For instance
/// to connect to a unix socket you need to run this on an operating system
/// that supports them.
#[derive(Clone, Debug)]
#[non_exhaustive]
pub enum ConnectionAddr {
    /// Format for this is `(host, port)`.
    Tcp(String, u16),
    /// Format for this is `(host, port)`.
    TcpTls {
        /// Hostname
        host: String,
        /// Port
        port: u16,
        /// Disable hostname verification when connecting.
        ///
        /// # Warning
        ///
        /// You should think very carefully before you use this method. If hostname
        /// verification is not used, any valid certificate for any site will be
        /// trusted for use from any other. This introduces a significant
        /// vulnerability to man-in-the-middle attacks.
        insecure: bool,

        /// TLS certificates and client key.
        tls_params: Option<TlsConnParams>,
    },
    /// Format for this is the path to the unix socket.
    Unix(PathBuf),
}

impl PartialEq for ConnectionAddr {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Tcp(host1, port1), Self::Tcp(host2, port2)) => host1 == host2 && port1 == port2,
            (
                Self::TcpTls {
                    host: host1,
                    port: port1,
                    insecure: insecure1,
                    tls_params: _,
                },
                Self::TcpTls {
                    host: host2,
                    port: port2,
                    insecure: insecure2,
                    tls_params: _,
                },
            ) => port1 == port2 && host1 == host2 && insecure1 == insecure2,
            (Self::Unix(path1), Self::Unix(path2)) => path1 == path2,
            _ => false,
        }
    }
}

impl Eq for ConnectionAddr {}

impl ConnectionAddr {
    /// Checks if this address is supported.
    ///
    /// Because not all platforms support all connection addresses this is a
    /// quick way to figure out if a connection method is supported. Currently
    /// this affects:
    ///
    /// - Unix socket addresses, which are supported only on Unix
    ///
    /// - TLS addresses, which are supported only if a TLS feature is enabled
    ///   (either `tls-native-tls` or `tls-rustls`).
    pub fn is_supported(&self) -> bool {
        match *self {
            Self::Tcp(_, _) => true,
            Self::TcpTls { .. } => {
                cfg!(any(feature = "tls-native-tls", feature = "tls-rustls"))
            }
            Self::Unix(_) => cfg!(unix),
        }
    }

    /// Configure this address to connect without checking certificate hostnames.
    ///
    /// # Warning
    ///
    /// You should think very carefully before you use this method. If hostname
    /// verification is not used, any valid certificate for any site will be
    /// trusted for use from any other. This introduces a significant
    /// vulnerability to man-in-the-middle attacks.
    #[cfg(any(feature = "tls-rustls-insecure", feature = "tls-native-tls"))]
    pub fn set_danger_accept_invalid_hostnames(&mut self, insecure: bool) {
        if let Self::TcpTls { tls_params, .. } = self {
            if let Some(params) = tls_params {
                params.danger_accept_invalid_hostnames = insecure;
            } else if insecure {
                *tls_params = Some(TlsConnParams {
                    #[cfg(feature = "tls-rustls")]
                    client_tls_params: None,
                    #[cfg(feature = "tls-rustls")]
                    root_cert_store: None,
                    danger_accept_invalid_hostnames: insecure,
                    verify_host: None,
                });
            }
        }
    }

    #[cfg(feature = "cluster")]
    pub(crate) fn tls_mode(&self) -> Option<TlsMode> {
        match self {
            Self::TcpTls { insecure, .. } => {
                if *insecure {
                    Some(TlsMode::Insecure)
                } else {
                    Some(TlsMode::Secure)
                }
            }
            _ => None,
        }
    }
}

impl fmt::Display for ConnectionAddr {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // Cluster::get_connection_info depends on the return value from this function
        match *self {
            Self::Tcp(ref host, port) | Self::TcpTls { ref host, port, .. } => {
                write!(f, "{host}:{port}")
            }
            Self::Unix(ref path) => write!(f, "{}", path.display()),
        }
    }
}

/// Holds the connection information that redis should use for connecting.
#[derive(Clone, Debug)]
pub struct ConnectionInfo {
    /// A connection address for where to connect to.
    pub(crate) addr: ConnectionAddr,

    /// The settings for the TCP connection
    pub(crate) tcp_settings: TcpSettings,
    /// A redis connection info for how to handshake with redis.
    pub(crate) redis: RedisConnectionInfo,
}

impl ConnectionInfo {
    /// Returns the connection address.
    pub fn addr(&self) -> &ConnectionAddr {
        &self.addr
    }

    /// Returns the settings for the TCP connection.
    pub fn tcp_settings(&self) -> &TcpSettings {
        &self.tcp_settings
    }

    /// Returns the redis connection info for how to handshake with redis.
    pub fn redis_settings(&self) -> &RedisConnectionInfo {
        &self.redis
    }

    /// Sets the connection address for where to connect to.
    pub fn set_addr(mut self, addr: ConnectionAddr) -> Self {
        self.addr = addr;
        self
    }

    /// Sets the TCP settings for the connection.
    pub fn set_tcp_settings(mut self, tcp_settings: TcpSettings) -> Self {
        self.tcp_settings = tcp_settings;
        self
    }

    /// Set all redis connection info fields at once.
    pub fn set_redis_settings(mut self, redis: RedisConnectionInfo) -> Self {
        self.redis = redis;
        self
    }
}

/// Redis specific/connection independent information used to establish a connection to redis.
#[derive(Clone, Default)]
pub struct RedisConnectionInfo {
    /// The database number to use.  This is usually `0`.
    pub(crate) db: i64,
    /// Optionally a username that should be used for connection.
    pub(crate) username: Option<ArcStr>,
    /// Optionally a password that should be used for connection.
    pub(crate) password: Option<ArcStr>,
    /// Version of the protocol to use.
    pub(crate) protocol: ProtocolVersion,
    /// If set, the connection shouldn't send the library name and version to the server.
    pub(crate) skip_set_lib_name: bool,
    /// Library name to send to the server after connecting (if [`Self::skip_set_lib_name`] is `false`)
    pub(crate) lib_name: Option<ArcStr>,
    /// Library name to send to the server after connecting (if [`Self::skip_set_lib_name`] is `false`)
    pub(crate) lib_ver: Option<ArcStr>,
}

impl RedisConnectionInfo {
    /// Returns the username that should be used for connection.
    pub fn username(&self) -> Option<&str> {
        self.username.as_deref()
    }

    /// Returns the password that should be used for connection.
    pub fn password(&self) -> Option<&str> {
        self.password.as_deref()
    }

    /// Returns version of the protocol to use.
    pub fn protocol(&self) -> ProtocolVersion {
        self.protocol
    }

    /// Returns `true` if the `CLIENT SETINFO` command should be skipped.
    pub fn skip_set_lib_name(&self) -> bool {
        self.skip_set_lib_name
    }

    /// Returns the set library name
    pub fn lib_name(&self) -> Option<&str> {
        self.lib_name.as_deref()
    }

    /// Returns the set library version
    pub fn lib_ver(&self) -> Option<&str> {
        self.lib_ver.as_deref()
    }

    /// Returns the database number to use.
    pub fn db(&self) -> i64 {
        self.db
    }

    /// Sets the username for the connection's ACL.
    pub fn set_username(mut self, username: impl AsRef<str>) -> Self {
        self.username = Some(username.as_ref().into());
        self
    }

    /// Sets the password for the connection's ACL.
    pub fn set_password(mut self, password: impl AsRef<str>) -> Self {
        self.password = Some(password.as_ref().into());
        self
    }

    /// Sets the version of the RESP to use.
    pub fn set_protocol(mut self, protocol: ProtocolVersion) -> Self {
        self.protocol = protocol;
        self
    }

    /// Removes the pipelined `CLIENT SETINFO` call from the connection creation.
    ///
    /// This function makes previously set [`lib_name`](Self::lib_name) and
    /// [`lib_ver`](Self::lib_ver) ineffective.
    pub fn set_skip_set_lib_name(mut self) -> Self {
        self.skip_set_lib_name = true;
        self
    }

    /// Sets the library information and enables sending it when connecting.
    ///
    /// This function clears [`skip_set_lib_name`](Self::skip_set_lib_name).
    pub fn set_lib_name(mut self, lib_name: impl AsRef<str>, lib_ver: impl AsRef<str>) -> Self {
        self.lib_name = Some(lib_name.as_ref().into());
        self.lib_ver = Some(lib_ver.as_ref().into());
        self.skip_set_lib_name = false;
        self
    }

    /// Sets the database number to use.
    pub fn set_db(mut self, db: i64) -> Self {
        self.db = db;
        self
    }
}

impl std::fmt::Debug for RedisConnectionInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self {
            db,
            username,
            password,
            protocol,
            skip_set_lib_name,
            lib_name,
            lib_ver,
        } = self;
        let mut debug_info = f.debug_struct("RedisConnectionInfo");

        debug_info.field("db", &db);
        debug_info.field("username", &username);
        debug_info.field("password", &password.as_ref().map(|_| "<redacted>"));
        debug_info.field("protocol", &protocol);
        debug_info.field("skip_set_lib_name", &skip_set_lib_name);
        debug_info.field("lib_name", &lib_name);
        debug_info.field("lib_ver", &lib_ver);

        debug_info.finish()
    }
}

impl FromStr for ConnectionInfo {
    type Err = RedisError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        s.into_connection_info()
    }
}

/// Converts an object into a connection info struct.  This allows the
/// constructor of the client to accept connection information in a
/// range of different formats.
pub trait IntoConnectionInfo {
    /// Converts the object into a connection info object.
    fn into_connection_info(self) -> RedisResult<ConnectionInfo>;
}

impl IntoConnectionInfo for ConnectionInfo {
    fn into_connection_info(self) -> RedisResult<ConnectionInfo> {
        Ok(self)
    }
}

impl IntoConnectionInfo for ConnectionAddr {
    fn into_connection_info(self) -> RedisResult<ConnectionInfo> {
        Ok(ConnectionInfo {
            addr: self,
            redis: Default::default(),
            tcp_settings: Default::default(),
        })
    }
}

/// URL format: `{redis|rediss|valkey|valkeys}://[<username>][:<password>@]<hostname>[:port][/<db>]`
///
/// - Basic: `redis://127.0.0.1:6379`
/// - Username & Password: `redis://user:password@127.0.0.1:6379`
/// - Password only: `redis://:password@127.0.0.1:6379`
/// - Specifying DB: `redis://127.0.0.1:6379/0`
/// - Enabling TLS: `rediss://127.0.0.1:6379`
/// - Enabling Insecure TLS: `rediss://127.0.0.1:6379/#insecure`
/// - Enabling RESP3: `redis://127.0.0.1:6379/?protocol=resp3`
impl IntoConnectionInfo for &str {
    fn into_connection_info(self) -> RedisResult<ConnectionInfo> {
        match parse_redis_url(self) {
            Some(u) => u.into_connection_info(),
            None => fail!((ErrorKind::InvalidClientConfig, "Redis URL did not parse")),
        }
    }
}

impl<T> IntoConnectionInfo for (T, u16)
where
    T: Into<String>,
{
    fn into_connection_info(self) -> RedisResult<ConnectionInfo> {
        Ok(ConnectionInfo {
            addr: ConnectionAddr::Tcp(self.0.into(), self.1),
            redis: RedisConnectionInfo::default(),
            tcp_settings: TcpSettings::default(),
        })
    }
}

/// URL format: `{redis|rediss|valkey|valkeys}://[<username>][:<password>@]<hostname>[:port][/<db>]`
///
/// - Basic: `redis://127.0.0.1:6379`
/// - Username & Password: `redis://user:password@127.0.0.1:6379`
/// - Password only: `redis://:password@127.0.0.1:6379`
/// - Specifying DB: `redis://127.0.0.1:6379/0`
/// - Enabling TLS: `rediss://127.0.0.1:6379`
/// - Enabling Insecure TLS: `rediss://127.0.0.1:6379/#insecure`
/// - Enabling RESP3: `redis://127.0.0.1:6379/?protocol=resp3`
impl IntoConnectionInfo for String {
    fn into_connection_info(self) -> RedisResult<ConnectionInfo> {
        match parse_redis_url(&self) {
            Some(u) => u.into_connection_info(),
            None => fail!((ErrorKind::InvalidClientConfig, "Redis URL did not parse")),
        }
    }
}

fn parse_protocol(query: &HashMap<Cow<str>, Cow<str>>) -> RedisResult<ProtocolVersion> {
    Ok(match query.get("protocol") {
        Some(protocol) => {
            if protocol == "2" || protocol == "resp2" {
                ProtocolVersion::RESP2
            } else if protocol == "3" || protocol == "resp3" {
                ProtocolVersion::RESP3
            } else {
                fail!((
                    ErrorKind::InvalidClientConfig,
                    "Invalid protocol version",
                    protocol.to_string()
                ))
            }
        }
        None => ProtocolVersion::RESP2,
    })
}

#[inline]
pub(crate) fn is_wildcard_address(address: &str) -> bool {
    address == "0.0.0.0" || address == "::"
}

fn url_to_tcp_connection_info(url: url::Url) -> RedisResult<ConnectionInfo> {
    let host = match url.host() {
        Some(host) => {
            // Here we manually match host's enum arms and call their to_string().
            // Because url.host().to_string() will add `[` and `]` for ipv6:
            // https://docs.rs/url/latest/src/url/host.rs.html#170
            // And these brackets will break host.parse::<Ipv6Addr>() when
            // `client.open()` - `ActualConnection::new()` - `addr.to_socket_addrs()`:
            // https://doc.rust-lang.org/src/std/net/addr.rs.html#963
            // https://doc.rust-lang.org/src/std/net/parser.rs.html#158
            // IpAddr string with brackets can ONLY parse to SocketAddrV6:
            // https://doc.rust-lang.org/src/std/net/parser.rs.html#255
            // But if we call Ipv6Addr.to_string directly, it follows rfc5952 without brackets:
            // https://doc.rust-lang.org/src/std/net/ip.rs.html#1755
            let host_str = match host {
                url::Host::Domain(path) => path.to_string(),
                url::Host::Ipv4(v4) => v4.to_string(),
                url::Host::Ipv6(v6) => v6.to_string(),
            };

            if is_wildcard_address(&host_str) {
                return Err(RedisError::from((
                    ErrorKind::InvalidClientConfig,
                    "Cannot connect to a wildcard address (0.0.0.0 or ::)",
                )));
            }
            host_str
        }
        None => fail!((ErrorKind::InvalidClientConfig, "Missing hostname")),
    };
    let port = url.port().unwrap_or(DEFAULT_PORT);
    let addr = if url.scheme() == "rediss" || url.scheme() == "valkeys" {
        #[cfg(any(feature = "tls-native-tls", feature = "tls-rustls"))]
        {
            match url.fragment() {
                Some("insecure") => ConnectionAddr::TcpTls {
                    host,
                    port,
                    insecure: true,
                    tls_params: None,
                },
                Some(_) => fail!((
                    ErrorKind::InvalidClientConfig,
                    "only #insecure is supported as URL fragment"
                )),
                _ => ConnectionAddr::TcpTls {
                    host,
                    port,
                    insecure: false,
                    tls_params: None,
                },
            }
        }

        #[cfg(not(any(feature = "tls-native-tls", feature = "tls-rustls")))]
        fail!((
            ErrorKind::InvalidClientConfig,
            "can't connect with TLS, the feature is not enabled"
        ));
    } else {
        ConnectionAddr::Tcp(host, port)
    };
    let query: HashMap<_, _> = url.query_pairs().collect();
    Ok(ConnectionInfo {
        addr,
        redis: RedisConnectionInfo {
            db: match url.path().trim_matches('/') {
                "" => 0,
                path => path.parse::<i64>().map_err(|_| -> RedisError {
                    (ErrorKind::InvalidClientConfig, "Invalid database number").into()
                })?,
            },
            username: if url.username().is_empty() {
                None
            } else {
                match percent_encoding::percent_decode(url.username().as_bytes()).decode_utf8() {
                    Ok(decoded) => Some(decoded.into()),
                    Err(_) => fail!((
                        ErrorKind::InvalidClientConfig,
                        "Username is not valid UTF-8 string"
                    )),
                }
            },
            password: match url.password() {
                Some(pw) => match percent_encoding::percent_decode(pw.as_bytes()).decode_utf8() {
                    Ok(decoded) => Some(decoded.into()),
                    Err(_) => fail!((
                        ErrorKind::InvalidClientConfig,
                        "Password is not valid UTF-8 string"
                    )),
                },
                None => None,
            },
            protocol: parse_protocol(&query)?,
            skip_set_lib_name: false,
            lib_name: None,
            lib_ver: None,
        },
        tcp_settings: TcpSettings::default(),
    })
}

#[cfg(unix)]
fn url_to_unix_connection_info(url: url::Url) -> RedisResult<ConnectionInfo> {
    let query: HashMap<_, _> = url.query_pairs().collect();
    Ok(ConnectionInfo {
        addr: ConnectionAddr::Unix(url.to_file_path().map_err(|_| -> RedisError {
            (ErrorKind::InvalidClientConfig, "Missing path").into()
        })?),
        redis: RedisConnectionInfo {
            db: match query.get("db") {
                Some(db) => db.parse::<i64>().map_err(|_| -> RedisError {
                    (ErrorKind::InvalidClientConfig, "Invalid database number").into()
                })?,

                None => 0,
            },
            username: query.get("user").map(|username| username.as_ref().into()),
            password: query.get("pass").map(|password| password.as_ref().into()),
            protocol: parse_protocol(&query)?,
            skip_set_lib_name: false,
            lib_name: None,
            lib_ver: None,
        },
        tcp_settings: TcpSettings::default(),
    })
}

#[cfg(not(unix))]
fn url_to_unix_connection_info(_: url::Url) -> RedisResult<ConnectionInfo> {
    fail!((
        ErrorKind::InvalidClientConfig,
        "Unix sockets are not available on this platform."
    ));
}

impl IntoConnectionInfo for url::Url {
    fn into_connection_info(self) -> RedisResult<ConnectionInfo> {
        match self.scheme() {
            "redis" | "rediss" | "valkey" | "valkeys" => url_to_tcp_connection_info(self),
            "unix" | "redis+unix" | "valkey+unix" => url_to_unix_connection_info(self),
            _ => fail!((
                ErrorKind::InvalidClientConfig,
                "URL provided is not a redis URL"
            )),
        }
    }
}

struct TcpConnection {
    reader: TcpStream,
    open: bool,
}

#[cfg(all(feature = "tls-native-tls", not(feature = "tls-rustls")))]
struct TcpNativeTlsConnection {
    reader: TlsStream<TcpStream>,
    open: bool,
}

#[cfg(feature = "tls-rustls")]
struct TcpRustlsConnection {
    reader: StreamOwned<rustls::ClientConnection, TcpStream>,
    open: bool,
}

#[cfg(unix)]
struct UnixConnection {
    sock: UnixStream,
    open: bool,
}

enum ActualConnection {
    Tcp(TcpConnection),
    #[cfg(all(feature = "tls-native-tls", not(feature = "tls-rustls")))]
    TcpNativeTls(Box<TcpNativeTlsConnection>),
    #[cfg(feature = "tls-rustls")]
    TcpRustls(Box<TcpRustlsConnection>),
    #[cfg(unix)]
    Unix(UnixConnection),
}

#[cfg(feature = "tls-rustls-insecure")]
struct NoCertificateVerification {
    supported: rustls::crypto::WebPkiSupportedAlgorithms,
}

#[cfg(feature = "tls-rustls-insecure")]
impl rustls::client::danger::ServerCertVerifier for NoCertificateVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.supported.supported_schemes()
    }
}

#[cfg(feature = "tls-rustls-insecure")]
impl fmt::Debug for NoCertificateVerification {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NoCertificateVerification").finish()
    }
}

/// Insecure `ServerCertVerifier` for rustls that implements `danger_accept_invalid_hostnames`.
#[cfg(feature = "tls-rustls-insecure")]
#[derive(Debug)]
struct AcceptInvalidHostnamesCertVerifier {
    inner: Arc<rustls::client::WebPkiServerVerifier>,
}

#[cfg(feature = "tls-rustls-insecure")]
fn is_hostname_error(err: &rustls::Error) -> bool {
    matches!(
        err,
        rustls::Error::InvalidCertificate(
            rustls::CertificateError::NotValidForName
                | rustls::CertificateError::NotValidForNameContext { .. }
        )
    )
}

#[cfg(feature = "tls-rustls-insecure")]
impl rustls::client::danger::ServerCertVerifier for AcceptInvalidHostnamesCertVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &rustls::pki_types::CertificateDer<'_>,
        intermediates: &[rustls::pki_types::CertificateDer<'_>],
        server_name: &rustls::pki_types::ServerName<'_>,
        ocsp_response: &[u8],
        now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        self.inner
            .verify_server_cert(end_entity, intermediates, server_name, ocsp_response, now)
            .or_else(|err| {
                if is_hostname_error(&err) {
                    Ok(rustls::client::danger::ServerCertVerified::assertion())
                } else {
                    Err(err)
                }
            })
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        self.inner
            .verify_tls12_signature(message, cert, dss)
            .or_else(|err| {
                if is_hostname_error(&err) {
                    Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
                } else {
                    Err(err)
                }
            })
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        self.inner
            .verify_tls13_signature(message, cert, dss)
            .or_else(|err| {
                if is_hostname_error(&err) {
                    Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
                } else {
                    Err(err)
                }
            })
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.inner.supported_verify_schemes()
    }
}

/// Represents a stateful redis TCP connection.
pub struct Connection {
    con: ActualConnection,
    parser: Parser,
    db: i64,

    /// Flag indicating whether the connection was left in the PubSub state after dropping `PubSub`.
    ///
    /// This flag is checked when attempting to send a command, and if it's raised, we attempt to
    /// exit the pubsub state before executing the new request.
    pubsub: bool,

    // Field indicating which protocol to use for server communications.
    protocol: ProtocolVersion,

    /// This is used to manage Push messages in RESP3 mode.
    push_sender: Option<SyncPushSender>,

    /// The number of messages that are expected to be returned from the server,
    /// but the user no longer waits for - answers for requests that already returned a transient error.
    messages_to_skip: usize,
}

/// Represents a RESP2 pubsub connection.
///
/// If you're using a DB that supports RESP3, consider using a regular connection and setting a push sender it using [Connection::set_push_sender].
pub struct PubSub<'a> {
    con: &'a mut Connection,
    waiting_messages: VecDeque<Msg>,
}

/// Represents a pubsub message.
#[derive(Debug, Clone)]
pub struct Msg {
    payload: Value,
    channel: Value,
    pattern: Option<Value>,
}

impl ActualConnection {
    pub fn new(
        addr: &ConnectionAddr,
        timeout: Option<Duration>,
        tcp_settings: &TcpSettings,
    ) -> RedisResult<Self> {
        Ok(match *addr {
            ConnectionAddr::Tcp(ref host, ref port) => {
                if is_wildcard_address(host) {
                    fail!((
                        ErrorKind::InvalidClientConfig,
                        "Cannot connect to a wildcard address (0.0.0.0 or ::)"
                    ));
                }
                let addr = (host.as_str(), *port);
                let tcp = match timeout {
                    None => connect_tcp(addr, tcp_settings)?,
                    Some(timeout) => {
                        let mut tcp = None;
                        let mut last_error = None;
                        for addr in addr.to_socket_addrs()? {
                            match connect_tcp_timeout(&addr, timeout, tcp_settings) {
                                Ok(l) => {
                                    tcp = Some(l);
                                    break;
                                }
                                Err(e) => {
                                    last_error = Some(e);
                                }
                            }
                        }
                        match (tcp, last_error) {
                            (Some(tcp), _) => tcp,
                            (None, Some(e)) => {
                                fail!(e);
                            }
                            (None, None) => {
                                fail!((
                                    ErrorKind::InvalidClientConfig,
                                    "could not resolve to any addresses"
                                ));
                            }
                        }
                    }
                };
                Self::Tcp(TcpConnection {
                    reader: tcp,
                    open: true,
                })
            }
            #[cfg(all(feature = "tls-native-tls", not(feature = "tls-rustls")))]
            ConnectionAddr::TcpTls {
                ref host,
                port,
                insecure,
                ref tls_params,
            } => {
                let tls_connector = if insecure {
                    TlsConnector::builder()
                        .danger_accept_invalid_certs(true)
                        .danger_accept_invalid_hostnames(true)
                        .use_sni(false)
                        .build()?
                } else if let Some(params) = tls_params {
                    TlsConnector::builder()
                        .danger_accept_invalid_hostnames(params.danger_accept_invalid_hostnames)
                        .build()?
                } else {
                    TlsConnector::new()?
                };
                let addr = (host.as_str(), port);
                let tls = match timeout {
                    None => {
                        let tcp = connect_tcp(addr, tcp_settings)?;
                        match tls_connector.connect(host, tcp) {
                            Ok(res) => res,
                            Err(e) => {
                                fail!((ErrorKind::Io, "SSL Handshake error", e.to_string()));
                            }
                        }
                    }
                    Some(timeout) => {
                        let mut tcp = None;
                        let mut last_error = None;
                        for addr in (host.as_str(), port).to_socket_addrs()? {
                            match connect_tcp_timeout(&addr, timeout, tcp_settings) {
                                Ok(l) => {
                                    tcp = Some(l);
                                    break;
                                }
                                Err(e) => {
                                    last_error = Some(e);
                                }
                            };
                        }
                        match (tcp, last_error) {
                            (Some(tcp), _) => tls_connector.connect(host, tcp).unwrap(),
                            (None, Some(e)) => {
                                fail!(e);
                            }
                            (None, None) => {
                                fail!((
                                    ErrorKind::InvalidClientConfig,
                                    "could not resolve to any addresses"
                                ));
                            }
                        }
                    }
                };
                ActualConnection::TcpNativeTls(Box::new(TcpNativeTlsConnection {
                    reader: tls,
                    open: true,
                }))
            }
            #[cfg(feature = "tls-rustls")]
            ConnectionAddr::TcpTls {
                ref host,
                port,
                insecure,
                ref tls_params,
            } => {
                let host: &str = host;
                let verify_host = tls_params
                    .as_ref()
                    .and_then(|params| params.verify_host.as_deref())
                    .unwrap_or(host);
                let config = create_rustls_config(insecure, tls_params.clone())?;
                let conn = rustls::ClientConnection::new(
                    Arc::new(config),
                    rustls::pki_types::ServerName::try_from(verify_host)?.to_owned(),
                )?;
                let reader = match timeout {
                    None => {
                        let tcp = connect_tcp((host, port), tcp_settings)?;
                        StreamOwned::new(conn, tcp)
                    }
                    Some(timeout) => {
                        let mut tcp = None;
                        let mut last_error = None;
                        for addr in (host, port).to_socket_addrs()? {
                            match connect_tcp_timeout(&addr, timeout, tcp_settings) {
                                Ok(l) => {
                                    tcp = Some(l);
                                    break;
                                }
                                Err(e) => {
                                    last_error = Some(e);
                                }
                            }
                        }
                        match (tcp, last_error) {
                            (Some(tcp), _) => StreamOwned::new(conn, tcp),
                            (None, Some(e)) => {
                                fail!(e);
                            }
                            (None, None) => {
                                fail!((
                                    ErrorKind::InvalidClientConfig,
                                    "could not resolve to any addresses"
                                ));
                            }
                        }
                    }
                };

                Self::TcpRustls(Box::new(TcpRustlsConnection { reader, open: true }))
            }
            #[cfg(not(any(feature = "tls-native-tls", feature = "tls-rustls")))]
            ConnectionAddr::TcpTls { .. } => {
                fail!((
                    ErrorKind::InvalidClientConfig,
                    "Cannot connect to TCP with TLS without the tls feature"
                ));
            }
            #[cfg(unix)]
            ConnectionAddr::Unix(ref path) => Self::Unix(UnixConnection {
                sock: UnixStream::connect(path)?,
                open: true,
            }),
            #[cfg(not(unix))]
            ConnectionAddr::Unix(ref _path) => {
                fail!((
                    ErrorKind::InvalidClientConfig,
                    "Cannot connect to unix sockets \
                     on this platform"
                ));
            }
        })
    }

    pub fn send_bytes(&mut self, bytes: &[u8]) -> RedisResult<Value> {
        match *self {
            Self::Tcp(ref mut connection) => {
                let res = connection.reader.write_all(bytes).map_err(RedisError::from);
                match res {
                    Err(e) => {
                        if e.is_unrecoverable_error() {
                            connection.open = false;
                        }
                        Err(e)
                    }
                    Ok(_) => Ok(Value::Okay),
                }
            }
            #[cfg(all(feature = "tls-native-tls", not(feature = "tls-rustls")))]
            ActualConnection::TcpNativeTls(ref mut connection) => {
                let res = connection.reader.write_all(bytes).map_err(RedisError::from);
                match res {
                    Err(e) => {
                        if e.is_unrecoverable_error() {
                            connection.open = false;
                        }
                        Err(e)
                    }
                    Ok(_) => Ok(Value::Okay),
                }
            }
            #[cfg(feature = "tls-rustls")]
            Self::TcpRustls(ref mut connection) => {
                let res = connection.reader.write_all(bytes).map_err(RedisError::from);
                match res {
                    Err(e) => {
                        if e.is_unrecoverable_error() {
                            connection.open = false;
                        }
                        Err(e)
                    }
                    Ok(_) => Ok(Value::Okay),
                }
            }
            #[cfg(unix)]
            Self::Unix(ref mut connection) => {
                let result = connection.sock.write_all(bytes).map_err(RedisError::from);
                match result {
                    Err(e) => {
                        if e.is_unrecoverable_error() {
                            connection.open = false;
                        }
                        Err(e)
                    }
                    Ok(_) => Ok(Value::Okay),
                }
            }
        }
    }

    pub fn set_write_timeout(&self, dur: Option<Duration>) -> RedisResult<()> {
        match *self {
            Self::Tcp(TcpConnection { ref reader, .. }) => {
                reader.set_write_timeout(dur)?;
            }
            #[cfg(all(feature = "tls-native-tls", not(feature = "tls-rustls")))]
            ActualConnection::TcpNativeTls(ref boxed_tls_connection) => {
                let reader = &(boxed_tls_connection.reader);
                reader.get_ref().set_write_timeout(dur)?;
            }
            #[cfg(feature = "tls-rustls")]
            Self::TcpRustls(ref boxed_tls_connection) => {
                let reader = &(boxed_tls_connection.reader);
                reader.get_ref().set_write_timeout(dur)?;
            }
            #[cfg(unix)]
            Self::Unix(UnixConnection { ref sock, .. }) => {
                sock.set_write_timeout(dur)?;
            }
        }
        Ok(())
    }

    pub fn set_read_timeout(&self, dur: Option<Duration>) -> RedisResult<()> {
        match *self {
            Self::Tcp(TcpConnection { ref reader, .. }) => {
                reader.set_read_timeout(dur)?;
            }
            #[cfg(all(feature = "tls-native-tls", not(feature = "tls-rustls")))]
            ActualConnection::TcpNativeTls(ref boxed_tls_connection) => {
                let reader = &(boxed_tls_connection.reader);
                reader.get_ref().set_read_timeout(dur)?;
            }
            #[cfg(feature = "tls-rustls")]
            Self::TcpRustls(ref boxed_tls_connection) => {
                let reader = &(boxed_tls_connection.reader);
                reader.get_ref().set_read_timeout(dur)?;
            }
            #[cfg(unix)]
            Self::Unix(UnixConnection { ref sock, .. }) => {
                sock.set_read_timeout(dur)?;
            }
        }
        Ok(())
    }

    pub fn is_open(&self) -> bool {
        match *self {
            Self::Tcp(TcpConnection { open, .. }) => open,
            #[cfg(all(feature = "tls-native-tls", not(feature = "tls-rustls")))]
            ActualConnection::TcpNativeTls(ref boxed_tls_connection) => boxed_tls_connection.open,
            #[cfg(feature = "tls-rustls")]
            Self::TcpRustls(ref boxed_tls_connection) => boxed_tls_connection.open,
            #[cfg(unix)]
            Self::Unix(UnixConnection { open, .. }) => open,
        }
    }
}

#[cfg(feature = "tls-rustls")]
pub(crate) fn create_rustls_config(
    insecure: bool,
    tls_params: Option<TlsConnParams>,
) -> RedisResult<rustls::ClientConfig> {
    #[allow(unused_mut)]
    let mut root_store = RootCertStore::empty();
    #[cfg(feature = "tls-rustls-webpki-roots")]
    root_store.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    #[cfg(all(
        feature = "tls-rustls",
        not(feature = "tls-native-tls"),
        not(feature = "tls-rustls-webpki-roots")
    ))]
    {
        let mut certificate_result = load_native_certs();
        if let Some(error) = certificate_result.errors.pop() {
            return Err(error.into());
        }
        for cert in certificate_result.certs {
            root_store.add(cert)?;
        }
    }

    let config = rustls::ClientConfig::builder();
    let config = if let Some(tls_params) = tls_params {
        let root_cert_store = tls_params.root_cert_store.unwrap_or(root_store);
        let config_builder = config.with_root_certificates(root_cert_store.clone());

        let config_builder = if let Some(ClientTlsParams {
            client_cert_chain: client_cert,
            client_key,
        }) = tls_params.client_tls_params
        {
            config_builder
                .with_client_auth_cert(client_cert, client_key)
                .map_err(|err| {
                    RedisError::from((
                        ErrorKind::InvalidClientConfig,
                        "Unable to build client with TLS parameters provided.",
                        err.to_string(),
                    ))
                })?
        } else {
            config_builder.with_no_client_auth()
        };

        // Implement `danger_accept_invalid_hostnames`.
        //
        // The strange cfg here is to handle a specific unusual combination of features: if
        // `tls-native-tls` and `tls-rustls` are enabled, but `tls-rustls-insecure` is not, and the
        // application tries to use the danger flag.
        #[cfg(any(feature = "tls-rustls-insecure", feature = "tls-native-tls"))]
        let config_builder = if !insecure && tls_params.danger_accept_invalid_hostnames {
            #[cfg(not(feature = "tls-rustls-insecure"))]
            {
                // This code should not enable an insecure mode if the `insecure` feature is not
                // set, but it shouldn't silently ignore the flag either. So return an error.
                fail!((
                    ErrorKind::InvalidClientConfig,
                    "Cannot create insecure client via danger_accept_invalid_hostnames without tls-rustls-insecure feature"
                ));
            }

            #[cfg(feature = "tls-rustls-insecure")]
            {
                let mut config = config_builder;
                config.dangerous().set_certificate_verifier(Arc::new(
                    AcceptInvalidHostnamesCertVerifier {
                        inner: rustls::client::WebPkiServerVerifier::builder(Arc::new(
                            root_cert_store,
                        ))
                        .build()
                        .map_err(|err| rustls::Error::from(rustls::OtherError(Arc::new(err))))?,
                    },
                ));
                config
            }
        } else {
            config_builder
        };

        config_builder
    } else {
        config
            .with_root_certificates(root_store)
            .with_no_client_auth()
    };

    match (insecure, cfg!(feature = "tls-rustls-insecure")) {
        #[cfg(feature = "tls-rustls-insecure")]
        (true, true) => {
            let mut config = config;
            config.enable_sni = false;
            let Some(crypto_provider) = rustls::crypto::CryptoProvider::get_default() else {
                return Err(RedisError::from((
                    ErrorKind::InvalidClientConfig,
                    "No crypto provider available for rustls",
                )));
            };
            config
                .dangerous()
                .set_certificate_verifier(Arc::new(NoCertificateVerification {
                    supported: crypto_provider.signature_verification_algorithms,
                }));

            Ok(config)
        }
        (true, false) => {
            fail!((
                ErrorKind::InvalidClientConfig,
                "Cannot create insecure client without tls-rustls-insecure feature"
            ));
        }
        _ => Ok(config),
    }
}

pub(crate) fn authenticate_cmd(username: Option<&str>, password: &str) -> Cmd {
    let mut command = cmd("AUTH");

    if let Some(username) = &username {
        command.arg(username);
    }

    command.arg(password);
    command
}

pub fn connect(
    connection_info: &ConnectionInfo,
    timeout: Option<Duration>,
) -> RedisResult<Connection> {
    let start = Instant::now();
    let con: ActualConnection = ActualConnection::new(
        &connection_info.addr,
        timeout,
        &connection_info.tcp_settings,
    )?;

    // we temporarily set the timeout, and will remove it after finishing setup.
    let remaining_timeout = timeout.and_then(|timeout| timeout.checked_sub(start.elapsed()));
    // TLS could run logic that doesn't contain a timeout, and should fail if it takes too long.
    if timeout.is_some() && remaining_timeout.is_none() {
        return Err(RedisError::from(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "Connection timed out",
        )));
    }
    con.set_read_timeout(remaining_timeout)?;
    con.set_write_timeout(remaining_timeout)?;

    let con = setup_connection(
        con,
        &connection_info.redis,
        #[cfg(feature = "cache-aio")]
        None,
    )?;

    // remove the temporary timeout.
    con.set_read_timeout(None)?;
    con.set_write_timeout(None)?;

    Ok(con)
}

pub(crate) struct ConnectionSetupComponents {
    resp3_auth_cmd_idx: Option<usize>,
    resp2_auth_cmd_idx: Option<usize>,
    select_cmd_idx: Option<usize>,
    #[cfg(feature = "cache-aio")]
    cache_cmd_idx: Option<usize>,
}

pub(crate) fn connection_setup_pipeline(
    connection_info: &RedisConnectionInfo,
    check_username: bool,
    #[cfg(feature = "cache-aio")] cache_config: Option<crate::caching::CacheConfig>,
) -> (crate::Pipeline, ConnectionSetupComponents) {
    let mut pipeline = pipe();
    let (authenticate_with_resp3_cmd_index, authenticate_with_resp2_cmd_index) =
        if connection_info.protocol.supports_resp3() {
            pipeline.add_command(resp3_hello(connection_info));
            (Some(0), None)
        } else if let Some(password) = connection_info.password.as_ref() {
            pipeline.add_command(authenticate_cmd(
                check_username.then(|| connection_info.username()).flatten(),
                password,
            ));
            (None, Some(0))
        } else {
            (None, None)
        };

    let select_db_cmd_index = (connection_info.db != 0)
        .then(|| pipeline.len())
        .inspect(|_| {
            pipeline.cmd("SELECT").arg(connection_info.db);
        });

    #[cfg(feature = "cache-aio")]
    let cache_cmd_index = cache_config.map(|cache_config| {
        pipeline.cmd("CLIENT").arg("TRACKING").arg("ON");
        match cache_config.mode {
            crate::caching::CacheMode::All => {}
            crate::caching::CacheMode::OptIn => {
                pipeline.arg("OPTIN");
            }
        }
        pipeline.len() - 1
    });

    // result is ignored, as per the command's instructions.
    // https://redis.io/commands/client-setinfo/
    if !connection_info.skip_set_lib_name {
        pipeline
            .cmd("CLIENT")
            .arg("SETINFO")
            .arg("LIB-NAME")
            .arg(
                connection_info
                    .lib_name
                    .as_ref()
                    .map_or(DEFAULT_CLIENT_SETINFO_LIB_NAME, ArcStr::as_str),
            )
            .ignore();
        pipeline
            .cmd("CLIENT")
            .arg("SETINFO")
            .arg("LIB-VER")
            .arg(
                connection_info
                    .lib_ver
                    .as_ref()
                    .map_or(DEFAULT_CLIENT_SETINFO_LIB_VER, ArcStr::as_str),
            )
            .ignore();
    }

    (
        pipeline,
        ConnectionSetupComponents {
            resp3_auth_cmd_idx: authenticate_with_resp3_cmd_index,
            resp2_auth_cmd_idx: authenticate_with_resp2_cmd_index,
            select_cmd_idx: select_db_cmd_index,
            #[cfg(feature = "cache-aio")]
            cache_cmd_idx: cache_cmd_index,
        },
    )
}

fn check_resp3_auth(result: &Value) -> RedisResult<()> {
    if let Value::ServerError(err) = result {
        return Err(get_resp3_hello_command_error(err.clone().into()));
    }
    Ok(())
}

#[derive(PartialEq)]
pub(crate) enum AuthResult {
    Succeeded,
    ShouldRetryWithoutUsername,
}

fn check_resp2_auth(result: &Value) -> RedisResult<AuthResult> {
    let err = match result {
        Value::Okay => {
            return Ok(AuthResult::Succeeded);
        }
        Value::ServerError(err) => err,
        _ => {
            return Err((
                ServerErrorKind::ResponseError.into(),
                "Redis server refused to authenticate, returns Ok() != Value::Okay",
            )
                .into());
        }
    };

    let err_msg = err.details().ok_or((
        ErrorKind::AuthenticationFailed,
        "Password authentication failed",
    ))?;
    if !err_msg.contains("wrong number of arguments for 'auth' command") {
        return Err((
            ErrorKind::AuthenticationFailed,
            "Password authentication failed",
        )
            .into());
    }
    Ok(AuthResult::ShouldRetryWithoutUsername)
}

fn check_db_select(value: &Value) -> RedisResult<()> {
    let Value::ServerError(err) = value else {
        return Ok(());
    };

    match err.details() {
        Some(err_msg) => Err((
            ServerErrorKind::ResponseError.into(),
            "Redis server refused to switch database",
            err_msg.to_string(),
        )
            .into()),
        None => Err((
            ServerErrorKind::ResponseError.into(),
            "Redis server refused to switch database",
        )
            .into()),
    }
}

#[cfg(feature = "cache-aio")]
fn check_caching(result: &Value) -> RedisResult<()> {
    match result {
        Value::Okay => Ok(()),
        _ => Err((
            ServerErrorKind::ResponseError.into(),
            "Client-side caching returned unknown response",
            format!("{result:?}"),
        )
            .into()),
    }
}

pub(crate) fn check_connection_setup(
    results: Vec<Value>,
    ConnectionSetupComponents {
        resp3_auth_cmd_idx,
        resp2_auth_cmd_idx,
        select_cmd_idx,
        #[cfg(feature = "cache-aio")]
        cache_cmd_idx,
    }: ConnectionSetupComponents,
) -> RedisResult<AuthResult> {
    // can't have both values set
    assert!(!(resp2_auth_cmd_idx.is_some() && resp3_auth_cmd_idx.is_some()));

    if let Some(index) = resp3_auth_cmd_idx {
        let Some(value) = results.get(index) else {
            return Err((ErrorKind::Client, "Missing RESP3 auth response").into());
        };
        check_resp3_auth(value)?;
    } else if let Some(index) = resp2_auth_cmd_idx {
        let Some(value) = results.get(index) else {
            return Err((ErrorKind::Client, "Missing RESP2 auth response").into());
        };
        if check_resp2_auth(value)? == AuthResult::ShouldRetryWithoutUsername {
            return Ok(AuthResult::ShouldRetryWithoutUsername);
        }
    }

    if let Some(index) = select_cmd_idx {
        let Some(value) = results.get(index) else {
            return Err((ErrorKind::Client, "Missing SELECT DB response").into());
        };
        check_db_select(value)?;
    }

    #[cfg(feature = "cache-aio")]
    if let Some(index) = cache_cmd_idx {
        let Some(value) = results.get(index) else {
            return Err((ErrorKind::Client, "Missing Caching response").into());
        };
        check_caching(value)?;
    }

    Ok(AuthResult::Succeeded)
}

fn execute_connection_pipeline(
    rv: &mut Connection,
    (pipeline, instructions): (crate::Pipeline, ConnectionSetupComponents),
) -> RedisResult<AuthResult> {
    if pipeline.is_empty() {
        return Ok(AuthResult::Succeeded);
    }
    let results = rv.req_packed_commands(&pipeline.get_packed_pipeline(), 0, pipeline.len())?;

    check_connection_setup(results, instructions)
}

fn setup_connection(
    con: ActualConnection,
    connection_info: &RedisConnectionInfo,
    #[cfg(feature = "cache-aio")] cache_config: Option<crate::caching::CacheConfig>,
) -> RedisResult<Connection> {
    let mut rv = Connection {
        con,
        parser: Parser::new(),
        db: connection_info.db,
        pubsub: false,
        protocol: connection_info.protocol,
        push_sender: None,
        messages_to_skip: 0,
    };

    if execute_connection_pipeline(
        &mut rv,
        connection_setup_pipeline(
            connection_info,
            true,
            #[cfg(feature = "cache-aio")]
            cache_config,
        ),
    )? == AuthResult::ShouldRetryWithoutUsername
    {
        execute_connection_pipeline(
            &mut rv,
            connection_setup_pipeline(
                connection_info,
                false,
                #[cfg(feature = "cache-aio")]
                cache_config,
            ),
        )?;
    }

    Ok(rv)
}

/// Implements the "stateless" part of the connection interface that is used by the
/// different objects in redis-rs.
///
/// Primarily it obviously applies to `Connection` object but also some other objects
///  implement the interface (for instance whole clients or certain redis results).
///
/// Generally clients and connections (as well as redis results of those) implement
/// this trait.  Actual connections provide more functionality which can be used
/// to implement things like `PubSub` but they also can modify the intrinsic
/// state of the TCP connection.  This is not possible with `ConnectionLike`
/// implementors because that functionality is not exposed.
pub trait ConnectionLike {
    /// Sends an already encoded (packed) command into the TCP socket and
    /// reads the single response from it.
    fn req_packed_command(&mut self, cmd: &[u8]) -> RedisResult<Value>;

    /// Sends multiple already encoded (packed) command into the TCP socket
    /// and reads `count` responses from it.  This is used to implement
    /// pipelining.
    /// Important - this function is meant for internal usage, since it's
    /// easy to pass incorrect `offset` & `count` parameters, which might
    /// cause the connection to enter an erroneous state. Users shouldn't
    /// call it, instead using the Pipeline::query function.
    #[doc(hidden)]
    fn req_packed_commands(
        &mut self,
        cmd: &[u8],
        offset: usize,
        count: usize,
    ) -> RedisResult<Vec<Value>>;

    /// Sends a [Cmd] into the TCP socket and reads a single response from it.
    fn req_command(&mut self, cmd: &Cmd) -> RedisResult<Value> {
        let pcmd = cmd.get_packed_command();
        self.req_packed_command(&pcmd)
    }

    /// Returns the database this connection is bound to.  Note that this
    /// information might be unreliable because it's initially cached and
    /// also might be incorrect if the connection like object is not
    /// actually connected.
    fn get_db(&self) -> i64;

    /// Does this connection support pipelining?
    #[doc(hidden)]
    fn supports_pipelining(&self) -> bool {
        true
    }

    /// Check that all connections it has are available (`PING` internally).
    fn check_connection(&mut self) -> bool;

    /// Returns the connection status.
    ///
    /// The connection is open until any `read` call received an
    /// invalid response from the server (most likely a closed or dropped
    /// connection, otherwise a Redis protocol error). When using unix
    /// sockets the connection is open until writing a command failed with a
    /// `BrokenPipe` error.
    fn is_open(&self) -> bool;
}

/// A connection is an object that represents a single redis connection.  It
/// provides basic support for sending encoded commands into a redis connection
/// and to read a response from it.  It's bound to a single database and can
/// only be created from the client.
///
/// You generally do not much with this object other than passing it to
/// `Cmd` objects.
impl Connection {
    /// Sends an already encoded (packed) command into the TCP socket and
    /// does not read a response.  This is useful for commands like
    /// `MONITOR` which yield multiple items.  This needs to be used with
    /// care because it changes the state of the connection.
    pub fn send_packed_command(&mut self, cmd: &[u8]) -> RedisResult<()> {
        self.send_bytes(cmd)?;
        Ok(())
    }

    /// Fetches a single response from the connection.  This is useful
    /// if used in combination with `send_packed_command`.
    pub fn recv_response(&mut self) -> RedisResult<Value> {
        self.read(true)
    }

    /// Sets the write timeout for the connection.
    ///
    /// If the provided value is `None`, then `send_packed_command` call will
    /// block indefinitely. It is an error to pass the zero `Duration` to this
    /// method.
    pub fn set_write_timeout(&self, dur: Option<Duration>) -> RedisResult<()> {
        self.con.set_write_timeout(dur)
    }

    /// Sets the read timeout for the connection.
    ///
    /// If the provided value is `None`, then `recv_response` call will
    /// block indefinitely. It is an error to pass the zero `Duration` to this
    /// method.
    pub fn set_read_timeout(&self, dur: Option<Duration>) -> RedisResult<()> {
        self.con.set_read_timeout(dur)
    }

    /// Creates a [`PubSub`] instance for this connection.
    pub fn as_pubsub(&mut self) -> PubSub<'_> {
        // NOTE: The pubsub flag is intentionally not raised at this time since
        // running commands within the pubsub state should not try and exit from
        // the pubsub state.
        PubSub::new(self)
    }

    fn exit_pubsub(&mut self) -> RedisResult<()> {
        let res = self.clear_active_subscriptions();
        if res.is_ok() {
            self.pubsub = false;
        } else {
            // Raise the pubsub flag to indicate the connection is "stuck" in that state.
            self.pubsub = true;
        }

        res
    }

    /// Get the inner connection out of a PubSub
    ///
    /// Any active subscriptions are unsubscribed. In the event of an error, the connection is
    /// dropped.
    fn clear_active_subscriptions(&mut self) -> RedisResult<()> {
        // Responses to unsubscribe commands return in a 3-tuple with values
        // ("unsubscribe" or "punsubscribe", name of subscription removed, count of remaining subs).
        // The "count of remaining subs" includes both pattern subscriptions and non pattern
        // subscriptions. Thus, to accurately drain all unsubscribe messages received from the
        // server, both commands need to be executed at once.
        {
            // Prepare both unsubscribe commands
            let unsubscribe = cmd("UNSUBSCRIBE").get_packed_command();
            let punsubscribe = cmd("PUNSUBSCRIBE").get_packed_command();

            // Execute commands
            self.send_bytes(&unsubscribe)?;
            self.send_bytes(&punsubscribe)?;
        }

        // Receive responses
        //
        // There will be at minimum two responses - 1 for each of punsubscribe and unsubscribe
        // commands. There may be more responses if there are active subscriptions. In this case,
        // messages are received until the _subscription count_ in the responses reach zero.
        let mut received_unsub = false;
        let mut received_punsub = false;

        loop {
            let resp = self.recv_response()?;

            match resp {
                Value::Push { kind, data } => {
                    if data.len() >= 2
                        && let Value::Int(num) = data[1]
                        && resp3_is_pub_sub_state_cleared(
                            &mut received_unsub,
                            &mut received_punsub,
                            &kind,
                            num as isize,
                        )
                    {
                        break;
                    }
                }
                Value::ServerError(err) => {
                    // a new error behavior, introduced in valkey 8.
                    // https://github.com/valkey-io/valkey/pull/759
                    if err.kind() == Some(ServerErrorKind::NoSub) {
                        if no_sub_err_is_pub_sub_state_cleared(
                            &mut received_unsub,
                            &mut received_punsub,
                            &err,
                        ) {
                            break;
                        } else {
                            continue;
                        }
                    }

                    return Err(err.into());
                }
                Value::Array(vec) => {
                    let res: (Vec<u8>, (), isize) = from_redis_value(Value::Array(vec))?;
                    if resp2_is_pub_sub_state_cleared(
                        &mut received_unsub,
                        &mut received_punsub,
                        &res.0,
                        res.2,
                    ) {
                        break;
                    }
                }
                _ => {
                    return Err((
                        ErrorKind::Client,
                        "Unexpected unsubscribe response",
                        format!("{resp:?}"),
                    )
                        .into());
                }
            }
        }

        // Finally, the connection is back in its normal state since all subscriptions were
        // cancelled *and* all unsubscribe messages were received.
        Ok(())
    }

    fn send_push(&self, push: PushInfo) {
        if let Some(sender) = &self.push_sender {
            let _ = sender.send(push);
        }
    }

    fn try_send(&self, value: &RedisResult<Value>) {
        if let Ok(Value::Push { kind, data }) = value {
            self.send_push(PushInfo {
                kind: kind.clone(),
                data: data.clone(),
            });
        }
    }

    fn send_disconnect(&self) {
        self.send_push(PushInfo::disconnect());
    }

    fn close_connection(&mut self) {
        // Notify the PushManager that the connection was lost
        self.send_disconnect();
        match self.con {
            ActualConnection::Tcp(ref mut connection) => {
                let _ = connection.reader.shutdown(net::Shutdown::Both);
                connection.open = false;
            }
            #[cfg(all(feature = "tls-native-tls", not(feature = "tls-rustls")))]
            ActualConnection::TcpNativeTls(ref mut connection) => {
                let _ = connection.reader.shutdown();
                connection.open = false;
            }
            #[cfg(feature = "tls-rustls")]
            ActualConnection::TcpRustls(ref mut connection) => {
                let _ = connection.reader.get_mut().shutdown(net::Shutdown::Both);
                connection.open = false;
            }
            #[cfg(unix)]
            ActualConnection::Unix(ref mut connection) => {
                let _ = connection.sock.shutdown(net::Shutdown::Both);
                connection.open = false;
            }
        }
    }

    /// Fetches a single message from the connection. If the message is a response,
    /// increment `messages_to_skip` if it wasn't received before a timeout.
    fn read(&mut self, is_response: bool) -> RedisResult<Value> {
        loop {
            let result = match self.con {
                ActualConnection::Tcp(TcpConnection { ref mut reader, .. }) => {
                    self.parser.parse_value(reader)
                }
                #[cfg(all(feature = "tls-native-tls", not(feature = "tls-rustls")))]
                ActualConnection::TcpNativeTls(ref mut boxed_tls_connection) => {
                    let reader = &mut boxed_tls_connection.reader;
                    self.parser.parse_value(reader)
                }
                #[cfg(feature = "tls-rustls")]
                ActualConnection::TcpRustls(ref mut boxed_tls_connection) => {
                    let reader = &mut boxed_tls_connection.reader;
                    self.parser.parse_value(reader)
                }
                #[cfg(unix)]
                ActualConnection::Unix(UnixConnection { ref mut sock, .. }) => {
                    self.parser.parse_value(sock)
                }
            };
            self.try_send(&result);

            let Err(err) = &result else {
                if self.messages_to_skip > 0 {
                    self.messages_to_skip -= 1;
                    continue;
                }
                return result;
            };
            let Some(io_error) = err.as_io_error() else {
                if self.messages_to_skip > 0 {
                    self.messages_to_skip -= 1;
                    continue;
                }
                return result;
            };
            // shutdown connection on protocol error
            if io_error.kind() == io::ErrorKind::UnexpectedEof {
                self.close_connection();
            } else if is_response {
                self.messages_to_skip += 1;
            }

            return result;
        }
    }

    /// Sets sender channel for push values.
    pub fn set_push_sender(&mut self, sender: SyncPushSender) {
        self.push_sender = Some(sender);
    }

    fn send_bytes(&mut self, bytes: &[u8]) -> RedisResult<Value> {
        if bytes.is_empty() {
            return Err(RedisError::make_empty_command());
        }
        let result = self.con.send_bytes(bytes);
        if self.protocol.supports_resp3()
            && let Err(e) = &result
            && e.is_connection_dropped()
        {
            self.send_disconnect();
        }
        result
    }

    /// Subscribes to a new channel(s).
    ///
    /// This only works if the connection was configured with [ProtocolVersion::RESP3] and [Self::set_push_sender].
    pub fn subscribe_resp3<T: ToRedisArgs>(&mut self, channel: T) -> RedisResult<()> {
        check_resp3!(self.protocol);
        cmd("SUBSCRIBE")
            .arg(channel)
            .set_no_response(true)
            .exec(self)
    }

    /// Subscribes to new channel(s) with pattern(s).
    ///
    /// This only works if the connection was configured with [ProtocolVersion::RESP3] and [Self::set_push_sender].
    pub fn psubscribe_resp3<T: ToRedisArgs>(&mut self, pchannel: T) -> RedisResult<()> {
        check_resp3!(self.protocol);
        cmd("PSUBSCRIBE")
            .arg(pchannel)
            .set_no_response(true)
            .exec(self)
    }

    /// Unsubscribes from a channel(s).
    ///
    /// This only works if the connection was configured with [ProtocolVersion::RESP3] and [Self::set_push_sender].
    pub fn unsubscribe_resp3<T: ToRedisArgs>(&mut self, channel: T) -> RedisResult<()> {
        check_resp3!(self.protocol);
        cmd("UNSUBSCRIBE")
            .arg(channel)
            .set_no_response(true)
            .exec(self)
    }

    /// Unsubscribes from channel pattern(s).
    ///
    /// This only works if the connection was configured with [ProtocolVersion::RESP3] and [Self::set_push_sender].
    pub fn punsubscribe_resp3<T: ToRedisArgs>(&mut self, pchannel: T) -> RedisResult<()> {
        check_resp3!(self.protocol);
        cmd("PUNSUBSCRIBE")
            .arg(pchannel)
            .set_no_response(true)
            .exec(self)
    }
}

impl ConnectionLike for Connection {
    /// Sends a [Cmd] into the TCP socket and reads a single response from it.
    fn req_command(&mut self, cmd: &Cmd) -> RedisResult<Value> {
        let pcmd = cmd.get_packed_command();
        if self.pubsub {
            self.exit_pubsub()?;
        }

        self.send_bytes(&pcmd)?;
        if cmd.is_no_response() {
            return Ok(Value::Nil);
        }
        loop {
            match self.read(true)? {
                Value::Push {
                    kind: _kind,
                    data: _data,
                } => continue,
                val => return Ok(val),
            }
        }
    }
    fn req_packed_command(&mut self, cmd: &[u8]) -> RedisResult<Value> {
        if self.pubsub {
            self.exit_pubsub()?;
        }

        self.send_bytes(cmd)?;
        loop {
            match self.read(true)? {
                Value::Push {
                    kind: _kind,
                    data: _data,
                } => continue,
                val => return Ok(val),
            }
        }
    }

    fn req_packed_commands(
        &mut self,
        cmd: &[u8],
        offset: usize,
        count: usize,
    ) -> RedisResult<Vec<Value>> {
        if self.pubsub {
            self.exit_pubsub()?;
        }
        self.send_bytes(cmd)?;
        let mut rv = vec![];
        let mut first_err = None;
        let mut server_errors = vec![];
        let mut count = count;
        let mut idx = 0;
        while idx < (offset + count) {
            // When processing a transaction, some responses may be errors.
            // We need to keep processing the rest of the responses in that case,
            // so bailing early with `?` would not be correct.
            // See: https://github.com/redis-rs/redis-rs/issues/436
            let response = self.read(true);
            match response {
                Ok(Value::ServerError(err)) => {
                    if idx < offset {
                        server_errors.push((idx - 1, err)); // -1, to offset the added MULTI call.
                    } else {
                        rv.push(Value::ServerError(err));
                    }
                }
                Ok(item) => {
                    // RESP3 can insert push data between command replies
                    if let Value::Push {
                        kind: _kind,
                        data: _data,
                    } = item
                    {
                        // if that is the case we have to extend the loop and handle push data
                        count += 1;
                    } else if idx >= offset {
                        rv.push(item);
                    }
                }
                Err(err) => {
                    if first_err.is_none() {
                        first_err = Some(err);
                    }
                }
            }
            idx += 1;
        }

        if !server_errors.is_empty() {
            return Err(RedisError::make_aborted_transaction(server_errors));
        }

        first_err.map_or(Ok(rv), Err)
    }

    fn get_db(&self) -> i64 {
        self.db
    }

    fn check_connection(&mut self) -> bool {
        cmd("PING").query::<String>(self).is_ok()
    }

    fn is_open(&self) -> bool {
        self.con.is_open()
    }
}

impl<C, T> ConnectionLike for T
where
    C: ConnectionLike,
    T: DerefMut<Target = C>,
{
    fn req_packed_command(&mut self, cmd: &[u8]) -> RedisResult<Value> {
        self.deref_mut().req_packed_command(cmd)
    }

    fn req_packed_commands(
        &mut self,
        cmd: &[u8],
        offset: usize,
        count: usize,
    ) -> RedisResult<Vec<Value>> {
        self.deref_mut().req_packed_commands(cmd, offset, count)
    }

    fn req_command(&mut self, cmd: &Cmd) -> RedisResult<Value> {
        self.deref_mut().req_command(cmd)
    }

    fn get_db(&self) -> i64 {
        self.deref().get_db()
    }

    fn supports_pipelining(&self) -> bool {
        self.deref().supports_pipelining()
    }

    fn check_connection(&mut self) -> bool {
        self.deref_mut().check_connection()
    }

    fn is_open(&self) -> bool {
        self.deref().is_open()
    }
}

/// The pubsub object provides convenient access to the redis pubsub
/// system.  Once created you can subscribe and unsubscribe from channels
/// and listen in on messages.
///
/// Example:
///
/// ```rust,no_run
/// # fn do_something() -> redis::RedisResult<()> {
/// let client = redis::Client::open("redis://127.0.0.1/")?;
/// let mut con = client.get_connection()?;
/// let mut pubsub = con.as_pubsub();
/// pubsub.subscribe("channel_1")?;
/// pubsub.subscribe("channel_2")?;
///
/// loop {
///     let msg = pubsub.get_message()?;
///     let payload : String = msg.get_payload()?;
///     println!("channel '{}': {}", msg.get_channel_name(), payload);
/// }
/// # }
/// ```
impl<'a> PubSub<'a> {
    fn new(con: &'a mut Connection) -> Self {
        Self {
            con,
            waiting_messages: VecDeque::new(),
        }
    }

    fn cache_messages_until_received_response(
        &mut self,
        cmd: &mut Cmd,
        is_sub_unsub: bool,
    ) -> RedisResult<Value> {
        let ignore_response = self.con.protocol.supports_resp3() && is_sub_unsub;
        cmd.set_no_response(ignore_response);

        self.con.send_packed_command(&cmd.get_packed_command())?;

        loop {
            let response = self.con.recv_response()?;
            if let Some(msg) = Msg::from_value(&response) {
                self.waiting_messages.push_back(msg);
            } else {
                return Ok(response);
            }
        }
    }

    /// Subscribes to a new channel(s).
    pub fn subscribe<T: ToRedisArgs>(&mut self, channel: T) -> RedisResult<()> {
        self.cache_messages_until_received_response(cmd("SUBSCRIBE").arg(channel), true)?;
        Ok(())
    }

    /// Subscribes to new channel(s) with pattern(s).
    pub fn psubscribe<T: ToRedisArgs>(&mut self, pchannel: T) -> RedisResult<()> {
        self.cache_messages_until_received_response(cmd("PSUBSCRIBE").arg(pchannel), true)?;
        Ok(())
    }

    /// Unsubscribes from a channel(s).
    pub fn unsubscribe<T: ToRedisArgs>(&mut self, channel: T) -> RedisResult<()> {
        self.cache_messages_until_received_response(cmd("UNSUBSCRIBE").arg(channel), true)?;
        Ok(())
    }

    /// Unsubscribes from channel pattern(s).
    pub fn punsubscribe<T: ToRedisArgs>(&mut self, pchannel: T) -> RedisResult<()> {
        self.cache_messages_until_received_response(cmd("PUNSUBSCRIBE").arg(pchannel), true)?;
        Ok(())
    }

    /// Sends a ping with a message to the server
    pub fn ping_message<T: FromRedisValue>(&mut self, message: impl ToRedisArgs) -> RedisResult<T> {
        Ok(from_redis_value(
            self.cache_messages_until_received_response(cmd("PING").arg(message), false)?,
        )?)
    }
    /// Sends a ping to the server
    pub fn ping<T: FromRedisValue>(&mut self) -> RedisResult<T> {
        Ok(from_redis_value(
            self.cache_messages_until_received_response(&mut cmd("PING"), false)?,
        )?)
    }

    /// Fetches the next message from the pubsub connection.  Blocks until
    /// a message becomes available.  This currently does not provide a
    /// wait not to block :(
    ///
    /// The message itself is still generic and can be converted into an
    /// appropriate type through the helper methods on it.
    pub fn get_message(&mut self) -> RedisResult<Msg> {
        if let Some(msg) = self.waiting_messages.pop_front() {
            return Ok(msg);
        }
        loop {
            if let Some(msg) = Msg::from_owned_value(self.con.read(false)?) {
                return Ok(msg);
            } else {
                continue;
            }
        }
    }

    /// Sets the read timeout for the connection.
    ///
    /// If the provided value is `None`, then `get_message` call will
    /// block indefinitely. It is an error to pass the zero `Duration` to this
    /// method.
    pub fn set_read_timeout(&self, dur: Option<Duration>) -> RedisResult<()> {
        self.con.set_read_timeout(dur)
    }
}

impl Drop for PubSub<'_> {
    fn drop(&mut self) {
        let _ = self.con.exit_pubsub();
    }
}

/// This holds the data that comes from listening to a pubsub
/// connection.  It only contains actual message data.
impl Msg {
    /// Tries to convert provided [`Value`] into [`Msg`].
    pub fn from_value(value: &Value) -> Option<Self> {
        Self::from_owned_value(value.clone())
    }

    /// Tries to convert provided [`Value`] into [`Msg`].
    pub fn from_owned_value(value: Value) -> Option<Self> {
        let mut pattern = None;
        let payload;
        let channel;

        if let Value::Push { kind, data } = value {
            return Self::from_push_info(PushInfo { kind, data });
        } else {
            let raw_msg: Vec<Value> = from_redis_value(value).ok()?;
            let mut iter = raw_msg.into_iter();
            let msg_type: String = from_redis_value(iter.next()?).ok()?;
            if msg_type == "message" {
                channel = iter.next()?;
                payload = iter.next()?;
            } else if msg_type == "pmessage" {
                pattern = Some(iter.next()?);
                channel = iter.next()?;
                payload = iter.next()?;
            } else {
                return None;
            }
        }
        Some(Self {
            payload,
            channel,
            pattern,
        })
    }

    /// Tries to convert provided [`PushInfo`] into [`Msg`].
    pub fn from_push_info(push_info: PushInfo) -> Option<Self> {
        let mut pattern = None;
        let payload;
        let channel;

        let mut iter = push_info.data.into_iter();
        if push_info.kind == PushKind::Message || push_info.kind == PushKind::SMessage {
            channel = iter.next()?;
            payload = iter.next()?;
        } else if push_info.kind == PushKind::PMessage {
            pattern = Some(iter.next()?);
            channel = iter.next()?;
            payload = iter.next()?;
        } else {
            return None;
        }

        Some(Self {
            payload,
            channel,
            pattern,
        })
    }

    /// Returns the channel this message came on.
    pub fn get_channel<T: FromRedisValue>(&self) -> RedisResult<T> {
        Ok(from_redis_value_ref(&self.channel)?)
    }

    /// Convenience method to get a string version of the channel.  Unless
    /// your channel contains non utf-8 bytes you can always use this
    /// method.  If the channel is not a valid string (which really should
    /// not happen) then the return value is `"?"`.
    pub fn get_channel_name(&self) -> &str {
        match self.channel {
            Value::BulkString(ref bytes) => from_utf8(bytes).unwrap_or("?"),
            _ => "?",
        }
    }

    /// Returns the message's payload in a specific format.
    pub fn get_payload<T: FromRedisValue>(&self) -> RedisResult<T> {
        Ok(from_redis_value_ref(&self.payload)?)
    }

    /// Returns the bytes that are the message's payload.  This can be used
    /// as an alternative to the `get_payload` function if you are interested
    /// in the raw bytes in it.
    pub fn get_payload_bytes(&self) -> &[u8] {
        match self.payload {
            Value::BulkString(ref bytes) => bytes,
            _ => b"",
        }
    }

    /// Returns true if the message was constructed from a pattern
    /// subscription.
    #[allow(clippy::wrong_self_convention)]
    pub fn from_pattern(&self) -> bool {
        self.pattern.is_some()
    }

    /// If the message was constructed from a message pattern this can be
    /// used to find out which one.  It's recommended to match against
    /// an `Option<String>` so that you do not need to use `from_pattern`
    /// to figure out if a pattern was set.
    pub fn get_pattern<T: FromRedisValue>(&self) -> RedisResult<T> {
        Ok(match self.pattern {
            None => from_redis_value_ref(&Value::Nil),
            Some(ref x) => from_redis_value_ref(x),
        }?)
    }
}

/// This function simplifies transaction management slightly.  What it
/// does is automatically watching keys and then going into a transaction
/// loop util it succeeds.  Once it goes through the results are
/// returned.
///
/// To use the transaction two pieces of information are needed: a list
/// of all the keys that need to be watched for modifications and a
/// closure with the code that should be execute in the context of the
/// transaction.  The closure is invoked with a fresh pipeline in atomic
/// mode.  To use the transaction the function needs to return the result
/// from querying the pipeline with the connection.
///
/// The end result of the transaction is then available as the return
/// value from the function call.
///
/// Example:
///
/// ```rust,no_run
/// use redis::Commands;
/// # fn do_something() -> redis::RedisResult<()> {
/// # let client = redis::Client::open("redis://127.0.0.1/").unwrap();
/// # let mut con = client.get_connection().unwrap();
/// let key = "the_key";
/// let (new_val,) : (isize,) = redis::transaction(&mut con, &[key], |con, pipe| {
///     let old_val : isize = con.get(key)?;
///     pipe
///         .set(key, old_val + 1).ignore()
///         .get(key).query(con)
/// })?;
/// println!("The incremented number is: {}", new_val);
/// # Ok(()) }
/// ```
pub fn transaction<
    C: ConnectionLike,
    K: ToRedisArgs,
    T,
    F: FnMut(&mut C, &mut Pipeline) -> RedisResult<Option<T>>,
>(
    con: &mut C,
    keys: &[K],
    func: F,
) -> RedisResult<T> {
    let mut func = func;
    loop {
        cmd("WATCH").arg(keys).exec(con)?;
        let mut p = pipe();
        let response: Option<T> = func(con, p.atomic())?;
        match response {
            None => {
                continue;
            }
            Some(response) => {
                // make sure no watch is left in the connection, even if
                // someone forgot to use the pipeline.
                cmd("UNWATCH").exec(con)?;
                return Ok(response);
            }
        }
    }
}
//TODO: for both clearing logic support sharded channels.

/// Common logic for clearing subscriptions in RESP2 async/sync
pub fn resp2_is_pub_sub_state_cleared(
    received_unsub: &mut bool,
    received_punsub: &mut bool,
    kind: &[u8],
    num: isize,
) -> bool {
    match kind.first() {
        Some(&b'u') => *received_unsub = true,
        Some(&b'p') => *received_punsub = true,
        _ => (),
    }
    *received_unsub && *received_punsub && num == 0
}

/// Common logic for clearing subscriptions in RESP3 async/sync
pub fn resp3_is_pub_sub_state_cleared(
    received_unsub: &mut bool,
    received_punsub: &mut bool,
    kind: &PushKind,
    num: isize,
) -> bool {
    match kind {
        PushKind::Unsubscribe => *received_unsub = true,
        PushKind::PUnsubscribe => *received_punsub = true,
        _ => (),
    }
    *received_unsub && *received_punsub && num == 0
}

pub fn no_sub_err_is_pub_sub_state_cleared(
    received_unsub: &mut bool,
    received_punsub: &mut bool,
    err: &ServerError,
) -> bool {
    let details = err.details();
    *received_unsub = *received_unsub
        || details
            .map(|details| details.starts_with("'unsub"))
            .unwrap_or_default();
    *received_punsub = *received_punsub
        || details
            .map(|details| details.starts_with("'punsub"))
            .unwrap_or_default();
    *received_unsub && *received_punsub
}

/// Common logic for checking real cause of hello3 command error
pub fn get_resp3_hello_command_error(err: RedisError) -> RedisError {
    if let Some(detail) = err.detail()
        && detail.starts_with("unknown command `HELLO`")
    {
        return (
            ErrorKind::RESP3NotSupported,
            "Redis Server doesn't support HELLO command therefore resp3 cannot be used",
        )
            .into();
    }
    err
}

#[cfg(test)]
mod tests {
    mod util {
        use crate::connection::connection_setup_pipeline;
        use crate::{RedisConnectionInfo, cmd};

        /// Assures that the given [`RedisConnectionInfo`] sets the given expected library name and version
        pub fn assert_lib_name_in_connection_setup_pipeline(
            redis_connection_info: &RedisConnectionInfo,
            expected_lib_name: &str,
            expected_lib_ver: &str,
        ) {
            // Build the pipeline
            let pipeline = connection_setup_pipeline(
                redis_connection_info,
                false,
                #[cfg(feature = "cache-aio")]
                None,
            )
            .0;

            let actual_packed_cmds = pipeline
                .commands
                .iter()
                .map(|c| c.get_packed_command())
                .collect::<Vec<_>>();

            let expected_lib_name_packed_cmd = cmd("CLIENT")
                .arg("SETINFO")
                .arg("LIB-NAME")
                .arg(expected_lib_name)
                .get_packed_command();
            assert!(actual_packed_cmds.contains(&expected_lib_name_packed_cmd));

            let expected_lib_ver_packed_cmd = cmd("CLIENT")
                .arg("SETINFO")
                .arg("LIB-VER")
                .arg(expected_lib_ver)
                .get_packed_command();
            assert!(actual_packed_cmds.contains(&expected_lib_ver_packed_cmd));
        }
    }

    use super::*;
    use util::assert_lib_name_in_connection_setup_pipeline;

    #[test]
    fn test_parse_redis_url() {
        let cases = vec![
            ("redis://127.0.0.1", true),
            ("redis://[::1]", true),
            ("rediss://127.0.0.1", true),
            ("rediss://[::1]", true),
            ("valkey://127.0.0.1", true),
            ("valkey://[::1]", true),
            ("valkeys://127.0.0.1", true),
            ("valkeys://[::1]", true),
            ("redis+unix:///run/redis.sock", true),
            ("valkey+unix:///run/valkey.sock", true),
            ("unix:///run/redis.sock", true),
            ("http://127.0.0.1", false),
            ("tcp://127.0.0.1", false),
        ];
        for (url, expected) in cases.into_iter() {
            let res = parse_redis_url(url);
            assert_eq!(
                res.is_some(),
                expected,
                "Parsed result of `{url}` is not expected",
            );
        }
    }

    #[test]
    fn test_url_to_tcp_connection_info() {
        let cases = vec![
            (
                url::Url::parse("redis://127.0.0.1").unwrap(),
                ConnectionInfo {
                    addr: ConnectionAddr::Tcp("127.0.0.1".to_string(), 6379),
                    redis: Default::default(),
                    tcp_settings: TcpSettings::default(),
                },
            ),
            (
                url::Url::parse("redis://[::1]").unwrap(),
                ConnectionInfo {
                    addr: ConnectionAddr::Tcp("::1".to_string(), 6379),
                    redis: Default::default(),
                    tcp_settings: TcpSettings::default(),
                },
            ),
            (
                url::Url::parse("redis://%25johndoe%25:%23%40%3C%3E%24@example.com/2").unwrap(),
                ConnectionInfo {
                    addr: ConnectionAddr::Tcp("example.com".to_string(), 6379),
                    redis: RedisConnectionInfo {
                        db: 2,
                        username: Some("%johndoe%".into()),
                        password: Some("#@<>$".into()),
                        protocol: ProtocolVersion::RESP2,
                        skip_set_lib_name: false,
                        lib_name: None,
                        lib_ver: None,
                    },
                    tcp_settings: TcpSettings::default(),
                },
            ),
            (
                url::Url::parse("redis://127.0.0.1/?protocol=2").unwrap(),
                ConnectionInfo {
                    addr: ConnectionAddr::Tcp("127.0.0.1".to_string(), 6379),
                    redis: Default::default(),
                    tcp_settings: TcpSettings::default(),
                },
            ),
            (
                url::Url::parse("redis://127.0.0.1/?protocol=resp3").unwrap(),
                ConnectionInfo {
                    addr: ConnectionAddr::Tcp("127.0.0.1".to_string(), 6379),
                    redis: RedisConnectionInfo {
                        db: 0,
                        username: None,
                        password: None,
                        protocol: ProtocolVersion::RESP3,
                        skip_set_lib_name: false,
                        lib_name: None,
                        lib_ver: None,
                    },
                    tcp_settings: TcpSettings::default(),
                },
            ),
        ];
        for (url, expected) in cases.into_iter() {
            let res = url_to_tcp_connection_info(url.clone()).unwrap();
            assert_eq!(res.addr, expected.addr, "addr of {url} is not expected");
            assert_eq!(
                res.redis.db, expected.redis.db,
                "db of {url} is not expected",
            );
            assert_eq!(
                res.redis.username, expected.redis.username,
                "username of {url} is not expected",
            );
            assert_eq!(
                res.redis.password, expected.redis.password,
                "password of {url} is not expected",
            );
        }
    }

    #[test]
    fn test_url_to_tcp_connection_info_failed() {
        let cases = vec![
            (
                url::Url::parse("redis://").unwrap(),
                "Missing hostname",
                None,
            ),
            (
                url::Url::parse("redis://127.0.0.1/db").unwrap(),
                "Invalid database number",
                None,
            ),
            (
                url::Url::parse("redis://C3%B0@127.0.0.1").unwrap(),
                "Username is not valid UTF-8 string",
                None,
            ),
            (
                url::Url::parse("redis://:C3%B0@127.0.0.1").unwrap(),
                "Password is not valid UTF-8 string",
                None,
            ),
            (
                url::Url::parse("redis://127.0.0.1/?protocol=4").unwrap(),
                "Invalid protocol version",
                Some("4"),
            ),
        ];
        for (url, expected, detail) in cases.into_iter() {
            let res = url_to_tcp_connection_info(url).unwrap_err();
            assert_eq!(res.kind(), crate::ErrorKind::InvalidClientConfig,);
            let desc = res.to_string();
            assert!(desc.contains(expected), "{desc}");
            assert_eq!(res.detail(), detail);
        }
    }

    #[test]
    #[cfg(unix)]
    fn test_url_to_unix_connection_info() {
        let cases = vec![
            (
                url::Url::parse("unix:///var/run/redis.sock").unwrap(),
                ConnectionInfo {
                    addr: ConnectionAddr::Unix("/var/run/redis.sock".into()),
                    redis: RedisConnectionInfo {
                        db: 0,
                        username: None,
                        password: None,
                        protocol: ProtocolVersion::RESP2,
                        skip_set_lib_name: false,
                        lib_name: None,
                        lib_ver: None,
                    },
                    tcp_settings: Default::default(),
                },
            ),
            (
                url::Url::parse("redis+unix:///var/run/redis.sock?db=1").unwrap(),
                ConnectionInfo {
                    addr: ConnectionAddr::Unix("/var/run/redis.sock".into()),
                    redis: RedisConnectionInfo {
                        db: 1,
                        username: None,
                        password: None,
                        protocol: ProtocolVersion::RESP2,
                        skip_set_lib_name: false,
                        lib_name: None,
                        lib_ver: None,
                    },
                    tcp_settings: TcpSettings::default(),
                },
            ),
            (
                url::Url::parse(
                    "unix:///example.sock?user=%25johndoe%25&pass=%23%40%3C%3E%24&db=2",
                )
                .unwrap(),
                ConnectionInfo {
                    addr: ConnectionAddr::Unix("/example.sock".into()),
                    redis: RedisConnectionInfo {
                        db: 2,
                        username: Some("%johndoe%".into()),
                        password: Some("#@<>$".into()),
                        protocol: ProtocolVersion::RESP2,
                        skip_set_lib_name: false,
                        lib_name: None,
                        lib_ver: None,
                    },
                    tcp_settings: TcpSettings::default(),
                },
            ),
            (
                url::Url::parse(
                    "redis+unix:///example.sock?pass=%26%3F%3D+%2A%2B&db=2&user=%25johndoe%25",
                )
                .unwrap(),
                ConnectionInfo {
                    addr: ConnectionAddr::Unix("/example.sock".into()),
                    redis: RedisConnectionInfo {
                        db: 2,
                        username: Some("%johndoe%".into()),
                        password: Some("&?= *+".into()),
                        protocol: ProtocolVersion::RESP2,
                        skip_set_lib_name: false,
                        lib_name: None,
                        lib_ver: None,
                    },
                    tcp_settings: TcpSettings::default(),
                },
            ),
            (
                url::Url::parse("redis+unix:///var/run/redis.sock?protocol=3").unwrap(),
                ConnectionInfo {
                    addr: ConnectionAddr::Unix("/var/run/redis.sock".into()),
                    redis: RedisConnectionInfo {
                        db: 0,
                        username: None,
                        password: None,
                        protocol: ProtocolVersion::RESP3,
                        skip_set_lib_name: false,
                        lib_name: None,
                        lib_ver: None,
                    },
                    tcp_settings: TcpSettings::default(),
                },
            ),
        ];
        for (url, expected) in cases.into_iter() {
            assert_eq!(
                ConnectionAddr::Unix(url.to_file_path().unwrap()),
                expected.addr,
                "addr of {url} is not expected",
            );
            let res = url_to_unix_connection_info(url.clone()).unwrap();
            assert_eq!(res.addr, expected.addr, "addr of {url} is not expected");
            assert_eq!(
                res.redis.db, expected.redis.db,
                "db of {url} is not expected",
            );
            assert_eq!(
                res.redis.username, expected.redis.username,
                "username of {url} is not expected",
            );
            assert_eq!(
                res.redis.password, expected.redis.password,
                "password of {url} is not expected",
            );
        }
    }

    #[test]
    fn redis_connection_info_lib_name_default() {
        let redis_connection_info = RedisConnectionInfo::default();

        // Check the accessors
        assert_eq!(redis_connection_info.lib_name(), None);
        assert_eq!(redis_connection_info.lib_ver(), None);

        // Check the connection setup pipeline
        assert_lib_name_in_connection_setup_pipeline(
            &redis_connection_info,
            DEFAULT_CLIENT_SETINFO_LIB_NAME,
            DEFAULT_CLIENT_SETINFO_LIB_VER,
        );
    }

    #[test]
    fn redis_connection_info_lib_name_custom() {
        let mut redis_connection_info = RedisConnectionInfo::default();

        // Mark to skip setting the lib_name. This allows to test that `set_lib_name` clears it again;
        redis_connection_info = redis_connection_info.set_skip_set_lib_name();
        assert!(redis_connection_info.skip_set_lib_name());

        // Set the lib_name
        redis_connection_info = redis_connection_info.set_lib_name("foo", "42.4711");

        // Check the accessors
        assert!(!redis_connection_info.skip_set_lib_name());
        assert_eq!(redis_connection_info.lib_name(), Some("foo"));
        assert_eq!(redis_connection_info.lib_ver(), Some("42.4711"));

        // Check the connection setup pipeline
        assert_lib_name_in_connection_setup_pipeline(&redis_connection_info, "foo", "42.4711");
    }
}

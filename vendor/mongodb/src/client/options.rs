#[cfg(test)]
mod test;

mod bulk_write;
mod parse;
mod resolver_config;

use std::{
    cmp::Ordering,
    collections::{HashMap, HashSet},
    convert::TryFrom,
    fmt::{self, Display, Formatter, Write},
    hash::{Hash, Hasher},
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    path::PathBuf,
    str::FromStr,
    time::Duration,
};

use derive_where::derive_where;
use macro_magic::export_tokens;
use serde::{de::Unexpected, Deserialize, Deserializer, Serialize, Serializer};
use serde_with::skip_serializing_none;
use std::sync::LazyLock;
use strsim::jaro_winkler;
use typed_builder::TypedBuilder;

#[cfg(any(
    feature = "zstd-compression",
    feature = "zlib-compression",
    feature = "snappy-compression"
))]
use crate::options::Compressor;
#[cfg(test)]
use crate::srv::LookupHosts;
use crate::{
    bson::{doc, Bson, Document, Timestamp, UuidRepresentation},
    client::auth::{AuthMechanism, Credential},
    concern::{Acknowledgment, ReadConcern, WriteConcern},
    error::{Error, ErrorKind, Redact, Result},
    event::EventHandler,
    options::ReadConcernLevel,
    sdam::{verify_max_staleness, DEFAULT_HEARTBEAT_FREQUENCY, MIN_HEARTBEAT_FREQUENCY},
    selection_criteria::{ReadPreference, SelectionCriteria, TagSet},
    serde_util,
    srv::{OriginalSrvInfo, SrvResolver},
};

pub use bulk_write::*;
#[cfg(feature = "dns-resolver")]
pub use resolver_config::ResolverConfig;
#[cfg(not(feature = "dns-resolver"))]
pub(crate) use resolver_config::ResolverConfig;

pub(crate) const DEFAULT_PORT: u16 = 27017;

const TLS_INSECURE: &str = "tlsinsecure";
const TLS_ALLOW_INVALID_CERTIFICATES: &str = "tlsallowinvalidcertificates";
#[cfg(feature = "openssl-tls")]
const TLS_ALLOW_INVALID_HOSTNAMES: &str = "tlsallowinvalidhostnames";
const PROXY_HOST: &str = "proxyhost";
const PROXY_PORT: &str = "proxyport";
const PROXY_USERNAME: &str = "proxyusername";
const PROXY_PASSWORD: &str = "proxypassword";
const URI_OPTIONS: &[&str] = &[
    "appname",
    "authmechanism",
    "authsource",
    "authmechanismproperties",
    "compressors",
    "connecttimeoutms",
    "directconnection",
    "heartbeatfrequencyms",
    "journal",
    "localthresholdms",
    "maxidletimems",
    "maxstalenessseconds",
    "maxpoolsize",
    "minpoolsize",
    "maxconnecting",
    PROXY_HOST,
    PROXY_PORT,
    PROXY_USERNAME,
    PROXY_PASSWORD,
    "readconcernlevel",
    "readpreference",
    "readpreferencetags",
    "replicaset",
    "retrywrites",
    "retryreads",
    "servermonitoringmode",
    "serverselectiontimeoutms",
    "sockettimeoutms",
    "tls",
    "ssl",
    TLS_INSECURE,
    TLS_ALLOW_INVALID_CERTIFICATES,
    "tlscafile",
    "tlscertificatekeyfile",
    "uuidRepresentation",
    "w",
    "waitqueuetimeoutms",
    "wtimeoutms",
    "zlibcompressionlevel",
    "srvservicename",
    "adaptiveretries",
    "maxadaptiveretries",
];

/// Reserved characters as defined by [Section 2.2 of RFC-3986](https://tools.ietf.org/html/rfc3986#section-2.2).
/// Usernames / passwords that contain these characters must instead include the URL encoded version
/// of them when included as part of the connection string.
static USERINFO_RESERVED_CHARACTERS: LazyLock<HashSet<&'static char>> =
    LazyLock::new(|| [':', '/', '?', '#', '[', ']', '@'].iter().collect());

static ILLEGAL_DATABASE_CHARACTERS: LazyLock<HashSet<&'static char>> =
    LazyLock::new(|| ['/', '\\', ' ', '"', '$'].iter().collect());

/// An enum representing the address of a MongoDB server.
#[derive(Clone, Debug, Eq, Serialize)]
#[non_exhaustive]
pub enum ServerAddress {
    /// A TCP/IP host and port combination.
    Tcp {
        /// The hostname or IP address where the MongoDB server can be found.
        host: String,

        /// The TCP port that the MongoDB server is listening on.
        ///
        /// The default is 27017.
        port: Option<u16>,
    },
    /// A Unix Domain Socket path.
    #[cfg(unix)]
    Unix {
        /// The path to the Unix Domain Socket.
        path: PathBuf,
    },
}

impl From<SocketAddr> for ServerAddress {
    fn from(item: SocketAddr) -> Self {
        ServerAddress::Tcp {
            host: item.ip().to_string(),
            port: Some(item.port()),
        }
    }
}

impl<'de> Deserialize<'de> for ServerAddress {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum ServerAddressHelper {
            String(String),
            Object { host: String, port: Option<u16> },
        }

        let helper = ServerAddressHelper::deserialize(deserializer)?;
        match helper {
            ServerAddressHelper::String(string) => {
                Self::parse(string).map_err(serde::de::Error::custom)
            }
            ServerAddressHelper::Object { host, port } => {
                #[cfg(unix)]
                if host.ends_with("sock") {
                    return Ok(Self::Unix {
                        path: PathBuf::from(host),
                    });
                }

                Ok(Self::Tcp { host, port })
            }
        }
    }
}

impl Default for ServerAddress {
    fn default() -> Self {
        Self::Tcp {
            host: "localhost".into(),
            port: None,
        }
    }
}

impl PartialEq for ServerAddress {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (
                Self::Tcp { host, port },
                Self::Tcp {
                    host: other_host,
                    port: other_port,
                },
            ) => host == other_host && port.unwrap_or(27017) == other_port.unwrap_or(27017),
            #[cfg(unix)]
            (Self::Unix { path }, Self::Unix { path: other_path }) => path == other_path,
            #[cfg(unix)]
            _ => false,
        }
    }
}

impl Hash for ServerAddress {
    fn hash<H>(&self, state: &mut H)
    where
        H: Hasher,
    {
        match self {
            Self::Tcp { host, port } => {
                host.hash(state);
                port.unwrap_or(27017).hash(state);
            }
            #[cfg(unix)]
            Self::Unix { path } => path.hash(state),
        }
    }
}

impl FromStr for ServerAddress {
    type Err = Error;
    fn from_str(address: &str) -> Result<Self> {
        ServerAddress::parse(address)
    }
}

impl ServerAddress {
    /// Parses an address string into a [`ServerAddress`].
    pub fn parse(address: impl AsRef<str>) -> Result<Self> {
        let address = address.as_ref();

        if address.ends_with(".sock") {
            #[cfg(unix)]
            {
                let address = percent_decode(address, "unix domain sockets must be URL-encoded")?;
                return Ok(Self::Unix {
                    path: PathBuf::from(address),
                });
            }
            #[cfg(not(unix))]
            return Err(ErrorKind::InvalidArgument {
                message: "unix domain sockets are not supported on this platform".to_string(),
            }
            .into());
        }

        let (hostname, port) = if let Some(ip_literal) = address.strip_prefix("[") {
            let Some((hostname, port)) = ip_literal.split_once("]") else {
                return Err(ErrorKind::InvalidArgument {
                    message: format!(
                        "invalid server address {}: missing closing ']' in IP literal hostname",
                        Redact(address),
                    ),
                }
                .into());
            };

            if let Err(parse_error) = Ipv6Addr::from_str(hostname) {
                return Err(ErrorKind::InvalidArgument {
                    message: format!("invalid server address {}: {parse_error}", Redact(address)),
                }
                .into());
            }

            let port = if port.is_empty() {
                None
            } else if let Some(port) = port.strip_prefix(":") {
                Some(port)
            } else {
                return Err(ErrorKind::InvalidArgument {
                    message: format!(
                        "invalid server address {}: the hostname can only be followed by a port \
                         prefixed with ':', got {port}",
                        Redact(address)
                    ),
                }
                .into());
            };

            (hostname, port)
        } else {
            match address.split_once(":") {
                Some((hostname, port)) => (hostname, Some(port)),
                None => (address, None),
            }
        };

        if hostname.is_empty() {
            return Err(ErrorKind::InvalidArgument {
                message: format!(
                    "invalid server address {}: the hostname cannot be empty",
                    Redact(address)
                ),
            }
            .into());
        }

        let normalized_hostname = if let Ok(v4) = hostname.parse::<Ipv4Addr>() {
            v4.to_string()
        } else if let Ok(v6) = hostname.parse::<Ipv6Addr>() {
            v6.to_string()
        } else {
            hostname.to_lowercase()
        };

        let port = if let Some(port) = port {
            match u16::from_str(port) {
                Ok(0) | Err(_) => {
                    return Err(ErrorKind::InvalidArgument {
                        message: format!(
                            "invalid server address {}: the port must be an integer between 1 and \
                             65535, got {port}",
                            Redact(address)
                        ),
                    }
                    .into());
                }
                Ok(port) => Some(port),
            }
        } else {
            None
        };

        Ok(Self::Tcp {
            host: normalized_hostname,
            port,
        })
    }

    #[cfg(feature = "dns-resolver")]
    pub(crate) fn host(&self) -> std::borrow::Cow<'_, str> {
        match self {
            Self::Tcp { host, .. } => std::borrow::Cow::Borrowed(host.as_str()),
            #[cfg(unix)]
            Self::Unix { path } => path.to_string_lossy(),
        }
    }
}

impl fmt::Display for ServerAddress {
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Self::Tcp { host, port } => {
                write!(fmt, "{}:{}", host, port.unwrap_or(DEFAULT_PORT))
            }
            #[cfg(unix)]
            Self::Unix { path } => write!(fmt, "{}", path.display()),
        }
    }
}

/// Specifies the server API version to declare
#[derive(Clone, Debug, PartialEq, Serialize)]
#[non_exhaustive]
pub enum ServerApiVersion {
    /// Use API version 1.
    #[serde(rename = "1")]
    V1,
}

impl FromStr for ServerApiVersion {
    type Err = Error;

    fn from_str(str: &str) -> Result<Self> {
        match str {
            "1" => Ok(Self::V1),
            _ => Err(ErrorKind::InvalidArgument {
                message: format!("invalid server api version string: {str}"),
            }
            .into()),
        }
    }
}

impl Display for ServerApiVersion {
    fn fmt(&self, f: &mut Formatter) -> fmt::Result {
        match self {
            Self::V1 => write!(f, "1"),
        }
    }
}

impl<'de> Deserialize<'de> for ServerApiVersion {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;

        ServerApiVersion::from_str(&s).map_err(|_| {
            serde::de::Error::invalid_value(Unexpected::Str(&s), &"a valid version number")
        })
    }
}

/// Options used to declare a stable server API.  For more information, see the [Stable API](
/// https://www.mongodb.com/docs/v5.0/reference/stable-api/) manual page.
#[serde_with::skip_serializing_none]
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct ServerApi {
    /// The declared API version.
    #[serde(rename = "apiVersion")]
    #[builder(!default)]
    pub version: ServerApiVersion,

    /// Whether the MongoDB server should reject all commands that are not part of the
    /// declared API version. This includes command options and aggregation pipeline stages.
    #[serde(rename = "apiStrict")]
    pub strict: Option<bool>,

    /// Whether the MongoDB server should return command failures when functionality that is
    /// deprecated from the declared API version is used.
    /// Note that at the time of this writing, no deprecations in version 1 exist.
    #[serde(rename = "apiDeprecationErrors")]
    pub deprecation_errors: Option<bool>,
}

/// Configuration for connecting to a SOCKS5 proxy.
#[cfg(feature = "socks5-proxy")]
#[derive(Clone, Debug, Deserialize, PartialEq, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct Socks5Proxy {
    /// The hostname or IP address on which the proxy is listening.
    #[builder(!default)]
    pub host: String,

    /// The port on which the proxy is listening. Defaults to 1080 if unset.
    pub port: Option<u16>,

    /// A username/password pair to authenticate to the proxy.
    pub authentication: Option<(String, String)>,
}

/// Dummy struct for internal use.
#[cfg(not(feature = "socks5-proxy"))]
#[derive(Clone, Debug)]
pub(crate) struct Socks5Proxy;

#[cfg(feature = "socks5-proxy")]
impl Socks5Proxy {
    fn serialize<S>(
        proxy: &Option<Socks5Proxy>,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Helper<'a> {
            proxy_host: &'a String,
            proxy_port: Option<u16>,
            proxy_username: Option<&'a String>,
            proxy_password: Option<&'a String>,
        }

        if let Some(proxy) = proxy.as_ref() {
            let helper = Helper {
                proxy_host: &proxy.host,
                proxy_port: proxy.port,
                proxy_username: proxy.authentication.as_ref().map(|auth| &auth.0),
                proxy_password: proxy.authentication.as_ref().map(|auth| &auth.1),
            };
            helper.serialize(serializer)
        } else {
            serializer.serialize_none()
        }
    }
}

/// Contains the options that can be used to create a new [`Client`](../struct.Client.html).
#[derive(Clone, Deserialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[derive_where(Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ClientOptions {
    /// The initial list of seeds that the Client should connect to.
    ///
    /// Note that by default, the driver will autodiscover other nodes in the cluster. To connect
    /// directly to a single server (rather than autodiscovering the rest of the cluster), set the
    /// `direct_connection` field to `true`.
    #[builder(default_code = "vec![ServerAddress::Tcp {
        host: \"localhost\".to_string(),
        port: Some(27017),
    }]")]
    #[serde(default = "default_hosts")]
    pub hosts: Vec<ServerAddress>,

    /// The application name that the Client will send to the server as part of the handshake. This
    /// can be used in combination with the server logs to determine which Client is connected to a
    /// server.
    pub app_name: Option<String>,

    /// The allowed compressors to use to compress messages sent to and decompress messages
    /// received from the server. This list should be specified in priority order, as the
    /// compressor used for messages will be the first compressor in this list that is also
    /// supported by the server selected for operations.
    #[cfg(any(
        feature = "zstd-compression",
        feature = "zlib-compression",
        feature = "snappy-compression"
    ))]
    #[serde(skip)]
    pub compressors: Option<Vec<Compressor>>,

    /// The handler that should process all Connection Monitoring and Pooling events.
    #[derive_where(skip)]
    #[builder(setter(strip_option))]
    #[serde(skip)]
    pub cmap_event_handler: Option<EventHandler<crate::event::cmap::CmapEvent>>,

    /// The handler that should process all command-related events.
    ///
    /// Note that monitoring command events may incur a performance penalty.
    #[derive_where(skip)]
    #[builder(setter(strip_option))]
    #[serde(skip)]
    pub command_event_handler: Option<EventHandler<crate::event::command::CommandEvent>>,

    /// The connect timeout passed to each underlying TcpStream when attemtping to connect to the
    /// server.
    ///
    /// The default value is 10 seconds.
    pub connect_timeout: Option<Duration>,

    /// The credential to use for authenticating connections made by this client.
    pub credential: Option<Credential>,

    /// Specifies whether the Client should directly connect to a single host rather than
    /// autodiscover all servers in the cluster.
    ///
    /// The default value is false.
    pub direct_connection: Option<bool>,

    /// Extra information to append to the driver version in the metadata of the handshake with the
    /// server. This should be used by libraries wrapping the driver, e.g. ODMs.
    pub driver_info: Option<DriverInfo>,

    /// The amount of time each monitoring thread should wait between performing server checks.
    ///
    /// The default value is 10 seconds.
    pub heartbeat_freq: Option<Duration>,

    /// Whether or not the client is connecting to a MongoDB cluster through a load balancer.
    #[builder(setter(skip))]
    #[serde(rename = "loadbalanced")]
    pub load_balanced: Option<bool>,

    /// When running a read operation with a ReadPreference that allows selecting secondaries,
    /// `local_threshold` is used to determine how much longer the average round trip time between
    /// the driver and server is allowed compared to the least round trip time of all the suitable
    /// servers. For example, if the average round trip times of the suitable servers are 5 ms, 10
    /// ms, and 15 ms, and the local threshold is 8 ms, then the first two servers are within the
    /// latency window and could be chosen for the operation, but the last one is not.
    ///
    /// A value of zero indicates that there is no latency window, so only the server with the
    /// lowest average round trip time is eligible.
    ///
    /// The default value is 15 ms.
    pub local_threshold: Option<Duration>,

    /// The amount of time that a connection can remain idle in a connection pool before being
    /// closed. A value of zero indicates that connections should not be closed due to being idle.
    ///
    /// By default, connections will not be closed due to being idle.
    pub max_idle_time: Option<Duration>,

    /// The maximum amount of connections that the Client should allow to be created in a
    /// connection pool for a given server. If an operation is attempted on a server while
    /// `max_pool_size` connections are checked out, the operation will block until an in-progress
    /// operation finishes and its connection is checked back into the pool.
    ///
    /// The default value is 10.
    pub max_pool_size: Option<u32>,

    /// The minimum number of connections that should be available in a server's connection pool at
    /// a given time. If fewer than `min_pool_size` connections are in the pool, connections will
    /// be added to the pool in the background until `min_pool_size` is reached.
    ///
    /// The default value is 0.
    pub min_pool_size: Option<u32>,

    /// The maximum number of new connections that can be created concurrently.
    ///
    /// If specified, this value must be greater than 0. The default is 2.
    pub max_connecting: Option<u32>,

    /// Specifies the default read concern for operations performed on the Client. See the
    /// ReadConcern type documentation for more details.
    pub read_concern: Option<ReadConcern>,

    /// The name of the replica set that the Client should connect to.
    pub repl_set_name: Option<String>,

    /// Whether or not the client should retry a read operation if the operation fails.
    ///
    /// The default value is true.
    pub retry_reads: Option<bool>,

    /// Whether or not the client should retry a write operation if the operation fails.
    ///
    /// The default value is true.
    pub retry_writes: Option<bool>,

    /// Configures which server monitoring protocol to use.
    ///
    /// The default is [`Auto`](ServerMonitoringMode::Auto).
    pub server_monitoring_mode: Option<ServerMonitoringMode>,

    /// The handler that should process all Server Discovery and Monitoring events.
    #[derive_where(skip)]
    #[builder(setter(strip_option))]
    #[serde(skip)]
    pub sdam_event_handler: Option<EventHandler<crate::event::sdam::SdamEvent>>,

    /// The default selection criteria for operations performed on the Client. See the
    /// SelectionCriteria type documentation for more details.
    pub selection_criteria: Option<SelectionCriteria>,

    /// The declared API version for this client.
    /// The declared API version is applied to all commands run through the client, including those
    /// sent through any handle derived from the client.
    ///
    /// Specifying stable API options in the command document passed to `run_command` AND
    /// declaring an API version on the client is not supported and is considered undefined
    /// behaviour. To run any command with a different API version or without declaring one, create
    /// a separate client that declares the appropriate API version.
    ///
    /// For more information, see the [Stable API](
    /// https://www.mongodb.com/docs/v5.0/reference/stable-api/) manual page.
    pub server_api: Option<ServerApi>,

    /// The amount of time the Client should attempt to select a server for an operation before
    /// timing outs
    ///
    /// The default value is 30 seconds.
    pub server_selection_timeout: Option<Duration>,

    /// Default database for this client.
    ///
    /// By default, no default database is specified.
    pub default_database: Option<String>,

    /// Overrides the default "mongodb" service name for SRV lookup in both discovery and polling
    pub srv_service_name: Option<String>,

    /// The TLS configuration for the Client to use in its connections with the server.
    ///
    /// By default, TLS is disabled.
    pub tls: Option<Tls>,

    /// The maximum number of bytes that the driver should include in a tracing event
    /// or log message's extended JSON string representation of a BSON document, e.g. a
    /// command or reply from the server.
    /// If truncation of a document at the exact specified length would occur in the middle
    /// of a Unicode codepoint, the document will be truncated at the closest larger length
    /// which falls on a boundary between codepoints.
    /// Note that in cases where truncation occurs the output will not be valid JSON.
    ///
    /// The default value is 1000.
    #[cfg(feature = "tracing-unstable")]
    pub tracing_max_document_length_bytes: Option<usize>,

    /// Specifies the default write concern for operations performed on the Client. See the
    /// WriteConcern type documentation for more details.
    pub write_concern: Option<WriteConcern>,

    /// Limit on the number of mongos connections that may be created for sharded topologies.
    pub srv_max_hosts: Option<u32>,

    /// Configuration for opentelemetry.
    #[cfg(feature = "opentelemetry")]
    pub tracing: Option<crate::otel::OpentelemetryOptions>,

    /// Configuration for connecting to a SOCKS5 proxy.
    #[cfg(feature = "socks5-proxy")]
    pub socks5_proxy: Option<Socks5Proxy>,

    /// Enable a per-client token bucket to limit overload error retry attempts. Defaults to false.
    pub(crate) adaptive_retries: Option<bool>,

    /// The maximum number of retries to perform when overload errors are encountered. Defaults to
    /// 2.
    ///
    /// This option only has an effect with MongoDB Atlas server version 9.0 and above.
    pub max_adaptive_retries: Option<u32>,

    /// Whether to enable overload retargeting when overload errors are encountered. When overload
    /// retargeting is enabled, the server on which an overload error occurs is deprioritized
    /// when selecting a server for a retry attempt. Defaults to false.
    ///
    /// This option only has an effect with MongoDB Atlas server version 9.0 and above.
    pub enable_overload_retargeting: Option<bool>,

    /// Information from the SRV URI that generated these client options, if applicable.
    #[builder(setter(skip))]
    #[serde(skip)]
    #[derive_where(skip(Debug))]
    pub(crate) original_srv_info: Option<OriginalSrvInfo>,

    #[cfg(test)]
    #[builder(setter(skip))]
    #[derive_where(skip(Debug))]
    pub(crate) original_uri: Option<String>,

    /// Configuration of the DNS resolver used for SRV and TXT lookups.
    /// By default, the host system's resolver configuration will be used.
    #[builder(setter(skip))]
    #[serde(skip)]
    #[derive_where(skip(Debug))]
    #[cfg(feature = "dns-resolver")]
    pub(crate) resolver_config: Option<ResolverConfig>,

    /// Control test behavior of the client.
    #[cfg(test)]
    #[builder(setter(skip))]
    #[serde(skip)]
    #[derive_where(skip)]
    pub(crate) test_options: Option<TestOptions>,
}

#[cfg(test)]
#[derive(Debug, Clone, Default)]
pub(crate) struct TestOptions {
    /// Override MIN_HEARTBEAT_FREQUENCY.
    pub(crate) min_heartbeat_freq: Option<Duration>,

    /// Disable server and SRV-polling monitor threads.
    pub(crate) disable_monitoring_threads: bool,

    /// Mock response for `SrvPollingMonitor::lookup_hosts`.
    pub(crate) mock_lookup_hosts: Option<Result<LookupHosts>>,

    /// Async-capable command event listener.
    pub(crate) async_event_listener: Option<TestEventSender>,

    /// Callback to receive hello commands.
    pub(crate) hello_cb: Option<EventHandler<crate::cmap::Command>>,

    /// The value to use for jitter when calculating retry backoff.
    pub(crate) jitter: Option<f32>,

    /// The amount of time to use for all retry backoffs. Set to a large number to detect the
    /// absence/presence of backoff.
    pub(crate) backoff: Option<Duration>,

    pub(crate) topology_worker_shutdown_delay: Option<Duration>,
}

pub(crate) type TestEventSender = tokio::sync::mpsc::Sender<
    crate::runtime::AcknowledgedMessage<crate::event::command::CommandEvent>,
>;

fn default_hosts() -> Vec<ServerAddress> {
    vec![ServerAddress::default()]
}

impl Default for ClientOptions {
    fn default() -> Self {
        Self::builder().build()
    }
}

#[cfg(test)]
impl Serialize for ClientOptions {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        #[derive(Serialize)]
        struct ClientOptionsHelper<'a> {
            appname: &'a Option<String>,

            #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
            connecttimeoutms: &'a Option<Duration>,

            #[serde(flatten, serialize_with = "Credential::serialize")]
            credential: &'a Option<Credential>,

            directconnection: &'a Option<bool>,

            #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
            heartbeatfrequencyms: &'a Option<Duration>,

            #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
            localthresholdms: &'a Option<Duration>,

            #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
            maxidletimems: &'a Option<Duration>,

            maxpoolsize: &'a Option<u32>,

            minpoolsize: &'a Option<u32>,

            maxconnecting: &'a Option<u32>,

            #[serde(flatten, serialize_with = "ReadConcern::serialize")]
            readconcern: &'a Option<ReadConcern>,

            replicaset: &'a Option<String>,

            retryreads: &'a Option<bool>,

            retrywrites: &'a Option<bool>,

            servermonitoringmode: Option<String>,

            #[serde(
                flatten,
                serialize_with = "SelectionCriteria::serialize_for_client_options"
            )]
            selectioncriteria: &'a Option<SelectionCriteria>,

            #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
            serverselectiontimeoutms: &'a Option<Duration>,

            #[serde(flatten, serialize_with = "Tls::serialize")]
            tls: &'a Option<Tls>,

            #[serde(flatten, serialize_with = "WriteConcern::serialize")]
            writeconcern: &'a Option<WriteConcern>,

            zlibcompressionlevel: &'a Option<i32>,

            loadbalanced: &'a Option<bool>,

            srvmaxhosts: Option<i32>,

            srvservicename: &'a Option<String>,

            adaptiveretries: &'a Option<bool>,

            maxadaptiveretries: &'a Option<u32>,

            enableoverloadretargeting: &'a Option<bool>,

            #[cfg(feature = "socks5-proxy")]
            #[serde(flatten, serialize_with = "Socks5Proxy::serialize")]
            socks5proxy: &'a Option<Socks5Proxy>,
        }

        let client_options = ClientOptionsHelper {
            appname: &self.app_name,
            connecttimeoutms: &self.connect_timeout,
            credential: &self.credential,
            directconnection: &self.direct_connection,
            heartbeatfrequencyms: &self.heartbeat_freq,
            localthresholdms: &self.local_threshold,
            maxidletimems: &self.max_idle_time,
            maxpoolsize: &self.max_pool_size,
            minpoolsize: &self.min_pool_size,
            maxconnecting: &self.max_connecting,
            readconcern: &self.read_concern,
            replicaset: &self.repl_set_name,
            retryreads: &self.retry_reads,
            retrywrites: &self.retry_writes,
            servermonitoringmode: self
                .server_monitoring_mode
                .as_ref()
                .map(|m| format!("{m:?}").to_lowercase()),
            selectioncriteria: &self.selection_criteria,
            serverselectiontimeoutms: &self.server_selection_timeout,
            tls: &self.tls,
            writeconcern: &self.write_concern,
            loadbalanced: &self.load_balanced,
            zlibcompressionlevel: &None,
            srvmaxhosts: self
                .srv_max_hosts
                .map(|v| v.try_into())
                .transpose()
                .map_err(serde::ser::Error::custom)?,
            srvservicename: &self.srv_service_name,
            adaptiveretries: &self.adaptive_retries,
            maxadaptiveretries: &self.max_adaptive_retries,
            enableoverloadretargeting: &self.enable_overload_retargeting,
            #[cfg(feature = "socks5-proxy")]
            socks5proxy: &self.socks5_proxy,
        };

        client_options.serialize(serializer)
    }
}

// For ConnectionString serialization
fn serialize_uuid_rep_option<S>(
    value: &Option<UuidRepresentation>,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error>
where
    S: Serializer,
{
    #[non_exhaustive]
    #[derive(Serialize)]
    #[serde(remote = "UuidRepresentation")]
    enum UuidRepresentationForSerialize {
        Standard,
        CSharpLegacy,
        JavaLegacy,
        PythonLegacy,
    }
    match value {
        Some(rep) => UuidRepresentationForSerialize::serialize(rep, serializer),
        None => serializer.serialize_none(),
    }
}

/// Contains the options that can be set via a MongoDB connection string.
///
/// The format of a MongoDB connection string is described [here](https://www.mongodb.com/docs/manual/reference/connection-string/#connection-string-formats).
#[skip_serializing_none]
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct ConnectionString {
    /// The initial list of seeds that the Client should connect to, or a DNS name used for SRV
    /// lookup of the initial seed list.
    ///
    /// Note that by default, the driver will autodiscover other nodes in the cluster. To connect
    /// directly to a single server (rather than autodiscovering the rest of the cluster), set the
    /// `direct_connection` field to `true`.
    pub host_info: HostInfo,

    /// The application name that the Client will send to the server as part of the handshake. This
    /// can be used in combination with the server logs to determine which Client is connected to a
    /// server.
    pub app_name: Option<String>,

    /// The TLS configuration for the Client to use in its connections with the server.
    ///
    /// By default, TLS is disabled.
    #[serde(serialize_with = "Tls::serialize")]
    pub tls: Option<Tls>,

    /// The amount of time each monitoring thread should wait between performing server checks.
    ///
    /// The default value is 10 seconds.
    #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
    pub heartbeat_frequency: Option<Duration>,

    /// When running a read operation with a ReadPreference that allows selecting secondaries,
    /// `local_threshold` is used to determine how much longer the average round trip time between
    /// the driver and server is allowed compared to the least round trip time of all the suitable
    /// servers. For example, if the average round trip times of the suitable servers are 5 ms, 10
    /// ms, and 15 ms, and the local threshold is 8 ms, then the first two servers are within the
    /// latency window and could be chosen for the operation, but the last one is not.
    ///
    /// A value of zero indicates that there is no latency window, so only the server with the
    /// lowest average round trip time is eligible.
    ///
    /// The default value is 15 ms.
    #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
    pub local_threshold: Option<Duration>,

    /// Specifies the default read concern for operations performed on the Client. See the
    /// ReadConcern type documentation for more details.
    #[serde(serialize_with = "ReadConcern::serialize")]
    pub read_concern: Option<ReadConcern>,

    /// The name of the replica set that the Client should connect to.
    pub replica_set: Option<String>,

    /// Specifies the default write concern for operations performed on the Client. See the
    /// WriteConcern type documentation for more details.
    #[serde(serialize_with = "WriteConcern::serialize")]
    pub write_concern: Option<WriteConcern>,

    /// The amount of time the Client should attempt to select a server for an operation before
    /// timing outs
    ///
    /// The default value is 30 seconds.
    #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
    pub server_selection_timeout: Option<Duration>,

    /// The maximum amount of connections that the Client should allow to be created in a
    /// connection pool for a given server. If an operation is attempted on a server while
    /// `max_pool_size` connections are checked out, the operation will block until an in-progress
    /// operation finishes and its connection is checked back into the pool.
    ///
    /// The default value is 10.
    pub max_pool_size: Option<u32>,

    /// The minimum number of connections that should be available in a server's connection pool at
    /// a given time. If fewer than `min_pool_size` connections are in the pool, connections will
    /// be added to the pool in the background until `min_pool_size` is reached.
    ///
    /// The default value is 0.
    pub min_pool_size: Option<u32>,

    /// The maximum number of new connections that can be created concurrently.
    ///
    /// If specified, this value must be greater than 0. The default is 2.
    pub max_connecting: Option<u32>,

    /// The amount of time that a connection can remain idle in a connection pool before being
    /// closed. A value of zero indicates that connections should not be closed due to being idle.
    ///
    /// By default, connections will not be closed due to being idle.
    #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
    pub max_idle_time: Option<Duration>,

    #[cfg(any(
        feature = "zstd-compression",
        feature = "zlib-compression",
        feature = "snappy-compression"
    ))]
    /// The compressors that the Client is willing to use in the order they are specified
    /// in the configuration.  The Client sends this list of compressors to the server.
    /// The server responds with the intersection of its supported list of compressors.
    /// The order of compressors indicates preference of compressors.
    pub compressors: Option<Vec<Compressor>>,

    /// The connect timeout passed to each underlying TcpStream when attempting to connect to the
    /// server.
    ///
    /// The default value is 10 seconds.
    #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
    pub connect_timeout: Option<Duration>,

    /// Whether or not the client should retry a read operation if the operation fails.
    ///
    /// The default value is true.
    pub retry_reads: Option<bool>,

    /// Whether or not the client should retry a write operation if the operation fails.
    ///
    /// The default value is true.
    pub retry_writes: Option<bool>,

    /// Configures which server monitoring protocol to use.
    ///
    /// The default is [`Auto`](ServerMonitoringMode::Auto).
    pub server_monitoring_mode: Option<ServerMonitoringMode>,

    /// Specifies whether the Client should directly connect to a single host rather than
    /// autodiscover all servers in the cluster.
    ///
    /// The default value is false.
    pub direct_connection: Option<bool>,

    /// The credential to use for authenticating connections made by this client.
    #[serde(serialize_with = "Credential::serialize")]
    pub credential: Option<Credential>,

    /// Default database for this client.
    ///
    /// By default, no default database is specified.
    pub default_database: Option<String>,

    /// Whether or not the client is connecting to a MongoDB cluster through a load balancer.
    pub load_balanced: Option<bool>,

    /// Amount of time spent attempting to send or receive on a socket before timing out; note that
    /// this only applies to application operations, not server discovery and monitoring.
    #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
    #[deprecated(
        since = "3.5.0",
        note = "the Rust driver does not support socketTimeoutMS"
    )]
    pub socket_timeout: Option<Duration>,

    /// Default read preference for the client.
    pub read_preference: Option<ReadPreference>,

    /// The [`UuidRepresentation`] to use when decoding [`Binary`](crate::bson::Binary) values with
    /// the [`UuidOld`](crate::bson::spec::BinarySubtype::UuidOld) subtype. This is not used by
    /// the driver; client code can use this when deserializing relevant values with
    /// [`Binary::to_uuid_with_representation`](crate::bson::binary::Binary::to_uuid_with_representation).
    #[serde(serialize_with = "serialize_uuid_rep_option")]
    pub uuid_representation: Option<UuidRepresentation>,

    /// Limit on the number of mongos connections that may be created for sharded topologies.
    pub srv_max_hosts: Option<u32>,

    /// Overrides the default "mongodb" service name for SRV lookup in both discovery and polling
    pub srv_service_name: Option<String>,

    /// Configuration for connecting to a SOCKS5 proxy.
    #[cfg(feature = "socks5-proxy")]
    #[serde(serialize_with = "Socks5Proxy::serialize")]
    pub socks5_proxy: Option<Socks5Proxy>,

    /// Enable a per-client token bucket to limit overload error retry attempts. Defaults to false.
    pub(crate) adaptive_retries: Option<bool>,

    /// The maximum number of retries to perform when overload errors are encountered. Defaults to
    /// 2.
    ///
    /// This option only has an effect with MongoDB Atlas server version 9.0 and above.
    pub max_adaptive_retries: Option<u32>,

    /// Whether to enable overload retargeting when overload errors are encountered. When overload
    /// retargeting is enabled, the server on which an overload error occurs is deprioritized
    /// when selecting a server for a retry attempt. Defaults to false.
    ///
    /// This option only has an effect with MongoDB Atlas server version 9.0 and above.
    pub enable_overload_retargeting: Option<bool>,

    #[serde(serialize_with = "serde_util::serialize_duration_option_as_int_millis")]
    wait_queue_timeout: Option<Duration>,
    tls_insecure: Option<bool>,

    #[cfg(test)]
    #[serde(skip_serializing)]
    original_uri: String,
}

/// Elements from the connection string that are not top-level fields in `ConnectionString`.
#[derive(Debug, Default)]
struct ConnectionStringParts {
    read_preference_tags: Option<Vec<TagSet>>,
    max_staleness: Option<Duration>,
    auth_mechanism: Option<AuthMechanism>,
    auth_mechanism_properties: Option<Document>,
    zlib_compression: Option<i32>,
    auth_source: Option<String>,
    #[cfg(feature = "socks5-proxy")]
    proxy_host: Option<String>,
    #[cfg(feature = "socks5-proxy")]
    proxy_port: Option<u16>,
    #[cfg(feature = "socks5-proxy")]
    proxy_username: Option<String>,
    #[cfg(feature = "socks5-proxy")]
    proxy_password: Option<String>,
}

/// Specification for mongodb server connections.
#[derive(Debug, PartialEq, Clone, Serialize)]
#[non_exhaustive]
pub enum HostInfo {
    /// A set of addresses.
    HostIdentifiers(Vec<ServerAddress>),
    /// A DNS record for SRV lookup.
    DnsRecord(String),
}

impl Default for HostInfo {
    fn default() -> Self {
        Self::HostIdentifiers(vec![])
    }
}

impl HostInfo {
    async fn resolve(
        self,
        resolver_config: Option<ResolverConfig>,
        srv_service_name: Option<String>,
    ) -> Result<ResolvedHostInfo> {
        Ok(match self {
            Self::HostIdentifiers(hosts) => ResolvedHostInfo::HostIdentifiers(hosts),
            Self::DnsRecord(hostname) => {
                let mut resolver =
                    SrvResolver::new(resolver_config.clone(), srv_service_name).await?;
                let config = resolver.resolve_client_options(&hostname).await?;
                ResolvedHostInfo::DnsRecord { hostname, config }
            }
        })
    }
}

enum ResolvedHostInfo {
    HostIdentifiers(Vec<ServerAddress>),
    DnsRecord {
        hostname: String,
        config: crate::srv::ResolvedConfig,
    },
}

/// Specifies whether TLS configuration should be used with the operations that the
/// [`Client`](../struct.Client.html) performs.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub enum Tls {
    /// Enable TLS with the specified options.
    Enabled(TlsOptions),

    /// Disable TLS.
    Disabled,
}

impl From<TlsOptions> for Tls {
    fn from(options: TlsOptions) -> Self {
        Self::Enabled(options)
    }
}

impl From<TlsOptions> for Option<Tls> {
    fn from(options: TlsOptions) -> Self {
        Some(Tls::Enabled(options))
    }
}

impl Tls {
    pub(crate) fn serialize<S>(
        tls: &Option<Tls>,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match tls {
            Some(Tls::Enabled(tls_options)) => TlsOptions::serialize(tls_options, serializer),
            _ => serializer.serialize_none(),
        }
    }
}

/// Specifies the TLS configuration that the [`Client`](../struct.Client.html) should use.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct TlsOptions {
    /// Whether or not the [`Client`](../struct.Client.html) should return an error if the server
    /// presents an invalid certificate. This setting should _not_ be set to `true` in
    /// production; it should only be used for testing.
    ///
    /// The default value is to error when the server presents an invalid certificate.
    pub allow_invalid_certificates: Option<bool>,

    /// The path to the CA file that the [`Client`](../struct.Client.html) should use for TLS. If
    /// none is specified, then the driver will use the Mozilla root certificates from the
    /// `webpki-roots` crate.
    pub ca_file_path: Option<PathBuf>,

    /// The path to the certificate file that the [`Client`](../struct.Client.html) should present
    /// to the server to verify its identify. If none is specified, then the
    /// [`Client`](../struct.Client.html) will not attempt to verify its identity to the
    /// server.
    pub cert_key_file_path: Option<PathBuf>,

    /// Whether or not the [`Client`](../struct.Client.html) should return an error if the hostname
    /// is invalid.
    ///
    /// The default value is to error on invalid hostnames.
    #[cfg(feature = "openssl-tls")]
    pub allow_invalid_hostnames: Option<bool>,

    /// If set, the key in `cert_key_file_path` must be encrypted with this password.
    #[cfg(feature = "cert-key-password")]
    pub tls_certificate_key_file_password: Option<Vec<u8>>,

    /// Overrides the hostname used for certificate verification (SNI and the
    /// hostname check) without changing which address the driver dials. Set
    /// this when the dial address is a local forwarding endpoint, such as an
    /// SSH tunnel, but the certificate was issued for the server's real
    /// hostname.
    pub verify_hostname: Option<String>,
}

impl TlsOptions {
    pub(crate) fn serialize<S>(
        tls_options: &TlsOptions,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        #[derive(Serialize)]
        struct TlsOptionsHelper<'a> {
            tls: bool,
            tlscafile: Option<&'a str>,
            tlscertificatekeyfile: Option<&'a str>,
            tlsallowinvalidcertificates: Option<bool>,
            #[cfg(feature = "cert-key-password")]
            tlscertificatekeyfilepassword: Option<&'a str>,
        }

        let state = TlsOptionsHelper {
            tls: true,
            tlscafile: tls_options
                .ca_file_path
                .as_ref()
                .map(|s| s.to_str().unwrap()),
            tlscertificatekeyfile: tls_options
                .cert_key_file_path
                .as_ref()
                .map(|s| s.to_str().unwrap()),
            tlsallowinvalidcertificates: tls_options.allow_invalid_certificates,
            #[cfg(feature = "cert-key-password")]
            tlscertificatekeyfilepassword: tls_options
                .tls_certificate_key_file_password
                .as_deref()
                .map(|b| std::str::from_utf8(b).unwrap()),
        };
        state.serialize(serializer)
    }
}

/// Extra information to append to the driver version in the metadata of the handshake with the
/// server. This should be used by libraries wrapping the driver, e.g. ODMs.
#[derive(Clone, Debug, Deserialize, TypedBuilder, Eq)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct DriverInfo {
    /// The name of the library wrapping the driver.
    #[builder(!default)]
    pub name: String,

    /// The version of the library wrapping the driver.
    pub version: Option<String>,

    /// Optional platform information for the wrapping driver.
    pub platform: Option<String>,
}

impl DriverInfo {
    pub(crate) fn spec_version(&self) -> &str {
        self.version.as_deref().unwrap_or("")
    }

    pub(crate) fn spec_platform(&self) -> &str {
        self.platform.as_deref().unwrap_or("")
    }
}

impl PartialEq for DriverInfo {
    fn eq(&self, other: &Self) -> bool {
        self.name == other.name
            && self.spec_version() == other.spec_version()
            && self.spec_platform() == other.spec_platform()
    }
}

impl Hash for DriverInfo {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.name.hash(state);
        self.spec_version().hash(state);
        self.spec_platform().hash(state);
    }
}

impl ClientOptions {
    /// Creates a new ClientOptions with the `original_srv_hostname` field set to the testing value
    /// used in the SRV tests.
    #[cfg(test)]
    pub(crate) fn new_srv() -> Self {
        Self {
            original_srv_info: Some(OriginalSrvInfo {
                hostname: "localhost.test.test.build.10gen.cc".into(),
                min_ttl: Duration::from_secs(60),
            }),
            ..Default::default()
        }
    }

    pub(crate) fn tls_options(&self) -> Option<TlsOptions> {
        match self.tls {
            Some(Tls::Enabled(ref opts)) => Some(opts.clone()),
            _ => None,
        }
    }

    /// Ensure the options set are valid, returning an error describing the problem if they are not.
    pub(crate) fn validate(&self) -> Result<()> {
        if let Some(true) = self.direct_connection {
            if self.hosts.len() > 1 {
                return Err(ErrorKind::InvalidArgument {
                    message: "cannot specify multiple seeds with directConnection=true".to_string(),
                }
                .into());
            }
        }

        if let Some(ref write_concern) = self.write_concern {
            write_concern.validate()?;
        }

        if self.load_balanced.unwrap_or(false) {
            if self.hosts.len() > 1 {
                return Err(ErrorKind::InvalidArgument {
                    message: "cannot specify multiple seeds with loadBalanced=true".to_string(),
                }
                .into());
            }
            if self.repl_set_name.is_some() {
                return Err(ErrorKind::InvalidArgument {
                    message: "cannot specify replicaSet with loadBalanced=true".to_string(),
                }
                .into());
            }
            if self.direct_connection == Some(true) {
                return Err(ErrorKind::InvalidArgument {
                    message: "cannot specify directConnection=true with loadBalanced=true"
                        .to_string(),
                }
                .into());
            }
        }

        #[cfg(any(
            feature = "zstd-compression",
            feature = "zlib-compression",
            feature = "snappy-compression"
        ))]
        if let Some(ref compressors) = self.compressors {
            for compressor in compressors {
                compressor.validate()?;
            }
        }

        if let Some(0) = self.max_pool_size {
            return Err(Error::invalid_argument("cannot specify maxPoolSize=0"));
        }

        if let Some(0) = self.max_connecting {
            return Err(Error::invalid_argument("cannot specify maxConnecting=0"));
        }

        if let Some(SelectionCriteria::ReadPreference(ref rp)) = self.selection_criteria {
            if let Some(max_staleness) = rp.max_staleness() {
                verify_max_staleness(
                    max_staleness,
                    self.heartbeat_freq.unwrap_or(DEFAULT_HEARTBEAT_FREQUENCY),
                )?;
            }
        }

        if let Some(heartbeat_frequency) = self.heartbeat_freq {
            if heartbeat_frequency < self.min_heartbeat_frequency() {
                return Err(ErrorKind::InvalidArgument {
                    message: format!(
                        "'heartbeat_freq' must be at least {}ms, but {}ms was given",
                        self.min_heartbeat_frequency().as_millis(),
                        heartbeat_frequency.as_millis()
                    ),
                }
                .into());
            }
        }

        #[cfg(feature = "tracing-unstable")]
        {
            let hostnames = if let Some(info) = &self.original_srv_info {
                vec![info.hostname.to_ascii_lowercase()]
            } else {
                self.hosts
                    .iter()
                    .filter_map(|addr| match addr {
                        ServerAddress::Tcp { host, .. } => Some(host.to_ascii_lowercase()),
                        #[cfg(unix)]
                        _ => None,
                    })
                    .collect()
            };
            if hostnames.iter().any(|s| s.ends_with(".cosmos.azure.com")) {
                tracing::info!("You appear to be connected to a CosmosDB cluster. For more information regarding feature compatibility and support please visit https://www.mongodb.com/supportability/cosmosdb");
            }
            if hostnames.iter().any(|s| {
                s.ends_with(".docdb.amazonaws.com") || s.ends_with(".docdb-elastic.amazonaws.com")
            }) {
                tracing::info!("You appear to be connected to a DocumentDB cluster. For more information regarding feature compatibility and support please visit https://www.mongodb.com/supportability/documentdb");
            }
        }

        #[cfg(feature = "socks5-proxy")]
        {
            if let Some(proxy) = self.socks5_proxy.as_ref() {
                if self
                    .hosts
                    .iter()
                    .any(|address| !matches!(address, ServerAddress::Tcp { .. }))
                {
                    return Err(Error::invalid_argument(
                        "cannot specify a non-TCP address when connected to a proxy host",
                    ));
                }

                if let Some((username, password)) = proxy.authentication.as_ref() {
                    if username.is_empty() || password.is_empty() {
                        return Err(Error::invalid_argument(
                            "cannot specify an empty username or password for proxy host",
                        ));
                    }
                }
            }
        }

        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn test_options_mut(&mut self) -> &mut TestOptions {
        self.test_options.get_or_insert_with(Default::default)
    }

    pub(crate) fn min_heartbeat_frequency(&self) -> Duration {
        #[cfg(test)]
        {
            self.test_options
                .as_ref()
                .and_then(|to| to.min_heartbeat_freq)
                .unwrap_or(MIN_HEARTBEAT_FREQUENCY)
        }

        #[cfg(not(test))]
        {
            MIN_HEARTBEAT_FREQUENCY
        }
    }

    pub(crate) fn resolver_config(&self) -> Option<&ResolverConfig> {
        #[cfg(feature = "dns-resolver")]
        {
            self.resolver_config.as_ref()
        }
        #[cfg(not(feature = "dns-resolver"))]
        {
            None
        }
    }

    pub(crate) fn connect_timeout(&self) -> Duration {
        match self.connect_timeout {
            Some(d) if d.is_zero() => Duration::MAX,
            Some(d) => d,
            None => crate::runtime::stream::DEFAULT_CONNECT_TIMEOUT,
        }
    }
}

/// Splits the string once on the first instance of the given delimiter. If the delimiter is not
/// present, returns the entire string as the "left" side.
///
/// e.g.
/// "abc.def" split on "." -> ("abc", Some("def"))
/// "ab.cd.ef" split on "." -> ("ab", Some("cd.ef"))
/// "abcdef" split on "." -> ("abcdef", None)
fn split_once_left<'a>(s: &'a str, delimiter: &str) -> (&'a str, Option<&'a str>) {
    match s.split_once(delimiter) {
        Some((l, r)) => (l, Some(r)),
        None => (s, None),
    }
}

/// Splits the string once on the last instance of the given delimiter. If the delimiter is not
/// present, returns the entire string as the "right" side.
///
/// e.g.
/// "abd.def" split on "." -> (Some("abc"), "def")
/// "ab.cd.ef" split on "." -> (Some("ab.cd"), "ef")
/// "abcdef" split on "." -> (None, "abcdef")
fn split_once_right<'a>(s: &'a str, delimiter: &str) -> (Option<&'a str>, &'a str) {
    match s.rsplit_once(delimiter) {
        Some((l, r)) => (Some(l), r),
        None => (None, s),
    }
}

fn percent_decode(s: &str, err_message: &str) -> Result<String> {
    match percent_encoding::percent_decode_str(s).decode_utf8() {
        Ok(result) => Ok(result.to_string()),
        Err(_) => Err(ErrorKind::InvalidArgument {
            message: err_message.to_string(),
        }
        .into()),
    }
}

fn percent_encode(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}

fn validate_and_parse_userinfo(s: &str, userinfo_type: &str) -> Result<String> {
    if s.chars().any(|c| USERINFO_RESERVED_CHARACTERS.contains(&c)) {
        return Err(Error::invalid_argument(format!(
            "{userinfo_type} must be URL encoded"
        )));
    }

    // All instances of '%' in the username must be part of an percent-encoded substring. This means
    // that there must be two hexidecimal digits following any '%' in the username.
    if s.split('%')
        .skip(1)
        .any(|part| part.len() < 2 || part[0..2].chars().any(|c| !c.is_ascii_hexdigit()))
    {
        return Err(Error::invalid_argument(format!(
            "{userinfo_type} cannot contain unescaped %"
        )));
    }

    percent_decode(s, &format!("{userinfo_type} must be URL encoded"))
}

impl TryFrom<&str> for ConnectionString {
    type Error = Error;

    fn try_from(value: &str) -> Result<Self> {
        Self::parse(value)
    }
}

impl TryFrom<&String> for ConnectionString {
    type Error = Error;

    fn try_from(value: &String) -> Result<Self> {
        Self::parse(value)
    }
}

impl TryFrom<String> for ConnectionString {
    type Error = Error;

    fn try_from(value: String) -> Result<Self> {
        Self::parse(value)
    }
}

impl ConnectionString {
    /// Parses a MongoDB connection string into a [`ConnectionString`] struct. If the string is
    /// malformed or one of the options has an invalid value, an error will be returned.
    pub fn parse(s: impl AsRef<str>) -> Result<Self> {
        let s = s.as_ref();

        let Some((scheme, after_scheme)) = s.split_once("://") else {
            return Err(Error::invalid_argument(
                "connection string contains no scheme",
            ));
        };

        let srv = match scheme {
            "mongodb" => false,
            #[cfg(feature = "dns-resolver")]
            "mongodb+srv" => true,
            #[cfg(not(feature = "dns-resolver"))]
            "mongodb+srv" => {
                return Err(Error::invalid_argument(
                    "mongodb+srv connection strings cannot be used when the 'dns-resolver' \
                     feature is disabled",
                ));
            }
            other => {
                return Err(Error::invalid_argument(format!(
                    "unsupported connection string scheme: {other}"
                )));
            }
        };

        let (pre_options, options) = split_once_left(after_scheme, "?");
        let (user_info, hosts_and_auth_db) = split_once_right(pre_options, "@");

        // if '@' is in the host section, it MUST be interpreted as a request for authentication
        let authentication_requested = user_info.is_some();
        let (username, password) = match user_info {
            Some(user_info) => {
                let (username, password) = split_once_left(user_info, ":");
                let username = if username.is_empty() {
                    None
                } else {
                    Some(validate_and_parse_userinfo(username, "username")?)
                };
                let password = match password {
                    Some(password) => Some(validate_and_parse_userinfo(password, "password")?),
                    None => None,
                };
                (username, password)
            }
            None => (None, None),
        };

        let (hosts, auth_db) = split_once_left(hosts_and_auth_db, "/");

        let hosts = hosts
            .split(",")
            .map(ServerAddress::parse)
            .collect::<Result<Vec<ServerAddress>>>()?;
        let host_info = if !srv {
            HostInfo::HostIdentifiers(hosts)
        } else {
            match &hosts[..] {
                [ServerAddress::Tcp { host, port: None }] => HostInfo::DnsRecord(host.clone()),
                [ServerAddress::Tcp {
                    host: _,
                    port: Some(_),
                }] => {
                    return Err(Error::invalid_argument(
                        "a port cannot be specified with 'mongodb+srv'",
                    ));
                }
                #[cfg(unix)]
                [ServerAddress::Unix { .. }] => {
                    return Err(Error::invalid_argument(
                        "unix sockets cannot be used with 'mongodb+srv'",
                    ));
                }
                _ => {
                    return Err(Error::invalid_argument(
                        "exactly one host must be specified with 'mongodb+srv'",
                    ));
                }
            }
        };

        let db = match auth_db {
            Some("") | None => None,
            Some(db) => {
                let decoded = percent_decode(db, "database name must be URL encoded")?;
                for c in decoded.chars() {
                    if ILLEGAL_DATABASE_CHARACTERS.contains(&c) {
                        return Err(Error::invalid_argument(format!(
                            "illegal character in database name: {c}"
                        )));
                    }
                }
                Some(decoded)
            }
        };

        let mut conn_str = ConnectionString {
            host_info,
            #[cfg(test)]
            original_uri: s.into(),
            ..Default::default()
        };

        let mut parts = match options {
            Some(options) => conn_str.parse_options(options)?,
            None => ConnectionStringParts::default(),
        };

        if conn_str.srv_service_name.is_some() && !srv {
            return Err(Error::invalid_argument(
                "srvServiceName cannot be specified with a non-SRV URI",
            ));
        }

        if let Some(srv_max_hosts) = conn_str.srv_max_hosts {
            if !srv {
                return Err(Error::invalid_argument(
                    "srvMaxHosts cannot be specified with a non-SRV URI",
                ));
            }
            if srv_max_hosts > 0 {
                if conn_str.replica_set.is_some() {
                    return Err(Error::invalid_argument(
                        "srvMaxHosts and replicaSet cannot both be present",
                    ));
                }
                if conn_str.load_balanced == Some(true) {
                    return Err(Error::invalid_argument(
                        "srvMaxHosts and loadBalanced=true cannot both be present",
                    ));
                }
            }
        }

        if let Some(username) = username {
            let credential = conn_str.credential.get_or_insert_with(Default::default);
            credential.username = Some(username);
            credential.password = password;
        }

        if parts.auth_source.as_deref() == Some("") {
            return Err(ErrorKind::InvalidArgument {
                message: "empty authSource provided".to_string(),
            }
            .into());
        }

        match parts.auth_mechanism {
            Some(ref mechanism) => {
                let credential = conn_str.credential.get_or_insert_with(Default::default);
                credential.source = parts.auth_source;

                if let Some(mut doc) = parts.auth_mechanism_properties.take() {
                    match doc.remove("CANONICALIZE_HOST_NAME") {
                        Some(Bson::String(s)) => {
                            let val = match &s.to_lowercase()[..] {
                                "true" => Bson::Boolean(true),
                                "false" => Bson::Boolean(false),
                                "none" | "forward" | "forwardandreverse" => Bson::String(s),
                                _ => {
                                    return Err(ErrorKind::InvalidArgument {
                                        message: format!(
                                            "Invalid CANONICALIZE_HOST_NAME value: {s}. Valid \
                                             values are 'none', 'forward', 'forwardAndReverse', \
                                             'true', 'false'"
                                        ),
                                    }
                                    .into());
                                }
                            };
                            doc.insert("CANONICALIZE_HOST_NAME", val);
                        }
                        Some(val) => {
                            doc.insert("CANONICALIZE_HOST_NAME", val);
                        }
                        None => {}
                    }

                    credential.mechanism_properties = Some(doc);
                }

                #[cfg(feature = "gssapi-auth")]
                if mechanism == &AuthMechanism::Gssapi {
                    // Set mongodb as the default SERVICE_NAME if none is provided
                    let mut doc = if let Some(doc) = credential.mechanism_properties.take() {
                        doc
                    } else {
                        Document::new()
                    };

                    if !doc.contains_key("SERVICE_NAME") {
                        doc.insert("SERVICE_NAME", "mongodb");
                    }

                    credential.mechanism_properties = Some(doc);
                }

                credential.mechanism = Some(mechanism.clone());
                mechanism.validate_credential(credential)?;
            }
            None => {
                if let Some(ref mut credential) = conn_str.credential {
                    credential.source = parts.auth_source;
                } else if authentication_requested {
                    return Err(ErrorKind::InvalidArgument {
                        message: "username and mechanism both not provided, but authentication \
                                  was requested"
                            .to_string(),
                    }
                    .into());
                }
            }
        };

        // set default database.
        conn_str.default_database = db;

        if conn_str.tls.is_none() && conn_str.is_srv() {
            conn_str.tls = Some(Tls::Enabled(Default::default()));
        }

        #[cfg(feature = "socks5-proxy")]
        {
            if let Some(host) = parts.proxy_host {
                let mut proxy = Socks5Proxy::builder().host(host).build();
                if let Some(port) = parts.proxy_port {
                    proxy.port = Some(port);
                }
                match (parts.proxy_username, parts.proxy_password) {
                    (Some(username), Some(password)) => {
                        proxy.authentication = Some((username, password))
                    }
                    (None, None) => {}
                    _ => {
                        return Err(Error::invalid_argument(
                            "proxy username and password must both be specified as nonempty \
                             strings or unset",
                        ));
                    }
                }
                conn_str.socks5_proxy = Some(proxy);
            } else {
                let error = |option: &str| {
                    Error::invalid_argument(format!(
                        "{option} cannot be set if {PROXY_HOST} is unspecified"
                    ))
                };
                if parts.proxy_port.is_some() {
                    return Err(error(PROXY_PORT));
                }
                if parts.proxy_username.is_some() {
                    return Err(error(PROXY_USERNAME));
                }
                if parts.proxy_password.is_some() {
                    return Err(error(PROXY_PASSWORD));
                }
            }
        }

        Ok(conn_str)
    }

    /// Un-parses a [`ConnectionString`] struct back into a MongoDB connection string.
    fn to_uri_str(&self) -> String {
        let ConnectionString {
            host_info,
            app_name,
            tls,
            heartbeat_frequency,
            local_threshold,
            read_concern,
            replica_set,
            write_concern,
            server_selection_timeout,
            max_pool_size,
            min_pool_size,
            max_connecting,
            max_idle_time,
            #[cfg(any(
                feature = "zstd-compression",
                feature = "zlib-compression",
                feature = "snappy-compression"
            ))]
            compressors,
            connect_timeout,
            retry_reads,
            retry_writes,
            server_monitoring_mode: _,
            direct_connection,
            credential,
            default_database,
            load_balanced,
            #[allow(deprecated)]
            socket_timeout,
            read_preference,
            uuid_representation,
            srv_max_hosts,
            srv_service_name: _,
            wait_queue_timeout,
            tls_insecure,
            #[cfg(feature = "socks5-proxy")]
            socks5_proxy,
            adaptive_retries,
            max_adaptive_retries,
            enable_overload_retargeting,
            #[cfg(test)]
                original_uri: _,
        } = self;

        let mut res: String = String::new();
        let mut opts = String::new();

        if self.is_srv() {
            res.push_str("mongodb+srv://");
        } else {
            res.push_str("mongodb://");
        }

        if let Some(credential) = credential {
            if let Some(username) = &credential.username {
                res.push_str(&percent_encode(username));
                if let Some(password) = &credential.password {
                    res.push_str(&format!(":{}", percent_encode(password)))
                }
                res.push('@');
            }
        }

        if self.is_srv() {
            if let HostInfo::DnsRecord(dns) = host_info {
                res.push_str(dns);
            }
        } else if let HostInfo::HostIdentifiers(hosts) = host_info {
            res.push_str(
                &hosts
                    .iter()
                    .map(|h| h.to_string())
                    .collect::<Vec<_>>()
                    .join(","),
            );
        }

        res.push('/');

        if let Some(authdb) = default_database {
            res.push_str(authdb);
        }

        if let Some(replica_set) = replica_set {
            opts.push_str(&format!("&replicaSet={replica_set}"));
        }

        if let Some(direct_connection) = direct_connection {
            opts.push_str(&format!("&directConnection={direct_connection}"));
        }

        if let Some(tls) = tls {
            match tls {
                Tls::Enabled(options) => {
                    opts.push_str("&tls=true");

                    if let Some(cert_key_file_path) = &options.cert_key_file_path {
                        opts.push_str(&format!(
                            "&tlsCertificateKeyFile={}",
                            cert_key_file_path.to_str().unwrap()
                        ));
                    }

                    #[cfg(feature = "cert-key-password")]
                    if let Some(tls_certificate_key_file_password) =
                        &options.tls_certificate_key_file_password
                    {
                        opts.push_str(&format!(
                            "&tlsCertificateKeyFilePassword={}",
                            std::str::from_utf8(tls_certificate_key_file_password).unwrap()
                        ));
                    }

                    if let Some(ca_file_path) = &options.ca_file_path {
                        opts.push_str(&format!("&tlsCAFile={}", ca_file_path.to_str().unwrap()));
                    }

                    if let Some(allow_invalid_certificates) = options.allow_invalid_certificates {
                        opts.push_str(&format!(
                            "&tlsAllowInvalidCertificates={allow_invalid_certificates}"
                        ));
                    }

                    #[cfg(feature = "openssl-tls")]
                    if let Some(allow_invalid_hostnames) = options.allow_invalid_hostnames {
                        opts.push_str(&format!(
                            "&tlsAllowInvalidHostnames={allow_invalid_hostnames}"
                        ));
                    }

                    if let Some(tls_insecure) = tls_insecure {
                        opts.push_str(&format!("&tlsInsecure={tls_insecure}"));
                    }
                }
                Tls::Disabled => {
                    opts.push_str("&tls=false");
                }
            }
        }

        if let Some(connect_timeout) = connect_timeout {
            opts.push_str(&format!(
                "&connectTimeoutMS={}",
                connect_timeout.as_millis()
            ));
        }

        if let Some(socket_timeout) = socket_timeout {
            opts.push_str(&format!("&socketTimeoutMS={}", socket_timeout.as_millis()));
        }

        #[cfg(any(
            feature = "zstd-compression",
            feature = "zlib-compression",
            feature = "snappy-compression"
        ))]
        if let Some(compressors) = compressors {
            opts.push_str(&format!(
                "&compressors={}",
                compressors
                    .iter()
                    .map(|c| c.name())
                    .collect::<Vec<_>>()
                    .join(",")
            ));
        }

        #[cfg(feature = "zlib-compression")]
        if let Some(compressors) = compressors {
            for compressor in compressors {
                if let Compressor::Zlib { level: Some(level) } = compressor {
                    opts.push_str(&format!("&zlibCompressionLevel={level}"));
                }
            }
        }

        if let Some(max_pool_size) = max_pool_size {
            opts.push_str(&format!("&maxPoolSize={max_pool_size}"));
        }

        if let Some(min_pool_size) = min_pool_size {
            opts.push_str(&format!("&minPoolSize={min_pool_size}"));
        }

        if let Some(max_connecting) = max_connecting {
            opts.push_str(&format!("&maxConnecting={max_connecting}"));
        }

        if let Some(max_idle_time) = max_idle_time {
            opts.push_str(&format!("&maxIdleTimeMS={}", max_idle_time.as_millis()));
        }

        if let Some(wait_queue_timeout) = wait_queue_timeout {
            opts.push_str(&format!(
                "&waitQueueTimeoutMS={}",
                wait_queue_timeout.as_millis()
            ));
        }

        if let Some(write_concern) = write_concern {
            if let Some(w) = &write_concern.w {
                match w {
                    Acknowledgment::Nodes(i) => {
                        opts.push_str(&format!("&w={i}"));
                    }
                    Acknowledgment::Majority => {
                        opts.push_str("&w=majority");
                    }
                    Acknowledgment::Custom(tag) => {
                        opts.push_str(&format!("&w={tag}"));
                    }
                }
            }

            if let Some(w_timeout) = write_concern.w_timeout {
                opts.push_str(&format!("&wtimeoutMS={}", w_timeout.as_millis()));
            }

            if let Some(journal) = write_concern.journal {
                opts.push_str(&format!("&journal={journal}"));
            }
        }

        if let Some(read_concern) = read_concern {
            opts.push_str(&format!(
                "&readConcernLevel={}",
                read_concern.level.as_str()
            ));
        }

        if let Some(read_preference) = read_preference {
            opts.push_str(&format!("&readPreference={}", read_preference.mode()));

            if let Some(max_staleness) = read_preference.max_staleness() {
                opts.push_str(&format!("&maxStalenessSeconds={}", max_staleness.as_secs()));
            }

            if let Some(tag_sets) = read_preference.tag_sets() {
                let ser_tag_set = |tag_set: &HashMap<String, String>| -> String {
                    let tags = tag_set
                        .iter()
                        .map(|(k, v)| format!("{k}:{v}"))
                        .collect::<Vec<_>>()
                        .join(",");
                    format!("&readPreferenceTags={tags}")
                };
                opts.push_str(
                    &tag_sets
                        .iter()
                        .map(ser_tag_set)
                        .collect::<Vec<_>>()
                        .join(""),
                )
            }
        }

        if let Some(auth_source) = credential
            .as_ref()
            .and_then(|c: &Credential| c.source.as_ref())
        {
            opts.push_str(&format!("&authSource={auth_source}"));
        }

        if let Some(auth_mechanism) = credential
            .as_ref()
            .and_then(|c: &Credential| c.mechanism.as_ref())
        {
            opts.push_str(&format!(
                "&authMechanism={}",
                auth_mechanism.as_str().to_uppercase()
            ));
        }

        if let Some(auth_mechanism_properties) = credential
            .as_ref()
            .and_then(|c: &Credential| c.mechanism_properties.as_ref())
        {
            if !auth_mechanism_properties.is_empty() {
                opts.push_str(&format!(
                    "&authMechanismProperties={}",
                    auth_mechanism_properties
                        .iter()
                        .map(|(k, v)| format!("{k}:{v}"))
                        .collect::<Vec<_>>()
                        .join(",")
                ))
            }
        }

        if let Some(local_threshold) = local_threshold {
            opts.push_str(&format!(
                "&localThresholdMS={}",
                local_threshold.as_millis()
            ));
        }

        if let Some(server_selection_timeout) = server_selection_timeout {
            opts.push_str(&format!(
                "&serverSelectionTimeoutMS={}",
                server_selection_timeout.as_millis()
            ));
        }

        if let Some(heartbeat_frequency) = heartbeat_frequency {
            opts.push_str(&format!(
                "&heartbeatFrequencyMS={}",
                heartbeat_frequency.as_millis()
            ));
        }

        if let Some(app_name) = app_name {
            opts.push_str(&format!("&appName={app_name}"));
        }

        if let Some(retry_reads) = retry_reads {
            opts.push_str(&format!("&retryReads={retry_reads}"));
        }

        if let Some(retry_writes) = retry_writes {
            opts.push_str(&format!("&retryWrites={retry_writes}"));
        }

        if let Some(uuid_rep) = uuid_representation {
            let s = match uuid_rep {
                UuidRepresentation::Standard => "standard",
                UuidRepresentation::CSharpLegacy => "csharpLegacy",
                UuidRepresentation::JavaLegacy => "javaLegacy",
                UuidRepresentation::PythonLegacy => "pythonLegacy",
                _ => "",
            };
            opts.push_str(&format!("&uuidRepresentation={s}"));
        }

        if let Some(load_balanced) = load_balanced {
            opts.push_str(&format!("&loadBalanced={load_balanced}"));
        }

        if let Some(srv_max_hosts) = srv_max_hosts {
            opts.push_str(&format!("&srvMaxHosts={srv_max_hosts}"));
        }

        #[cfg(feature = "socks5-proxy")]
        if let Some(proxy) = socks5_proxy {
            opts.push_str(&format!("&proxyHost={}", proxy.host));
            if let Some(port) = proxy.port {
                opts.push_str(&format!("&proxyPort={port}"));
            }
            if let Some((username, password)) = proxy.authentication.as_ref() {
                opts.push_str(&format!(
                    "&proxyUsername={username}&proxyPassword={password}"
                ));
            }
        }

        if let Some(adaptive_retries) = adaptive_retries {
            opts.push_str(&format!("&adaptiveRetries={adaptive_retries}"));
        }

        if let Some(max_adaptive_retries) = max_adaptive_retries {
            opts.push_str(&format!("&maxAdaptiveRetries={max_adaptive_retries}"));
        }

        if let Some(enable_overload_retargeting) = enable_overload_retargeting {
            opts.push_str(&format!(
                "&enableOverloadRetargeting={enable_overload_retargeting}"
            ));
        }

        if !opts.is_empty() {
            opts.replace_range(0..1, "?"); // mark start of options
            res.push_str(&opts);
        }

        res
    }

    /// Amount of time spent attempting to check out a connection from a server's connection pool
    /// before timing out.  Not supported by the Rust driver.
    pub fn wait_queue_timeout(&self) -> Option<Duration> {
        self.wait_queue_timeout
    }

    /// Relax TLS constraints as much as possible (e.g. allowing invalid certificates or hostname
    /// mismatches). This option can only be set in a URI. If it is set in a URI provided to
    /// [`ConnectionString::parse`], [`TlsOptions::allow_invalid_certificates`] and
    /// [`TlsOptions::allow_invalid_hostnames`] are set to its value.
    pub fn tls_insecure(&self) -> Option<bool> {
        self.tls_insecure
    }

    fn is_srv(&self) -> bool {
        matches!(self.host_info, HostInfo::DnsRecord(_))
    }

    fn parse_options(&mut self, options: &str) -> Result<ConnectionStringParts> {
        let mut parts = ConnectionStringParts::default();
        if options.is_empty() {
            return Ok(parts);
        }

        let mut keys = HashSet::new();

        for option_pair in options.split('&') {
            let (key, value) = match option_pair.split_once('=') {
                Some((key, value)) => (key.to_lowercase(), value),
                None => {
                    return Err(Error::invalid_argument(format!(
                        "connection string option is not a 'key=value' pair: {option_pair}"
                    )));
                }
            };

            if !keys.insert(key.clone()) && key != "readpreferencetags" {
                return Err(Error::invalid_argument(
                    "repeated options are not allowed in the connection string",
                ));
            }

            self.parse_option_pair(
                &mut parts,
                &key,
                percent_encoding::percent_decode(value.as_bytes())
                    .decode_utf8_lossy()
                    .as_ref(),
            )?;
        }

        if keys.contains(TLS_INSECURE) {
            #[cfg(feature = "openssl-tls")]
            let disallowed = [TLS_ALLOW_INVALID_CERTIFICATES, TLS_ALLOW_INVALID_HOSTNAMES];
            #[cfg(not(feature = "openssl-tls"))]
            let disallowed = [TLS_ALLOW_INVALID_CERTIFICATES];
            for option in disallowed {
                if keys.contains(option) {
                    return Err(Error::invalid_argument(format!(
                        "cannot set both {TLS_INSECURE} and {option} in the connection string"
                    )));
                }
            }
        }

        if let Some(tags) = parts.read_preference_tags.take() {
            self.read_preference = match self.read_preference.take() {
                Some(read_pref) => Some(read_pref.with_tags(tags)?),
                None => {
                    return Err(ErrorKind::InvalidArgument {
                        message: "cannot set read preference tags without also setting read \
                                  preference mode"
                            .to_string(),
                    }
                    .into());
                }
            };
        }

        if let Some(max_staleness) = parts.max_staleness.take() {
            self.read_preference = match self.read_preference.take() {
                Some(read_pref) => Some(read_pref.with_max_staleness(max_staleness)?),
                None => {
                    return Err(ErrorKind::InvalidArgument {
                        message: "cannot set max staleness without also setting read preference \
                                  mode"
                            .to_string(),
                    }
                    .into());
                }
            };
        }

        if let Some(true) = self.direct_connection {
            if self.is_srv() {
                return Err(ErrorKind::InvalidArgument {
                    message: "cannot use SRV-style URI with directConnection=true".to_string(),
                }
                .into());
            }
        }

        #[cfg(feature = "zlib-compression")]
        if let Some(zlib_compression_level) = parts.zlib_compression {
            if let Some(compressors) = self.compressors.as_mut() {
                for compressor in compressors {
                    compressor.write_zlib_level(zlib_compression_level)?;
                }
            }
        }
        #[cfg(not(feature = "zlib-compression"))]
        if parts.zlib_compression.is_some() {
            return Err(ErrorKind::InvalidArgument {
                message: "zlibCompressionLevel may not be specified without the zlib-compression \
                          feature flag enabled"
                    .into(),
            }
            .into());
        }

        Ok(parts)
    }

    fn parse_option_pair(
        &mut self,
        parts: &mut ConnectionStringParts,
        key: &str,
        value: &str,
    ) -> Result<()> {
        macro_rules! get_bool {
            ($value:expr, $option:expr) => {
                match $value {
                    "true" => true,
                    "false" => false,
                    _ => {
                        return Err(ErrorKind::InvalidArgument {
                            message: format!(
                                "connection string `{}` option must be a boolean",
                                $option,
                            ),
                        }
                        .into())
                    }
                }
            };
        }

        macro_rules! get_duration {
            ($value:expr, $option:expr) => {
                match $value.parse::<u64>() {
                    Ok(i) => i,
                    _ => {
                        return Err(ErrorKind::InvalidArgument {
                            message: format!(
                                "connection string `{}` option must be a non-negative integer",
                                $option
                            ),
                        }
                        .into())
                    }
                }
            };
        }

        macro_rules! get_u32 {
            ($value:expr, $option:expr) => {
                match value.parse::<u32>() {
                    Ok(u) => u,
                    Err(_) => {
                        return Err(ErrorKind::InvalidArgument {
                            message: format!(
                                "connection string `{}` argument must be a positive integer",
                                $option,
                            ),
                        }
                        .into())
                    }
                }
            };
        }

        macro_rules! get_i32 {
            ($value:expr, $option:expr) => {
                match value.parse::<i32>() {
                    Ok(u) => u,
                    Err(_) => {
                        return Err(ErrorKind::InvalidArgument {
                            message: format!(
                                "connection string `{}` argument must be an integer",
                                $option
                            ),
                        }
                        .into())
                    }
                }
            };
        }

        match key {
            "appname" => {
                self.app_name = Some(value.into());
            }
            "authmechanism" => {
                parts.auth_mechanism = Some(AuthMechanism::from_str(value)?);
            }
            "authsource" => parts.auth_source = Some(value.to_string()),
            "authmechanismproperties" => {
                let mut properties = Document::new();

                for property in value.split(",") {
                    let Some((k, v)) = property.split_once(":") else {
                        return Err(Error::invalid_argument(format!(
                            "each entry in authMechanismProperties must be a colon-separated \
                             key-value pair, got {property}"
                        )));
                    };
                    if k == "ALLOWED_HOSTS" || k == "OIDC_CALLBACK" || k == "OIDC_HUMAN_CALLBACK" {
                        return Err(Error::invalid_argument(format!(
                            "{k} must only be specified through client options"
                        )));
                    }
                    properties.insert(k, v);
                }

                parts.auth_mechanism_properties = Some(properties);
            }
            #[cfg(any(
                feature = "zstd-compression",
                feature = "zlib-compression",
                feature = "snappy-compression"
            ))]
            "compressors" => {
                let mut compressors: Option<Vec<Compressor>> = None;
                for compressor in value.split(',') {
                    let compressor = Compressor::from_str(compressor)?;
                    compressors
                        .get_or_insert_with(Default::default)
                        .push(compressor);
                }
                self.compressors = compressors;
            }
            k @ "connecttimeoutms" => {
                self.connect_timeout = Some(Duration::from_millis(get_duration!(value, k)));
            }
            k @ "directconnection" => {
                self.direct_connection = Some(get_bool!(value, k));
            }
            k @ "heartbeatfrequencyms" => {
                self.heartbeat_frequency = Some(Duration::from_millis(get_duration!(value, k)));
            }
            k @ "journal" => {
                let write_concern = self.write_concern.get_or_insert_with(Default::default);
                write_concern.journal = Some(get_bool!(value, k));
            }
            k @ "loadbalanced" => {
                self.load_balanced = Some(get_bool!(value, k));
            }
            k @ "localthresholdms" => {
                self.local_threshold = Some(Duration::from_millis(get_duration!(value, k)))
            }
            k @ "maxidletimems" => {
                self.max_idle_time = Some(Duration::from_millis(get_duration!(value, k)));
            }
            "maxstalenessseconds" => {
                let max_staleness_seconds = value.parse::<i64>().map_err(|e| {
                    Error::invalid_argument(format!("invalid maxStalenessSeconds value: {e}"))
                })?;

                let max_staleness = match max_staleness_seconds.cmp(&-1) {
                    Ordering::Less => {
                        return Err(Error::invalid_argument(format!(
                            "maxStalenessSeconds must be -1 or positive, instead got \
                             {max_staleness_seconds}"
                        )));
                    }
                    Ordering::Equal => {
                        // -1 maxStaleness means no maxStaleness, which is the default
                        return Ok(());
                    }
                    Ordering::Greater => {
                        // unwrap safety: `max_staleness_seconds` will always be >= 0
                        Duration::from_secs(max_staleness_seconds.try_into().unwrap())
                    }
                };

                parts.max_staleness = Some(max_staleness);
            }
            k @ "maxpoolsize" => {
                self.max_pool_size = Some(get_u32!(value, k));
            }
            k @ "minpoolsize" => {
                self.min_pool_size = Some(get_u32!(value, k));
            }
            k @ "maxconnecting" => {
                self.max_connecting = Some(get_u32!(value, k));
            }
            "readconcernlevel" => {
                self.read_concern = Some(ReadConcernLevel::from_str(value).into());
            }
            "readpreference" => {
                self.read_preference = Some(match &value.to_lowercase()[..] {
                    "primary" => ReadPreference::Primary,
                    "secondary" => ReadPreference::Secondary {
                        options: Default::default(),
                    },
                    "primarypreferred" => ReadPreference::PrimaryPreferred {
                        options: Default::default(),
                    },
                    "secondarypreferred" => ReadPreference::SecondaryPreferred {
                        options: Default::default(),
                    },
                    "nearest" => ReadPreference::Nearest {
                        options: Default::default(),
                    },
                    other => {
                        return Err(ErrorKind::InvalidArgument {
                            message: format!("'{other}' is not a valid read preference"),
                        }
                        .into());
                    }
                });
            }
            "readpreferencetags" => {
                let tags: Result<TagSet> = if value.is_empty() {
                    Ok(TagSet::new())
                } else {
                    value
                        .split(',')
                        .map(|tag| {
                            let mut values = tag.split(':');

                            match (values.next(), values.next()) {
                                (Some(key), Some(value)) => {
                                    Ok((key.to_string(), value.to_string()))
                                }
                                _ => Err(ErrorKind::InvalidArgument {
                                    message: format!(
                                        "'{value}' is not a valid read preference tag (which must \
                                         be of the form 'key:value'",
                                    ),
                                }
                                .into()),
                            }
                        })
                        .collect()
                };

                parts
                    .read_preference_tags
                    .get_or_insert_with(Vec::new)
                    .push(tags?);
            }
            "replicaset" => {
                self.replica_set = Some(value.to_string());
            }
            k @ "retrywrites" => {
                self.retry_writes = Some(get_bool!(value, k));
            }
            k @ "retryreads" => {
                self.retry_reads = Some(get_bool!(value, k));
            }
            "servermonitoringmode" => {
                self.server_monitoring_mode = Some(match value.to_lowercase().as_str() {
                    "stream" => ServerMonitoringMode::Stream,
                    "poll" => ServerMonitoringMode::Poll,
                    "auto" => ServerMonitoringMode::Auto,
                    other => {
                        return Err(Error::invalid_argument(format!(
                            "{other:?} is not a valid server monitoring mode"
                        )));
                    }
                });
            }
            k @ "serverselectiontimeoutms" => {
                self.server_selection_timeout = Some(Duration::from_millis(get_duration!(value, k)))
            }
            #[allow(deprecated)]
            k @ "sockettimeoutms" => {
                self.socket_timeout = Some(Duration::from_millis(get_duration!(value, k)));
            }
            k @ "srvmaxhosts" => {
                self.srv_max_hosts = Some(get_u32!(value, k));
            }
            "srvservicename" => {
                self.srv_service_name = Some(value.to_string());
            }
            k @ "tls" | k @ "ssl" => {
                let tls = get_bool!(value, k);

                match self.tls {
                    Some(Tls::Enabled(_)) if !tls => {
                        return Err(Error::invalid_argument(
                            "cannot set {key}={tls} if other TLS options are set",
                        ));
                    }
                    Some(Tls::Disabled) if tls => {
                        return Err(Error::invalid_argument(
                            "cannot set {key}={tls} if TLS is disabled",
                        ));
                    }
                    None => {
                        if tls {
                            self.tls = Some(Tls::Enabled(Default::default()))
                        } else {
                            self.tls = Some(Tls::Disabled)
                        }
                    }
                    _ => {}
                }
            }
            TLS_INSECURE => {
                let val = get_bool!(value, key);
                self.tls_insecure = Some(val);

                match self
                    .tls
                    .get_or_insert_with(|| Tls::Enabled(Default::default()))
                {
                    Tls::Enabled(ref mut options) => {
                        options.allow_invalid_certificates = Some(val);
                        #[cfg(feature = "openssl-tls")]
                        {
                            options.allow_invalid_hostnames = Some(val);
                        }
                    }
                    Tls::Disabled => {
                        return Err(Error::invalid_argument(format!(
                            "cannot set {key} when TLS is disabled"
                        )));
                    }
                }
            }
            TLS_ALLOW_INVALID_CERTIFICATES => {
                let val = get_bool!(value, key);

                match self
                    .tls
                    .get_or_insert_with(|| Tls::Enabled(Default::default()))
                {
                    Tls::Enabled(ref mut options) => {
                        options.allow_invalid_certificates = Some(val);
                    }
                    Tls::Disabled => {
                        return Err(Error::invalid_argument(format!(
                            "cannot set {key} when TLS is disabled"
                        )));
                    }
                }
            }
            "tlscafile" => match self.tls {
                Some(Tls::Disabled) => {
                    return Err(ErrorKind::InvalidArgument {
                        message: "'tlsCAFile' can't be set if tls=false".into(),
                    }
                    .into());
                }
                Some(Tls::Enabled(ref mut options)) => {
                    options.ca_file_path = Some(value.into());
                }
                None => {
                    self.tls = Some(Tls::Enabled(
                        TlsOptions::builder()
                            .ca_file_path(PathBuf::from(value))
                            .build(),
                    ))
                }
            },
            "tlscertificatekeyfile" => match self.tls {
                Some(Tls::Disabled) => {
                    return Err(ErrorKind::InvalidArgument {
                        message: "'tlsCertificateKeyFile' can't be set if tls=false".into(),
                    }
                    .into());
                }
                Some(Tls::Enabled(ref mut options)) => {
                    options.cert_key_file_path = Some(value.into());
                }
                None => {
                    self.tls = Some(Tls::Enabled(
                        TlsOptions::builder()
                            .cert_key_file_path(PathBuf::from(value))
                            .build(),
                    ))
                }
            },
            #[cfg(feature = "cert-key-password")]
            "tlscertificatekeyfilepassword" => match &mut self.tls {
                Some(Tls::Disabled) => {
                    return Err(ErrorKind::InvalidArgument {
                        message: "'tlsCertificateKeyFilePassword' can't be set if tls=false".into(),
                    }
                    .into());
                }
                Some(Tls::Enabled(options)) => {
                    options.tls_certificate_key_file_password = Some(value.as_bytes().to_vec());
                }
                None => {
                    self.tls = Some(Tls::Enabled(
                        TlsOptions::builder()
                            .tls_certificate_key_file_password(value.as_bytes().to_vec())
                            .build(),
                    ))
                }
            },
            #[cfg(not(feature = "cert-key-password"))]
            "tlscertificatekeyfilepassword" => {
                return Err(Error::invalid_argument(
                    "the cert-key-password feature must be enabled to specify \
                     tlsCertificateKeyFilePassword in the URI",
                ));
            }
            "uuidrepresentation" => match value.to_lowercase().as_str() {
                "csharplegacy" => self.uuid_representation = Some(UuidRepresentation::CSharpLegacy),
                "javalegacy" => self.uuid_representation = Some(UuidRepresentation::JavaLegacy),
                "pythonlegacy" => self.uuid_representation = Some(UuidRepresentation::PythonLegacy),
                _ => {
                    return Err(ErrorKind::InvalidArgument {
                        message: format!(
                            "connection string `uuidRepresentation` option can be one of \
                             `csharpLegacy`, `javaLegacy`, or `pythonLegacy`. Received invalid \
                             `{value}`"
                        ),
                    }
                    .into());
                }
            },
            "w" => {
                let write_concern = self.write_concern.get_or_insert_with(Default::default);

                match value.parse::<i32>() {
                    Ok(w) => match u32::try_from(w) {
                        Ok(uw) => write_concern.w = Some(Acknowledgment::from(uw)),
                        Err(_) => {
                            return Err(ErrorKind::InvalidArgument {
                                message: "connection string `w` option cannot be a negative \
                                          integer"
                                    .to_string(),
                            }
                            .into());
                        }
                    },
                    Err(_) => {
                        write_concern.w = Some(Acknowledgment::from(value.to_string()));
                    }
                };
            }
            k @ "waitqueuetimeoutms" => {
                self.wait_queue_timeout = Some(Duration::from_millis(get_duration!(value, k)));
            }
            k @ "wtimeoutms" => {
                let write_concern = self.write_concern.get_or_insert_with(Default::default);
                write_concern.w_timeout = Some(Duration::from_millis(get_duration!(value, k)));
            }
            k @ "zlibcompressionlevel" => {
                let i = get_i32!(value, k);
                if i < -1 {
                    return Err(ErrorKind::InvalidArgument {
                        message: "'zlibCompressionLevel' cannot be less than -1".to_string(),
                    }
                    .into());
                }

                if i > 9 {
                    return Err(ErrorKind::InvalidArgument {
                        message: "'zlibCompressionLevel' cannot be greater than 9".to_string(),
                    }
                    .into());
                }

                parts.zlib_compression = Some(i);
            }
            // "adaptiveretries" => {
            //     self.adaptive_retries = Some(get_bool!(value, key));
            // }
            "maxadaptiveretries" => {
                self.max_adaptive_retries = Some(get_u32!(value, key));
            }
            "enableoverloadretargeting" => {
                self.enable_overload_retargeting = Some(get_bool!(value, key));
            }
            #[cfg(feature = "socks5-proxy")]
            PROXY_HOST => parts.proxy_host = Some(value.to_string()),
            #[cfg(feature = "socks5-proxy")]
            PROXY_PORT => {
                let port = u16::from_str(value)
                    .map_err(|_| Error::invalid_argument(format!("invalid proxy port: {value}")))?;
                parts.proxy_port = Some(port);
            }
            #[cfg(feature = "socks5-proxy")]
            PROXY_USERNAME if !value.is_empty() => parts.proxy_username = Some(value.to_string()),
            #[cfg(feature = "socks5-proxy")]
            PROXY_PASSWORD if !value.is_empty() => parts.proxy_password = Some(value.to_string()),
            #[cfg(not(feature = "socks5-proxy"))]
            PROXY_HOST | PROXY_PORT | PROXY_USERNAME | PROXY_PASSWORD => {
                return Err(Error::invalid_argument(format!(
                    "cannot specify {key} if socks5-proxy feature is not enabled"
                )));
            }

            other => {
                let (jaro_winkler, option) = URI_OPTIONS.iter().fold((0.0, ""), |acc, option| {
                    let jaro_winkler = jaro_winkler(option, other).abs();
                    if jaro_winkler > acc.0 {
                        return (jaro_winkler, option);
                    }
                    acc
                });
                let mut message = format!("{other} is an invalid option");
                if jaro_winkler >= 0.84 {
                    let _ = write!(message, ". An option with a similar name exists: {option}");
                }
                return Err(ErrorKind::InvalidArgument { message }.into());
            }
        }

        Ok(())
    }
}

impl FromStr for ConnectionString {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self> {
        ConnectionString::parse(s)
    }
}

impl<'de> Deserialize<'de> for ConnectionString {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_str(ConnectionStringVisitor)
    }
}

impl Display for ConnectionString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_uri_str())
    }
}

struct ConnectionStringVisitor;

impl serde::de::Visitor<'_> for ConnectionStringVisitor {
    type Value = ConnectionString;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        write!(formatter, "a MongoDB connection string")
    }

    fn visit_str<E>(self, v: &str) -> std::result::Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        ConnectionString::parse(v).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use pretty_assertions::assert_eq;

    use super::{ClientOptions, ServerAddress};
    use crate::{
        concern::{Acknowledgment, ReadConcernLevel, WriteConcern},
        selection_criteria::{ReadPreference, ReadPreferenceOptions},
    };

    macro_rules! tag_set {
        ( $($k:expr => $v:expr),* ) => {
            #[allow(clippy::let_and_return)]
            {
                use std::collections::HashMap;

                #[allow(unused_mut)]
                let mut ts = HashMap::new();
                $(
                    ts.insert($k.to_string(), $v.to_string());
                )*

                ts
            }
        }
    }

    fn host_without_port(hostname: &str) -> ServerAddress {
        ServerAddress::Tcp {
            host: hostname.to_string(),
            port: None,
        }
    }

    #[test]
    fn test_parse_address_with_from_str() {
        let x = "localhost:27017".parse::<ServerAddress>().unwrap();
        match x {
            ServerAddress::Tcp { host, port } => {
                assert_eq!(host, "localhost");
                assert_eq!(port, Some(27017));
            }
            #[cfg(unix)]
            _ => panic!("expected ServerAddress::Tcp"),
        }

        // Port defaults to 27017 (so this doesn't fail)
        let x = "localhost".parse::<ServerAddress>().unwrap();
        match x {
            ServerAddress::Tcp { host, port } => {
                assert_eq!(host, "localhost");
                assert_eq!(port, None);
            }
            #[cfg(unix)]
            _ => panic!("expected ServerAddress::Tcp"),
        }

        let x = "localhost:not a number".parse::<ServerAddress>();
        assert!(x.is_err());

        #[cfg(unix)]
        {
            let x = "/path/to/socket.sock".parse::<ServerAddress>().unwrap();
            match x {
                ServerAddress::Unix { path } => {
                    assert_eq!(path.to_str().unwrap(), "/path/to/socket.sock");
                }
                _ => panic!("expected ServerAddress::Unix"),
            }
        }
    }

    #[tokio::test]
    async fn fails_without_scheme() {
        assert!(ClientOptions::parse("localhost:27017").await.is_err());
    }

    #[tokio::test]
    async fn fails_with_invalid_scheme() {
        assert!(ClientOptions::parse("mangodb://localhost:27017")
            .await
            .is_err());
    }

    #[tokio::test]
    async fn fails_with_nothing_after_scheme() {
        assert!(ClientOptions::parse("mongodb://").await.is_err());
    }

    #[tokio::test]
    async fn fails_with_only_slash_after_scheme() {
        assert!(ClientOptions::parse("mongodb:///").await.is_err());
    }

    #[tokio::test]
    async fn fails_with_no_host() {
        assert!(ClientOptions::parse("mongodb://:27017").await.is_err());
    }

    #[tokio::test]
    async fn no_port() {
        let uri = "mongodb://localhost";

        assert_eq!(
            ClientOptions::parse(uri).await.unwrap(),
            ClientOptions {
                hosts: vec![host_without_port("localhost")],
                original_uri: Some(uri.into()),
                ..Default::default()
            }
        );
    }

    #[tokio::test]
    async fn no_port_trailing_slash() {
        let uri = "mongodb://localhost/";

        assert_eq!(
            ClientOptions::parse(uri).await.unwrap(),
            ClientOptions {
                hosts: vec![host_without_port("localhost")],
                original_uri: Some(uri.into()),
                ..Default::default()
            }
        );
    }

    #[tokio::test]
    async fn with_port() {
        let uri = "mongodb://localhost/";

        assert_eq!(
            ClientOptions::parse(uri).await.unwrap(),
            ClientOptions {
                hosts: vec![ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27017),
                }],
                original_uri: Some(uri.into()),
                ..Default::default()
            }
        );
    }

    #[tokio::test]
    async fn with_port_and_trailing_slash() {
        let uri = "mongodb://localhost:27017/";

        assert_eq!(
            ClientOptions::parse(uri).await.unwrap(),
            ClientOptions {
                hosts: vec![ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27017),
                }],
                original_uri: Some(uri.into()),
                ..Default::default()
            }
        );
    }

    #[tokio::test]
    async fn with_read_concern() {
        let uri = "mongodb://localhost:27017/?readConcernLevel=foo";

        assert_eq!(
            ClientOptions::parse(uri).await.unwrap(),
            ClientOptions {
                hosts: vec![ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27017),
                }],
                read_concern: Some(ReadConcernLevel::Custom("foo".to_string()).into()),
                original_uri: Some(uri.into()),
                ..Default::default()
            }
        );
    }

    #[tokio::test]
    async fn with_w_negative_int() {
        assert!(ClientOptions::parse("mongodb://localhost:27017/?w=-1")
            .await
            .is_err());
    }

    #[tokio::test]
    async fn with_w_non_negative_int() {
        let uri = "mongodb://localhost:27017/?w=1";
        let write_concern = WriteConcern::builder().w(Acknowledgment::from(1)).build();

        assert_eq!(
            ClientOptions::parse(uri).await.unwrap(),
            ClientOptions {
                hosts: vec![ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27017),
                }],
                write_concern: Some(write_concern),
                original_uri: Some(uri.into()),
                ..Default::default()
            }
        );
    }

    #[tokio::test]
    async fn with_w_string() {
        let uri = "mongodb://localhost:27017/?w=foo";
        let write_concern = WriteConcern::builder()
            .w(Acknowledgment::from("foo".to_string()))
            .build();

        assert_eq!(
            ClientOptions::parse(uri).await.unwrap(),
            ClientOptions {
                hosts: vec![ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27017),
                }],
                write_concern: Some(write_concern),
                original_uri: Some(uri.into()),
                ..Default::default()
            }
        );
    }

    #[tokio::test]
    async fn with_invalid_j() {
        assert!(
            ClientOptions::parse("mongodb://localhost:27017/?journal=foo")
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn with_j() {
        let uri = "mongodb://localhost:27017/?journal=true";
        let write_concern = WriteConcern::builder().journal(true).build();

        assert_eq!(
            ClientOptions::parse(uri).await.unwrap(),
            ClientOptions {
                hosts: vec![ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27017),
                }],
                write_concern: Some(write_concern),
                original_uri: Some(uri.into()),
                ..Default::default()
            }
        );
    }

    #[tokio::test]
    async fn with_wtimeout_non_int() {
        assert!(
            ClientOptions::parse("mongodb://localhost:27017/?wtimeoutMS=foo")
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn with_wtimeout_negative_int() {
        assert!(
            ClientOptions::parse("mongodb://localhost:27017/?wtimeoutMS=-1")
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn with_wtimeout() {
        let uri = "mongodb://localhost:27017/?wtimeoutMS=27";
        let write_concern = WriteConcern::builder()
            .w_timeout(Duration::from_millis(27))
            .build();

        assert_eq!(
            ClientOptions::parse(uri).await.unwrap(),
            ClientOptions {
                hosts: vec![ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27017),
                }],
                write_concern: Some(write_concern),
                original_uri: Some(uri.into()),
                ..Default::default()
            }
        );
    }

    #[tokio::test]
    async fn with_all_write_concern_options() {
        let uri = "mongodb://localhost:27017/?w=majority&journal=false&wtimeoutMS=27";
        let write_concern = WriteConcern::builder()
            .w(Acknowledgment::Majority)
            .journal(false)
            .w_timeout(Duration::from_millis(27))
            .build();

        assert_eq!(
            ClientOptions::parse(uri).await.unwrap(),
            ClientOptions {
                hosts: vec![ServerAddress::Tcp {
                    host: "localhost".to_string(),
                    port: Some(27017),
                }],
                write_concern: Some(write_concern),
                original_uri: Some(uri.into()),
                ..Default::default()
            }
        );
    }

    #[tokio::test]
    async fn with_mixed_options() {
        let uri = "mongodb://localhost,localhost:27018/?w=majority&readConcernLevel=majority&\
                   journal=false&wtimeoutMS=27&replicaSet=foo&heartbeatFrequencyMS=1000&\
                   localThresholdMS=4000&readPreference=secondaryPreferred&readpreferencetags=dc:\
                   ny,rack:1&serverselectiontimeoutms=2000&readpreferencetags=dc:ny&\
                   readpreferencetags=";
        let write_concern = WriteConcern::builder()
            .w(Acknowledgment::Majority)
            .journal(false)
            .w_timeout(Duration::from_millis(27))
            .build();

        assert_eq!(
            ClientOptions::parse(uri).await.unwrap(),
            ClientOptions {
                hosts: vec![
                    ServerAddress::Tcp {
                        host: "localhost".to_string(),
                        port: None,
                    },
                    ServerAddress::Tcp {
                        host: "localhost".to_string(),
                        port: Some(27018),
                    },
                ],
                selection_criteria: Some(
                    ReadPreference::SecondaryPreferred {
                        options: Some(
                            ReadPreferenceOptions::builder()
                                .tag_sets(vec![
                                    tag_set! {
                                        "dc" => "ny",
                                        "rack" => "1"
                                    },
                                    tag_set! {
                                        "dc" => "ny"
                                    },
                                    tag_set! {},
                                ])
                                .build()
                        )
                    }
                    .into()
                ),
                read_concern: Some(ReadConcernLevel::Majority.into()),
                write_concern: Some(write_concern),
                repl_set_name: Some("foo".to_string()),
                heartbeat_freq: Some(Duration::from_millis(1000)),
                local_threshold: Some(Duration::from_millis(4000)),
                server_selection_timeout: Some(Duration::from_millis(2000)),
                original_uri: Some(uri.into()),
                ..Default::default()
            }
        );
    }
}

/// Contains the options that can be used to create a new [`ClientSession`](crate::ClientSession).
#[derive(Clone, Debug, Default, Deserialize, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
#[export_tokens]
pub struct SessionOptions {
    /// The default options to use for transactions started on this session.
    ///
    /// If these options are not specified, they will be inherited from the
    /// [`Client`](../struct.Client.html) associated with this session. They will not
    /// be inherited from the options specified
    /// on the [`Database`](../struct.Database.html) or [`Collection`](../struct.Collection.html)
    /// associated with the operations within the transaction.
    pub default_transaction_options: Option<TransactionOptions>,

    /// If true, all operations performed in the context of this session
    /// will be [causally consistent](https://www.mongodb.com/docs/manual/core/causal-consistency-read-write-concerns/).
    ///
    /// Defaults to true if [`SessionOptions::snapshot`] is unspecified.
    pub causal_consistency: Option<bool>,

    /// If true, all read operations performed using this client session will share the same
    /// snapshot.  Defaults to false.
    pub snapshot: Option<bool>,

    /// The snapshot time to use for a snapshot session. This option can only be set if `snapshot`
    /// is set to true.
    pub snapshot_time: Option<Timestamp>,
}

impl SessionOptions {
    pub(crate) fn validate(&self) -> Result<()> {
        if let (Some(causal_consistency), Some(snapshot)) = (self.causal_consistency, self.snapshot)
        {
            if causal_consistency && snapshot {
                return Err(Error::invalid_argument(
                    "snapshot and causal consistency are mutually exclusive",
                ));
            }
        }
        if self.snapshot_time.is_some() && self.snapshot != Some(true) {
            return Err(Error::invalid_argument(
                "cannot set `snapshot_time` without setting `snapshot` to true",
            ));
        }
        Ok(())
    }
}

/// Contains the options that can be used for a transaction.
#[skip_serializing_none]
#[derive(Debug, Default, Serialize, Deserialize, TypedBuilder, Clone)]
#[builder(field_defaults(default, setter(into)))]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
#[export_tokens]
pub struct TransactionOptions {
    /// The read concern to use for the transaction.
    #[builder(default)]
    #[serde(skip_serializing)]
    pub read_concern: Option<ReadConcern>,

    /// The write concern to use when committing or aborting a transaction.
    #[builder(default)]
    #[serde(skip_serializing)]
    pub write_concern: Option<WriteConcern>,

    /// The selection criteria to use for all read operations in a transaction.
    #[builder(default)]
    #[serde(skip_serializing, rename = "readPreference")]
    pub selection_criteria: Option<SelectionCriteria>,

    /// The maximum amount of time to allow a single commitTransaction to run.
    #[builder(default)]
    #[serde(
        serialize_with = "serde_util::serialize_duration_option_as_int_millis",
        deserialize_with = "serde_util::deserialize_duration_option_from_u64_millis",
        rename(serialize = "maxTimeMS", deserialize = "maxCommitTimeMS"),
        default
    )]
    pub max_commit_time: Option<Duration>,
}

/// Which server monitoring protocol to use.
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[non_exhaustive]
pub enum ServerMonitoringMode {
    /// The client will use the streaming protocol when the server supports it and fall back to the
    /// polling protocol otherwise.
    Stream,
    /// The client will use the polling protocol.
    Poll,
    /// The client will use the polling protocol when running on a FaaS platform and behave the
    /// same as `Stream` otherwise.
    Auto,
}

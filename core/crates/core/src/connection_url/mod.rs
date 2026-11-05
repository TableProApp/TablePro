//! A connection URL as providers and clients write one, read into the
//! settings of a connection.

mod connection_url_error;
mod tls_hints;

use std::path::{Path, PathBuf};

pub use connection_url_error::ConnectionUrlError;
use percent_encoding::percent_decode_str;
use secrecy::SecretString;
use tls_hints::{TlsHints, Wanted};

use crate::{ClientIdentity, NetworkOptions, TlsMode};

#[derive(Debug, Clone)]
pub struct ConnectionUrl {
    pub driver_id: &'static str,
    // An absolute path is a local socket. Empty for a file engine, and for PostgreSQL or MySQL
    // when the URL names no host, which means the client's default socket.
    pub host: String,
    pub port: Option<u16>,
    pub username: String,
    pub password: Option<SecretString>,
    // The database name or number, the keyspace, or a file engine's path.
    pub database: String,
    pub tls: UrlTls,
    pub options: NetworkOptions,
}

// What a URL says about TLS. No mode leaves the connection's default, with the files still applied.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UrlTls {
    pub mode: Option<TlsMode>,
    pub ca_file: Option<PathBuf>,
    pub client_identity: Option<ClientIdentity>,
    pub server_name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Engine {
    Postgres,
    Mysql { x_protocol: bool },
    Mssql,
    Mongo { seed_list: bool },
    Redis { tls: bool },
    Clickhouse,
    Cassandra,
    Sqlite,
    Duckdb,
}

impl Engine {
    fn from_scheme(scheme: &str) -> Option<Self> {
        Some(match scheme {
            "postgres" | "postgresql" => Self::Postgres,
            "mysql" | "mariadb" => Self::Mysql { x_protocol: false },
            "mysqlx" => Self::Mysql { x_protocol: true },
            "sqlserver" | "mssql" => Self::Mssql,
            "mongodb" => Self::Mongo { seed_list: false },
            "mongodb+srv" => Self::Mongo { seed_list: true },
            "redis" | "valkey" => Self::Redis { tls: false },
            "rediss" | "valkeys" => Self::Redis { tls: true },
            "clickhouse" | "ch" => Self::Clickhouse,
            "cassandra" | "cql" | "scylla" | "scylladb" => Self::Cassandra,
            "sqlite" | "sqlite3" => Self::Sqlite,
            "duckdb" => Self::Duckdb,
            _ => return None,
        })
    }

    fn driver_id(self) -> &'static str {
        match self {
            Self::Postgres => "postgres",
            Self::Mysql { .. } => "mysql",
            Self::Mssql => "mssql",
            Self::Mongo { .. } => "mongodb",
            Self::Redis { .. } => "redis",
            Self::Clickhouse => "clickhouse",
            Self::Cassandra => "cassandra",
            Self::Sqlite => "sqlite",
            Self::Duckdb => "duckdb",
        }
    }

    fn has_local_socket(self) -> bool {
        matches!(self, Self::Postgres | Self::Mysql { .. })
    }
}

pub fn parse(text: &str) -> Result<ConnectionUrl, ConnectionUrlError> {
    let text = text.trim();
    let jdbc = strip_prefix_ignoring_case(text, "jdbc:");
    let (scheme, rest) = split_scheme(jdbc.unwrap_or(text))?;
    let engine = Engine::from_scheme(&scheme).ok_or(ConnectionUrlError::UnknownScheme { scheme })?;
    match engine {
        Engine::Sqlite | Engine::Duckdb => Ok(file_url(engine, rest)?),
        // Only SQL Server's JDBC grammar has `;` properties; a URL's userinfo may hold a `;`.
        _ => network_url(engine, rest, jdbc.is_some() && engine == Engine::Mssql),
    }
}

fn split_scheme(body: &str) -> Result<(String, &str), ConnectionUrlError> {
    let (scheme, rest) = body.split_once(':').ok_or(ConnectionUrlError::Invalid)?;
    let valid = scheme.chars().next().is_some_and(|first| first.is_ascii_alphabetic())
        && scheme
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '+' | '-' | '.'));
    if !valid {
        return Err(ConnectionUrlError::Invalid);
    }
    let scheme = scheme.to_ascii_lowercase();
    // `sqlite:/home/ada/app.db` names a file with no authority at all.
    let rest = match rest.strip_prefix("//") {
        Some(rest) => rest,
        None if rest.starts_with('/') && matches!(scheme.as_str(), "sqlite" | "sqlite3" | "duckdb") => rest,
        None => return Err(ConnectionUrlError::Invalid),
    };
    Ok((scheme, rest))
}

// `sqlite:///C:/data/app.db` keeps the drive letter, and `sqlite://app.db` is a relative name the form refuses.
fn file_url(engine: Engine, rest: &str) -> Result<ConnectionUrl, ConnectionUrlError> {
    let path = rest.split(['?', '#']).next().unwrap_or_default();
    let path = match path.strip_prefix("localhost") {
        Some(local) if local.starts_with('/') => local,
        _ => path,
    };
    let mut path = decode(path)?;
    let bytes = path.as_bytes();
    if bytes.len() >= 3 && bytes[0] == b'/' && bytes[1].is_ascii_alphabetic() && bytes[2] == b':' {
        path.remove(0);
    }
    Ok(ConnectionUrl {
        driver_id: engine.driver_id(),
        host: String::new(),
        port: None,
        username: String::new(),
        password: None,
        database: path,
        tls: UrlTls::default(),
        options: NetworkOptions::default(),
    })
}

struct Parts<'a> {
    userinfo: Option<&'a str>,
    hosts: &'a str,
    path: &'a str,
    // SQL Server JDBC's `;key=value` properties.
    properties: &'a str,
    query: &'a str,
    fragment: &'a str,
}

// The userinfo is the authority's, which ends at the first `/` or `?`, or SQL Server's first `;`:
// a path may hold an `@`, so a password holding `/` or `?` has to escape it. Within the authority
// the last `@` ends it, so an unescaped `@` or `#` in a password reads as typed. SQL Server's
// properties run to the end: JDBC has no query or fragment, so a `#` or `?` there is a password's.
fn split_parts(rest: &str, properties: bool) -> Parts<'_> {
    let authority_end = match properties {
        true => rest.find(['/', '?', ';']),
        false => rest.find(['/', '?']),
    }
    .unwrap_or(rest.len());
    let (userinfo, after_userinfo) = match rest[..authority_end].rfind('@') {
        Some(at) => (Some(&rest[..at]), &rest[at + 1..]),
        None => (None, rest),
    };
    let (address, properties) = match properties {
        true => after_userinfo.split_once(';').unwrap_or((after_userinfo, "")),
        false => (after_userinfo, ""),
    };
    let (before_fragment, fragment) = address.split_once('#').unwrap_or((address, ""));
    let (before_query, query) = before_fragment.split_once('?').unwrap_or((before_fragment, ""));
    let (hosts, path) = match before_query.find('/') {
        Some(slash) => (&before_query[..slash], &before_query[slash..]),
        None => (before_query, ""),
    };
    Parts {
        userinfo,
        hosts,
        path,
        properties,
        query,
        fragment,
    }
}

struct HostPort {
    host: String,
    port: Option<u16>,
}

// A connection as a URL describes it, filled in a step at a time.
struct Draft {
    host: String,
    port: Option<u16>,
    username: String,
    password: Option<String>,
    database: String,
    tls: TlsHints,
    options: NetworkOptions,
    socket: Option<String>,
    instance: bool,
    direct: Option<bool>,
    query_user: Option<String>,
    query_password: Option<String>,
}

fn network_url(engine: Engine, rest: &str, properties: bool) -> Result<ConnectionUrl, ConnectionUrlError> {
    let parts = split_parts(rest, properties);
    let (username, password) = match parts.userinfo {
        Some(userinfo) => match userinfo.split_once(':') {
            Some((user, secret)) => (decode(user)?, Some(decode(secret)?)),
            None => (decode(userinfo)?, None),
        },
        None => (String::new(), None),
    };
    let (first, more) = hosts(engine, parts.hosts)?;
    let mut draft = Draft {
        host: first.host,
        port: first.port,
        username,
        password,
        database: decode(parts.path.trim_start_matches('/'))?,
        tls: TlsHints::default(),
        options: NetworkOptions::default(),
        socket: None,
        instance: false,
        direct: None,
        query_user: None,
        query_password: None,
    };
    for pair in parameters(parts.query, false).chain(parameters(parts.properties, true)) {
        let (key, value) = pair?;
        if !draft.tls.read(&key, &value)? {
            read_parameter(engine, &mut draft, &key, value)?;
        }
    }
    // MongoDB names its login in the userinfo only.
    if !matches!(engine, Engine::Mongo { .. }) {
        if draft.username.is_empty() {
            draft.username = draft.query_user.take().unwrap_or_default();
        }
        if draft.password.is_none() {
            draft.password = draft.query_password.take();
        }
    }
    finish(engine, &mut draft, &more, parts.fragment)?;
    Ok(ConnectionUrl {
        driver_id: engine.driver_id(),
        host: draft.host,
        port: draft.port,
        username: draft.username,
        password: draft.password.map(SecretString::from),
        database: draft.database,
        tls: draft.tls.resolve(),
        options: draft.options,
    })
}

// Only a MongoDB URL lists several hosts, and a seed list names one.
fn hosts(engine: Engine, text: &str) -> Result<(HostPort, Vec<HostPort>), ConnectionUrlError> {
    let mut hosts = text.split(',').map(host_port).collect::<Result<Vec<_>, _>>()?;
    if hosts.len() > 1 {
        if !matches!(engine, Engine::Mongo { seed_list: false }) {
            return Err(match engine {
                Engine::Mongo { .. } => ConnectionUrlError::SeedListHost,
                _ => ConnectionUrlError::SeveralHosts,
            });
        }
        if hosts.iter().any(|listed| listed.host.is_empty()) {
            return Err(ConnectionUrlError::NoHost);
        }
    }
    let first = hosts.remove(0);
    Ok((first, hosts))
}

fn read_parameter(engine: Engine, draft: &mut Draft, key: &str, value: String) -> Result<(), ConnectionUrlError> {
    match (engine, key) {
        (Engine::Mongo { .. }, "authsource") => {
            draft.options.auth_database = Some(value).filter(|name| !name.is_empty())
        }
        (Engine::Mongo { .. }, "replicaset") => draft.options.replica_set = Some(value).filter(|name| !name.is_empty()),
        (Engine::Mongo { .. }, "authmechanism") => check_mechanism(&value)?,
        (Engine::Mongo { .. }, "directconnection") => draft.direct = Some(value.trim().eq_ignore_ascii_case("true")),
        (Engine::Mongo { .. }, _) => {}
        // libpq's `host` names one host and no port; a list is its failover, which is not read.
        (Engine::Postgres, "host") => {
            if value.contains(',') {
                return Err(ConnectionUrlError::SeveralHosts);
            }
            draft.host = value.trim().trim_start_matches('[').trim_end_matches(']').to_owned();
        }
        (Engine::Postgres | Engine::Mssql, "port" | "portnumber") => draft.port = Some(parse_port(&value)?),
        (Engine::Postgres, "channel_binding") => {
            draft.options.channel_binding = value.trim().eq_ignore_ascii_case("require")
        }
        // Protections libpq enforces that the driver cannot: refused, never dropped.
        (Engine::Postgres, "requirepeer" | "require_auth" | "sslcrl" | "sslcrldir") if !value.trim().is_empty() => {
            return Err(ConnectionUrlError::UnsupportedParameter { name: key.to_owned() });
        }
        (Engine::Postgres, "gssencmode" | "sslcertmode") if value.trim().eq_ignore_ascii_case("require") => {
            return Err(ConnectionUrlError::UnsupportedParameter { name: key.to_owned() });
        }
        (Engine::Postgres, "dbname") | (Engine::Mssql, "database" | "databasename") if draft.database.is_empty() => {
            draft.database = value;
        }
        (Engine::Mssql, "servername") if draft.host.is_empty() => draft.host = value,
        (Engine::Mssql, "instancename") => draft.instance = !value.trim().is_empty(),
        (Engine::Mysql { .. }, "socket" | "unix_socket") => draft.socket = Some(value),
        (_, "user" | "username") => draft.query_user = Some(value),
        (_, "password") => draft.query_password = Some(value),
        _ => {}
    }
    Ok(())
}

// What each engine reads in the host, the port and the path, and the TLS its scheme implies.
fn finish(engine: Engine, draft: &mut Draft, more: &[HostPort], fragment: &str) -> Result<(), ConnectionUrlError> {
    match engine {
        Engine::Postgres => (draft.host, draft.port) = postgres_socket(std::mem::take(&mut draft.host), draft.port),
        Engine::Mysql { x_protocol } => {
            let local = draft.host.is_empty() || draft.host.eq_ignore_ascii_case("localhost");
            if let Some(socket) = draft.socket.take().filter(|_| local) {
                draft.host = absolute_socket(socket.trim_start_matches('(').trim_end_matches(')'))?;
            }
            // The X Protocol's port; the driver speaks the classic protocol.
            if x_protocol && draft.port == Some(33060) {
                draft.port = None;
            }
        }
        Engine::Mongo { seed_list } => {
            if seed_list && draft.port.is_some() {
                return Err(ConnectionUrlError::SeedListHost);
            }
            // True is the named server alone, never its set; false is the set, found from a name or a host list.
            match draft.direct {
                Some(true) if seed_list || !more.is_empty() => return Err(ConnectionUrlError::DirectConnection),
                Some(true) => draft.options.replica_set = None,
                Some(false) if !seed_list && more.is_empty() && draft.options.replica_set.is_none() => {
                    return Err(ConnectionUrlError::DirectConnection);
                }
                _ => {}
            }
            draft.options.dns_seed_list = seed_list;
            draft.options.more_hosts = more.iter().map(HostPort::text).collect();
            if seed_list {
                draft.tls.by_scheme = Some(Wanted::VerifyFull);
            }
        }
        Engine::Redis { tls } => {
            draft.database = redis_database(&draft.database)?;
            if tls {
                draft.tls.by_scheme = Some(Wanted::VerifyFull);
            }
            // redis-rs's own spelling for a certificate it does not check.
            if fragment == "insecure" {
                draft.tls.weaken();
            }
        }
        Engine::Clickhouse => clickhouse_port(draft),
        // Microsoft's drivers encrypt and check the certificate unless told otherwise.
        Engine::Mssql => draft.tls.by_scheme = Some(Wanted::VerifyFull),
        Engine::Cassandra | Engine::Sqlite | Engine::Duckdb => {}
    }
    if draft.host.is_empty() && !engine.has_local_socket() {
        return Err(ConnectionUrlError::NoHost);
    }
    // An instance is found through SQL Server Browser, which is not read; its port reaches it directly.
    if engine == Engine::Mssql {
        if let Some((server, _instance)) = draft.host.split_once('\\') {
            draft.host = server.to_owned();
            draft.instance = true;
        }
        if draft.instance && draft.port.is_none() {
            return Err(ConnectionUrlError::InstanceName);
        }
    }
    Ok(())
}

// The driver speaks HTTP, so clickhouse-client's native ports become the HTTP ones.
fn clickhouse_port(draft: &mut Draft) {
    draft.port = match draft.port {
        Some(9000) => Some(8123),
        Some(9440) => Some(8443),
        other => other,
    };
    let cloud = draft.host.to_ascii_lowercase().ends_with(".clickhouse.cloud");
    if matches!(draft.port, Some(8443 | 443)) || (draft.port.is_none() && cloud) {
        draft.tls.by_scheme = Some(Wanted::VerifyFull);
    }
    if draft.port.is_none() && draft.tls.asks_for_tls() {
        draft.port = Some(8443);
    }
}

impl HostPort {
    fn text(&self) -> String {
        let host = match self.host.contains(':') {
            true => format!("[{}]", self.host),
            false => self.host.clone(),
        };
        match self.port {
            Some(port) => format!("{host}:{port}"),
            None => host,
        }
    }
}

fn host_port(text: &str) -> Result<HostPort, ConnectionUrlError> {
    let text = text.trim();
    let (host, port) = match text.strip_prefix('[') {
        Some(bracketed) => {
            let (host, after) = bracketed.split_once(']').ok_or(ConnectionUrlError::Invalid)?;
            match after {
                "" => (host, None),
                _ => (host, Some(after.strip_prefix(':').ok_or(ConnectionUrlError::Invalid)?)),
            }
        }
        None => match text.rsplit_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (text, None),
        },
    };
    let port = match port {
        Some("") | None => None,
        Some(port) => Some(parse_port(port)?),
    };
    Ok(HostPort {
        host: decode(host)?,
        port,
    })
}

fn parse_port(text: &str) -> Result<u16, ConnectionUrlError> {
    match text.trim().parse::<u16>() {
        Ok(port) if port > 0 => Ok(port),
        _ => Err(ConnectionUrlError::InvalidPort),
    }
}

// libpq: a host that is a path is the socket's folder; one naming the socket file sets the port from its name.
fn postgres_socket(host: String, port: Option<u16>) -> (String, Option<u16>) {
    if !host.starts_with('/') {
        return (host, port);
    }
    let path = Path::new(&host);
    let named_port = path
        .file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.strip_prefix(".s.PGSQL."))
        .and_then(|number| number.parse::<u16>().ok());
    match (named_port, path.parent()) {
        (Some(named), Some(folder)) => (folder.display().to_string(), Some(named)),
        _ => (host, port),
    }
}

fn absolute_socket(path: &str) -> Result<String, ConnectionUrlError> {
    if path.starts_with('/') {
        Ok(path.to_owned())
    } else {
        Err(ConnectionUrlError::RelativePath)
    }
}

// redis-cli's `/2`, and the `db2` some providers write.
fn redis_database(path: &str) -> Result<String, ConnectionUrlError> {
    let number = path.strip_prefix("db").unwrap_or(path);
    match number {
        "" => Ok(String::new()),
        _ if number.parse::<u32>().is_ok() => Ok(number.to_owned()),
        _ => Err(ConnectionUrlError::DatabaseNumber),
    }
}

// The password logins the driver offers; another mechanism would fail as a wrong password.
fn check_mechanism(value: &str) -> Result<(), ConnectionUrlError> {
    match value.to_ascii_uppercase().as_str() {
        "" | "DEFAULT" | "SCRAM-SHA-1" | "SCRAM-SHA-256" => Ok(()),
        _ => Err(ConnectionUrlError::AuthMechanism {
            mechanism: value.to_owned(),
        }),
    }
}

fn parameters(text: &str, jdbc: bool) -> impl Iterator<Item = Result<(String, String), ConnectionUrlError>> + '_ {
    let pairs = match jdbc {
        true => jdbc_properties(text),
        false => text.split('&').collect(),
    };
    pairs
        .into_iter()
        .filter(|pair| !pair.trim().is_empty())
        .map(move |pair| {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            let value = value.trim();
            // JDBC values are literal: only a URL's query is percent-encoded.
            let value = match jdbc {
                true => match value.strip_prefix('{').and_then(|inner| inner.strip_suffix('}')) {
                    Some(quoted) => quoted.replace("}}", "}"),
                    None => value.to_owned(),
                },
                false => decode(value)?,
            };
            Ok((decode(key.trim())?.to_ascii_lowercase(), value))
        })
}

// JDBC's `{...}` quotes a value, `;` included, and `}}` inside it is one `}`.
fn jdbc_properties(text: &str) -> Vec<&str> {
    let mut pairs = Vec::new();
    let (mut start, mut quoted) = (0, false);
    let mut characters = text.char_indices().peekable();
    while let Some((index, character)) = characters.next() {
        match character {
            '{' if !quoted => quoted = true,
            '}' if quoted && characters.peek().is_some_and(|(_, next)| *next == '}') => {
                characters.next();
            }
            '}' => quoted = false,
            ';' if !quoted => {
                pairs.push(&text[start..index]);
                start = index + 1;
            }
            _ => {}
        }
    }
    pairs.push(&text[start..]);
    pairs
}

// Only `%` escapes decode, as libpq reads a URI: `+` stays a plus.
fn decode(text: &str) -> Result<String, ConnectionUrlError> {
    percent_decode_str(text)
        .decode_utf8()
        .map(|decoded| decoded.into_owned())
        .map_err(|_| ConnectionUrlError::Invalid)
}

fn strip_prefix_ignoring_case<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let head = text.get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix).then(|| &text[prefix.len()..])
}

#[cfg(test)]
mod tests;

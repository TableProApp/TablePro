use secrecy::SecretString;
use uuid::Uuid;

use tablepro_core::{AuthMode, Environment, TlsMode};

use crate::connections::SavedConnection;
use crate::error::StorageError;

/// Longest URL accepted. A connection URL is pasted by hand or arrives
/// from a clipboard, so the bound exists to stop a pathological input
/// from driving allocation in the percent decoder.
const MAX_URL_LEN: usize = 2048;
const MAX_HOST_LEN: usize = 253;
const MAX_FIELD_LEN: usize = 256;

/// Scheme aliases mapped to the driver id they select and the port to
/// assume when the URL omits one. The app crate has a test that pins
/// each port against the registered driver's own default.
const SCHEMES: &[(&str, &str, u16)] = &[
    ("postgres", "postgres", 5432),
    ("postgresql", "postgres", 5432),
    ("mysql", "mysql", 3306),
    ("mariadb", "mysql", 3306),
    ("mssql", "mssql", 1433),
    ("sqlserver", "mssql", 1433),
    ("clickhouse", "clickhouse", 8123),
    ("mongodb", "mongodb", 27017),
    ("redis", "redis", 6379),
];

/// A connection URL after parsing. The password never reaches
/// `connection`: it stays in a `secrecy` wrapper so the caller has to
/// hand it to Secret Service explicitly, and a caller that only saves
/// the JSON record cannot leak it to disk.
pub struct ParsedConnectionUrl {
    pub connection: SavedConnection,
    pub password: Option<SecretString>,
}

pub fn parse_connection_url(input: &str) -> Result<ParsedConnectionUrl, StorageError> {
    let raw = input.trim();
    if raw.is_empty() {
        return Err(invalid("a connection URL is required"));
    }
    if raw.len() > MAX_URL_LEN {
        return Err(invalid("the connection URL is too long"));
    }
    if raw.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err(invalid("the connection URL contains whitespace or control characters"));
    }

    let Some((scheme, remainder)) = raw.split_once("://") else {
        return Err(invalid("the connection URL needs a scheme such as postgres://"));
    };
    let scheme = scheme.to_ascii_lowercase();
    let Some(&(_, driver_id, default_port)) = SCHEMES.iter().find(|(alias, _, _)| *alias == scheme) else {
        return Err(invalid(&format!("{scheme} is not a database scheme TablePro knows")));
    };

    // Strip the query string before splitting on '/' so a database name
    // is never taken from a parameter value.
    let remainder = remainder.split(['?', '#']).next().unwrap_or_default();
    let (authority, path) = match remainder.split_once('/') {
        Some((authority, path)) => (authority, path),
        None => (remainder, ""),
    };
    if path.contains('/') {
        return Err(invalid("the connection URL has more than one path segment"));
    }

    let (credentials, host_port) = match authority.rsplit_once('@') {
        Some((credentials, host_port)) => (Some(credentials), host_port),
        None => (None, authority),
    };

    let (username, password) = match credentials {
        None => (String::new(), None),
        Some(credentials) => {
            let (user, secret) = match credentials.split_once(':') {
                Some((user, secret)) => (user, Some(secret)),
                None => (credentials, None),
            };
            let user = decode_field(user, "username")?;
            let secret = match secret {
                Some(secret) if !secret.is_empty() => Some(SecretString::from(decode_field(secret, "password")?)),
                _ => None,
            };
            (user, secret)
        }
    };

    let (host, port) = split_host_port(host_port, default_port)?;
    let database = decode_field(path, "database")?;

    let name = if database.is_empty() {
        host.clone()
    } else {
        format!("{database} on {host}")
    };

    let connection = SavedConnection {
        id: Uuid::new_v4(),
        name,
        driver_id: driver_id.to_string(),
        host,
        port,
        socket_dir: None,
        database,
        username,
        use_tls: false,
        tls_mode: Some(TlsMode::Disabled),
        tls_root_cert: None,
        tls_client_cert: None,
        tls_client_key: None,
        read_only: false,
        auth_mode: AuthMode::Password,
        environment: Environment::Local,
        ssh: None,
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    };

    Ok(ParsedConnectionUrl { connection, password })
}

fn split_host_port(authority: &str, default_port: u16) -> Result<(String, u16), StorageError> {
    if authority.is_empty() {
        return Err(invalid("the connection URL is missing a host"));
    }
    // Bracketed IPv6 literal: the colons inside the brackets are part of
    // the address, so only a colon after ']' introduces a port.
    if let Some(rest) = authority.strip_prefix('[') {
        let Some((address, tail)) = rest.split_once(']') else {
            return Err(invalid("the bracketed host in the connection URL is not closed"));
        };
        let port = parse_port(tail.strip_prefix(':'), default_port)?;
        return Ok((validate_host(address)?, port));
    }
    match authority.rsplit_once(':') {
        Some((host, port)) => Ok((validate_host(host)?, parse_port(Some(port), default_port)?)),
        None => Ok((validate_host(authority)?, default_port)),
    }
}

fn parse_port(port: Option<&str>, default_port: u16) -> Result<u16, StorageError> {
    let Some(port) = port else {
        return Ok(default_port);
    };
    if port.is_empty() {
        return Ok(default_port);
    }
    let parsed: u16 = port
        .parse()
        .map_err(|_| invalid("the port in the connection URL is not a number between 1 and 65535"))?;
    if parsed == 0 {
        return Err(invalid(
            "the port in the connection URL is not a number between 1 and 65535",
        ));
    }
    Ok(parsed)
}

fn validate_host(host: &str) -> Result<String, StorageError> {
    if host.is_empty() {
        return Err(invalid("the connection URL is missing a host"));
    }
    if host.len() > MAX_HOST_LEN {
        return Err(invalid("the host in the connection URL is too long"));
    }
    let acceptable = host
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ':' | '%'));
    if !acceptable {
        return Err(invalid(
            "the host in the connection URL contains characters that are not allowed",
        ));
    }
    Ok(host.to_ascii_lowercase())
}

fn decode_field(raw: &str, field: &str) -> Result<String, StorageError> {
    if raw.len() > MAX_FIELD_LEN {
        return Err(invalid(&format!("the {field} in the connection URL is too long")));
    }
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'%' {
            out.push(bytes[index]);
            index += 1;
            continue;
        }
        if index + 2 >= bytes.len() {
            return Err(invalid(&format!(
                "the {field} in the connection URL has a truncated escape"
            )));
        }
        let high = hex_value(bytes[index + 1]);
        let low = hex_value(bytes[index + 2]);
        match (high, low) {
            (Some(high), Some(low)) => out.push(high * 16 + low),
            _ => {
                return Err(invalid(&format!(
                    "the {field} in the connection URL has an invalid escape"
                )));
            }
        }
        index += 3;
    }
    let decoded = String::from_utf8(out)
        .map_err(|_| invalid(&format!("the {field} in the connection URL is not valid UTF-8")))?;
    if decoded.chars().any(char::is_control) {
        return Err(invalid(&format!(
            "the {field} in the connection URL contains control characters"
        )));
    }
    Ok(decoded)
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn invalid(message: &str) -> StorageError {
    StorageError::Schema(message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use secrecy::ExposeSecret;

    #[test]
    fn a_postgres_url_becomes_a_saved_connection() {
        let parsed = parse_connection_url("postgres://alice@db.example.com:5433/sales").unwrap();
        assert_eq!(parsed.connection.driver_id, "postgres");
        assert_eq!(parsed.connection.host, "db.example.com");
        assert_eq!(parsed.connection.port, 5433);
        assert_eq!(parsed.connection.database, "sales");
        assert_eq!(parsed.connection.username, "alice");
        assert_eq!(parsed.connection.name, "sales on db.example.com");
        assert!(parsed.password.is_none());
    }

    #[test]
    fn an_omitted_port_falls_back_to_the_scheme_default() {
        assert_eq!(
            parse_connection_url("mysql://root@localhost/app")
                .unwrap()
                .connection
                .port,
            3306
        );
        assert_eq!(
            parse_connection_url("postgresql://localhost").unwrap().connection.port,
            5432
        );
        assert_eq!(
            parse_connection_url("mariadb://localhost")
                .unwrap()
                .connection
                .driver_id,
            "mysql"
        );
    }

    #[test]
    fn a_password_is_kept_out_of_the_saved_record() {
        let parsed = parse_connection_url("postgres://alice:s3cr3t@db.example.com/sales").unwrap();
        assert_eq!(parsed.password.as_ref().map(|p| p.expose_secret()), Some("s3cr3t"));
        let json = serde_json::to_string(&parsed.connection).unwrap();
        assert!(
            !json.contains("s3cr3t"),
            "the serialized record must not carry the password"
        );
    }

    #[test]
    fn percent_escapes_are_decoded_in_credentials_and_database() {
        let parsed = parse_connection_url("postgres://a%40corp:p%2Fw%3A1@db.example.com/my%20db").unwrap();
        assert_eq!(parsed.connection.username, "a@corp");
        assert_eq!(parsed.connection.database, "my db");
        assert_eq!(parsed.password.as_ref().map(|p| p.expose_secret()), Some("p/w:1"));
    }

    #[test]
    fn a_bracketed_ipv6_host_keeps_its_address() {
        let parsed = parse_connection_url("postgres://u@[2001:db8::1]:6000/app").unwrap();
        assert_eq!(parsed.connection.host, "2001:db8::1");
        assert_eq!(parsed.connection.port, 6000);
    }

    #[test]
    fn a_query_string_never_becomes_the_database_name() {
        let parsed = parse_connection_url("postgres://u@db.example.com/app?sslmode=require").unwrap();
        assert_eq!(parsed.connection.database, "app");
    }

    #[test]
    fn imported_urls_default_to_a_local_read_write_password_connection() {
        let parsed = parse_connection_url("postgres://u@db.example.com/app").unwrap();
        assert_eq!(parsed.connection.environment, Environment::Local);
        assert_eq!(parsed.connection.auth_mode, AuthMode::Password);
        assert_eq!(parsed.connection.effective_tls_mode(), TlsMode::Disabled);
        assert!(!parsed.connection.read_only);
        assert!(parsed.connection.ssh.is_none());
    }

    #[test]
    fn hostile_and_malformed_urls_are_refused() {
        for input in [
            "",
            "   ",
            "db.example.com/app",
            "file:///etc/passwd",
            "javascript://db/app",
            "postgres://",
            "postgres:///app",
            "postgres://db.example.com:0/app",
            "postgres://db.example.com:99999/app",
            "postgres://db.example.com:abc/app",
            "postgres://db.example.com/a/b",
            "postgres://db.exa mple.com/app",
            "postgres://db.example.com/ap%2p",
            "postgres://db.example.com/ap%",
            "postgres://[2001:db8::1/app",
            "postgres://db;DROP TABLE t/app",
        ] {
            assert!(
                parse_connection_url(input).is_err(),
                "{input:?} must be refused, not imported"
            );
        }
    }

    #[test]
    fn an_over_long_url_is_refused_before_decoding() {
        let long = format!("postgres://u@db.example.com/{}", "a".repeat(MAX_URL_LEN));
        assert!(parse_connection_url(&long).is_err());
    }

    #[test]
    fn a_semicolon_or_quote_in_the_host_cannot_reach_a_saved_record() {
        assert!(parse_connection_url("postgres://u@db'--/app").is_err());
        assert!(parse_connection_url("postgres://u@db\"/app").is_err());
    }
}

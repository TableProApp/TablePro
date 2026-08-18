//! Connection configuration options.
//!
//! Provides `ConnectOptions` for configuring Dameng database connections
//! with charset, schema, timezone, SSL, and other parameters.
//! Also provides DSN string parsing for convenient connection setup.

use std::time::Duration;

use dameng_protocol::message::isolation::IsolationLevel;

/// Connection configuration options for Dameng database.
#[derive(Debug, Clone)]
pub struct ConnectOptions {
    /// Database host (required).
    pub host: String,
    /// Database port (default: 5236).
    pub port: u16,
    /// Username (required).
    pub username: String,
    /// Password (required).
    pub password: String,
    /// Character set (e.g., "utf8", "gb18030").
    pub charset: Option<String>,
    /// Database schema.
    pub schema: Option<String>,
    /// Timezone offset in hours.
    pub timezone: Option<i16>,
    /// Enable SSL/TLS encryption.
    pub ssl: bool,
    /// Maximum row size.
    pub max_row_size: Option<i32>,
    /// Connection timeout.
    pub connect_timeout: Option<Duration>,
    /// Auto-commit mode (default: true).
    pub auto_commit: bool,
    /// Transaction isolation level (default: ReadCommitted).
    pub isolation_level: IsolationLevel,
}

impl ConnectOptions {
    /// Create new ConnectOptions with required fields.
    pub fn new(host: &str, port: u16, username: &str, password: &str) -> Self {
        Self {
            host: host.to_string(),
            port,
            username: username.to_string(),
            password: password.to_string(),
            charset: None,
            schema: None,
            timezone: None,
            ssl: false,
            max_row_size: None,
            connect_timeout: None,
            auto_commit: true,
            isolation_level: IsolationLevel::ReadCommitted,
        }
    }

    /// Set the character set.
    pub fn charset(mut self, charset: &str) -> Self {
        self.charset = Some(charset.to_string());
        self
    }

    /// Set the database schema.
    pub fn schema(mut self, schema: &str) -> Self {
        self.schema = Some(schema.to_string());
        self
    }

    /// Set the timezone offset in hours.
    pub fn timezone(mut self, timezone: i16) -> Self {
        self.timezone = Some(timezone);
        self
    }

    /// Enable SSL/TLS encryption.
    pub fn ssl(mut self, ssl: bool) -> Self {
        self.ssl = ssl;
        self
    }

    /// Set the maximum row size.
    pub fn max_row_size(mut self, max_row_size: i32) -> Self {
        self.max_row_size = Some(max_row_size);
        self
    }

    /// Set the connection timeout.
    pub fn connect_timeout(mut self, timeout: Duration) -> Self {
        self.connect_timeout = Some(timeout);
        self
    }

    /// Set the auto-commit mode.
    pub fn auto_commit(mut self, auto_commit: bool) -> Self {
        self.auto_commit = auto_commit;
        self
    }

    /// Set the transaction isolation level.
    pub fn isolation_level(mut self, level: IsolationLevel) -> Self {
        self.isolation_level = level;
        self
    }

    /// Parse a DSN string into ConnectOptions.
    ///
    /// DSN format: `dm://username:password@host:port/schema?param1=value1&param2=value2`
    ///
    /// Supported query parameters:
    /// - `charset`: Character set (e.g., "utf8", "gb18030")
    /// - `timezone`: Timezone offset in hours
    /// - `ssl`: Enable SSL ("true" or "false")
    /// - `max_row_size`: Maximum row size
    /// - `connect_timeout`: Connection timeout in seconds
    /// - `auto_commit`: Auto-commit mode ("true" or "false")
    /// - `isolation_level`: Transaction isolation level ("read_uncommitted", "read_committed",
    ///   "repeatable_read", "serializable")
    ///
    /// # Examples
    ///
    /// ```ignore
    /// let opts = ConnectOptions::from_dsn(
    ///     "dm://SYSDBA:SYSDBA@127.0.0.1:5236/?charset=utf8&auto_commit=true"
    /// ).unwrap();
    /// ```
    pub fn from_dsn(dsn: &str) -> crate::error::Result<Self> {
        use crate::error::Error;

        // Parse scheme
        let (uri, _scheme) = if let Some(rest) = dsn.strip_prefix("dm://") {
            (rest, "dm")
        } else if let Some(rest) = dsn.strip_prefix("dm") {
            (rest, "dm")
        } else {
            return Err(Error::ConfigError(
                "invalid DSN: missing 'dm://' scheme".to_string(),
            ));
        };

        // Parse query parameters
        let (uri, query_params) = if let Some((before, after)) = uri.split_once('?') {
            (before, Self::parse_query_params(after))
        } else {
            (uri, std::collections::HashMap::new())
        };

        // Parse authority@host:port/schema
        let (userinfo, hostport) = if let Some((before, after)) = uri.split_once('@') {
            (Some(before), after)
        } else {
            (None, uri)
        };

        // Extract schema from hostport/schema
        let (hostport, schema) = if let Some((hp, sc)) = hostport.split_once('/') {
            (hp, Some(sc.to_string()))
        } else {
            (hostport, None)
        };

        // Parse host:port
        let (host, port) = if let Some((h, p)) = hostport.rsplit_once(':') {
            match p.parse::<u16>() {
                Ok(port) => (h, port),
                Err(_) => (hostport, 5236),
            }
        } else {
            (hostport, 5236)
        };

        if host.is_empty() {
            return Err(Error::ConfigError("invalid DSN: missing host".to_string()));
        }

        // Parse username:password
        let (username, password) = if let Some(ui) = userinfo {
            if let Some((u, p)) = ui.split_once(':') {
                (u, p)
            } else {
                (ui, "")
            }
        } else {
            ("", "")
        };

        let mut opts = ConnectOptions::new(host, port, username, password);

        // Apply schema from URL path (if present)
        if let Some(sc) = schema {
            opts.schema = Some(sc);
        }

        // Apply query parameters (can override URL path values)
        if let Some(charset) = query_params.get("charset") {
            opts.charset = Some(charset.clone());
        }
        if let Some(schema) = query_params.get("schema") {
            opts.schema = Some(schema.clone());
        }
        if let Some(tz) = query_params.get("timezone") {
            if let Ok(tz) = tz.parse::<i16>() {
                opts.timezone = Some(tz);
            }
        }
        if let Some(ssl_str) = query_params.get("ssl") {
            opts.ssl = ssl_str == "true";
        }
        if let Some(mrs) = query_params.get("max_row_size") {
            if let Ok(mrs) = mrs.parse::<i32>() {
                opts.max_row_size = Some(mrs);
            }
        }
        if let Some(ct) = query_params.get("connect_timeout") {
            if let Ok(ct) = ct.parse::<u64>() {
                opts.connect_timeout = Some(Duration::from_secs(ct));
            }
        }
        if let Some(ac) = query_params.get("auto_commit") {
            opts.auto_commit = ac == "true";
        }
        if let Some(iso) = query_params.get("isolation_level") {
            if let Some(level) = match iso.as_str() {
                "read_uncommitted" => Some(IsolationLevel::ReadUncommitted),
                "read_committed" => Some(IsolationLevel::ReadCommitted),
                "repeatable_read" => Some(IsolationLevel::RepeatableRead),
                "serializable" => Some(IsolationLevel::Serializable),
                _ => None,
            } {
                opts.isolation_level = level;
            }
        }

        Ok(opts)
    }

    /// Parse query parameter string into a HashMap.
    fn parse_query_params(params: &str) -> std::collections::HashMap<String, String> {
        let mut map = std::collections::HashMap::new();
        for pair in params.split('&') {
            if let Some((key, value)) = pair.split_once('=') {
                map.insert(key.to_string(), value.to_string());
            }
        }
        map
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_connect_options_new() {
        let opts = ConnectOptions::new("127.0.0.1", 5236, "SYSDBA", "SYSDBA");
        assert_eq!(opts.host, "127.0.0.1");
        assert_eq!(opts.port, 5236);
        assert_eq!(opts.username, "SYSDBA");
        assert_eq!(opts.password, "SYSDBA");
        assert_eq!(opts.charset, None);
        assert_eq!(opts.schema, None);
        assert!(!opts.ssl);
        assert!(opts.auto_commit);
        assert_eq!(opts.isolation_level, IsolationLevel::ReadCommitted);
    }

    #[test]
    fn test_connect_options_builder() {
        let opts = ConnectOptions::new("127.0.0.1", 5236, "SYSDBA", "SYSDBA")
            .charset("utf8")
            .schema("TEST")
            .timezone(8)
            .ssl(true)
            .max_row_size(8192)
            .connect_timeout(Duration::from_secs(30))
            .auto_commit(false)
            .isolation_level(IsolationLevel::Serializable);

        assert_eq!(opts.charset, Some("utf8".to_string()));
        assert_eq!(opts.schema, Some("TEST".to_string()));
        assert_eq!(opts.timezone, Some(8));
        assert!(opts.ssl);
        assert_eq!(opts.max_row_size, Some(8192));
        assert_eq!(opts.connect_timeout, Some(Duration::from_secs(30)));
        assert!(!opts.auto_commit);
        assert_eq!(opts.isolation_level, IsolationLevel::Serializable);
    }

    #[test]
    fn test_dsn_basic() {
        let opts = ConnectOptions::from_dsn("dm://SYSDBA:SYSDBA@127.0.0.1:5236/").unwrap();
        assert_eq!(opts.host, "127.0.0.1");
        assert_eq!(opts.port, 5236);
        assert_eq!(opts.username, "SYSDBA");
        assert_eq!(opts.password, "SYSDBA");
    }

    #[test]
    fn test_dsn_with_params() {
        let opts = ConnectOptions::from_dsn(
            "dm://SYSDBA:SYSDBA@127.0.0.1:5236/?charset=utf8&ssl=true&auto_commit=false",
        )
        .unwrap();
        assert_eq!(opts.charset, Some("utf8".to_string()));
        assert!(opts.ssl);
        assert!(!opts.auto_commit);
    }

    #[test]
    fn test_dsn_with_schema() {
        let opts =
            ConnectOptions::from_dsn("dm://SYSDBA:SYSDBA@127.0.0.1:5236/TEST?charset=gb18030")
                .unwrap();
        assert_eq!(opts.schema, Some("TEST".to_string()));
        assert_eq!(opts.charset, Some("gb18030".to_string()));
    }

    #[test]
    fn test_dsn_default_port() {
        let opts = ConnectOptions::from_dsn("dm://SYSDBA:SYSDBA@127.0.0.1").unwrap();
        assert_eq!(opts.host, "127.0.0.1");
        assert_eq!(opts.port, 5236);
    }

    #[test]
    fn test_dsn_isolation_level() {
        let opts = ConnectOptions::from_dsn(
            "dm://SYSDBA:SYSDBA@127.0.0.1:5236/?isolation_level=serializable",
        )
        .unwrap();
        assert_eq!(opts.isolation_level, IsolationLevel::Serializable);
    }

    #[test]
    fn test_dsn_invalid_scheme() {
        let result = ConnectOptions::from_dsn("mysql://SYSDBA:SYSDBA@127.0.0.1:5236/");
        assert!(result.is_err());
    }

    #[test]
    fn test_dsn_missing_host() {
        let result = ConnectOptions::from_dsn("dm://SYSDBA:SYSDBA@");
        assert!(result.is_err());
    }

    #[test]
    fn test_dsn_connect_timeout() {
        let opts =
            ConnectOptions::from_dsn("dm://SYSDBA:SYSDBA@127.0.0.1:5236/?connect_timeout=60")
                .unwrap();
        assert_eq!(opts.connect_timeout, Some(Duration::from_secs(60)));
    }

    #[test]
    fn test_dsn_max_row_size() {
        let opts =
            ConnectOptions::from_dsn("dm://SYSDBA:SYSDBA@127.0.0.1:5236/?max_row_size=16384")
                .unwrap();
        assert_eq!(opts.max_row_size, Some(16384));
    }
}

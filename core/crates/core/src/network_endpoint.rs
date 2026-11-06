use std::fmt;

use crate::ConfigError;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NetworkEndpoint {
    host: String,
    port: u16,
}

impl NetworkEndpoint {
    pub fn new(host: impl AsRef<str>, port: u16) -> Result<Self, ConfigError> {
        let trimmed = host.as_ref().trim();
        let host = trimmed
            .strip_prefix('[')
            .and_then(|inner| inner.strip_suffix(']'))
            .unwrap_or(trimmed);
        if host.is_empty() {
            return Err(ConfigError::EmptyHost);
        }
        // A socket's path may hold spaces, which no host name does.
        let socket = crate::is_local_socket_host(host);
        if host.chars().any(|c| c.is_control() || (c.is_whitespace() && !socket)) {
            return Err(ConfigError::InvalidHost);
        }
        if port == 0 {
            return Err(ConfigError::InvalidPort);
        }
        Ok(Self {
            host: host.to_owned(),
            port,
        })
    }

    // `host`, `host:port`, `[v6]` or `[v6]:port`; a bare v6 address takes `default_port`.
    pub fn parse(text: &str, default_port: u16) -> Result<Self, ConfigError> {
        let text = text.trim();
        let (host, port) = match text.strip_prefix('[') {
            Some(rest) => {
                let (host, after) = rest.split_once(']').ok_or(ConfigError::InvalidHost)?;
                match after {
                    "" => (host, None),
                    _ => (host, Some(after.strip_prefix(':').ok_or(ConfigError::InvalidHost)?)),
                }
            }
            None => match text.rsplit_once(':') {
                Some((host, port)) if !host.contains(':') => (host, Some(port)),
                _ => (text, None),
            },
        };
        let port = match port {
            Some(port) => port.parse().map_err(|_| ConfigError::InvalidPort)?,
            None => default_port,
        };
        Self::new(host, port)
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }
}

impl fmt::Display for NetworkEndpoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.host.contains(':') {
            write!(f, "[{}]:{}", self.host, self.port)
        } else {
            write!(f, "{}:{}", self.host, self.port)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_whitespace_control_and_port_zero() {
        assert_eq!(NetworkEndpoint::new("", 5432), Err(ConfigError::EmptyHost));
        assert_eq!(NetworkEndpoint::new("   ", 5432), Err(ConfigError::EmptyHost));
        assert_eq!(NetworkEndpoint::new("[]", 5432), Err(ConfigError::EmptyHost));
        assert_eq!(NetworkEndpoint::new("db host", 5432), Err(ConfigError::InvalidHost));
        assert_eq!(NetworkEndpoint::new("db\thost", 5432), Err(ConfigError::InvalidHost));
        assert_eq!(NetworkEndpoint::new("db\u{7}host", 5432), Err(ConfigError::InvalidHost));
        assert_eq!(NetworkEndpoint::new("db.example.com", 0), Err(ConfigError::InvalidPort));
    }

    #[test]
    fn parses_a_host_with_or_without_its_port() {
        let parse = |text| NetworkEndpoint::parse(text, 27017).map(|endpoint| endpoint.to_string());

        assert_eq!(parse("mongo1.example.com").as_deref(), Ok("mongo1.example.com:27017"));
        assert_eq!(parse(" mongo2:27018 ").as_deref(), Ok("mongo2:27018"));
        assert_eq!(parse("[::1]:27019").as_deref(), Ok("[::1]:27019"));
        assert_eq!(parse("[fe80::1]").as_deref(), Ok("[fe80::1]:27017"));
        assert_eq!(parse("::1").as_deref(), Ok("[::1]:27017"));
        assert_eq!(parse("mongo:http"), Err(ConfigError::InvalidPort));
        assert_eq!(parse("mongo:0"), Err(ConfigError::InvalidPort));
        assert_eq!(parse("[::1"), Err(ConfigError::InvalidHost));
        assert_eq!(parse("[::1]x"), Err(ConfigError::InvalidHost));
        assert_eq!(parse(":27017"), Err(ConfigError::EmptyHost));
    }

    #[test]
    fn a_socket_path_may_hold_spaces_and_no_control_characters() {
        let socket = NetworkEndpoint::new("/home/ada/My Databases/mysql.sock", 3306).unwrap();
        assert_eq!(socket.host(), "/home/ada/My Databases/mysql.sock");
        assert_eq!(
            NetworkEndpoint::new("/run/my\u{7}sql", 3306),
            Err(ConfigError::InvalidHost)
        );
    }

    #[test]
    fn trims_surrounding_whitespace() {
        let endpoint = NetworkEndpoint::new("  db.example.com\n", 5432).unwrap();
        assert_eq!(endpoint.host(), "db.example.com");
        assert_eq!(endpoint.port(), 5432);
    }

    #[test]
    fn strips_ipv6_brackets_and_displays_them() {
        let bracketed = NetworkEndpoint::new("[::1]", 5432).unwrap();
        assert_eq!(bracketed.host(), "::1");
        assert_eq!(bracketed.to_string(), "[::1]:5432");
        assert_eq!(NetworkEndpoint::new("::1", 5432).unwrap(), bracketed);
        assert_eq!(
            NetworkEndpoint::new("db.example.com", 3306).unwrap().to_string(),
            "db.example.com:3306"
        );
    }
}

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
        if host.chars().any(|c| c.is_whitespace() || c.is_control()) {
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

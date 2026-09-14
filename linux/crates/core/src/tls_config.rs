use std::path::{Path, PathBuf};

use rustls_pki_types::ServerName;
use serde::{Deserialize, Serialize};

use crate::{ClientIdentity, ConfigError, ServerNameOverride, TlsCapabilities, TlsMode, TransportClass};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TlsConfig {
    pub mode: TlsMode,
    #[serde(default)]
    pub ca_file: Option<PathBuf>,
    #[serde(default)]
    pub client_identity: Option<ClientIdentity>,
    #[serde(default)]
    pub server_name: Option<String>,
}

impl TlsConfig {
    pub fn verify_full() -> Self {
        Self::with_mode(TlsMode::VerifyFull)
    }

    pub fn disabled() -> Self {
        Self::with_mode(TlsMode::Disable)
    }

    fn with_mode(mode: TlsMode) -> Self {
        Self {
            mode,
            ca_file: None,
            client_identity: None,
            server_name: None,
        }
    }

    pub fn validate(&self, caps: &TlsCapabilities, route: TransportClass) -> Result<(), ConfigError> {
        if !caps.modes.contains(&self.mode) {
            return Err(ConfigError::UnsupportedTlsMode);
        }
        let encrypted = self.mode != TlsMode::Disable;
        if let Some(ca_file) = &self.ca_file {
            if !(caps.ca_file && encrypted) {
                return Err(ConfigError::CaFileUnsupported);
            }
            require_absolute(ca_file)?;
        }
        if let Some(identity) = &self.client_identity {
            if !(caps.client_identity && encrypted) {
                return Err(ConfigError::ClientIdentityUnsupported);
            }
            validate_identity(identity)?;
        }
        if let Some(server_name) = &self.server_name {
            validate_server_name(server_name, caps.server_name_override, route)?;
        }
        Ok(())
    }
}

fn require_absolute(path: &Path) -> Result<(), ConfigError> {
    if path.is_absolute() {
        Ok(())
    } else {
        Err(ConfigError::RelativePath)
    }
}

fn validate_identity(identity: &ClientIdentity) -> Result<(), ConfigError> {
    if identity.certificate.as_os_str().is_empty() || identity.key.as_os_str().is_empty() {
        return Err(ConfigError::ClientIdentityIncomplete);
    }
    require_absolute(&identity.certificate)?;
    require_absolute(&identity.key)
}

fn validate_server_name(
    server_name: &str,
    coverage: ServerNameOverride,
    route: TransportClass,
) -> Result<(), ConfigError> {
    if ServerName::try_from(server_name).is_err() {
        return Err(ConfigError::InvalidServerName);
    }
    match (coverage, route) {
        (ServerNameOverride::AnyRoute, _) | (ServerNameOverride::SshForwardOnly, TransportClass::SshForward) => Ok(()),
        (ServerNameOverride::SshForwardOnly | ServerNameOverride::Unsupported, _) => {
            Err(ConfigError::ServerNameOverrideUnsupported { route })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL_MODES: &[TlsMode] = &[TlsMode::Disable, TlsMode::Require, TlsMode::VerifyFull];
    const ROUTES: [TransportClass; 2] = [TransportClass::DirectTcp, TransportClass::SshForward];

    const POSTGRES: TlsCapabilities = TlsCapabilities {
        modes: ALL_MODES,
        ca_file: true,
        client_identity: true,
        server_name_override: ServerNameOverride::AnyRoute,
    };
    const MYSQL: TlsCapabilities = TlsCapabilities {
        server_name_override: ServerNameOverride::SshForwardOnly,
        ..POSTGRES
    };
    const MSSQL: TlsCapabilities = TlsCapabilities {
        client_identity: false,
        ..POSTGRES
    };
    const VERIFY_ONLY: TlsCapabilities = TlsCapabilities {
        modes: &[TlsMode::VerifyFull],
        ca_file: false,
        client_identity: false,
        server_name_override: ServerNameOverride::Unsupported,
    };

    fn with_server_name(name: &str) -> TlsConfig {
        TlsConfig {
            server_name: Some(name.to_owned()),
            ..TlsConfig::verify_full()
        }
    }

    fn with_ca_file(mode: TlsMode, path: &str) -> TlsConfig {
        TlsConfig {
            mode,
            ca_file: Some(PathBuf::from(path)),
            client_identity: None,
            server_name: None,
        }
    }

    fn with_identity(certificate: &str, key: &str) -> TlsConfig {
        TlsConfig {
            client_identity: Some(ClientIdentity {
                certificate: PathBuf::from(certificate),
                key: PathBuf::from(key),
            }),
            ..TlsConfig::verify_full()
        }
    }

    #[test]
    fn validate_table() {
        for caps in [POSTGRES, MYSQL, MSSQL] {
            for mode in ALL_MODES {
                for route in ROUTES {
                    let config = TlsConfig {
                        mode: *mode,
                        ..TlsConfig::disabled()
                    };
                    assert_eq!(config.validate(&caps, route), Ok(()), "{mode:?} {caps:?} {route:?}");
                }
            }
        }

        let cases = [
            (
                "mode outside the capabilities",
                TlsConfig {
                    mode: TlsMode::Require,
                    ..TlsConfig::disabled()
                },
                VERIFY_ONLY,
                TransportClass::DirectTcp,
                Err(ConfigError::UnsupportedTlsMode),
            ),
            (
                "mysql server name over direct tcp",
                with_server_name("db.internal"),
                MYSQL,
                TransportClass::DirectTcp,
                Err(ConfigError::ServerNameOverrideUnsupported {
                    route: TransportClass::DirectTcp,
                }),
            ),
            (
                "mysql server name over an ssh forward",
                with_server_name("db.internal"),
                MYSQL,
                TransportClass::SshForward,
                Ok(()),
            ),
            (
                "postgres server name over direct tcp",
                with_server_name("db.internal"),
                POSTGRES,
                TransportClass::DirectTcp,
                Ok(()),
            ),
            (
                "server name without override support",
                with_server_name("db.internal"),
                VERIFY_ONLY,
                TransportClass::SshForward,
                Err(ConfigError::ServerNameOverrideUnsupported {
                    route: TransportClass::SshForward,
                }),
            ),
            (
                "mssql client identity",
                with_identity("/etc/tls/client.pem", "/etc/tls/client.key"),
                MSSQL,
                TransportClass::DirectTcp,
                Err(ConfigError::ClientIdentityUnsupported),
            ),
            (
                "postgres client identity",
                with_identity("/etc/tls/client.pem", "/etc/tls/client.key"),
                POSTGRES,
                TransportClass::DirectTcp,
                Ok(()),
            ),
            (
                "client identity with tls disabled",
                TlsConfig {
                    mode: TlsMode::Disable,
                    ..with_identity("/etc/tls/client.pem", "/etc/tls/client.key")
                },
                POSTGRES,
                TransportClass::DirectTcp,
                Err(ConfigError::ClientIdentityUnsupported),
            ),
            (
                "identity with a missing key",
                with_identity("/etc/tls/client.pem", ""),
                POSTGRES,
                TransportClass::DirectTcp,
                Err(ConfigError::ClientIdentityIncomplete),
            ),
            (
                "identity with a relative key",
                with_identity("/etc/tls/client.pem", "client.key"),
                POSTGRES,
                TransportClass::DirectTcp,
                Err(ConfigError::RelativePath),
            ),
            (
                "ca file with tls disabled",
                with_ca_file(TlsMode::Disable, "/etc/tls/ca.pem"),
                POSTGRES,
                TransportClass::DirectTcp,
                Err(ConfigError::CaFileUnsupported),
            ),
            (
                "ca file without support",
                with_ca_file(TlsMode::VerifyFull, "/etc/tls/ca.pem"),
                VERIFY_ONLY,
                TransportClass::DirectTcp,
                Err(ConfigError::CaFileUnsupported),
            ),
            (
                "relative ca file",
                with_ca_file(TlsMode::VerifyFull, "certs/ca.pem"),
                MSSQL,
                TransportClass::DirectTcp,
                Err(ConfigError::RelativePath),
            ),
            (
                "absolute ca file",
                with_ca_file(TlsMode::Require, "/etc/tls/ca.pem"),
                MSSQL,
                TransportClass::SshForward,
                Ok(()),
            ),
        ];
        for (name, config, caps, route, expected) in cases {
            assert_eq!(config.validate(&caps, route), expected, "{name}");
        }
    }

    #[test]
    fn invalid_server_name_is_config_error() {
        for name in ["", "has space.example.com", "double..dot.example.com"] {
            assert_eq!(
                with_server_name(name).validate(&POSTGRES, TransportClass::DirectTcp),
                Err(ConfigError::InvalidServerName),
                "{name:?}"
            );
        }
        for name in ["db.example.com", "10.0.0.5", "::1"] {
            assert_eq!(
                with_server_name(name).validate(&POSTGRES, TransportClass::DirectTcp),
                Ok(()),
                "{name:?}"
            );
        }
    }

    #[test]
    fn serde_round_trip_keeps_optional_fields() {
        let config = TlsConfig {
            mode: TlsMode::VerifyFull,
            ca_file: Some(PathBuf::from("/etc/tls/ca.pem")),
            client_identity: Some(ClientIdentity {
                certificate: PathBuf::from("/etc/tls/client.pem"),
                key: PathBuf::from("/etc/tls/client.key"),
            }),
            server_name: Some("db.internal".to_owned()),
        };
        let json = serde_json::to_string(&config).unwrap();
        assert!(json.contains(r#""mode":"verify_full""#), "{json}");
        assert_eq!(serde_json::from_str::<TlsConfig>(&json).unwrap(), config);

        let minimal: TlsConfig = serde_json::from_str(r#"{"mode":"require"}"#).unwrap();
        assert_eq!(
            minimal,
            TlsConfig {
                mode: TlsMode::Require,
                ..TlsConfig::disabled()
            }
        );
    }
}

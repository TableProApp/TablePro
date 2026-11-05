use crate::{ServerNameOverride, TlsMode};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TlsCapabilities {
    pub modes: &'static [TlsMode],
    /// The mode a new connection starts on: the one the engine's own
    /// client starts on (core ADR 0011).
    pub default_mode: TlsMode,
    /// Ports that serve only TLS, where a new connection starts on
    /// `VerifyFull` instead.
    pub tls_ports: &'static [u16],
    pub ca_file: bool,
    pub client_identity: bool,
    pub server_name_override: ServerNameOverride,
}

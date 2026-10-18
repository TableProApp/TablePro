use crate::{ServerNameOverride, TlsMode};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TlsCapabilities {
    pub modes: &'static [TlsMode],
    pub ca_file: bool,
    pub client_identity: bool,
    pub server_name_override: ServerNameOverride,
}

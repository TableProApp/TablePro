#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PkiFile {
    Ca,
    UnrelatedCa,
    ServerCertificate,
    ServerKey,
    ClientCertificate,
    ClientKey,
}

impl PkiFile {
    pub const ALL: [Self; 6] = [
        Self::Ca,
        Self::UnrelatedCa,
        Self::ServerCertificate,
        Self::ServerKey,
        Self::ClientCertificate,
        Self::ClientKey,
    ];

    pub fn file_name(self) -> &'static str {
        match self {
            Self::Ca => "ca.pem",
            Self::UnrelatedCa => "unrelated-ca.pem",
            Self::ServerCertificate => "server.pem",
            Self::ServerKey => "server.key",
            Self::ClientCertificate => "client.pem",
            Self::ClientKey => "client.key",
        }
    }

    pub fn is_private_key(self) -> bool {
        matches!(self, Self::ServerKey | Self::ClientKey)
    }
}

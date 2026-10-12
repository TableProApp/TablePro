/// A row of the connect dialog that a problem can be pinned to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FormField {
    Host,
    Port,
    Database,
    File,
    AuthMode,
    Username,
    Encryption,
    CaFile,
    ClientCertificate,
    ClientKey,
    ServerName,
    SshHost,
    SshPort,
    SshUser,
    SshJumpHosts,
    SshKeyPath,
}

impl FormField {
    /// The rows that live in the Security group, so the dialog knows
    /// which section to hand a problem to.
    pub fn is_tls(self) -> bool {
        matches!(
            self,
            Self::Encryption | Self::CaFile | Self::ClientCertificate | Self::ClientKey | Self::ServerName
        )
    }

    pub fn is_ssh(self) -> bool {
        matches!(
            self,
            Self::SshHost | Self::SshPort | Self::SshUser | Self::SshJumpHosts | Self::SshKeyPath
        )
    }
}

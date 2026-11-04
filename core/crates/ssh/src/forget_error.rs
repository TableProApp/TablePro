use std::path::PathBuf;

use tablepro_core::SshFailure;

/// Why a key reported as changed was left in known_hosts.
#[derive(Debug, thiserror::Error)]
pub enum ForgetHostKeyError {
    /// No host of this connection reads `known_hosts` under `host`, so
    /// the report did not come from this connection's own check.
    #[error("{host} in {} is not a host key this connection uses", .known_hosts.display())]
    NotThisConnection { host: String, known_hosts: PathBuf },
    #[error(transparent)]
    Ssh(#[from] SshFailure),
}

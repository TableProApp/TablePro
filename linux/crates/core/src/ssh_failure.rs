use std::path::PathBuf;

use thiserror::Error;

use crate::ErrorCategory;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum SshFailure {
    #[error("the OpenSSH client {} was not found", .program.display())]
    OpenSshClientMissing { program: PathBuf },

    #[error("the askpass helper {} was not found", .program.display())]
    AskpassHelperMissing { program: PathBuf },

    #[error("invalid SSH destination: {detail}")]
    InvalidDestination { detail: String },

    #[error("ssh rejected the configuration: {detail}")]
    ConfigRejected { detail: String },

    #[error("the SSH control socket path {} is too long", .path.display())]
    ControlPathTooLong { path: PathBuf },

    #[error("the SSH runtime directory {} is unsafe: {detail}", .path.display())]
    RuntimeDirUnsafe { path: PathBuf, detail: String },

    #[error("the {algorithm} host key {sha256_fingerprint} for {host} is not known")]
    HostKeyUnknown {
        host: String,
        algorithm: String,
        sha256_fingerprint: String,
        trust_allowed: bool,
        declined: bool,
    },

    #[error(
        "the {algorithm} host key for {host} changed to {sha256_fingerprint}; the old key is at {}:{line}",
        .known_hosts.display()
    )]
    HostKeyChanged {
        host: String,
        algorithm: String,
        sha256_fingerprint: String,
        known_hosts: PathBuf,
        line: usize,
    },

    #[error("the host key for {host} is revoked: {detail}")]
    HostKeyRevoked { host: String, detail: String },

    #[error("{user}@{host} rejected authentication (tried {})", .methods.join(", "))]
    AuthenticationRejected {
        user: String,
        host: String,
        methods: Vec<String>,
    },

    #[error("the SSH prompt was cancelled")]
    InteractionCancelled,

    #[error("the SSH server refused to forward to {target}: {detail}")]
    ForwardRejected { target: String, detail: String },

    #[error("could not open an SSH channel to {target}: {detail}")]
    ChannelOpenFailed { target: String, detail: String },

    #[error("the SSH connection ended: {detail}")]
    MasterExited { status: Option<i32>, detail: String },

    #[error("unexpected output from ssh: {detail}")]
    Protocol { detail: String },
}

impl SshFailure {
    pub fn category(&self) -> ErrorCategory {
        match self {
            Self::AuthenticationRejected { .. }
            | Self::InteractionCancelled
            | Self::HostKeyUnknown { .. }
            | Self::HostKeyChanged { .. }
            | Self::HostKeyRevoked { .. } => ErrorCategory::Authentication,
            Self::OpenSshClientMissing { .. }
            | Self::AskpassHelperMissing { .. }
            | Self::InvalidDestination { .. }
            | Self::ConfigRejected { .. }
            | Self::ControlPathTooLong { .. }
            | Self::RuntimeDirUnsafe { .. } => ErrorCategory::Configuration,
            Self::ForwardRejected { .. } | Self::ChannelOpenFailed { .. } | Self::MasterExited { .. } => {
                ErrorCategory::Network
            }
            Self::Protocol { .. } => ErrorCategory::Internal,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detail() -> String {
        "detail".to_owned()
    }

    #[test]
    fn category_matrix() {
        let cases = [
            (
                SshFailure::OpenSshClientMissing {
                    program: PathBuf::from("/usr/bin/ssh"),
                },
                ErrorCategory::Configuration,
            ),
            (
                SshFailure::AskpassHelperMissing {
                    program: PathBuf::from("/usr/libexec/tablepro-askpass"),
                },
                ErrorCategory::Configuration,
            ),
            (
                SshFailure::InvalidDestination { detail: detail() },
                ErrorCategory::Configuration,
            ),
            (
                SshFailure::ConfigRejected { detail: detail() },
                ErrorCategory::Configuration,
            ),
            (
                SshFailure::ControlPathTooLong {
                    path: PathBuf::from("/run/user/1000/app/control"),
                },
                ErrorCategory::Configuration,
            ),
            (
                SshFailure::RuntimeDirUnsafe {
                    path: PathBuf::from("/run/user/1000/app"),
                    detail: detail(),
                },
                ErrorCategory::Configuration,
            ),
            (
                SshFailure::HostKeyUnknown {
                    host: "bastion".to_owned(),
                    algorithm: "ssh-ed25519".to_owned(),
                    sha256_fingerprint: "SHA256:abc".to_owned(),
                    trust_allowed: true,
                    declined: false,
                },
                ErrorCategory::Authentication,
            ),
            (
                SshFailure::HostKeyChanged {
                    host: "bastion".to_owned(),
                    algorithm: "ssh-ed25519".to_owned(),
                    sha256_fingerprint: "SHA256:abc".to_owned(),
                    known_hosts: PathBuf::from("/home/user/.ssh/known_hosts"),
                    line: 3,
                },
                ErrorCategory::Authentication,
            ),
            (
                SshFailure::HostKeyRevoked {
                    host: "bastion".to_owned(),
                    detail: detail(),
                },
                ErrorCategory::Authentication,
            ),
            (
                SshFailure::AuthenticationRejected {
                    user: "deploy".to_owned(),
                    host: "bastion".to_owned(),
                    methods: vec!["publickey".to_owned(), "password".to_owned()],
                },
                ErrorCategory::Authentication,
            ),
            (SshFailure::InteractionCancelled, ErrorCategory::Authentication),
            (
                SshFailure::ForwardRejected {
                    target: "db:5432".to_owned(),
                    detail: detail(),
                },
                ErrorCategory::Network,
            ),
            (
                SshFailure::ChannelOpenFailed {
                    target: "db:5432".to_owned(),
                    detail: detail(),
                },
                ErrorCategory::Network,
            ),
            (
                SshFailure::MasterExited {
                    status: Some(255),
                    detail: detail(),
                },
                ErrorCategory::Network,
            ),
            (SshFailure::Protocol { detail: detail() }, ErrorCategory::Internal),
        ];
        for (failure, expected) in cases {
            assert_eq!(failure.category(), expected, "{failure:?}");
        }
    }

    #[test]
    fn authentication_rejected_lists_the_methods_tried() {
        let failure = SshFailure::AuthenticationRejected {
            user: "deploy".to_owned(),
            host: "bastion".to_owned(),
            methods: vec!["publickey".to_owned(), "password".to_owned()],
        };
        assert_eq!(
            failure.to_string(),
            "deploy@bastion rejected authentication (tried publickey, password)"
        );
    }
}

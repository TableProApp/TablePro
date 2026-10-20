use std::io::ErrorKind;
use std::path::PathBuf;

use thiserror::Error;

use crate::{ErrorCategory, SshAlgorithmKind, SshDestinationProblem, SshRuntimeDirProblem};

#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum SshFailure {
    #[error("the OpenSSH client {} was not found", .program.display())]
    OpenSshClientMissing { program: PathBuf },

    #[error("the askpass helper {} was not found", .program.display())]
    AskpassHelperMissing { program: PathBuf },

    #[error("{} could not be started: {kind}", .program.display())]
    LaunchFailed { program: PathBuf, kind: ErrorKind },

    #[error("invalid SSH destination: {problem}")]
    InvalidDestination { problem: SshDestinationProblem },

    #[error("ssh rejected the configuration: {detail}")]
    ConfigRejected { detail: String },

    #[error("the ssh_config file {} could not be read: {kind}", .path.display())]
    ConfigUnreadable { path: PathBuf, kind: ErrorKind },

    #[error("the SSH control socket path {} is too long", .path.display())]
    ControlPathTooLong { path: PathBuf },

    #[error("the SSH runtime directory {} is unsafe: {problem}", .path.display())]
    RuntimeDirUnsafe {
        path: PathBuf,
        problem: SshRuntimeDirProblem,
    },

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
        /// False when the host's ssh configuration takes only keys already
        /// in known_hosts, so ssh would refuse the new key without asking
        /// once the old one is removed.
        trust_allowed: bool,
    },

    #[error("the host key for {host} is revoked: {detail}")]
    HostKeyRevoked { host: String, detail: String },

    #[error("{user}@{host} rejected authentication (tried {})", .methods.join(", "))]
    AuthenticationRejected {
        user: String,
        host: String,
        methods: Vec<String>,
    },

    /// The server's MaxAuthTries ran out, as with an agent holding more keys than it allows.
    #[error("{host} closed the connection after too many authentication attempts")]
    AuthenticationAttemptsExceeded { host: String },

    #[error("{host} and the OpenSSH client share no {kind} (the server offers {})", .server_offer.join(", "))]
    NoCommonAlgorithm {
        host: String,
        kind: SshAlgorithmKind,
        server_offer: Vec<String>,
    },

    #[error("the SSH prompt was cancelled")]
    InteractionCancelled,

    #[error("the SSH server refused to forward to {target}: {detail}")]
    ForwardRejected { target: String, detail: String },

    #[error("could not open an SSH channel to {target}: {detail}")]
    ChannelOpenFailed { target: String, detail: String },

    /// `detail` is ssh's last line, empty when it printed none.
    #[error("the SSH connection ended: {detail}")]
    MasterExited { status: Option<i32>, detail: String },

    /// `status` is set when ssh exited with one, and `detail` is the end
    /// of what it printed.
    #[error("unexpected output from ssh (exit status {status:?}): {detail}")]
    Protocol { status: Option<i32>, detail: String },

    /// A step of TablePro's own failed, such as a setup task that
    /// panicked. Its cause is logged where it happened.
    #[error("an internal step of the SSH setup failed")]
    Internal,
}

impl SshFailure {
    pub fn category(&self) -> ErrorCategory {
        match self {
            Self::AuthenticationRejected { .. }
            | Self::AuthenticationAttemptsExceeded { .. }
            | Self::InteractionCancelled
            | Self::HostKeyUnknown { .. }
            | Self::HostKeyChanged { .. }
            | Self::HostKeyRevoked { .. } => ErrorCategory::Authentication,
            Self::OpenSshClientMissing { .. }
            | Self::AskpassHelperMissing { .. }
            | Self::LaunchFailed { .. }
            | Self::InvalidDestination { .. }
            | Self::ConfigRejected { .. }
            | Self::ConfigUnreadable { .. }
            | Self::ControlPathTooLong { .. }
            | Self::RuntimeDirUnsafe { .. }
            | Self::NoCommonAlgorithm { .. } => ErrorCategory::Configuration,
            Self::ForwardRejected { .. } | Self::ChannelOpenFailed { .. } | Self::MasterExited { .. } => {
                ErrorCategory::Network
            }
            Self::Protocol { .. } | Self::Internal => ErrorCategory::Internal,
        }
    }
}

impl From<SshDestinationProblem> for SshFailure {
    fn from(problem: SshDestinationProblem) -> Self {
        Self::InvalidDestination { problem }
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
                SshFailure::InvalidDestination {
                    problem: SshDestinationProblem::PortZero,
                },
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
                    problem: SshRuntimeDirProblem::OtherOwner,
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
                    trust_allowed: true,
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
        ];
        for (failure, expected) in cases {
            assert_eq!(failure.category(), expected, "{failure:?}");
        }
    }

    #[test]
    fn a_program_or_file_ssh_needs_is_configuration_and_the_rest_internal() {
        let launch = SshFailure::LaunchFailed {
            program: PathBuf::from("ssh"),
            kind: ErrorKind::PermissionDenied,
        };
        let unreadable = SshFailure::ConfigUnreadable {
            path: PathBuf::from("/home/user/.ssh/tablepro_config"),
            kind: ErrorKind::NotFound,
        };
        let protocol = SshFailure::Protocol {
            status: Some(255),
            detail: detail(),
        };

        assert_eq!(launch.category(), ErrorCategory::Configuration);
        assert_eq!(unreadable.category(), ErrorCategory::Configuration);
        assert_eq!(protocol.category(), ErrorCategory::Internal);
        assert_eq!(SshFailure::Internal.category(), ErrorCategory::Internal);
    }

    /// Neither clears on a retry, so both park the reconnect monitor
    /// rather than counting as internal.
    #[test]
    fn exhausted_attempts_and_no_common_algorithm_need_the_user() {
        let exhausted = SshFailure::AuthenticationAttemptsExceeded {
            host: "bastion".to_owned(),
        };
        let no_common = SshFailure::NoCommonAlgorithm {
            host: "bastion".to_owned(),
            kind: SshAlgorithmKind::KeyExchange,
            server_offer: vec!["mlkem768x25519-sha256".to_owned()],
        };

        assert_eq!(exhausted.category(), ErrorCategory::Authentication);
        assert_eq!(no_common.category(), ErrorCategory::Configuration);
    }

    #[test]
    fn no_common_algorithm_names_the_list_and_the_server_offer() {
        let failure = SshFailure::NoCommonAlgorithm {
            host: "bastion".to_owned(),
            kind: SshAlgorithmKind::KeyExchange,
            server_offer: vec!["mlkem768x25519-sha256".to_owned(), "sntrup761x25519-sha512".to_owned()],
        };

        assert_eq!(
            failure.to_string(),
            "bastion and the OpenSSH client share no key exchange method \
             (the server offers mlkem768x25519-sha256, sntrup761x25519-sha512)"
        );
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

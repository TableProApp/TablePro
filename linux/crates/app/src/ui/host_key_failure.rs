//! A host key ssh refused, in the terms the review dialog shows it.

use std::path::PathBuf;

use tablepro_core::{DriverError, SshFailure, TransportError};
use tablepro_session::ConnectError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HostKeyFailure {
    /// The name ssh looks the host up by: `host`, `[host]:port` or an
    /// alias, as ssh printed it.
    pub host: String,
    pub algorithm: String,
    /// Empty when ssh refused without showing the key.
    pub fingerprint: String,
    pub kind: HostKeyFailureKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum HostKeyFailureKind {
    /// `trust_allowed` is false when the user's ssh configuration takes
    /// only keys already in known_hosts, so ssh never asks.
    Unknown {
        trust_allowed: bool,
    },
    /// The old key is at `line` of `known_hosts`. `trust_allowed` is as
    /// for `Unknown`, for the new key once the old one is removed.
    Changed {
        known_hosts: PathBuf,
        line: usize,
        trust_allowed: bool,
    },
    Revoked {
        detail: String,
    },
}

impl HostKeyFailure {
    pub(crate) fn from_connect_error(error: &ConnectError) -> Option<Self> {
        let ConnectError::Driver(DriverError::Transport(TransportError::Ssh(failure))) = error else {
            return None;
        };
        Self::from_ssh_failure(failure)
    }

    fn from_ssh_failure(failure: &SshFailure) -> Option<Self> {
        match failure {
            SshFailure::HostKeyUnknown {
                host,
                algorithm,
                sha256_fingerprint,
                trust_allowed,
                ..
            } => Some(Self {
                host: host.clone(),
                algorithm: algorithm.clone(),
                fingerprint: sha256_fingerprint.clone(),
                kind: HostKeyFailureKind::Unknown {
                    trust_allowed: *trust_allowed,
                },
            }),
            SshFailure::HostKeyChanged {
                host,
                algorithm,
                sha256_fingerprint,
                known_hosts,
                line,
                trust_allowed,
            } => Some(Self {
                host: host.clone(),
                algorithm: algorithm.clone(),
                fingerprint: sha256_fingerprint.clone(),
                kind: HostKeyFailureKind::Changed {
                    known_hosts: known_hosts.clone(),
                    line: *line,
                    trust_allowed: *trust_allowed,
                },
            }),
            SshFailure::HostKeyRevoked { host, detail } => Some(Self {
                host: host.clone(),
                algorithm: String::new(),
                fingerprint: String::new(),
                kind: HostKeyFailureKind::Revoked { detail: detail.clone() },
            }),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::LossPhase;

    use super::*;

    fn ssh(failure: SshFailure) -> ConnectError {
        ConnectError::Driver(DriverError::Transport(TransportError::Ssh(failure)))
    }

    #[test]
    fn each_host_key_refusal_becomes_a_failure_to_review() {
        let unknown = ssh(SshFailure::HostKeyUnknown {
            host: "bastion".to_owned(),
            algorithm: "ED25519".to_owned(),
            sha256_fingerprint: "SHA256:new".to_owned(),
            trust_allowed: true,
            declined: true,
        });
        let changed = ssh(SshFailure::HostKeyChanged {
            host: "[db.example.com]:2222".to_owned(),
            algorithm: "ED25519".to_owned(),
            sha256_fingerprint: "SHA256:new".to_owned(),
            known_hosts: PathBuf::from("/home/u/.ssh/known_hosts"),
            line: 3,
            trust_allowed: false,
        });
        let revoked = ssh(SshFailure::HostKeyRevoked {
            host: "bastion".to_owned(),
            detail: "revoked by file /etc/ssh/krl".to_owned(),
        });

        assert_eq!(
            HostKeyFailure::from_connect_error(&unknown).map(|failure| failure.kind),
            Some(HostKeyFailureKind::Unknown { trust_allowed: true })
        );
        let changed = HostKeyFailure::from_connect_error(&changed).unwrap();
        assert_eq!(changed.host, "[db.example.com]:2222");
        assert_eq!(changed.fingerprint, "SHA256:new");
        assert_eq!(
            changed.kind,
            HostKeyFailureKind::Changed {
                known_hosts: PathBuf::from("/home/u/.ssh/known_hosts"),
                line: 3,
                trust_allowed: false,
            }
        );
        assert!(matches!(
            HostKeyFailure::from_connect_error(&revoked).map(|failure| failure.kind),
            Some(HostKeyFailureKind::Revoked { .. })
        ));
    }

    #[test]
    fn other_failures_have_no_key_to_review() {
        let errors = [
            ssh(SshFailure::InteractionCancelled),
            ConnectError::Driver(DriverError::auth(None)),
            ConnectError::Driver(DriverError::ConnectionLost {
                during: LossPhase::Connect,
            }),
            ConnectError::Cancelled,
        ];

        for error in errors {
            assert_eq!(HostKeyFailure::from_connect_error(&error), None, "{error:?}");
        }
    }
}

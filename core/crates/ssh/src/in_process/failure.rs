use tablepro_core::{SshAlgorithmKind, SshFailure, TimeoutPhase, TransportError};

use super::handler::SessionEnd;

const TOO_MANY_FAILURES: &str = "Too many authentication failures";

// A russh error from a hop's handshake or login, read with what the session's end recorded.
pub(crate) fn from_russh(error: russh::Error, host: &str, end: &SessionEnd) -> TransportError {
    let detail = end.detail();
    if detail
        .as_deref()
        .is_some_and(|detail| detail.contains(TOO_MANY_FAILURES))
    {
        return SshFailure::TooManyAuthenticationFailures { host: host.to_owned() }.into();
    }
    match error {
        russh::Error::NoCommonAlgo { kind, theirs, .. } => SshFailure::NoCommonAlgorithm {
            host: host.to_owned(),
            kind: algorithm_kind(&kind),
            server_offer: theirs
                .into_iter()
                // Markers a server appends to its key exchange list, not methods it offers.
                .filter(|name| !name.starts_with("ext-info-") && !name.starts_with("kex-strict-"))
                .collect(),
        }
        .into(),
        russh::Error::ConnectionTimeout | russh::Error::Elapsed(_) => TransportError::Timeout {
            phase: TimeoutPhase::SshHandshake,
        },
        russh::Error::Disconnect
        | russh::Error::HUP
        | russh::Error::IO(_)
        | russh::Error::SendError
        | russh::Error::RecvError
        | russh::Error::KeepaliveTimeout
        | russh::Error::InactivityTimeout => SshFailure::MasterExited {
            status: None,
            detail: detail.unwrap_or_else(|| error.to_string()),
        }
        .into(),
        other => SshFailure::Protocol {
            status: None,
            detail: other.to_string(),
        }
        .into(),
    }
}

pub(crate) fn ended(end: &SessionEnd) -> TransportError {
    SshFailure::MasterExited {
        status: None,
        detail: end.detail().unwrap_or_default(),
    }
    .into()
}

pub(crate) fn channel_failure(reason: &russh::ChannelOpenFailure) -> String {
    let text = match reason {
        russh::ChannelOpenFailure::AdministrativelyProhibited => "administratively prohibited",
        russh::ChannelOpenFailure::ConnectFailed => "connect failed",
        russh::ChannelOpenFailure::UnknownChannelType => "unknown channel type",
        russh::ChannelOpenFailure::ResourceShortage => "resource shortage",
        russh::ChannelOpenFailure::Other { reason, .. } => return format!("open failed: {reason}"),
    };
    format!("open failed: {text}")
}

fn algorithm_kind(kind: &russh::AlgorithmKind) -> SshAlgorithmKind {
    match kind {
        russh::AlgorithmKind::Kex => SshAlgorithmKind::KeyExchange,
        russh::AlgorithmKind::Key => SshAlgorithmKind::HostKey,
        russh::AlgorithmKind::Cipher => SshAlgorithmKind::Cipher,
        russh::AlgorithmKind::Mac => SshAlgorithmKind::Mac,
        russh::AlgorithmKind::Compression => SshAlgorithmKind::Compression,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_negotiation_names_the_kind_and_what_the_server_offers() {
        let error = russh::Error::NoCommonAlgo {
            kind: russh::AlgorithmKind::Kex,
            ours: vec!["mlkem768x25519-sha256".to_owned()],
            theirs: vec![
                "diffie-hellman-group1-sha1".to_owned(),
                "kex-strict-s-v00@openssh.com".to_owned(),
            ],
        };

        assert_eq!(
            from_russh(error, "bastion", &SessionEnd::default()),
            TransportError::Ssh(SshFailure::NoCommonAlgorithm {
                host: "bastion".to_owned(),
                kind: SshAlgorithmKind::KeyExchange,
                server_offer: vec!["diffie-hellman-group1-sha1".to_owned()],
            })
        );
    }

    #[test]
    fn the_servers_disconnect_message_explains_a_lost_session() {
        let end = SessionEnd::default();
        end.record(TOO_MANY_FAILURES.to_owned());
        let refused = from_russh(russh::Error::Disconnect, "bastion", &end);

        let end = SessionEnd::default();
        end.record("Keepalive timeout".to_owned());
        let lost = from_russh(russh::Error::SendError, "bastion", &end);

        assert_eq!(
            refused,
            TransportError::Ssh(SshFailure::TooManyAuthenticationFailures {
                host: "bastion".to_owned()
            })
        );
        assert_eq!(
            lost,
            TransportError::Ssh(SshFailure::MasterExited {
                status: None,
                detail: "Keepalive timeout".to_owned(),
            })
        );
        assert_eq!(
            ended(&end),
            TransportError::Ssh(SshFailure::MasterExited {
                status: None,
                detail: "Keepalive timeout".to_owned(),
            })
        );
    }

    #[test]
    fn a_refused_channel_reads_as_ssh_prints_it() {
        assert_eq!(
            channel_failure(&russh::ChannelOpenFailure::ConnectFailed),
            "open failed: connect failed"
        );
    }
}

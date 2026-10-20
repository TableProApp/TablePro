use std::path::PathBuf;

use tablepro_core::{NetworkEndpoint, SshAlgorithmKind, SshFailure, TimeoutPhase, TransportError};

const PROTOCOL_DETAIL_LIMIT: usize = 4096;
const NEGOTIATION_FAILURES: [(&str, SshAlgorithmKind); 5] = [
    ("no matching key exchange method found", SshAlgorithmKind::KeyExchange),
    ("no matching host key type found", SshAlgorithmKind::HostKey),
    ("no matching cipher found", SshAlgorithmKind::Cipher),
    ("no matching MAC found", SshAlgorithmKind::Mac),
    ("no matching compression method found", SshAlgorithmKind::Compression),
];
// ssh names a peer it reached through a ProxyCommand or ProxyJump pipe this way.
const UNKNOWN_PEER: &str = "UNKNOWN";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DeclinedHostKey {
    /// The host ssh asked about, which behind a jump host is not always
    /// the destination.
    pub host: String,
    pub algorithm: String,
    pub fingerprint: String,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct ClassifyContext<'a> {
    pub host: &'a str,
    pub forward_target: Option<&'a str>,
    pub declined_host_key: Option<&'a DeclinedHostKey>,
    /// The known_hosts names of the hosts whose configuration sets
    /// StrictHostKeyChecking yes. ssh prints the same changed-key error
    /// for yes, ask and accept-new, so only `ssh -G` tells them apart.
    pub strict_hosts: &'a [String],
}

pub(crate) fn classify(status: Option<i32>, stderr: &str, context: &ClassifyContext<'_>) -> TransportError {
    let failure = host_key_failure(stderr, context)
        .or_else(|| negotiation_failure(stderr, context))
        .or_else(|| authentication_failure(stderr, context))
        .or_else(|| forwarding_failure(stderr, context))
        .or_else(|| configuration_failure(stderr));
    if let Some(failure) = failure {
        return TransportError::Ssh(failure);
    }
    if let Some(error) = network_error(stderr) {
        return error;
    }
    TransportError::Ssh(SshFailure::Protocol {
        detail: protocol_detail(status, stderr),
    })
}

fn host_key_failure(stderr: &str, context: &ClassifyContext<'_>) -> Option<SshFailure> {
    if let Some(line) = line_containing(stderr, " revoked by file ") {
        return Some(SshFailure::HostKeyRevoked {
            host: context.host.to_owned(),
            detail: line.to_owned(),
        });
    }
    if stderr.contains("REVOKED HOST KEY DETECTED") {
        let host = between(stderr, " host key for ", " is marked as revoked.").unwrap_or(context.host);
        let detail = line_containing(stderr, "is marked as revoked.").unwrap_or("the host key is revoked");
        return Some(SshFailure::HostKeyRevoked {
            host: host.to_owned(),
            detail: detail.to_owned(),
        });
    }
    if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
        return Some(changed_host_key(stderr, context));
    }
    if let Some(line) = line_containing(stderr, "host key is known for") {
        let algorithm = between(line, "No ", " host key is known for").unwrap_or_default();
        let host = between(line, " host key is known for ", " and you have").unwrap_or(context.host);
        return Some(unknown_host_key(host, algorithm, "", false, false));
    }
    if stderr.contains("Exiting, you have requested strict checking.") {
        return Some(unknown_host_key(context.host, "", "", false, false));
    }
    if stderr.contains("Host key verification failed.") {
        let (host, algorithm, fingerprint) = context.declined_host_key.map_or((context.host, "", ""), |key| {
            (key.host.as_str(), key.algorithm.as_str(), key.fingerprint.as_str())
        });
        return Some(unknown_host_key(host, algorithm, fingerprint, true, true));
    }
    None
}

fn changed_host_key(stderr: &str, context: &ClassifyContext<'_>) -> SshFailure {
    let mut lines = stderr.lines();
    let mut algorithm = "";
    let mut fingerprint = "";
    while let Some(line) = lines.next() {
        if let Some(found) = between(line, "The fingerprint for the ", " key sent by the remote host is") {
            algorithm = found;
            fingerprint = lines.next().map_or("", |next| next.trim().trim_end_matches('.'));
            break;
        }
    }
    let (known_hosts, line) = line_containing(stderr, "Offending ")
        .and_then(|offending| offending.split_once(" key in "))
        .and_then(|(_, location)| location.rsplit_once(':'))
        .map_or((PathBuf::new(), 0), |(path, line)| {
            (PathBuf::from(path), line.trim().parse().unwrap_or(0))
        });
    let host = between(stderr, "Host key for ", " has changed").unwrap_or(context.host);
    let strict = context
        .strict_hosts
        .iter()
        .any(|strict| strict.eq_ignore_ascii_case(host));
    SshFailure::HostKeyChanged {
        host: host.to_owned(),
        algorithm: algorithm.to_owned(),
        sha256_fingerprint: fingerprint.to_owned(),
        known_hosts,
        line,
        trust_allowed: !strict,
    }
}

fn unknown_host_key(host: &str, algorithm: &str, fingerprint: &str, trust_allowed: bool, declined: bool) -> SshFailure {
    SshFailure::HostKeyUnknown {
        host: host.to_owned(),
        algorithm: algorithm.to_owned(),
        sha256_fingerprint: fingerprint.to_owned(),
        trust_allowed,
        declined,
    }
}

fn negotiation_failure(stderr: &str, context: &ClassifyContext<'_>) -> Option<SshFailure> {
    let line = line_containing(stderr, "Unable to negotiate with ")?;
    let kind = NEGOTIATION_FAILURES
        .iter()
        .find(|(text, _)| line.contains(text))
        .map(|&(_, kind)| kind)?;
    let peer = between(line, "Unable to negotiate with ", ": no matching ").unwrap_or_default();
    let server_offer = line
        .split_once("Their offer: ")
        .map(|(_, offer)| {
            offer
                .split(',')
                .map(str::trim)
                // Markers a server appends to its key exchange list, not methods it offers.
                .filter(|name| !name.is_empty() && !name.starts_with("ext-info-") && !name.starts_with("kex-strict-"))
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    Some(SshFailure::NoCommonAlgorithm {
        host: peer_host(peer, context),
        kind,
        server_offer,
    })
}

fn authentication_failure(stderr: &str, context: &ClassifyContext<'_>) -> Option<SshFailure> {
    if let Some(line) = line_containing(stderr, "Too many authentication failures") {
        let peer = between(line, "Received disconnect from ", " port ").unwrap_or_default();
        return Some(SshFailure::TooManyAuthenticationFailures {
            host: peer_host(peer, context),
        });
    }
    let line = line_containing(stderr, ": Permission denied (")?;
    let (user_host, methods) = line.split_once(": Permission denied (")?;
    let (user, host) = user_host.rsplit_once('@')?;
    let methods = methods.trim_end_matches(").").split(',').map(str::to_owned).collect();
    Some(SshFailure::AuthenticationRejected {
        user: user.trim().to_owned(),
        host: host.to_owned(),
        methods,
    })
}

fn forwarding_failure(stderr: &str, context: &ClassifyContext<'_>) -> Option<SshFailure> {
    let target = context.forward_target.unwrap_or_default().to_owned();
    if let Some(line) = line_containing(stderr, "master forward request failed") {
        return Some(SshFailure::ForwardRejected {
            target,
            detail: line.to_owned(),
        });
    }
    let line = stderr
        .lines()
        .find(|line| line.contains("channel ") && line.contains(": open failed"))?;
    Some(SshFailure::ChannelOpenFailed {
        target,
        detail: line.to_owned(),
    })
}

fn configuration_failure(stderr: &str) -> Option<SshFailure> {
    if let Some(path) = between(stderr, "ControlPath too long ('", "' >= ") {
        return Some(SshFailure::ControlPathTooLong {
            path: PathBuf::from(path),
        });
    }
    let line = line_containing(stderr, "Bad configuration option")
        .or_else(|| line_containing(stderr, "Bad owner or permissions"))?;
    Some(SshFailure::ConfigRejected {
        detail: line.to_owned(),
    })
}

fn network_error(stderr: &str) -> Option<TransportError> {
    if let Some(line) = line_containing(stderr, "Could not resolve hostname ") {
        let rest = line.split_once("Could not resolve hostname ")?.1;
        let (host, detail) = rest.split_once(": ").unwrap_or((rest, ""));
        return Some(TransportError::NameResolution {
            host: host.to_owned(),
            detail: detail.to_owned(),
        });
    }
    let line = line_containing(stderr, "connect to host ")?;
    let rest = line.split_once("connect to host ")?.1;
    let (host, rest) = rest.split_once(" port ")?;
    let (port, detail) = rest.split_once(": ")?;
    if detail.contains("timed out") {
        return Some(TransportError::Timeout {
            phase: TimeoutPhase::SshHandshake,
        });
    }
    let endpoint = NetworkEndpoint::new(host, port.parse().ok()?).ok()?;
    if detail.contains("Connection refused") {
        return Some(TransportError::Refused { endpoint });
    }
    Some(TransportError::Unreachable {
        endpoint,
        detail: detail.to_owned(),
    })
}

fn protocol_detail(status: Option<i32>, stderr: &str) -> String {
    let trimmed = stderr.trim();
    let mut start = trimmed.len().saturating_sub(PROTOCOL_DETAIL_LIMIT);
    while !trimmed.is_char_boundary(start) {
        start += 1;
    }
    let tail = &trimmed[start..];
    match status {
        Some(code) => format!("ssh exited with status {code}: {tail}"),
        None => format!("ssh ended without a status: {tail}"),
    }
}

fn peer_host(peer: &str, context: &ClassifyContext<'_>) -> String {
    let host = peer.rsplit_once(" port ").map_or(peer, |(host, _)| host).trim();
    if host.is_empty() || host == UNKNOWN_PEER {
        return context.host.to_owned();
    }
    host.to_owned()
}

fn line_containing<'a>(text: &'a str, needle: &str) -> Option<&'a str> {
    text.lines().find(|line| line.contains(needle)).map(str::trim)
}

fn between<'a>(text: &'a str, start: &str, end: &str) -> Option<&'a str> {
    let after = text.split_once(start)?.1;
    after.split_once(end).map(|(inner, _)| inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONTEXT: ClassifyContext<'static> = ClassifyContext {
        host: "bastion",
        forward_target: Some("db:5432"),
        declined_host_key: None,
        strict_hosts: &[],
    };

    fn fixture(stderr: &str) -> TransportError {
        classify(Some(255), stderr, &CONTEXT)
    }

    #[test]
    fn stderr_classification_fixture_name_resolution() {
        assert!(matches!(
            fixture(include_str!("../tests/fixtures/stderr/name_resolution.txt")),
            TransportError::NameResolution { host, .. } if host == "nonexistent-host.invalid"
        ));
    }

    #[test]
    fn stderr_classification_fixture_refused() {
        assert!(matches!(
            fixture(include_str!("../tests/fixtures/stderr/refused.txt")),
            TransportError::Refused { endpoint } if endpoint.port() == 1
        ));
    }

    #[test]
    fn stderr_classification_fixture_timeout() {
        assert_eq!(
            fixture(include_str!("../tests/fixtures/stderr/timeout.txt")),
            TransportError::Timeout {
                phase: TimeoutPhase::SshHandshake
            }
        );
    }

    #[test]
    fn stderr_classification_fixture_config_rejected_option() {
        assert!(matches!(
            fixture(include_str!("../tests/fixtures/stderr/config_rejected_option.txt")),
            TransportError::Ssh(SshFailure::ConfigRejected { .. })
        ));
    }

    #[test]
    fn bad_config_permissions_are_config_rejected() {
        assert_eq!(
            fixture("Bad owner or permissions on /home/deploy/.ssh/config\n"),
            TransportError::Ssh(SshFailure::ConfigRejected {
                detail: "Bad owner or permissions on /home/deploy/.ssh/config".to_owned()
            })
        );
    }

    #[test]
    fn stderr_classification_fixture_control_path_too_long() {
        assert!(matches!(
            fixture(include_str!("../tests/fixtures/stderr/control_path_too_long.txt")),
            TransportError::Ssh(SshFailure::ControlPathTooLong { .. })
        ));
    }

    /// Under StrictHostKeyChecking yes ssh names the key type and host
    /// but refuses before it prints a fingerprint.
    #[test]
    fn stderr_classification_fixture_host_key_unknown_strict() {
        assert!(matches!(
            fixture(include_str!("../tests/fixtures/stderr/host_key_unknown_strict.txt")),
            TransportError::Ssh(SshFailure::HostKeyUnknown {
                host,
                algorithm,
                sha256_fingerprint,
                trust_allowed: false,
                declined: false,
            }) if host == "[127.0.0.1]:32768" && algorithm == "ED25519" && sha256_fingerprint.is_empty()
        ));
    }

    #[test]
    fn stderr_classification_fixture_auth_rejected() {
        assert!(matches!(
            fixture(include_str!("../tests/fixtures/stderr/auth_rejected.txt")),
            TransportError::Ssh(SshFailure::AuthenticationRejected { user, host, methods })
                if user == "deploy" && host == "127.0.0.1" && methods == ["publickey", "password", "keyboard-interactive"]
        ));
    }

    #[test]
    fn stderr_classification_fixture_host_key_changed() {
        assert!(matches!(
            fixture(include_str!("../tests/fixtures/stderr/host_key_changed.txt")),
            TransportError::Ssh(SshFailure::HostKeyChanged {
                host,
                algorithm,
                sha256_fingerprint,
                known_hosts,
                line: 1,
                trust_allowed: true,
            }) if host == "[127.0.0.1]:32768"
                && algorithm == "ED25519"
                && sha256_fingerprint == "SHA256:hqQS4EIntVyXA99oGaFNB9YErcr85eUmEi96ZPSAEDg"
                && known_hosts.ends_with("known_hosts")
        ));
    }

    /// ssh prints the same lines under StrictHostKeyChecking yes as under
    /// ask, so the changed host's own configuration decides.
    #[test]
    fn a_changed_key_of_a_strict_host_cannot_be_trusted() {
        let stderr = include_str!("../tests/fixtures/stderr/host_key_changed.txt");
        let trust_allowed = |strict_hosts: &[String]| {
            let context = ClassifyContext {
                strict_hosts,
                ..CONTEXT
            };
            match classify(Some(255), stderr, &context) {
                TransportError::Ssh(SshFailure::HostKeyChanged { trust_allowed, .. }) => trust_allowed,
                other => panic!("{other:?}"),
            }
        };

        assert!(!trust_allowed(&["[127.0.0.1]:32768".to_owned()]));
        assert!(!trust_allowed(&["jump".to_owned(), "[127.0.0.1]:32768".to_owned()]));
        assert!(trust_allowed(&["127.0.0.1".to_owned(), "[127.0.0.1]:22".to_owned()]));
        assert!(trust_allowed(&[]));
    }

    #[test]
    fn stderr_classification_fixture_host_key_revoked() {
        assert!(matches!(
            fixture(include_str!("../tests/fixtures/stderr/host_key_revoked.txt")),
            TransportError::Ssh(SshFailure::HostKeyRevoked { detail, .. }) if detail.contains("revoked by file")
        ));
    }

    #[test]
    fn crlf_line_endings_classify_the_same() {
        for stderr in [
            include_str!("../tests/fixtures/stderr/auth_rejected.txt"),
            include_str!("../tests/fixtures/stderr/host_key_changed.txt"),
        ] {
            assert_eq!(fixture(&stderr.replace('\n', "\r\n")), fixture(stderr));
        }
    }

    #[test]
    fn stderr_classification_fixture_no_matching_key_exchange() {
        assert!(matches!(
            fixture(include_str!("../tests/fixtures/stderr/no_matching_key_exchange.txt")),
            TransportError::Ssh(SshFailure::NoCommonAlgorithm { host, kind: SshAlgorithmKind::KeyExchange, server_offer })
                if host == "172.17.0.1" && server_offer == ["mlkem768x25519-sha256", "sntrup761x25519-sha512"]
        ));
    }

    #[test]
    fn stderr_classification_fixture_too_many_authentication_failures() {
        assert_eq!(
            fixture(include_str!(
                "../tests/fixtures/stderr/too_many_authentication_failures.txt"
            )),
            TransportError::Ssh(SshFailure::TooManyAuthenticationFailures {
                host: "172.17.0.1".to_owned()
            })
        );
    }

    #[test]
    fn each_negotiation_failure_names_its_kind_and_the_servers_offer() {
        let cases = [
            ("key exchange method", SshAlgorithmKind::KeyExchange),
            ("host key type", SshAlgorithmKind::HostKey),
            ("cipher", SshAlgorithmKind::Cipher),
            ("MAC", SshAlgorithmKind::Mac),
            ("compression method", SshAlgorithmKind::Compression),
        ];
        for (text, kind) in cases {
            let stderr =
                format!("Unable to negotiate with 203.0.113.5 port 22: no matching {text} found. Their offer: a,b\n");

            assert_eq!(
                fixture(&stderr),
                TransportError::Ssh(SshFailure::NoCommonAlgorithm {
                    host: "203.0.113.5".to_owned(),
                    kind,
                    server_offer: vec!["a".to_owned(), "b".to_owned()],
                }),
                "{text}"
            );
        }
    }

    #[test]
    fn a_legacy_servers_host_key_offer_is_named() {
        assert_eq!(
            fixture(
                "Unable to negotiate with 2001:db8::5 port 2222: no matching host key type found. Their offer: ssh-rsa,ssh-dss\n"
            ),
            TransportError::Ssh(SshFailure::NoCommonAlgorithm {
                host: "2001:db8::5".to_owned(),
                kind: SshAlgorithmKind::HostKey,
                server_offer: vec!["ssh-rsa".to_owned(), "ssh-dss".to_owned()],
            })
        );
    }

    #[test]
    fn a_peer_behind_a_proxy_is_named_by_the_destination() {
        let negotiation = fixture(
            "Unable to negotiate with UNKNOWN port 65535: no matching key exchange method found. \
             Their offer: mlkem768x25519-sha256,ext-info-s,kex-strict-s-v00@openssh.com\n",
        );
        let too_many = fixture("Received disconnect from UNKNOWN port 65535:2: Too many authentication failures\n");

        assert_eq!(
            negotiation,
            TransportError::Ssh(SshFailure::NoCommonAlgorithm {
                host: "bastion".to_owned(),
                kind: SshAlgorithmKind::KeyExchange,
                server_offer: vec!["mlkem768x25519-sha256".to_owned()],
            })
        );
        assert_eq!(
            too_many,
            TransportError::Ssh(SshFailure::TooManyAuthenticationFailures {
                host: "bastion".to_owned()
            })
        );
    }

    #[test]
    fn too_many_failures_from_an_ipv6_peer_keeps_the_address() {
        assert_eq!(
            fixture(
                "Received disconnect from ::1 port 22:2: Too many authentication failures\nDisconnected from ::1 port 22\n"
            ),
            TransportError::Ssh(SshFailure::TooManyAuthenticationFailures { host: "::1".to_owned() })
        );
    }

    #[test]
    fn unknown_output_becomes_protocol_with_status() {
        let error = fixture("kex_exchange_identification: Connection closed by remote host\n");
        assert_eq!(
            error,
            TransportError::Ssh(SshFailure::Protocol {
                detail: "ssh exited with status 255: kex_exchange_identification: Connection closed by remote host"
                    .to_owned()
            })
        );
    }

    #[test]
    fn declined_prompt_reports_the_declined_key() {
        let declined = DeclinedHostKey {
            host: "[jump.example.com]:2200".to_owned(),
            algorithm: "ED25519".to_owned(),
            fingerprint: "SHA256:abc".to_owned(),
        };
        let context = ClassifyContext {
            declined_host_key: Some(&declined),
            ..CONTEXT
        };
        assert_eq!(
            classify(Some(255), "Host key verification failed.\n", &context),
            TransportError::Ssh(SshFailure::HostKeyUnknown {
                host: "[jump.example.com]:2200".to_owned(),
                algorithm: "ED25519".to_owned(),
                sha256_fingerprint: "SHA256:abc".to_owned(),
                trust_allowed: true,
                declined: true,
            })
        );
    }
}

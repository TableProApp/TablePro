use std::path::PathBuf;

use tablepro_core::{NetworkEndpoint, SshFailure, TimeoutPhase, TransportError};

const PROTOCOL_DETAIL_LIMIT: usize = 4096;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DeclinedHostKey {
    pub algorithm: String,
    pub fingerprint: String,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct ClassifyContext<'a> {
    pub host: &'a str,
    pub forward_target: Option<&'a str>,
    pub declined_host_key: Option<&'a DeclinedHostKey>,
}

pub(crate) fn classify(status: Option<i32>, stderr: &str, context: &ClassifyContext<'_>) -> TransportError {
    let failure = host_key_failure(stderr, context)
        .or_else(|| authentication_failure(stderr))
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
        let (algorithm, fingerprint) = context
            .declined_host_key
            .map_or(("", ""), |key| (key.algorithm.as_str(), key.fingerprint.as_str()));
        return Some(unknown_host_key(context.host, algorithm, fingerprint, true, true));
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
    SshFailure::HostKeyChanged {
        host: host.to_owned(),
        algorithm: algorithm.to_owned(),
        sha256_fingerprint: fingerprint.to_owned(),
        known_hosts,
        line,
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

fn authentication_failure(stderr: &str) -> Option<SshFailure> {
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

    #[test]
    fn stderr_classification_fixture_host_key_unknown_strict() {
        assert!(matches!(
            fixture(include_str!("../tests/fixtures/stderr/host_key_unknown_strict.txt")),
            TransportError::Ssh(SshFailure::HostKeyUnknown {
                algorithm,
                trust_allowed: false,
                declined: false,
                ..
            }) if algorithm == "ED25519"
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
            }) if host == "[127.0.0.1]:32768"
                && algorithm == "ED25519"
                && sha256_fingerprint == "SHA256:hqQS4EIntVyXA99oGaFNB9YErcr85eUmEi96ZPSAEDg"
                && known_hosts.ends_with("known_hosts")
        ));
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
                host: "bastion".to_owned(),
                algorithm: "ED25519".to_owned(),
                sha256_fingerprint: "SHA256:abc".to_owned(),
                trust_allowed: true,
                declined: true,
            })
        );
    }
}

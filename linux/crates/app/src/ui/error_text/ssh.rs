use tablepro_core::{SshAlgorithmKind, SshDestinationPart, SshDestinationProblem, SshFailure};

/// One sentence per way OpenSSH can fail, each naming what to change.
pub fn ssh_failure_message(failure: &SshFailure) -> String {
    match failure {
        SshFailure::OpenSshClientMissing { program } => crate::i18n::gettext_f(
            "The OpenSSH client {program} is not installed. Install openssh-client to connect over SSH.",
            &[("program", &program.display().to_string())],
        ),
        SshFailure::AskpassHelperMissing { program } => crate::i18n::gettext_f(
            "TablePro's SSH helper is missing at {program}. Reinstall TablePro to connect over SSH.",
            &[("program", &program.display().to_string())],
        ),
        SshFailure::InvalidDestination { problem } => crate::i18n::gettext_f(
            "The SSH host or jump host is not valid: {detail}",
            &[("detail", &ssh_destination_problem_text(problem))],
        ),
        SshFailure::ConfigRejected { detail } => crate::i18n::gettext_f(
            "ssh refused the configuration. Check ~/.ssh/config for this host: {detail}",
            &[("detail", detail)],
        ),
        SshFailure::ControlPathTooLong { .. } => crate::i18n::gettext(
            "The runtime directory path is too long for an SSH control socket. Use a shorter XDG_RUNTIME_DIR.",
        ),
        SshFailure::RuntimeDirUnsafe { path, detail } => crate::i18n::gettext_f(
            "The SSH runtime directory {path} cannot be used safely: {detail}",
            &[("path", &path.display().to_string()), ("detail", detail)],
        ),
        SshFailure::HostKeyUnknown { host, declined, .. } if *declined => crate::i18n::gettext_f(
            "The host key of {host} was not trusted, so the connection was not made.",
            &[("host", host)],
        ),
        // ssh refuses under StrictHostKeyChecking yes before it shows the
        // key, so there is no fingerprint and nothing to review.
        SshFailure::HostKeyUnknown {
            host,
            trust_allowed: false,
            ..
        } => crate::i18n::gettext_f(
            "The SSH configuration for {host} accepts only keys already in known_hosts. Add the server's key to known_hosts outside TablePro, then retry.",
            &[("host", host)],
        ),
        SshFailure::HostKeyUnknown {
            host,
            sha256_fingerprint,
            ..
        } if sha256_fingerprint.is_empty() => crate::i18n::gettext_f(
            "{host} is not in known_hosts. Connect once to review and trust its key.",
            &[("host", host)],
        ),
        SshFailure::HostKeyUnknown {
            host,
            sha256_fingerprint,
            ..
        } => crate::i18n::gettext_f(
            "{host} is not in known_hosts (key {fingerprint}). Connect once to review and trust its key.",
            &[("host", host), ("fingerprint", sha256_fingerprint)],
        ),
        SshFailure::HostKeyChanged {
            host,
            known_hosts,
            line,
            ..
        } => crate::i18n::gettext_f(
            "The host key of {host} changed since it was trusted ({file}, line {line}). This can mean someone is intercepting the connection; check with the server's administrator before removing the old key.",
            &[
                ("host", host),
                ("file", &known_hosts.display().to_string()),
                ("line", &line.to_string()),
            ],
        ),
        SshFailure::HostKeyRevoked { host, .. } => crate::i18n::gettext_f(
            "The host key of {host} is revoked, so the connection was refused.",
            &[("host", host)],
        ),
        SshFailure::AuthenticationRejected { user, host, .. } => crate::i18n::gettext_f(
            "The SSH server {host} refused the login for {user}. Check the key, the agent or the password.",
            &[("host", host), ("user", user)],
        ),
        SshFailure::TooManyAuthenticationFailures { host } => too_many_failures_message(host),
        SshFailure::NoCommonAlgorithm {
            host,
            kind,
            server_offer,
        } => no_common_algorithm_message(host, *kind, &server_offer.join(", ")),
        SshFailure::InteractionCancelled => crate::i18n::gettext("The SSH login was cancelled."),
        SshFailure::ForwardRejected { target, detail } => crate::i18n::gettext_f(
            "The SSH server would not forward to {target}: {detail}",
            &[("target", target), ("detail", detail)],
        ),
        SshFailure::ChannelOpenFailed { target, detail } => crate::i18n::gettext_f(
            "The SSH server could not reach {target}: {detail}",
            &[("target", target), ("detail", detail)],
        ),
        SshFailure::MasterExited { detail, .. } => {
            crate::i18n::gettext_f("The SSH connection ended: {detail}", &[("detail", detail)])
        }
        SshFailure::Protocol { detail } => {
            crate::i18n::gettext_f("ssh printed something unexpected: {detail}", &[("detail", detail)])
        }
        other => {
            tracing::warn!(%other, "shown as an SSH failure with no sentence of its own");
            crate::i18n::gettext("The SSH connection failed.")
        }
    }
}

fn too_many_failures_message(host: &str) -> String {
    crate::i18n::gettext_f(
        "The SSH server {host} ended the login after too many failed attempts, which usually means the SSH agent offered too many keys. Choose Private key with this server's key file, or set IdentityFile and IdentitiesOnly yes for the host in ~/.ssh/config.",
        &[("host", host)],
    )
}

fn no_common_algorithm_message(host: &str, kind: SshAlgorithmKind, offer: &str) -> String {
    let arguments: &[(&str, &str)] = &[("host", host), ("offer", offer)];
    match kind {
        SshAlgorithmKind::KeyExchange => crate::i18n::gettext_f(
            "The SSH server {host} and this computer's OpenSSH have no key exchange method in common. The server offers {offer}. Update OpenSSH or check KexAlgorithms in ~/.ssh/config, or ask the server's administrator to allow another method.",
            arguments,
        ),
        SshAlgorithmKind::HostKey => crate::i18n::gettext_f(
            "The SSH server {host} and this computer's OpenSSH have no host key type in common. The server offers {offer}. Check HostKeyAlgorithms in ~/.ssh/config, or ask the server's administrator to add another host key.",
            arguments,
        ),
        SshAlgorithmKind::Cipher => crate::i18n::gettext_f(
            "The SSH server {host} and this computer's OpenSSH have no cipher in common. The server offers {offer}. Check Ciphers in ~/.ssh/config, or ask the server's administrator to allow another cipher.",
            arguments,
        ),
        SshAlgorithmKind::Mac => crate::i18n::gettext_f(
            "The SSH server {host} and this computer's OpenSSH have no MAC in common. The server offers {offer}. Check MACs in ~/.ssh/config, or ask the server's administrator to allow another MAC.",
            arguments,
        ),
        SshAlgorithmKind::Compression => crate::i18n::gettext_f(
            "The SSH server {host} and this computer's OpenSSH have no compression method in common. The server offers {offer}. Check Compression in ~/.ssh/config for this host.",
            arguments,
        ),
    }
}

/// What is wrong with a host, username or jump host as typed, as the
/// part after "is not valid:" or "cannot be used:".
pub fn ssh_destination_problem_text(problem: &SshDestinationProblem) -> String {
    use SshDestinationPart::{Host, User};

    match problem {
        SshDestinationProblem::Empty { part: Host } => crate::i18n::gettext("the host name is empty"),
        SshDestinationProblem::Empty { part: User } => crate::i18n::gettext("the username is empty"),
        SshDestinationProblem::LeadingDash { part: Host } => crate::i18n::gettext("the host name starts with “-”"),
        SshDestinationProblem::LeadingDash { part: User } => crate::i18n::gettext("the username starts with “-”"),
        SshDestinationProblem::Whitespace { part: Host } => {
            crate::i18n::gettext("the host name contains a space or a control character")
        }
        SshDestinationProblem::Whitespace { part: User } => {
            crate::i18n::gettext("the username contains a space or a control character")
        }
        SshDestinationProblem::Character { part: Host, character } => crate::i18n::gettext_f(
            "the host name contains “{character}”",
            &[("character", &character.to_string())],
        ),
        SshDestinationProblem::Character { part: User, character } => crate::i18n::gettext_f(
            "the username contains “{character}”",
            &[("character", &character.to_string())],
        ),
        SshDestinationProblem::PortZero => crate::i18n::gettext("the port cannot be 0"),
        SshDestinationProblem::NotAPort { text } => {
            crate::i18n::gettext_f("“{text}” is not a port number", &[("text", text)])
        }
        SshDestinationProblem::UnclosedBracket => crate::i18n::gettext("an IPv6 address is missing its closing “]”"),
    }
}

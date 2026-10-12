use tablepro_core::SshFailure;

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
        SshFailure::InvalidDestination { detail } => crate::i18n::gettext_f(
            "The SSH host or jump host is not valid: {detail}",
            &[("detail", detail)],
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
        other => crate::i18n::gettext_f("SSH failed: {detail}", &[("detail", &other.to_string())]),
    }
}

use std::io::ErrorKind;

use tablepro_core::{SshDestinationPart, SshDestinationProblem, SshFailure, SshRuntimeDirProblem};

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
        SshFailure::LaunchFailed { program, kind } => launch_message(program, *kind),
        SshFailure::InvalidDestination { problem } => crate::i18n::gettext_f(
            "The SSH host or jump host is not valid: {detail}",
            &[("detail", &ssh_destination_problem_text(problem))],
        ),
        SshFailure::ConfigRejected { detail } => crate::i18n::gettext_f(
            "ssh refused the configuration. Check ~/.ssh/config for this host: {detail}",
            &[("detail", detail)],
        ),
        SshFailure::ConfigUnreadable { path, .. } => crate::i18n::gettext_f(
            "The SSH configuration file {path} could not be read.",
            &[("path", &path.display().to_string())],
        ),
        SshFailure::ControlPathTooLong { .. } => crate::i18n::gettext(
            "The runtime directory path is too long for an SSH control socket. Use a shorter XDG_RUNTIME_DIR.",
        ),
        SshFailure::RuntimeDirUnsafe { path, problem } => crate::i18n::gettext_f(
            "The SSH runtime directory {path} cannot be used safely: {detail}",
            &[
                ("path", &path.display().to_string()),
                ("detail", &runtime_dir_problem_text(*problem)),
            ],
        ),
        SshFailure::HostKeyUnknown {
            host,
            sha256_fingerprint,
            trust_allowed,
            declined,
            ..
        } => unknown_host_key_message(host, sha256_fingerprint, *trust_allowed, *declined),
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
        SshFailure::ChannelOpenFailed { target, detail } if detail.is_empty() => {
            crate::i18n::gettext_f("The SSH server could not reach {target}.", &[("target", target)])
        }
        SshFailure::ChannelOpenFailed { target, detail } => crate::i18n::gettext_f(
            "The SSH server could not reach {target}: {detail}",
            &[("target", target), ("detail", detail)],
        ),
        SshFailure::MasterExited { detail, .. } if detail.is_empty() => {
            crate::i18n::gettext("The SSH connection ended.")
        }
        SshFailure::MasterExited { detail, .. } => {
            crate::i18n::gettext_f("The SSH connection ended: {detail}", &[("detail", detail)])
        }
        SshFailure::Protocol { status, detail } => protocol_message(*status, detail),
        SshFailure::Internal => crate::i18n::gettext("TablePro hit an internal error."),
        other => {
            tracing::warn!(%other, "shown as an SSH failure with no sentence of its own");
            crate::i18n::gettext("The SSH connection failed.")
        }
    }
}

fn launch_message(program: &std::path::Path, kind: ErrorKind) -> String {
    let program = program.display().to_string();
    match kind {
        ErrorKind::PermissionDenied => crate::i18n::gettext_f(
            "TablePro is not allowed to run {program}. Check that it is executable.",
            &[("program", &program)],
        ),
        _ => crate::i18n::gettext_f("{program} could not be started.", &[("program", &program)]),
    }
}

fn unknown_host_key_message(host: &str, fingerprint: &str, trust_allowed: bool, declined: bool) -> String {
    if declined {
        return crate::i18n::gettext_f(
            "The host key of {host} was not trusted, so the connection was not made.",
            &[("host", host)],
        );
    }
    // ssh refuses under StrictHostKeyChecking yes before it shows the
    // key, so there is no fingerprint and nothing to review.
    if !trust_allowed {
        return crate::i18n::gettext_f(
            "The SSH configuration for {host} accepts only keys already in known_hosts. Add the server's key to known_hosts outside TablePro, then retry.",
            &[("host", host)],
        );
    }
    if fingerprint.is_empty() {
        return crate::i18n::gettext_f(
            "{host} is not in known_hosts. Connect once to review and trust its key.",
            &[("host", host)],
        );
    }
    crate::i18n::gettext_f(
        "{host} is not in known_hosts (key {fingerprint}). Connect once to review and trust its key.",
        &[("host", host), ("fingerprint", fingerprint)],
    )
}

fn protocol_message(status: Option<i32>, detail: &str) -> String {
    match (status, detail.is_empty()) {
        (Some(status), true) => crate::i18n::gettext_f(
            "ssh exited with status {status} and printed nothing.",
            &[("status", &status.to_string())],
        ),
        (Some(status), false) => crate::i18n::gettext_f(
            "ssh exited with status {status}: {detail}",
            &[("status", &status.to_string()), ("detail", detail)],
        ),
        (None, true) => crate::i18n::gettext("ssh did not answer as TablePro expected."),
        (None, false) => crate::i18n::gettext_f("ssh printed something unexpected: {detail}", &[("detail", detail)]),
    }
}

// The part after "cannot be used safely:".
fn runtime_dir_problem_text(problem: SshRuntimeDirProblem) -> String {
    match problem {
        SshRuntimeDirProblem::OtherOwner => crate::i18n::gettext("it belongs to another user"),
        SshRuntimeDirProblem::NotADirectory => crate::i18n::gettext("it is not a directory"),
        SshRuntimeDirProblem::OpenToOthers { mode } => crate::i18n::gettext_f(
            "other users can open it (mode {mode})",
            &[("mode", &format!("{mode:o}"))],
        ),
        SshRuntimeDirProblem::NoDirectoryName => crate::i18n::gettext("its path does not end in a directory name"),
        SshRuntimeDirProblem::NotAShellWord => {
            crate::i18n::gettext("its path has spaces or shell characters, which a jump host's ssh cannot be given")
        }
        SshRuntimeDirProblem::Io {
            kind: ErrorKind::PermissionDenied,
        } => crate::i18n::gettext("TablePro is not allowed to use it"),
        SshRuntimeDirProblem::Io {
            kind: ErrorKind::StorageFull | ErrorKind::QuotaExceeded,
        } => crate::i18n::gettext("the disk is full"),
        SshRuntimeDirProblem::Io {
            kind: ErrorKind::ReadOnlyFilesystem,
        } => crate::i18n::gettext("the disk is read-only"),
        SshRuntimeDirProblem::Io {
            kind: ErrorKind::NotFound | ErrorKind::NotADirectory,
        } => crate::i18n::gettext("a directory in its path is missing or is a file"),
        SshRuntimeDirProblem::Io { .. } => crate::i18n::gettext("the file system refused it"),
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

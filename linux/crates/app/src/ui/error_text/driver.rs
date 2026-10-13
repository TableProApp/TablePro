use tablepro_core::{
    ConfigError, DriverError, ErrorCategory, ReadOnlyRefusal, ServerCode, ServerDiagnostics, TimeoutPhase,
    TransportError,
};

use super::ssh::ssh_failure_message;
use super::tls::tls_message;

pub fn driver_message(error: &DriverError) -> String {
    // An SSH failure carries its own category and its own next step.
    if let DriverError::Transport(TransportError::Ssh(failure)) = error {
        return ssh_failure_message(failure);
    }
    match error.category() {
        ErrorCategory::Configuration => configuration_message(error),
        ErrorCategory::Network => network_message(error),
        ErrorCategory::Tls => match error {
            DriverError::Tls { failure, detail } => tls_message(*failure, detail),
            other => detail_sentence(crate::i18n::gettext("The secure connection failed."), other),
        },
        ErrorCategory::Authentication => authentication_message(error),
        ErrorCategory::ReadOnly => read_only_message(error),
        ErrorCategory::Server => match error {
            DriverError::Server(diagnostics) => server_message(diagnostics),
            other => detail_sentence(crate::i18n::gettext("The server refused the request."), other),
        },
        ErrorCategory::Interrupted => crate::i18n::gettext("Stopped."),
        ErrorCategory::Timeout => timeout_message(error),
        ErrorCategory::ConnectionLost => crate::i18n::gettext("The connection was closed. Try reconnecting."),
        ErrorCategory::WriteOutcome => write_outcome_message(error),
        ErrorCategory::File => file_message(error),
        ErrorCategory::Busy => match error {
            DriverError::EditorSessionBusy => {
                crate::i18n::gettext("This tab is still running a statement. Stop it or wait for it to finish.")
            }
            _ => crate::i18n::gettext("The server has no room for another connection right now. Try again shortly."),
        },
        ErrorCategory::Internal => internal_message(error),
    }
}

/// A category sentence followed by what the error itself says, for a
/// variant this build has no sentence of its own for.
fn detail_sentence(sentence: String, error: &DriverError) -> String {
    format!("{sentence} {error}")
}

fn configuration_message(error: &DriverError) -> String {
    match error {
        DriverError::Config(config) => config_message(config),
        DriverError::Unsupported { feature } => {
            crate::i18n::gettext_f("This database has no {feature}.", &[("feature", feature)])
        }
        other => detail_sentence(crate::i18n::gettext("The connection settings cannot be used."), other),
    }
}

pub fn config_message(error: &ConfigError) -> String {
    match error {
        ConfigError::EmptyHost => crate::i18n::gettext("Enter the server's host name."),
        ConfigError::InvalidHost => crate::i18n::gettext("The host name has spaces or control characters in it."),
        ConfigError::InvalidPort => crate::i18n::gettext("The port must be a number from 1 to 65535."),
        ConfigError::RelativePath => crate::i18n::gettext("Use a full path, starting with /."),
        ConfigError::UnsupportedTlsMode => crate::i18n::gettext("This database does not offer that TLS mode."),
        ConfigError::CaFileUnsupported => {
            crate::i18n::gettext("A CA certificate needs TLS turned on and a database that accepts one.")
        }
        ConfigError::ClientIdentityUnsupported => {
            crate::i18n::gettext("A client certificate needs TLS turned on and a database that accepts one.")
        }
        ConfigError::ClientIdentityIncomplete => {
            crate::i18n::gettext("A client certificate needs both its certificate file and its key file.")
        }
        ConfigError::CaFile { path, problem } => crate::i18n::gettext_f(
            "The CA certificate {path} cannot be used: {problem}",
            &[("path", &path.display().to_string()), ("problem", &problem.to_string())],
        ),
        ConfigError::ClientIdentityFile { path, problem } => crate::i18n::gettext_f(
            "The client certificate {path} cannot be used: {problem}",
            &[("path", &path.display().to_string()), ("problem", &problem.to_string())],
        ),
        ConfigError::InvalidServerName => {
            crate::i18n::gettext("The TLS server name is not a valid host name or IP address.")
        }
        ConfigError::ServerNameOverrideUnsupported { .. } => {
            crate::i18n::gettext("This database cannot check the certificate against another server name here.")
        }
        ConfigError::AuthModeUnsupported => {
            crate::i18n::gettext("This database does not support that way of logging in.")
        }
        ConfigError::DatabaseRequired => crate::i18n::gettext("Enter the name of the database to open."),
    }
}

fn network_message(error: &DriverError) -> String {
    match error {
        DriverError::Transport(TransportError::Refused { endpoint }) => crate::i18n::gettext_f(
            "{host}:{port} refused the connection. Is the database running?",
            &[("host", endpoint.host()), ("port", &endpoint.port().to_string())],
        ),
        DriverError::Transport(TransportError::NameResolution { host, .. }) => {
            crate::i18n::gettext_f("Could not look up {host}.", &[("host", host)])
        }
        DriverError::Transport(TransportError::Unreachable { endpoint, .. }) => crate::i18n::gettext_f(
            "Could not reach {host}:{port}.",
            &[("host", endpoint.host()), ("port", &endpoint.port().to_string())],
        ),
        other => detail_sentence(crate::i18n::gettext("The server could not be reached."), other),
    }
}

/// Never echoes what was typed: the server's own explanation is safe to
/// show, the secret is not part of any variant.
fn authentication_message(error: &DriverError) -> String {
    match error {
        DriverError::Auth {
            diagnostics: Some(diagnostics),
        } => crate::i18n::gettext_f(
            "Username or password is wrong. The server said: {detail}",
            &[("detail", &diagnostics.message)],
        ),
        DriverError::IntegratedAuth(detail) => crate::i18n::gettext_f(
            "Kerberos login failed: {detail}. Check that klist shows a valid ticket, run kinit if it does not, and make sure the server's SPN matches the host you typed.",
            &[("detail", detail)],
        ),
        _ => crate::i18n::gettext("Username or password is wrong."),
    }
}

fn read_only_message(error: &DriverError) -> String {
    match error {
        DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(diagnostics)) => crate::i18n::gettext_f(
            "The server refused the write: {message}",
            &[("message", &diagnostics.message)],
        ),
        _ => crate::i18n::gettext("This connection is read-only. Reopen it without read-only mode to make changes."),
    }
}

/// The server's words with whatever it added: its code, the detail line
/// and its hint.
pub fn server_message(diagnostics: &ServerDiagnostics) -> String {
    let mut message = match &diagnostics.code {
        Some(code) => crate::i18n::gettext_f(
            "Query failed ({code}): {message}",
            &[("code", &server_code_text(code)), ("message", &diagnostics.message)],
        ),
        None => crate::i18n::gettext_f("Query failed: {message}", &[("message", &diagnostics.message)]),
    };
    if let Some(detail) = diagnostics.detail.as_deref().filter(|detail| !detail.is_empty()) {
        message.push('\n');
        message.push_str(detail);
    }
    if let Some(hint) = diagnostics.hint.as_deref().filter(|hint| !hint.is_empty()) {
        message.push('\n');
        message.push_str(&crate::i18n::gettext_f("Hint: {hint}", &[("hint", hint)]));
    }
    message
}

/// The code in the words each engine's own documentation uses, so it
/// can be looked up there.
fn server_code_text(code: &ServerCode) -> String {
    let number = code.to_string();
    match code {
        ServerCode::SqlState(_) => crate::i18n::gettext_f("SQLSTATE {code}", &[("code", &number)]),
        ServerCode::MySql { .. } => crate::i18n::gettext_f("MySQL error {code}", &[("code", &number)]),
        ServerCode::Tds { .. } => crate::i18n::gettext_f("SQL Server error {code}", &[("code", &number)]),
        ServerCode::ClickHouse { .. } => crate::i18n::gettext_f("ClickHouse code {code}", &[("code", &number)]),
        ServerCode::Sqlite { .. } => crate::i18n::gettext_f("SQLite error {code}", &[("code", &number)]),
    }
}

fn timeout_message(error: &DriverError) -> String {
    let phase = match error {
        DriverError::Timeout { phase, .. } | DriverError::Transport(TransportError::Timeout { phase }) => *phase,
        other => return detail_sentence(crate::i18n::gettext("The server took too long to answer."), other),
    };
    match phase {
        TimeoutPhase::Connect => crate::i18n::gettext("The server did not answer the connection in time."),
        TimeoutPhase::Login => crate::i18n::gettext("The server did not finish the login in time."),
        TimeoutPhase::SshHandshake => crate::i18n::gettext("The SSH server did not finish the handshake in time."),
        TimeoutPhase::SshChannelOpen => {
            crate::i18n::gettext("The SSH server did not open the tunnel to the database in time.")
        }
        TimeoutPhase::LockWait => {
            crate::i18n::gettext("Another session holds a lock this needs. Try again when it has finished.")
        }
        TimeoutPhase::Statement => {
            crate::i18n::gettext("The statement ran past its time limit, so the server stopped it.")
        }
        TimeoutPhase::Probe => crate::i18n::gettext("The server did not answer a check in time."),
    }
}

/// After a failed write the question is what is in the database now,
/// and each variant answers it differently. Only `RolledBack` and a
/// failed guard may say nothing changed.
fn write_outcome_message(error: &DriverError) -> String {
    match error {
        DriverError::RolledBack {
            statement_index,
            source,
        } => crate::i18n::gettext_f(
            "Save failed at statement {n}: {error}. The transaction was rolled back; no rows were changed.",
            &[
                ("n", &(statement_index + 1).to_string()),
                ("error", &driver_message(source)),
            ],
        ),
        DriverError::RowGuardFailed { expected, actual, .. } => crate::i18n::gettext_f(
            "The save matched {actual} rows where it expected {expected}, so the row is not the one that was loaded. Nothing was changed; reload and try again.",
            &[("actual", &actual.to_string()), ("expected", &expected.to_string())],
        ),
        DriverError::PartiallyApplied {
            applied,
            statement_index,
            ..
        } => crate::i18n::gettext_f(
            "{applied} of the save's statements were applied before statement {n} failed, and this database has no transaction to undo them. Reload to see what the server has.",
            &[
                ("applied", &applied.to_string()),
                ("n", &(statement_index + 1).to_string()),
            ],
        ),
        _ => crate::i18n::gettext(
            "The connection was lost after the save was sent, so whether it was applied is not known. Reload to see what the server has.",
        ),
    }
}

fn file_message(error: &DriverError) -> String {
    match error {
        DriverError::FileNotFound { path } => {
            crate::i18n::gettext_f("No database file at {path}.", &[("path", &path.display().to_string())])
        }
        DriverError::FileAccessDenied { path } => crate::i18n::gettext_f(
            "No permission to open {path}.",
            &[("path", &path.display().to_string())],
        ),
        DriverError::NotADatabase { path } => crate::i18n::gettext_f(
            "{path} is not a database file.",
            &[("path", &path.display().to_string())],
        ),
        DriverError::FileIo { path, kind } => crate::i18n::gettext_f(
            "Could not write {path}: {reason}",
            &[("path", &path.display().to_string()), ("reason", &kind.to_string())],
        ),
        other => detail_sentence(crate::i18n::gettext("The database file cannot be used."), other),
    }
}

fn internal_message(error: &DriverError) -> String {
    match error {
        DriverError::GuardUnsupported { .. } => crate::i18n::gettext(
            "This database does not report how many rows a statement changed, so the save cannot be checked. Use a table with a primary key.",
        ),
        DriverError::Decode { column, detail } => crate::i18n::gettext_f(
            "Could not read column {column}: {detail}",
            &[("column", column), ("detail", detail)],
        ),
        DriverError::Protocol(detail) => crate::i18n::gettext_f(
            "The driver could not read the server's reply: {detail}",
            &[("detail", detail)],
        ),
        other => detail_sentence(crate::i18n::gettext("The driver hit an internal error."), other),
    }
}

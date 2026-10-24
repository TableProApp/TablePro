use std::io;

use mongodb::error::{Error, ErrorKind, WriteFailure};
use tablepro_core::{
    DriverError, LossPhase, NetworkEndpoint, ServerCode, ServerDiagnostics, TimeoutPhase, TlsFailure, TransportError,
};

use tablepro_core::sql_syntax::mongo::ShellSyntaxError;

use crate::to_bson::ValueError;

/// `AuthenticationFailed`: the user or the password is wrong.
pub(crate) const AUTHENTICATION_FAILED: i32 = 18;
/// `MaxTimeMSExpired`: the server stopped the operation at its time limit.
pub(crate) const MAX_TIME_MS_EXPIRED: i32 = 50;
/// `Interrupted`, `InterruptedAtShutdown`, `CursorKilled` and
/// `QueryPlanKilled`: what an operation a `killSessions` reached reports.
const STOPPED_BY_KILL: [i32; 4] = [11601, 11600, 237, 175];
/// `CursorNotFound`: a cursor the kill already closed.
const CURSOR_NOT_FOUND: i32 = 43;

/// What a failure of the client means, with `during` saying what a lost
/// connection was doing.
pub(crate) fn map_error(error: &Error, endpoint: &NetworkEndpoint, during: LossPhase) -> DriverError {
    match error.kind.as_ref() {
        ErrorKind::Authentication { message, .. } => DriverError::auth(Some(ServerDiagnostics::new(
            Some(code(AUTHENTICATION_FAILED, Some("AuthenticationFailed"))),
            message.clone(),
        ))),
        ErrorKind::Command(command) if command.code == AUTHENTICATION_FAILED => DriverError::auth(Some(diagnostics(
            command.code,
            Some(&command.code_name),
            &command.message,
        ))),
        ErrorKind::Command(command) if command.code == MAX_TIME_MS_EXPIRED => DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        },
        ErrorKind::Command(command) => {
            DriverError::reported(diagnostics(command.code, Some(&command.code_name), &command.message))
        }
        ErrorKind::Write(WriteFailure::WriteError(write)) => {
            DriverError::reported(diagnostics(write.code, write.code_name.as_deref(), &write.message))
        }
        ErrorKind::Write(WriteFailure::WriteConcernError(concern)) => {
            DriverError::reported(diagnostics(concern.code, Some(&concern.code_name), &concern.message))
        }
        ErrorKind::Io(io_error) => io_failure(io_error, endpoint, during),
        ErrorKind::DnsResolve { message, .. } => DriverError::Transport(TransportError::NameResolution {
            host: endpoint.host().to_owned(),
            detail: message.clone(),
        }),
        ErrorKind::ServerSelection { message, .. } => DriverError::Transport(TransportError::Unreachable {
            endpoint: endpoint.clone(),
            detail: message.clone(),
        }),
        ErrorKind::InvalidTlsConfig { message, .. } => DriverError::Tls {
            failure: TlsFailure::Other,
            detail: message.clone(),
        },
        ErrorKind::ConnectionPoolCleared { .. } | ErrorKind::Shutdown => DriverError::ConnectionLost { during },
        ErrorKind::InvalidArgument { message, .. } | ErrorKind::InvalidResponse { message, .. } => {
            DriverError::server(message.clone())
        }
        _ => DriverError::Protocol(error.to_string()),
    }
}

fn io_failure(error: &io::Error, endpoint: &NetworkEndpoint, during: LossPhase) -> DriverError {
    if let Some((failure, detail)) = tablepro_net::tls::classify(error) {
        return DriverError::Tls { failure, detail };
    }
    match error.kind() {
        io::ErrorKind::ConnectionRefused if during == LossPhase::Connect => {
            DriverError::Transport(TransportError::Refused {
                endpoint: endpoint.clone(),
            })
        }
        io::ErrorKind::TimedOut if during == LossPhase::Connect => DriverError::Transport(TransportError::Timeout {
            phase: TimeoutPhase::Connect,
        }),
        io::ErrorKind::NotFound | io::ErrorKind::HostUnreachable | io::ErrorKind::NetworkUnreachable
            if during == LossPhase::Connect =>
        {
            DriverError::Transport(TransportError::Unreachable {
                endpoint: endpoint.clone(),
                detail: error.to_string(),
            })
        }
        _ => DriverError::ConnectionLost { during },
    }
}

fn code(number: i32, name: Option<&str>) -> ServerCode {
    ServerCode::Mongo {
        code: number,
        name: name.filter(|name| !name.is_empty()).map(str::to_owned),
    }
}

fn diagnostics(number: i32, name: Option<&str>, message: &str) -> ServerDiagnostics {
    ServerDiagnostics::new(Some(code(number, name)), message)
}

/// The server's error code, where the failure carries one.
pub(crate) fn server_code(error: &DriverError) -> Option<i32> {
    match error {
        DriverError::Server(diagnostics) => match &diagnostics.code {
            Some(ServerCode::Mongo { code, .. }) => Some(*code),
            _ => None,
        },
        _ => None,
    }
}

/// Whether a failure is the server acting on a `killSessions` the driver
/// sent to stop it.
pub(crate) fn stopped_by_kill(error: &DriverError) -> bool {
    server_code(error).is_some_and(|code| STOPPED_BY_KILL.contains(&code) || code == CURSOR_NOT_FOUND)
}

/// A value the text names that BSON cannot hold, reported as mongosh
/// reports one, before anything is sent.
pub(crate) fn value_error(error: ValueError) -> DriverError {
    DriverError::reported(ServerDiagnostics::new(Some(code(2, Some("BadValue"))), error.0))
}

/// Text that is not a statement, refused before anything is sent, with
/// where the problem is: `start` is where the statement begins in
/// `text`, and the position counts characters from 1, as an editor does.
pub(crate) fn syntax_error(error: &ShellSyntaxError, text: &str, start: usize) -> DriverError {
    let mut diagnostics = ServerDiagnostics::new(None, format!("SyntaxError: {error}"));
    diagnostics.position = error
        .offset()
        .and_then(|offset| text.get(..start + offset))
        .and_then(|before| u32::try_from(before.chars().count() + 1).ok());
    DriverError::reported(diagnostics)
}

/// A write the server refused, inside a write command's reply, which
/// the server sends with `ok: 1`.
pub(crate) fn reply_write_error(reply: &bson::Document) -> Option<DriverError> {
    reply_error(reply, "writeErrors")
}

/// A write concern the server could not meet, such as a majority that
/// did not answer in time. The write was applied where the command ran,
/// so whether it lasts is not known.
pub(crate) fn reply_write_concern_error(reply: &bson::Document) -> Option<DriverError> {
    reply_error(reply, "writeConcernError")
}

fn reply_error(reply: &bson::Document, key: &str) -> Option<DriverError> {
    let error = match reply.get(key) {
        Some(bson::Bson::Array(items)) => items.first().and_then(bson::Bson::as_document).cloned(),
        Some(bson::Bson::Document(document)) => Some(document.clone()),
        _ => None,
    }?;
    let number = error.get_i32("code").unwrap_or(8);
    let name = error.get_str("codeName").ok();
    let message = error.get_str("errmsg").unwrap_or("the write failed");
    Some(DriverError::reported(diagnostics(number, name, message)))
}

#[cfg(test)]
mod tests {
    use bson::doc;

    use super::*;

    #[test]
    fn a_write_error_inside_an_ok_reply_is_an_error() {
        let reply = doc! {
            "n": 0_i32,
            "writeErrors": [{ "index": 0_i32, "code": 11000_i32, "errmsg": "E11000 duplicate key" }],
            "ok": 1.0_f64,
        };

        let error = reply_write_error(&reply).expect("a write error");

        assert_eq!(server_code(&error), Some(11000));
        assert!(reply_write_error(&doc! { "n": 1_i32, "ok": 1.0_f64 }).is_none());
        let unconfirmed = doc! {
            "n": 1_i32,
            "writeConcernError": { "code": 64_i32, "codeName": "WriteConcernFailed", "errmsg": "waiting timed out" },
            "ok": 1.0_f64,
        };
        assert!(reply_write_error(&unconfirmed).is_none(), "the write was applied");
        assert_eq!(
            reply_write_concern_error(&unconfirmed).as_ref().and_then(server_code),
            Some(64)
        );
    }

    #[test]
    fn a_syntax_error_points_at_the_character_it_is_at() {
        let text = "db.a.find()\ndb.é.find({a: b})";
        let error = tablepro_core::sql_syntax::mongo::parse_statement(&text[12..]).expect_err("not a statement");

        let DriverError::Server(diagnostics) = syntax_error(&error, text, 12) else {
            panic!("not reported");
        };

        assert!(diagnostics.message.starts_with("SyntaxError: "));
        assert_eq!(diagnostics.position, Some(27));
    }

    #[test]
    fn a_stop_is_told_apart_from_a_failure() {
        let interrupted = DriverError::reported(diagnostics(11601, Some("Interrupted"), "operation was interrupted"));
        let duplicate = DriverError::reported(diagnostics(11000, Some("DuplicateKey"), "dup"));

        assert!(stopped_by_kill(&interrupted));
        assert!(!stopped_by_kill(&duplicate));
    }
}

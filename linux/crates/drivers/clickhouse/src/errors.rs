use std::error::Error as StdError;
use std::io;

use clickhouse::error::Error as ClickHouseError;
use tablepro_core::{
    DriverError, LossPhase, ReadOnlyRefusal, ServerCode, ServerDiagnostics, TimeoutPhase, TlsFailure, TransportError,
};

/// Codes the app acts on. Everything else is the server's own answer,
/// passed through with its message.
pub(crate) mod code {
    pub(crate) const TIMEOUT_EXCEEDED: i32 = 159;
    pub(crate) const READONLY: i32 = 164;
    pub(crate) const UNKNOWN_USER: i32 = 192;
    pub(crate) const WRONG_PASSWORD: i32 = 193;
    pub(crate) const REQUIRED_PASSWORD: i32 = 194;
    pub(crate) const TOO_MANY_SIMULTANEOUS_QUERIES: i32 = 202;
    pub(crate) const NO_FREE_CONNECTION: i32 = 203;
    pub(crate) const SOCKET_TIMEOUT: i32 = 209;
    pub(crate) const NETWORK_ERROR: i32 = 210;
    pub(crate) const UNFINISHED: i32 = 341;
    pub(crate) const SESSION_NOT_FOUND: i32 = 372;
    pub(crate) const SESSION_IS_LOCKED: i32 = 373;
    pub(crate) const QUERY_IS_PROHIBITED: i32 = 392;
    pub(crate) const QUERY_WAS_CANCELLED: i32 = 394;
    pub(crate) const ACCESS_DENIED: i32 = 497;
    pub(crate) const AUTHENTICATION_FAILED: i32 = 516;
}

/// Where an error happened, which decides what a lost stream or an
/// access refusal means.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ErrorContext {
    /// The first request of a connect, where a refused access is a login
    /// the server did not accept.
    Login {
        tls_requested: bool,
    },
    Statement,
}

/// The number ClickHouse prints at the start of every exception. The
/// HTTP interface carries it nowhere else, and clickhouse 0.15 reports
/// the body as one string.
pub(crate) fn clickhouse_code(message: &str) -> Option<i32> {
    let rest = &message[message.find("Code: ")? + "Code: ".len()..];
    let digits = rest
        .find(|character: char| !character.is_ascii_digit())
        .unwrap_or(rest.len());
    rest[..digits].parse().ok()
}

/// The server's code of an error the driver mapped, where it carries one.
pub(crate) fn server_code(error: &DriverError) -> Option<i32> {
    let diagnostics = match error {
        DriverError::Server(diagnostics)
        | DriverError::Auth {
            diagnostics: Some(diagnostics),
        } => diagnostics,
        DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(diagnostics)) => diagnostics,
        _ => return None,
    };
    match diagnostics.code {
        Some(ServerCode::ClickHouse { code }) => Some(code),
        _ => None,
    }
}

pub(crate) fn map_error(error: &ClickHouseError) -> DriverError {
    map_error_in(error, ErrorContext::Statement)
}

pub(crate) fn map_error_in(error: &ClickHouseError, context: ErrorContext) -> DriverError {
    match error {
        ClickHouseError::BadResponse(message) => server_error(message, context),
        ClickHouseError::TimedOut => DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: false,
        },
        ClickHouseError::Network(_) | ClickHouseError::Other(_) => network_error(error, context),
        other => DriverError::Protocol(other.to_string()),
    }
}

/// An I/O error from reading a response body. The cursor carries the
/// client's own error inside it, so that is recovered first.
pub(crate) fn map_io_error(error: io::Error) -> DriverError {
    map_error(&ClickHouseError::from(error))
}

fn server_error(message: &str, context: ErrorContext) -> DriverError {
    let code = clickhouse_code(message);
    let diagnostics = ServerDiagnostics::new(code.map(|code| ServerCode::ClickHouse { code }), message.trim());
    let login = matches!(context, ErrorContext::Login { .. });
    match code {
        Some(code::UNKNOWN_USER | code::WRONG_PASSWORD | code::REQUIRED_PASSWORD | code::AUTHENTICATION_FAILED) => {
            DriverError::auth(Some(diagnostics))
        }
        // A user who exists but may read nothing is refused at the first
        // request, which is the login here.
        Some(code::ACCESS_DENIED) if login => DriverError::auth(Some(diagnostics)),
        // allow_ddl=0 is only ever sent for a read-only connection, so a
        // prohibited query is that connection refusing a schema change.
        Some(code::READONLY | code::QUERY_IS_PROHIBITED) => DriverError::ReadOnly(ReadOnlyRefusal::server(diagnostics)),
        Some(code::TIMEOUT_EXCEEDED) => DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        },
        Some(code::TOO_MANY_SIMULTANEOUS_QUERIES | code::NO_FREE_CONNECTION) => DriverError::Busy,
        _ => DriverError::reported(diagnostics),
    }
}

/// A failure below the HTTP answer, classified by what is in its source
/// chain rather than by its words: a message can mention a certificate
/// without being a TLS failure.
fn network_error(error: &(dyn StdError + 'static), context: ErrorContext) -> DriverError {
    if let Some(transport) = find::<TransportError>(error) {
        return DriverError::Transport(transport.clone());
    }
    if let Some((failure, detail)) = tablepro_net::tls::classify(error) {
        return DriverError::Tls { failure, detail };
    }
    match context {
        ErrorContext::Login { tls_requested: true } if connect_phase(error) => DriverError::Tls {
            failure: TlsFailure::Other,
            detail: describe(error),
        },
        ErrorContext::Login { .. } => DriverError::ConnectionLost {
            during: LossPhase::Connect,
        },
        ErrorContext::Statement => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
    }
}

/// Whether hyper failed while it was still opening the connection, which
/// with TLS on is the handshake. Nothing of the request was sent then.
pub(crate) fn connect_phase(error: &(dyn StdError + 'static)) -> bool {
    find::<hyper_util::client::legacy::Error>(error).is_some_and(hyper_util::client::legacy::Error::is_connect)
}

/// The first error of type `T` in the chain, looking inside `io::Error`
/// too, since that is where hyper and tokio-rustls keep the cause.
fn find<'a, T: StdError + 'static>(error: &'a (dyn StdError + 'static)) -> Option<&'a T> {
    let mut current = Some(error);
    while let Some(candidate) = current {
        if let Some(found) = candidate.downcast_ref::<T>() {
            return Some(found);
        }
        current = match candidate.downcast_ref::<io::Error>() {
            Some(io_error) => io_error.get_ref().map(|inner| inner as &(dyn StdError + 'static)),
            None => candidate.source(),
        };
    }
    None
}

/// The whole chain in one line, for a detail the user can act on.
fn describe(error: &(dyn StdError + 'static)) -> String {
    let mut text = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        text.push_str(": ");
        text.push_str(&cause.to_string());
        source = cause.source();
    }
    text
}

#[cfg(test)]
mod tests {
    use tablepro_core::{ErrorCategory, NetworkEndpoint};

    use super::*;

    fn bad_response(message: &str) -> DriverError {
        map_error(&ClickHouseError::BadResponse(message.to_owned()))
    }

    #[test]
    fn code_prefix_parsing() {
        assert_eq!(
            clickhouse_code("Code: 516. DB::Exception: Authentication failed"),
            Some(516)
        );
        assert_eq!(clickhouse_code("Code: 60"), Some(60));
        assert_eq!(
            clickhouse_code("Received from localhost. Code: 394. DB::Exception: Query was cancelled."),
            Some(394)
        );
        assert_eq!(clickhouse_code("500 Internal Server Error"), None);
        assert_eq!(clickhouse_code("Code: x"), None);
    }

    #[test]
    fn login_codes_are_auth_and_access_denied_only_at_login() {
        assert!(matches!(
            bad_response("Code: 516. DB::Exception: tablepro: Authentication failed"),
            DriverError::Auth { .. }
        ));
        let denied = ClickHouseError::BadResponse("Code: 497. DB::Exception: Not enough privileges".to_owned());
        assert!(matches!(
            map_error_in(&denied, ErrorContext::Login { tls_requested: false }),
            DriverError::Auth { .. }
        ));
        assert_eq!(map_error(&denied).category(), ErrorCategory::Server);
    }

    #[test]
    fn a_read_only_refusal_carries_the_servers_code() {
        let error = bad_response("Code: 164. DB::Exception: Cannot execute query in readonly mode");

        let DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(diagnostics)) = &error else {
            panic!("got {error:?}");
        };
        assert_eq!(diagnostics.code, Some(ServerCode::ClickHouse { code: 164 }));
        assert_eq!(server_code(&error), Some(164));
    }

    #[test]
    fn a_cancelled_query_stays_the_servers_answer_for_owned_calls_to_read() {
        let error = bad_response("Code: 394. DB::Exception: Query was cancelled");

        assert_eq!(server_code(&error), Some(394));
        assert_eq!(error.category(), ErrorCategory::Server);
    }

    #[test]
    fn a_server_timeout_is_a_statement_timeout_the_server_enforced() {
        assert_eq!(
            bad_response("Code: 159. DB::Exception: Timeout exceeded: elapsed 1.0 seconds"),
            DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: true,
            }
        );
    }

    #[test]
    fn a_server_error_mentioning_a_certificate_stays_a_server_error() {
        let error = bad_response("Code: 47. DB::Exception: Unknown identifier: certificate");

        assert!(matches!(error, DriverError::Server(_)), "got {error:?}");
    }

    #[test]
    fn network_error_classified_by_source() {
        let endpoint = NetworkEndpoint::new("db.example.com", 8123).expect("an endpoint");
        let refused = TransportError::Refused {
            endpoint: endpoint.clone(),
        };
        let wrapped = io::Error::other(refused.clone());
        let network = ClickHouseError::Network(Box::new(wrapped));
        assert_eq!(map_error(&network), DriverError::Transport(refused));

        let certificate = rustls_failure();
        let network = ClickHouseError::Network(Box::new(io::Error::new(io::ErrorKind::InvalidData, certificate)));
        assert!(matches!(
            map_error(&network),
            DriverError::Tls {
                failure: TlsFailure::UnknownIssuer,
                ..
            }
        ));

        let reset = ClickHouseError::Network(Box::new(io::Error::from(io::ErrorKind::ConnectionReset)));
        assert_eq!(
            map_error(&reset),
            DriverError::ConnectionLost {
                during: LossPhase::Statement
            }
        );
        assert_eq!(
            map_error_in(&reset, ErrorContext::Login { tls_requested: false }),
            DriverError::ConnectionLost {
                during: LossPhase::Connect
            }
        );
    }

    #[test]
    fn a_body_error_read_through_the_cursor_keeps_its_code() {
        let carried = io::Error::other(ClickHouseError::BadResponse(
            "Code: 394. DB::Exception: Query was cancelled".to_owned(),
        ));

        assert_eq!(server_code(&map_io_error(carried)), Some(394));
    }

    /// The error the way tokio-rustls reports a refused certificate.
    fn rustls_failure() -> io::Error {
        io::Error::new(
            io::ErrorKind::InvalidData,
            rustls::Error::InvalidCertificate(rustls::CertificateError::UnknownIssuer),
        )
    }
}

use clickhouse::error::Error as ClickHouseError;

use crate::errors::{clickhouse_code, code, connect_phase};

/// What a failed write statement left behind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WriteErrorClass {
    /// The server refused it before it changed anything.
    Refused,
    /// It may have applied, or may still be applying: a mutation keeps
    /// running after the request that started it is gone.
    MayHaveApplied,
}

/// Sort a write's failure by whether the statement can have landed.
///
/// Read from the client's own error rather than the mapped one, because
/// the mapping folds a server timeout into the same timeout a lost
/// response reads as.
pub(crate) fn classify(error: &ClickHouseError) -> WriteErrorClass {
    match error {
        ClickHouseError::BadResponse(message) => match clickhouse_code(message) {
            // Cancelled, timed out, or the mutation wait gave up: the
            // statement was accepted, and what it did is not known.
            Some(
                code::QUERY_WAS_CANCELLED
                | code::TIMEOUT_EXCEEDED
                | code::UNFINISHED
                | code::SOCKET_TIMEOUT
                | code::NETWORK_ERROR,
            ) => WriteErrorClass::MayHaveApplied,
            // A body with no code is a proxy or a dropped response, not
            // the server's refusal.
            None => WriteErrorClass::MayHaveApplied,
            Some(_) => WriteErrorClass::Refused,
        },
        // A connection that never opened carried nothing.
        ClickHouseError::Network(_) if connect_phase(error) => WriteErrorClass::Refused,
        ClickHouseError::Network(_) | ClickHouseError::TimedOut | ClickHouseError::Other(_) => {
            WriteErrorClass::MayHaveApplied
        }
        // Everything else is the client failing to build the request,
        // which therefore never reached the server.
        _ => WriteErrorClass::Refused,
    }
}

#[cfg(test)]
mod tests {
    use std::io;

    use super::*;

    fn server(code: i32) -> ClickHouseError {
        ClickHouseError::BadResponse(format!("Code: {code}. DB::Exception: something"))
    }

    #[test]
    fn unknown_versus_refused_codes() {
        for code in [394, 159, 341, 209, 210] {
            assert_eq!(classify(&server(code)), WriteErrorClass::MayHaveApplied, "{code}");
        }
        for code in [16, 47, 60, 62, 164, 241, 516] {
            assert_eq!(classify(&server(code)), WriteErrorClass::Refused, "{code}");
        }
        assert_eq!(
            classify(&ClickHouseError::Network(Box::new(io::Error::from(
                io::ErrorKind::ConnectionReset
            )))),
            WriteErrorClass::MayHaveApplied
        );
        assert_eq!(
            classify(&ClickHouseError::BadResponse("502 Bad Gateway".to_owned())),
            WriteErrorClass::MayHaveApplied
        );
        assert_eq!(
            classify(&ClickHouseError::InvalidParams(Box::new(io::Error::other("bad param")))),
            WriteErrorClass::Refused
        );
    }
}

use redis::{ErrorKind, RedisError, ServerError};
use tablepro_core::sql_syntax::redis::CommandSyntaxError;
use tablepro_core::{DriverError, LossPhase, ReadOnlyRefusal, ServerCode, ServerDiagnostics, TimeoutPhase};

/// A failure the library reported, from the phase the link was in.
pub(crate) fn map_error(error: &RedisError, phase: LossPhase) -> DriverError {
    match error.kind() {
        ErrorKind::AuthenticationFailed => DriverError::auth(error.detail().map(|detail| {
            ServerDiagnostics::new(None, detail.to_owned())
        })),
        ErrorKind::Server(_) | ErrorKind::Extension => {
            from_code(error.code().unwrap_or("ERR"), error.detail().unwrap_or_default())
        }
        ErrorKind::Io if error.is_timeout() => DriverError::Timeout {
            phase: match phase {
                LossPhase::Connect => TimeoutPhase::Login,
                _ => TimeoutPhase::Statement,
            },
            server_cancelled: false,
        },
        ErrorKind::Io => DriverError::ConnectionLost { during: phase },
        _ if error.is_connection_dropped() || error.is_connection_refusal() => {
            DriverError::ConnectionLost { during: phase }
        }
        _ => DriverError::Protocol(error.to_string()),
    }
}

/// An error reply, as a value in a reply or as the reply itself.
pub(crate) fn server_error(error: &ServerError) -> DriverError {
    from_code(error.code(), error.details().unwrap_or_default())
}

/// `-WRONGPASS` and `-NOAUTH` are the server refusing the login, and
/// `-READONLY` a replica refusing a write: the app has its own words and
/// remedies for both. Any other reply keeps the server's code.
fn from_code(code: &str, detail: &str) -> DriverError {
    let diagnostics = diagnostics(code, detail);
    match code {
        "WRONGPASS" | "NOAUTH" => DriverError::auth(Some(diagnostics)),
        "READONLY" => DriverError::ReadOnly(ReadOnlyRefusal::server(diagnostics)),
        _ => DriverError::reported(diagnostics),
    }
}

pub(crate) fn diagnostics(code: &str, detail: &str) -> ServerDiagnostics {
    let message = match detail.trim() {
        "" => code.to_owned(),
        detail => detail.to_owned(),
    };
    ServerDiagnostics::new(
        Some(ServerCode::Redis {
            prefix: code.to_owned(),
        }),
        message,
    )
}

/// A line the client cannot turn into arguments, refused before it is
/// sent in redis-cli's own words for it.
pub(crate) fn invalid_arguments(_error: CommandSyntaxError) -> DriverError {
    DriverError::server("Invalid argument(s)")
}

/// The error reply that says `CLIENT UNBLOCK` ended a blocked command.
pub(crate) fn is_unblocked(error: &DriverError) -> bool {
    matches!(
        error,
        DriverError::Server(diagnostics) if matches!(
            &diagnostics.code,
            Some(ServerCode::Redis { prefix }) if prefix == "UNBLOCKED"
        )
    )
}

#[cfg(test)]
mod tests {
    use tablepro_core::ErrorCategory;

    use super::*;

    fn reply(line: &str) -> DriverError {
        let (code, detail) = line.split_once(' ').unwrap_or((line, ""));
        from_code(code, detail)
    }

    #[test]
    fn a_refused_password_is_an_authentication_failure() {
        for line in [
            "WRONGPASS invalid username-password pair or user is disabled.",
            "NOAUTH Authentication required.",
        ] {
            assert_eq!(reply(line).category(), ErrorCategory::Authentication, "{line}");
        }
    }

    #[test]
    fn a_replica_refusing_a_write_is_the_servers_read_only_refusal() {
        let error = reply("READONLY You can't write against a read only replica.");

        assert!(matches!(error, DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_))), "{error:?}");
    }

    #[test]
    fn any_other_reply_keeps_its_code_and_words() {
        let error = reply("WRONGTYPE Operation against a key holding the wrong kind of value");

        let DriverError::Server(diagnostics) = &error else {
            panic!("not a server error: {error:?}");
        };
        assert_eq!(
            diagnostics.code,
            Some(ServerCode::Redis {
                prefix: "WRONGTYPE".to_owned()
            })
        );
        assert_eq!(diagnostics.message, "Operation against a key holding the wrong kind of value");
        assert!(!is_unblocked(&error));
        assert!(is_unblocked(&reply("UNBLOCKED client unblocked via CLIENT UNBLOCK")));
    }

    #[test]
    fn a_reply_with_no_words_shows_its_code() {
        let DriverError::Server(diagnostics) = reply("BUSY") else {
            panic!("not a server error");
        };

        assert_eq!(diagnostics.message, "BUSY");
    }
}

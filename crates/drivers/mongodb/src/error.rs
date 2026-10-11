use tablepro_core::{DriverError, looks_like_tls_failure};

/// The mongodb crate boxes the transport error inside `ErrorKind::Io`
/// rather than exposing it through `source()`, so the handshake cause is
/// only reachable by walking that box as a second chain.
fn error_chain_text(err: &mongodb::error::Error) -> String {
    let mut text = tablepro_core::error_chain_text(err);
    if let mongodb::error::ErrorKind::Io(io) = &*err.kind {
        text.push(' ');
        text.push_str(&tablepro_core::error_chain_text(io.as_ref()));
    }
    text
}

fn mongo_error_can_hide_tls(kind: &mongodb::error::ErrorKind) -> bool {
    use mongodb::error::ErrorKind;
    matches!(
        kind,
        ErrorKind::Io(_)
            | ErrorKind::ServerSelection { .. }
            | ErrorKind::DnsResolve { .. }
            | ErrorKind::ConnectionPoolCleared { .. }
    )
}

pub(super) fn map_mongo_error(err: mongodb::error::Error) -> DriverError {
    map_mongo_error_in_context(err, false)
}

pub(super) fn map_mongo_connect_error(err: mongodb::error::Error, _verifies_cert: bool) -> DriverError {
    map_mongo_error_in_context(err, true)
}

fn map_mongo_error_in_context(err: mongodb::error::Error, connecting: bool) -> DriverError {
    use mongodb::error::ErrorKind;
    let chain = error_chain_text(&err);
    if mongo_error_can_hide_tls(&err.kind) && looks_like_tls_failure(&chain) {
        return DriverError::Tls(chain);
    }
    match &*err.kind {
        ErrorKind::Authentication { .. } => DriverError::AuthFailed,
        ErrorKind::Io(io) if io.kind() == std::io::ErrorKind::ConnectionRefused && connecting => {
            DriverError::ConnectionRefused
        }
        ErrorKind::Io(io) if io.kind() == std::io::ErrorKind::ConnectionRefused => DriverError::Disconnected,
        ErrorKind::Io(io)
            if matches!(
                io.kind(),
                std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::UnexpectedEof
                    | std::io::ErrorKind::NotConnected
            ) =>
        {
            DriverError::Disconnected
        }
        ErrorKind::ServerSelection { .. } | ErrorKind::DnsResolve { .. } if connecting => {
            DriverError::ConnectionRefused
        }
        ErrorKind::ServerSelection { .. } | ErrorKind::DnsResolve { .. } => DriverError::Disconnected,
        _ => DriverError::Query {
            message: err.to_string(),
            sqlstate: None,
            position: None,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_connection_refused_io_error_during_connect_maps_to_connection_refused() {
        let io = std::io::Error::from(std::io::ErrorKind::ConnectionRefused);
        let error = mongodb::error::Error::from(io);
        assert!(matches!(
            map_mongo_connect_error(error, false),
            DriverError::ConnectionRefused
        ));
    }

    #[test]
    fn a_connection_refused_io_error_during_an_operation_maps_to_disconnected() {
        let io = std::io::Error::from(std::io::ErrorKind::ConnectionRefused);
        let error = mongodb::error::Error::from(io);
        assert!(matches!(map_mongo_error(error), DriverError::Disconnected));
    }

    #[test]
    fn an_unrelated_io_error_is_not_mistaken_for_connection_refused() {
        let io = std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        let error = mongodb::error::Error::from(io);
        assert!(matches!(map_mongo_error(error), DriverError::Query { .. }));
    }

    #[test]
    fn unexpected_transport_loss_is_reported_as_disconnected() {
        for kind in [
            std::io::ErrorKind::ConnectionReset,
            std::io::ErrorKind::UnexpectedEof,
            std::io::ErrorKind::BrokenPipe,
        ] {
            let io = std::io::Error::new(kind, "MongoDB server closed the connection");
            let mapped = map_mongo_error(mongodb::error::Error::from(io));
            assert!(matches!(mapped, DriverError::Disconnected), "{kind:?}: {mapped:?}");
        }
    }

    /// The mongodb error's own Display prints only the io error's message,
    /// not the chain behind it, so a handshake cause one layer deeper is
    /// lost unless the Io box is walked as its own chain.
    #[test]
    fn a_handshake_cause_nested_under_the_io_error_still_reaches_the_text() {
        #[derive(Debug)]
        struct Handshake;

        impl std::fmt::Display for Handshake {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("invalid peer certificate: NotValidForName")
            }
        }

        impl std::error::Error for Handshake {}

        #[derive(Debug)]
        struct Transport(Handshake);

        impl std::fmt::Display for Transport {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("transport closed")
            }
        }

        impl std::error::Error for Transport {
            fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
                Some(&self.0)
            }
        }

        let io = std::io::Error::other(Transport(Handshake));
        let err = mongodb::error::Error::from(io);

        let text = error_chain_text(&err);
        assert!(
            looks_like_tls_failure(&text),
            "the nested handshake cause must survive into the chain: {text}"
        );
        assert!(
            !looks_like_tls_failure(&tablepro_core::error_chain_text(&err)),
            "this case is only reachable by walking the Io box"
        );
    }

    #[test]
    fn a_certificate_name_mismatch_io_error_maps_to_tls() {
        let io = std::io::Error::other("invalid peer certificate: certificate not valid for name \"127.0.0.1\"");
        let mapped = map_mongo_error(mongodb::error::Error::from(io));
        assert!(matches!(mapped, DriverError::Tls(detail) if detail.contains("certificate")));
    }

    #[test]
    fn a_connection_refused_carrying_a_name_mismatch_maps_to_tls() {
        let io = std::io::Error::new(
            std::io::ErrorKind::ConnectionRefused,
            "invalid peer certificate: certificate not valid for name \"127.0.0.1\"",
        );
        let mapped = map_mongo_error(mongodb::error::Error::from(io));
        assert!(matches!(mapped, DriverError::Tls(detail) if detail.contains("certificate")));
    }

    #[test]
    fn a_plain_connection_refused_stays_connection_refused_when_verifying() {
        let io = std::io::Error::from(std::io::ErrorKind::ConnectionRefused);
        let mapped = map_mongo_connect_error(mongodb::error::Error::from(io), true);
        assert!(matches!(mapped, DriverError::ConnectionRefused));
    }

    #[test]
    fn verifying_connect_does_not_report_a_hostname_mismatch_as_a_refusal() {
        let io = std::io::Error::new(
            std::io::ErrorKind::ConnectionRefused,
            "invalid peer certificate: NotValidForName",
        );
        let mapped = map_mongo_connect_error(mongodb::error::Error::from(io), true);
        assert!(matches!(
            mapped,
            DriverError::Tls(detail)
                if detail.to_ascii_lowercase().contains("certificate")
                    || detail.to_ascii_lowercase().contains("notvalidforname")
        ));
    }

    #[test]
    fn a_server_selection_timeout_embedding_a_name_mismatch_is_tls() {
        let text = "Server selection timeout: No available servers. Topology: { Type: Unknown, \
                    Servers: [ { Address: 127.0.0.1:27018, Type: Unknown, Error: Kind: I/O error: \
                    invalid peer certificate: certificate not valid for name \"127.0.0.1\" } ] }";
        assert!(looks_like_tls_failure(text));
        assert!(!looks_like_tls_failure(
            "Server selection timeout: No available servers. Topology: { Type: Unknown }"
        ));
    }
}

use std::error::Error as StdError;

use rustls::{CertificateError, Error as RustlsError};
use tablepro_core::TlsFailure;

pub fn classify(error: &(dyn StdError + 'static)) -> Option<(TlsFailure, String)> {
    let mut current: Option<&(dyn StdError + 'static)> = Some(error);
    while let Some(candidate) = current {
        if let Some(rustls_error) = candidate.downcast_ref::<RustlsError>() {
            return Some((failure_for(rustls_error), rustls_error.to_string()));
        }
        current = match candidate.downcast_ref::<std::io::Error>() {
            Some(io_error) => io_error.get_ref().map(|inner| inner as &(dyn StdError + 'static)),
            None => candidate.source(),
        };
    }
    None
}

fn failure_for(error: &RustlsError) -> TlsFailure {
    match error {
        RustlsError::InvalidCertificate(certificate) => match certificate {
            CertificateError::UnknownIssuer => TlsFailure::UnknownIssuer,
            CertificateError::NotValidForName | CertificateError::NotValidForNameContext { .. } => {
                TlsFailure::NameMismatch
            }
            CertificateError::Expired | CertificateError::ExpiredContext { .. } => TlsFailure::Expired,
            CertificateError::NotValidYet | CertificateError::NotValidYetContext { .. } => TlsFailure::NotYetValid,
            CertificateError::Revoked => TlsFailure::Revoked,
            _ => TlsFailure::Other,
        },
        RustlsError::AlertReceived(_) => TlsFailure::HandshakeRejected,
        RustlsError::InvalidMessage(_) => TlsFailure::ServerRefusedTls,
        _ => TlsFailure::Other,
    }
}

#[cfg(test)]
mod tests {
    use std::io;

    use rustls::{AlertDescription, InvalidMessage};
    use thiserror::Error;

    use super::*;

    #[derive(Debug, Error)]
    #[error("connecting failed")]
    struct ConnectFailed(#[source] RustlsError);

    fn failure(error: &(dyn StdError + 'static)) -> Option<TlsFailure> {
        classify(error).map(|(failure, _)| failure)
    }

    #[test]
    fn rustls_error_boxed_in_io_error_reached_via_get_ref() {
        let io_error = io::Error::new(
            io::ErrorKind::InvalidData,
            RustlsError::InvalidCertificate(CertificateError::UnknownIssuer),
        );
        assert_eq!(failure(&io_error), Some(TlsFailure::UnknownIssuer));
        assert_eq!(failure(&io::Error::other("plain")), None);
    }

    #[test]
    fn thiserror_wrapper_source_chain_reaches_rustls_error() {
        let wrapped = ConnectFailed(RustlsError::InvalidCertificate(CertificateError::NotValidForName));
        assert_eq!(failure(&wrapped), Some(TlsFailure::NameMismatch));
    }

    #[test]
    fn mapping_table() {
        let cases = [
            (
                RustlsError::InvalidCertificate(CertificateError::UnknownIssuer),
                TlsFailure::UnknownIssuer,
            ),
            (
                RustlsError::InvalidCertificate(CertificateError::NotValidForName),
                TlsFailure::NameMismatch,
            ),
            (
                RustlsError::InvalidCertificate(CertificateError::Expired),
                TlsFailure::Expired,
            ),
            (
                RustlsError::InvalidCertificate(CertificateError::NotValidYet),
                TlsFailure::NotYetValid,
            ),
            (
                RustlsError::InvalidCertificate(CertificateError::Revoked),
                TlsFailure::Revoked,
            ),
            (
                RustlsError::InvalidCertificate(CertificateError::BadSignature),
                TlsFailure::Other,
            ),
            (
                RustlsError::AlertReceived(AlertDescription::HandshakeFailure),
                TlsFailure::HandshakeRejected,
            ),
            (
                RustlsError::InvalidMessage(InvalidMessage::InvalidContentType),
                TlsFailure::ServerRefusedTls,
            ),
            (RustlsError::DecryptError, TlsFailure::Other),
        ];
        for (error, expected) in cases {
            assert_eq!(failure(&error), Some(expected), "{error:?}");
        }
    }
}

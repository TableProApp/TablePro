use tablepro_core::{DriverError, TlsFailure};
use tablepro_session::ConnectError;

/// The one setting that fixes a TLS failure, when there is one the
/// user can change in the connect dialog.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TlsRemedy {
    ChooseCaCertificate,
    SetServerName,
}

impl TlsRemedy {
    /// The toast button that takes the user to the setting.
    pub fn label(self) -> String {
        match self {
            Self::ChooseCaCertificate => crate::i18n::gettext("Choose CA Certificate…"),
            Self::SetServerName => crate::i18n::gettext("Set TLS Server Name"),
        }
    }
}

/// Only an unknown issuer and a name mismatch are fixed from this side;
/// an expired or revoked certificate is the server's to replace.
pub fn remedy(failure: TlsFailure) -> Option<TlsRemedy> {
    match failure {
        TlsFailure::UnknownIssuer => Some(TlsRemedy::ChooseCaCertificate),
        TlsFailure::NameMismatch => Some(TlsRemedy::SetServerName),
        TlsFailure::Expired
        | TlsFailure::NotYetValid
        | TlsFailure::Revoked
        | TlsFailure::ServerRefusedTls
        | TlsFailure::ServerRequiresTls
        | TlsFailure::HandshakeRejected
        | TlsFailure::CaFileInvalid
        | TlsFailure::ClientIdentityInvalid
        | TlsFailure::Other => None,
    }
}

/// The remedy for a connect that failed on TLS. Setting a server name
/// is offered only where the connect dialog shows that row: MySQL over
/// a direct route checks the host it dials and no other name.
pub fn connect_remedy(error: &ConnectError, server_name_shown: bool) -> Option<TlsRemedy> {
    match error {
        ConnectError::Driver(DriverError::Tls { failure, .. }) => {
            remedy(*failure).filter(|remedy| *remedy != TlsRemedy::SetServerName || server_name_shown)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_issuer_and_name_mismatch_have_actions() {
        assert_eq!(remedy(TlsFailure::UnknownIssuer), Some(TlsRemedy::ChooseCaCertificate));
        assert_eq!(remedy(TlsFailure::NameMismatch), Some(TlsRemedy::SetServerName));
        for failure in [TlsFailure::Expired, TlsFailure::Revoked, TlsFailure::Other] {
            assert_eq!(remedy(failure), None, "{failure:?}");
        }
        assert_ne!(TlsRemedy::ChooseCaCertificate.label(), TlsRemedy::SetServerName.label());
    }

    #[test]
    fn a_connect_error_carries_the_remedy_of_its_tls_failure() {
        let error = ConnectError::Driver(DriverError::Tls {
            failure: TlsFailure::NameMismatch,
            detail: "certificate is for db.internal".to_owned(),
        });

        assert_eq!(connect_remedy(&error, true), Some(TlsRemedy::SetServerName));
        assert_eq!(connect_remedy(&ConnectError::Cancelled, true), None);
    }

    #[test]
    fn a_server_name_is_not_offered_where_the_dialog_hides_its_row() {
        let mismatch = ConnectError::Driver(DriverError::Tls {
            failure: TlsFailure::NameMismatch,
            detail: "certificate is for db.internal".to_owned(),
        });
        let unknown_issuer = ConnectError::Driver(DriverError::Tls {
            failure: TlsFailure::UnknownIssuer,
            detail: "UnknownIssuer".to_owned(),
        });

        assert_eq!(connect_remedy(&mismatch, false), None);
        assert_eq!(
            connect_remedy(&unknown_issuer, false),
            Some(TlsRemedy::ChooseCaCertificate)
        );
    }
}

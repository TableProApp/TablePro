use tablepro_core::TlsFailure;

/// Each TLS failure has a different next step, which is the whole point
/// of telling them apart.
pub(super) fn tls_message(failure: TlsFailure, detail: &str) -> String {
    match failure {
        TlsFailure::UnknownIssuer => crate::i18n::gettext(
            "The server's certificate was signed by an authority this machine does not know. Choose a CA certificate for this connection.",
        ),
        TlsFailure::NameMismatch => crate::i18n::gettext(
            "The server's certificate is for a different name. Set the TLS server name to the one on the certificate.",
        ),
        TlsFailure::Expired => crate::i18n::gettext("The server's certificate has expired."),
        TlsFailure::NotYetValid => crate::i18n::gettext("The server's certificate is not valid yet."),
        TlsFailure::Revoked => crate::i18n::gettext("The server's certificate was revoked."),
        TlsFailure::ServerRefusedTls => crate::i18n::gettext("The server does not accept TLS on this port."),
        TlsFailure::ServerRequiresTls => {
            crate::i18n::gettext("The server requires TLS. Turn TLS on for this connection.")
        }
        TlsFailure::HandshakeRejected => {
            crate::i18n::gettext_f("The server ended the secure handshake: {detail}", &[("detail", detail)])
        }
        TlsFailure::CaFileInvalid => crate::i18n::gettext("The chosen CA certificate file could not be read."),
        TlsFailure::ClientIdentityInvalid => crate::i18n::gettext("The client certificate or key could not be read."),
        TlsFailure::Other => crate::i18n::gettext_f("TLS failed: {detail}", &[("detail", detail)]),
    }
}
